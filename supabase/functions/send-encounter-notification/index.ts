import { serve } from 'https://deno.land/std@0.224.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders() });
  }

  try {
    const authHeader = req.headers.get('Authorization') ?? '';
    const accessToken = authHeader.startsWith('Bearer ')
      ? authHeader.slice('Bearer '.length)
      : '';

    if (!accessToken) {
      return new Response(JSON.stringify({ error: 'missing auth token' }), {
        status: 401,
        headers: corsHeaders(),
      });
    }

    const { user_a_id, user_b_id, user_b_ids } = await req.json();

    // user_b_ids（複数）優先。後方互換で user_b_id（単数）も引き続き受け付ける。
    const rawTargetIds: unknown[] = Array.isArray(user_b_ids)
      ? user_b_ids
      : user_b_id
        ? [user_b_id]
        : [];

    const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
    const targetIds = [...new Set(rawTargetIds)].filter(
      (id): id is string => typeof id === 'string' && uuidPattern.test(id),
    );

    if (!user_a_id || targetIds.length === 0) {
      return new Response(JSON.stringify({ error: 'missing user ids' }), {
        status: 400,
        headers: corsHeaders(),
      });
    }

    // 集会などでの一斉検知でも1回の呼び出しで収まる上限（クライアント側の
    // バッチ上限やDBのregister_encounters_batch上限と揃えている）
    const MAX_BATCH = 200;
    if (targetIds.length > MAX_BATCH) {
      return new Response(JSON.stringify({ error: 'too many recipients in one batch' }), {
        status: 400,
        headers: corsHeaders(),
      });
    }

    const supabaseAuth = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
      global: { headers: { Authorization: `Bearer ${accessToken}` } },
    });

    const {
      data: { user },
      error: userErr,
    } = await supabaseAuth.auth.getUser();

    if (userErr || !user) {
      return new Response(JSON.stringify({ error: 'unauthorized' }), {
        status: 401,
        headers: corsHeaders(),
      });
    }

    const { data: callerRow, error: callerErr } = await supabaseAuth
      .from('users')
      .select('user_id')
      .eq('auth_id', user.id)
      .maybeSingle();

    if (callerErr || !callerRow?.user_id) {
      return new Response(JSON.stringify({ error: 'caller profile not found' }), {
        status: 403,
        headers: corsHeaders(),
      });
    }

    const callerUserId = callerRow.user_id as string;

    if (callerUserId !== user_a_id) {
      return new Response(JSON.stringify({ error: 'forbidden: caller mismatch' }), {
        status: 403,
        headers: corsHeaders(),
      });
    }

    // 直近5分以内に実際にすれ違い登録された相手だけを対象にする（なりすまし送信防止）。
    // 複数宛先でも1回のクエリでまとめて検証する。
    const sinceIso = new Date(Date.now() - 5 * 60 * 1000).toISOString();
    const orFilter = targetIds
      .map((id) => {
        const sortedA = user_a_id < id ? user_a_id : id;
        const sortedB = user_a_id < id ? id : user_a_id;
        return `and(user_a_id.eq.${sortedA},user_b_id.eq.${sortedB})`;
      })
      .join(',');

    const { data: encounterRows, error: encounterErr } = await supabaseAuth
      .from('encounters')
      .select('user_a_id, user_b_id')
      .or(orFilter)
      .gt('time', sinceIso);

    if (encounterErr) {
      return new Response(JSON.stringify({ error: 'no recent encounter' }), {
        status: 403,
        headers: corsHeaders(),
      });
    }

    const verifiedTargetIds = [
      ...new Set(
        (encounterRows ?? []).map((row) =>
          row.user_a_id === user_a_id ? row.user_b_id : row.user_a_id,
        ),
      ),
    ];

    if (verifiedTargetIds.length === 0) {
      return new Response(JSON.stringify({ skipped: 'no recent encounter with any target' }), {
        headers: corsHeaders(),
      });
    }

    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    const { data: tokenRows } = await supabase
      .from('user_push_tokens')
      .select('user_id, fcm_token')
      .in('user_id', verifiedTargetIds);

    if (!tokenRows || tokenRows.length === 0) {
      return new Response(JSON.stringify({ skipped: 'no fcm token' }), {
        headers: corsHeaders(),
      });
    }

    // Firebaseのアクセストークンは宛先数によらず1回だけ取得して使い回す
    // （集会で一斉に多数へ送る場合でもOAuthラウンドトリップは1回で済む）
    const accessTokenFcm = await getFirebaseAccessToken();
    const results = await Promise.all(
      tokenRows.map((row) =>
        sendFcmPush(row.fcm_token, accessTokenFcm).catch((e) => ({ error: String(e) })),
      ),
    );

    return new Response(JSON.stringify({ ok: true, sent: results.length, results }), {
      headers: corsHeaders(),
    });
  } catch (e) {
    console.error('[send-encounter-notification]', e);
    return new Response(JSON.stringify({ error: String(e) }), {
      status: 500,
      headers: corsHeaders(),
    });
  }
});

const FIREBASE_PROJECT_ID = Deno.env.get('FIREBASE_PROJECT_ID') ?? '';
const FIREBASE_SERVICE_ACCOUNT_JSON = Deno.env.get('FIREBASE_SERVICE_ACCOUNT_JSON') ?? '{}';

async function sendFcmPush(token: string, accessToken: string) {
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
          notification: {
            title: '⚡ YAHEしたよ！',
            body: 'どんな人か確認してみよう 👀',
          },
          data: { type: 'encounter' },
          apns: {
            payload: {
              aps: { sound: 'default', badge: 1 },
            },
          },
          android: {
            priority: 'high',
            notification: { channel_id: 'yahe_encounter' },
          },
        },
      }),
    },
  );
  return await res.json();
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

  const sig = b64urlFromBuffer(sigBuffer);
  const jwt = `${header}.${claim}.${sig}`;

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

function corsHeaders() {
  return {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Content-Type': 'application/json',
  };
}
