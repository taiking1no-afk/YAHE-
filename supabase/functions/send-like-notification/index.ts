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

    const { to_user_id, is_matched } = await req.json();

    const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
    if (typeof to_user_id !== 'string' || !uuidPattern.test(to_user_id)) {
      return new Response(JSON.stringify({ error: 'missing user id' }), {
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

    if (callerUserId === to_user_id) {
      return new Response(JSON.stringify({ error: 'forbidden: self target' }), {
        status: 403,
        headers: corsHeaders(),
      });
    }

    // 直近5分以内に実際に caller → to_user_id へ「いいね」した記録があるかを検証
    // （なりすまし送信防止。send-encounter-notification と同じ考え方）
    const sinceIso = new Date(Date.now() - 5 * 60 * 1000).toISOString();
    const { data: likeRows, error: likeErr } = await supabaseAuth
      .from('likes')
      .select('like_id, boost_type')
      .eq('from_user_id', callerUserId)
      .eq('to_user_id', to_user_id)
      .gt('created_at', sinceIso)
      .order('created_at', { ascending: false })
      .limit(1);

    if (likeErr || !likeRows || likeRows.length === 0) {
      return new Response(JSON.stringify({ error: 'no recent like from caller' }), {
        status: 403,
        headers: corsHeaders(),
      });
    }

    const boostType = likeRows[0]?.boost_type as string | null;

    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    const { data: tokenRow } = await supabase
      .from('user_push_tokens')
      .select('fcm_token')
      .eq('user_id', to_user_id)
      .maybeSingle();

    if (!tokenRow?.fcm_token) {
      return new Response(JSON.stringify({ skipped: 'no fcm token' }), {
        headers: corsHeaders(),
      });
    }

    const accessTokenFcm = await getFirebaseAccessToken();
    const result = await sendFcmPush(
      tokenRow.fcm_token,
      accessTokenFcm,
      Boolean(is_matched),
      boostType,
    ).catch((e) => ({ error: String(e) }));

    return new Response(JSON.stringify({ ok: true, result }), {
      headers: corsHeaders(),
    });
  } catch (e) {
    console.error('[send-like-notification]', e);
    return new Response(JSON.stringify({ error: String(e) }), {
      status: 500,
      headers: corsHeaders(),
    });
  }
});

const FIREBASE_PROJECT_ID = Deno.env.get('FIREBASE_PROJECT_ID') ?? '';
const FIREBASE_SERVICE_ACCOUNT_JSON = Deno.env.get('FIREBASE_SERVICE_ACCOUNT_JSON') ?? '{}';

async function sendFcmPush(
  token: string,
  accessToken: string,
  isMatched: boolean,
  boostType: string | null,
) {
  const notification = isMatched
    ? { title: '🎉 マッチしました！', body: 'お互いにいいねが届きました。SNSで繋がってみよう。' }
    : boostType === 'geki_shibu'
      ? { title: '🌟 激渋！が届きました', body: '特別ないいねです。どんな人か確認してみよう 👀' }
      : boostType === 'shibu'
        ? { title: '🔥 渋！が届きました', body: '特別ないいねです。どんな人か確認してみよう 👀' }
        : { title: '💛 いいねが届きました', body: 'どんな人か確認してみよう 👀' };

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
          notification,
          data: {
            type: isMatched ? 'match' : 'like',
            ...(boostType ? { boost_type: boostType } : {}),
          },
          apns: {
            payload: {
              aps: { sound: 'default', badge: 1 },
            },
          },
          android: {
            priority: 'high',
            notification: { channel_id: isMatched ? 'yahe_encounter' : 'yahe_like' },
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
