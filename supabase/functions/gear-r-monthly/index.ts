// ============================================================
// Edge Function: gear-r-monthly
// ------------------------------------------------------------
// Gear R 購入者へ「前月のアクセス解析レポート」を自動生成し、
// プッシュ通知で連絡する（毎月1日 cron から呼び出し想定）。
//
// POST body:
//   { "action": "deliver" }           … 前月分を生成＋未通知分にプッシュ
//   { "action": "deliver", "year": 2026, "month": 5 }  … 指定月
//
// 認証: x-ops-secret ヘッダ = OPS_ALERT_SECRET
//
// 環境変数:
//   OPS_ALERT_SECRET, SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
//   FIREBASE_PROJECT_ID, FIREBASE_SERVICE_ACCOUNT_JSON
//   SLACK_WEBHOOK_URL（任意・運営向けサマリー）
// ============================================================

import { serve } from 'https://deno.land/std@0.224.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const OPS_ALERT_SECRET = Deno.env.get('OPS_ALERT_SECRET') ?? '';
const SLACK_WEBHOOK_URL = Deno.env.get('SLACK_WEBHOOK_URL') ?? '';
const FIREBASE_PROJECT_ID = Deno.env.get('FIREBASE_PROJECT_ID') ?? '';
const FIREBASE_SERVICE_ACCOUNT_JSON = Deno.env.get('FIREBASE_SERVICE_ACCOUNT_JSON') ?? '{}';

type ReportRow = {
  report_id: string;
  user_id: string;
  nickname: string;
  encounters: number;
  profile_views: number;
  likes_received: number;
  likes_sent: number;
  matches: number;
  push_sent_at: string | null;
};

serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors() });

  const secret = req.headers.get('x-ops-secret') ?? '';
  if (!OPS_ALERT_SECRET || secret !== OPS_ALERT_SECRET) {
    return json({ error: 'unauthorized' }, 401);
  }

  let body: Record<string, unknown> = {};
  try {
    body = await req.json();
  } catch {
    // empty body OK
  }

  if (body.action !== 'deliver') {
    return json({ error: 'unknown action. use { "action": "deliver" }' }, 400);
  }

  try {
    const { year, month } = resolveTargetMonth(body);
    const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

    // 月次アイテム付与（スーパーニトロ+1 / 激渋！+10）
    const { error: itemsErr } = await supabase.rpc('grant_gear_r_monthly_items');
    if (itemsErr) console.warn('[gear-r-monthly] items grant:', itemsErr.message);

    // レポート生成（全 Gear R 購入者）
    const { data: reports, error: genErr } = await supabase.rpc(
      'generate_gear_r_monthly_reports',
      { p_year: year, p_month: month },
    );
    if (genErr) throw new Error(`generate failed: ${genErr.message}`);

    const rows = (reports ?? []) as ReportRow[];
    let pushed = 0;
    let skipped = 0;
    let failed = 0;

    const accessToken = await getFirebaseAccessToken();

    for (const row of rows) {
      if (row.push_sent_at) {
        skipped++;
        continue;
      }

      const { data: tokenRow } = await supabase
        .from('user_push_tokens')
        .select('fcm_token')
        .eq('user_id', row.user_id)
        .maybeSingle();

      const token = tokenRow?.fcm_token as string | undefined;
      if (!token) {
        skipped++;
        continue;
      }

      const title = `📊 ${month}月のアクセスレポート`;
      const bodyText =
        `すれ違い ${row.encounters}回 · プロフィール閲覧 ${row.profile_views}回\n` +
        `いいね ${row.likes_received}件 · マッチ ${row.matches}件\n` +
        `アプリのストアから詳細を確認できます`;

      try {
        await sendFcmPush(token, accessToken, title, bodyText, {
          type: 'gear_r_monthly_report',
          year: String(year),
          month: String(month),
          report_id: row.report_id,
        });

        await supabase.rpc('mark_gear_r_report_pushed', { p_report_id: row.report_id });
        pushed++;
      } catch (e) {
        console.error(`[gear-r-monthly] push failed user=${row.user_id}`, e);
        failed++;
      }
    }

    // 運営向けサマリー（Slack）
    if (SLACK_WEBHOOK_URL) {
      const summary =
        `*Gear R 月次レポート配信完了*\n` +
        `対象: ${year}年${month}月\n` +
        `生成: ${rows.length}件 / プッシュ送信: ${pushed}件 / スキップ: ${skipped}件 / 失敗: ${failed}件`;
      await fetch(SLACK_WEBHOOK_URL, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ text: summary }),
      });
    }

    return json({
      ok: true,
      year,
      month,
      generated: rows.length,
      pushed,
      skipped,
      failed,
    });
  } catch (e) {
    console.error('[gear-r-monthly]', e);
    return json({ error: String(e) }, 500);
  }
});

/** 前月（JST）をデフォルト。body で year/month 指定も可 */
function resolveTargetMonth(body: Record<string, unknown>): { year: number; month: number } {
  if (body.year != null && body.month != null) {
    return { year: Number(body.year), month: Number(body.month) };
  }
  const now = new Date();
  const jst = new Date(now.toLocaleString('en-US', { timeZone: 'Asia/Tokyo' }));
  let y = jst.getFullYear();
  let m = jst.getMonth(); // 0-indexed; 前月
  if (m === 0) {
    y -= 1;
    m = 12;
  }
  return { year: y, month: m };
}

async function sendFcmPush(
  token: string,
  accessToken: string,
  title: string,
  body: string,
  data: Record<string, string>,
) {
  const res = await fetch(
    `https://fcm.googleapis.com/v1/projects/${FIREBASE_PROJECT_ID}/messages:send`,
    {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${accessToken}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        message: {
          token,
          notification: { title, body },
          data,
          apns: { payload: { aps: { sound: 'default', badge: 1 } } },
          android: { priority: 'high', notification: { channel_id: 'yahe_gear_r' } },
        },
      }),
    },
  );
  if (!res.ok) {
    const err = await res.text();
    throw new Error(`FCM error: ${err}`);
  }
}

async function getFirebaseAccessToken(): Promise<string> {
  const sa = JSON.parse(FIREBASE_SERVICE_ACCOUNT_JSON);
  const clientEmail: string = sa.client_email;
  const privateKeyPem: string = sa.private_key;

  const now = Math.floor(Date.now() / 1000);
  const header = b64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
  const claim = b64url(
    JSON.stringify({
      iss: clientEmail,
      sub: clientEmail,
      aud: 'https://oauth2.googleapis.com/token',
      iat: now,
      exp: now + 3600,
      scope: 'https://www.googleapis.com/auth/firebase.messaging',
    }),
  );

  const keyData = await crypto.subtle.importKey(
    'pkcs8',
    pemToBuffer(privateKeyPem),
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign'],
  );

  const sigBuffer = await crypto.subtle.sign(
    'RSASSA-PKCS1-v1_5',
    keyData,
    new TextEncoder().encode(`${header}.${claim}`),
  );

  const jwt = `${header}.${claim}.${b64urlFromBuffer(sigBuffer)}`;

  const tokenRes = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: jwt,
    }),
  });

  const { access_token } = await tokenRes.json();
  return access_token as string;
}

function pemToBuffer(pem: string): ArrayBuffer {
  const b64 = pem.replace(/-----[^-]+-----/g, '').replace(/\s/g, '');
  const binary = atob(b64);
  const buf = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) buf[i] = binary.charCodeAt(i);
  return buf.buffer;
}

function b64url(str: string): string {
  return btoa(str).replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, '');
}

function b64urlFromBuffer(buf: ArrayBuffer): string {
  return btoa(String.fromCharCode(...new Uint8Array(buf)))
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=/g, '');
}

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: cors(),
  });
}

function cors() {
  return {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers':
      'authorization, x-client-info, apikey, content-type, x-ops-secret',
    'Content-Type': 'application/json',
  };
}
