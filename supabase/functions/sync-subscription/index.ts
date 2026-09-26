import { serve } from 'https://deno.land/std@0.224.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

/**
 * 購入直後のクライアント同期（RevenueCat REST で検証してから plan 反映）
 *
 * Authorization: Bearer <user access token>
 * Body: {} （任意で product_id）
 *
 * Secrets: REVENUECAT_SECRET_API_KEY（RevenueCat → API keys → Secret）
 */

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
const RC_SECRET = Deno.env.get('REVENUECAT_SECRET_API_KEY') ?? '';

const PRODUCT_PRICE: Record<string, number> = {
  yahe_nitro_1h: 200,
  yahe_shibu_10: 200,
  yahe_super_nitro_1h: 2000,
  yahe_geki_shibu_10: 2000,
  yahe_gear_plus_24h: 300,
};

const CONSUMABLE_PRODUCTS = new Set(Object.keys(PRODUCT_PRICE));

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: cors() });
  }

  try {
    const authHeader = req.headers.get('Authorization') ?? '';
    const accessToken = authHeader.startsWith('Bearer ')
      ? authHeader.slice(7)
      : '';
    if (!accessToken) return json({ error: 'missing auth' }, 401);
    if (!RC_SECRET) return json({ error: 'server misconfigured' }, 500);

    const body = await req.json().catch(() => ({}));
    const hintProductId = typeof body?.product_id === 'string' ? body.product_id : null;

    const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      global: { headers: { Authorization: `Bearer ${accessToken}` } },
    });
    const {
      data: { user },
      error: userErr,
    } = await userClient.auth.getUser();
    if (userErr || !user) return json({ error: 'unauthorized' }, 401);

    const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
    const { data: profile } = await admin
      .from('users')
      .select('user_id')
      .eq('auth_id', user.id)
      .maybeSingle();
    if (!profile?.user_id) return json({ error: 'profile not found' }, 403);

    const userId = profile.user_id as string;

    const rcRes = await fetch(
      `https://api.revenuecat.com/v1/subscribers/${encodeURIComponent(userId)}`,
      {
        headers: {
          Authorization: `Bearer ${RC_SECRET}`,
          'Content-Type': 'application/json',
        },
      },
    );
    if (!rcRes.ok) {
      const t = await rcRes.text();
      console.error('[sync-subscription] RC error', t);
      return json({ error: 'revenuecat_fetch_failed' }, 502);
    }
    const rc = await rcRes.json();
    const subscriber = rc.subscriber;
    const entitlements = subscriber?.entitlements ?? {};
    const now = Date.now();

    const active = Object.entries(entitlements)
      .filter(([, v]: [string, any]) => {
        if (!v?.expires_date) return true;
        return new Date(v.expires_date).getTime() > now;
      })
      .map(([k]) => k);

    let plan = 'free';
    let trialEndsAt: string | null = null;
    if (active.includes('gear_r')) {
      plan = 'gear_r';
      // 「お試し500円」導入価格(Introductory Offer)期間中は RevenueCat が
      // period_type: 'trial' | 'intro' を返す（Gear+の初月無料と同じ扱い）。
      const e = entitlements.gear_r;
      if (e?.period_type === 'trial' || e?.period_type === 'intro') {
        trialEndsAt = e.expires_date ?? null;
      }
    } else if (active.includes('gear_plus')) {
      plan = 'gear_plus';
      const e = entitlements.gear_plus;
      if (e?.period_type === 'trial' || e?.period_type === 'intro') {
        trialEndsAt = e.expires_date ?? null;
      }
    } else if (active.includes('pit_in')) {
      plan = 'pit_in';
    }

    const { error: syncErr } = await admin.rpc('sync_subscription_plan', {
      p_user_id: userId,
      p_plan: plan,
      p_trial_ends_at: trialEndsAt,
      p_mark_trial_used: plan === 'gear_plus' || plan === 'gear_r',
    });
    if (syncErr) {
      console.error('[sync-subscription] sync', syncErr);
      return json({ error: syncErr.message }, 500);
    }

    // サブスク特典アイテム（ニトロ・渋！等）の即時付与。
    // 今月分を未付与の場合のみ付与するため、毎月1日のcronと二重付与しない。
    if (plan === 'gear_plus' || plan === 'gear_r' || plan === 'pit_in') {
      const { error: grantErr } = await admin.rpc('grant_monthly_items_for_user', {
        p_user_id: userId,
      });
      if (grantErr) {
        console.error('[sync-subscription] item grant', grantErr);
      }
    }

    // 直近の消耗型を原子的付与（txn 冪等 → Webhook との二重付与なし）
    const nonSubs = subscriber?.non_subscriptions ?? {};
    const fulfilled: unknown[] = [];
    for (const [productId, purchases] of Object.entries(nonSubs)) {
      if (!CONSUMABLE_PRODUCTS.has(productId)) continue;
      const list = Array.isArray(purchases) ? purchases : [];
      for (const p of list) {
        const txn = p?.id ? String(p.id) : null;
        if (!txn) continue;
        if (hintProductId && hintProductId !== productId) continue;

        const { data, error } = await admin.rpc('fulfill_consumable_purchase', {
          p_user_id: userId,
          p_product_id: productId,
          p_store_txn_id: txn,
          p_amount_jpy: PRODUCT_PRICE[productId] ?? null,
        });
        if (error) {
          console.error('[sync-subscription] fulfill', error);
          continue;
        }
        fulfilled.push({ productId, txn, data });
      }
    }

    return json({ ok: true, plan, active, fulfilled });
  } catch (e) {
    console.error('[sync-subscription]', e);
    return json({ error: String(e) }, 500);
  }
});

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
