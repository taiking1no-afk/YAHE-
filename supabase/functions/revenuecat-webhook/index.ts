import { serve } from 'https://deno.land/std@0.224.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

/**
 * RevenueCat Webhook → Supabase plan / アイテム同期
 *
 * RevenueCat Dashboard → Integrations → Webhooks
 * URL: https://<project>.supabase.co/functions/v1/revenuecat-webhook
 * Authorization: Bearer <REVENUECAT_WEBHOOK_SECRET>（必須）
 *
 * App User ID はアプリ側で users.user_id を logIn している前提。
 */

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const WEBHOOK_SECRET = Deno.env.get('REVENUECAT_WEBHOOK_SECRET') ?? '';

const PRODUCT_PRICE: Record<string, number> = {
  yahe_nitro_1h: 200,
  yahe_shibu_10: 200,
  yahe_super_nitro_1h: 2000,
  yahe_geki_shibu_10: 2000,
  yahe_gear_plus_24h: 300,
  yahe_pit_in_monthly: 300,
  yahe_gear_plus_monthly: 500,
  yahe_gear_r_monthly: 3000,
};

const CONSUMABLE_PRODUCTS = new Set([
  'yahe_nitro_1h',
  'yahe_shibu_10',
  'yahe_super_nitro_1h',
  'yahe_geki_shibu_10',
  'yahe_gear_plus_24h',
]);

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: cors() });
  }

  try {
    if (!WEBHOOK_SECRET) {
      console.error('[revenuecat-webhook] REVENUECAT_WEBHOOK_SECRET is not set');
      return json({ error: 'server misconfigured' }, 500);
    }

    const auth = req.headers.get('Authorization') ?? '';
    if (auth !== `Bearer ${WEBHOOK_SECRET}`) {
      return json({ error: 'unauthorized' }, 401);
    }

    const body = await req.json();
    const event = body?.event;
    if (!event) return json({ error: 'missing event' }, 400);

    const appUserId = String(event.app_user_id ?? event.original_app_user_id ?? '');
    if (!appUserId || appUserId.startsWith('$RCAnonymousID')) {
      return json({ skipped: 'anonymous or missing app_user_id' });
    }

    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
    const type = String(event.type ?? '');
    const entitlements: Record<string, unknown> = event.entitlement_ids
      ? Object.fromEntries((event.entitlement_ids as string[]).map((id) => [id, true]))
      : {};
    const activeEntitlements = event.subscriber?.entitlements
      ? Object.keys(event.subscriber.entitlements).filter(
          (k) => event.subscriber.entitlements[k]?.expires_date == null
            || new Date(event.subscriber.entitlements[k].expires_date) > new Date(),
        )
      : Object.keys(entitlements);

    const productId = String(event.product_id ?? '');
    const txnId = event.transaction_id
      ? String(event.transaction_id)
      : event.id
        ? String(event.id)
        : null;

    // 消耗型: 原子的 fulfill（txn 冪等）
    if (
      type === 'NON_RENEWING_PURCHASE' ||
      (type === 'INITIAL_PURCHASE' && CONSUMABLE_PRODUCTS.has(productId))
    ) {
      if (!CONSUMABLE_PRODUCTS.has(productId)) {
        return json({ skipped: 'unknown consumable' });
      }
      if (!txnId) {
        return json({ error: 'missing transaction id' }, 400);
      }

      const { data, error } = await supabase.rpc('fulfill_consumable_purchase', {
        p_user_id: appUserId,
        p_product_id: productId,
        p_store_txn_id: txnId,
        p_amount_jpy: PRODUCT_PRICE[productId] ?? null,
      });
      if (error) {
        console.error('[revenuecat-webhook] fulfill error', error);
        return json({ error: error.message }, 500);
      }
      return json({ ok: true, fulfilled: data });
    }

    // サブスク系: 有効エンタイトルメントから plan を決定
    const plan = resolvePlan(activeEntitlements, type, productId);
    let trialEndsAt: string | null = null;
    if (plan === 'gear_plus' && event.expiration_at_ms && event.period_type === 'TRIAL') {
      trialEndsAt = new Date(Number(event.expiration_at_ms)).toISOString();
    }

    const { data, error } = await supabase.rpc('sync_subscription_plan', {
      p_user_id: appUserId,
      p_plan: plan,
      p_trial_ends_at: trialEndsAt,
      p_mark_trial_used: plan === 'gear_plus' || plan === 'gear_r',
    });

    if (error) {
      console.error('[revenuecat-webhook] sync error', error);
      return json({ error: error.message }, 500);
    }

    // サブスク特典アイテムの付与（新規加入・更新・プラン変更時）。
    // 今月分を未付与の場合のみ付与するため、毎月1日のcronと二重付与しない。
    if (
      (plan === 'gear_plus' || plan === 'gear_r' || plan === 'pit_in') &&
      ['INITIAL_PURCHASE', 'RENEWAL', 'PRODUCT_CHANGE'].includes(type)
    ) {
      const { error: grantErr } = await supabase.rpc('grant_monthly_items_for_user', {
        p_user_id: appUserId,
      });
      if (grantErr) {
        console.error('[revenuecat-webhook] item grant', grantErr);
      }
    }

    if (productId && ['INITIAL_PURCHASE', 'RENEWAL', 'PRODUCT_CHANGE'].includes(type) && txnId) {
      await supabase.rpc('record_purchase', {
        p_user_id: appUserId,
        p_product_id: productId,
        p_amount_jpy: PRODUCT_PRICE[productId] ?? null,
        p_store_txn_id: txnId,
      });
    }

    return json({ ok: true, plan, data });
  } catch (e) {
    console.error('[revenuecat-webhook]', e);
    return json({ error: String(e) }, 500);
  }
});

function resolvePlan(active: string[], eventType: string, productId: string): string {
  if (['EXPIRATION', 'EXPIRATION_TRANSFER'].includes(eventType)) {
    if (active.includes('gear_r')) return 'gear_r';
    if (active.includes('gear_plus')) return 'gear_plus';
    if (active.includes('pit_in')) return 'pit_in';
    return 'free';
  }
  if (active.includes('gear_r') || productId.includes('gear_r')) return 'gear_r';
  if (active.includes('gear_plus') || productId.includes('gear_plus_monthly')) return 'gear_plus';
  if (active.includes('pit_in') || productId.includes('pit_in')) return 'pit_in';
  if (['CANCELLATION'].includes(eventType)) {
    if (active.includes('gear_r')) return 'gear_r';
    if (active.includes('gear_plus')) return 'gear_plus';
    if (active.includes('pit_in')) return 'pit_in';
  }
  return 'free';
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: cors() });
}

function cors() {
  return {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Content-Type': 'application/json',
  };
}
