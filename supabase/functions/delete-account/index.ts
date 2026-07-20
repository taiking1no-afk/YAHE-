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

    // 呼び出し元ユーザーを特定するため、JWT を付けた状態で auth.getUser() する。
    // 削除操作は service_role で実行する。
    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
      global: { headers: { Authorization: `Bearer ${accessToken}` } },
    });

    const {
      data: { user },
      error: userErr,
    } = await supabase.auth.getUser();

    if (userErr || !user) {
      return new Response(JSON.stringify({ error: 'failed to resolve user' }), {
        status: 401,
        headers: corsHeaders(),
      });
    }

    const authUserId = user.id;

    // 可能なら Storage の参照（object名）を先に掃除してから auth.users を削除する
    try {
      const { data: publicUser } = await supabase
        .from('users')
        .select('user_id')
        .eq('auth_id', authUserId)
        .maybeSingle();

      const yaheUserId = publicUser?.user_id;
      if (yaheUserId) {
        await cleanupStorageBestEffort(supabase, yaheUserId);
      }
    } catch (_) {
      // storage cleanup はベストエフォート（本体削除を止めない）
    }

    const { error: deleteErr } = await supabase.auth.admin.deleteUser(authUserId);
    if (deleteErr) {
      return new Response(JSON.stringify({ error: String(deleteErr) }), {
        status: 500,
        headers: corsHeaders(),
      });
    }

    return new Response(JSON.stringify({ ok: true }), {
      headers: corsHeaders(),
    });
  } catch (e) {
    console.error('[delete-account]', e);
    return new Response(JSON.stringify({ error: String(e) }), {
      status: 500,
      headers: corsHeaders(),
    });
  }
});

async function cleanupStorageBestEffort(
  supabase: ReturnType<typeof createClient>,
  yaheUserId: string,
) {
  // profile-photos: avatar_{userId}_* の object を削除
  try {
    const { data: avatarObjects } = await supabase.storage.from('profile-photos').list('');
    const toRemove = (avatarObjects ?? [])
      .filter((o: any) => String(o?.name ?? '').startsWith(`avatar_${yaheUserId}_`))
      .map((o: any) => o.name as string);
    if (toRemove.length > 0) {
      await supabase.storage.from('profile-photos').remove(toRemove);
    }
  } catch (_) {}

  // vehicle-photos: vehicles.photos に含まれる参照から object 名を抽出して削除
  try {
    const bucket = 'vehicle-photos';
    const { data: vehicles } = await supabase
      .from('vehicles')
      .select('photos')
      .eq('user_id', yaheUserId);

    const fileNames = new Set<string>();
    for (const v of vehicles ?? []) {
      for (const photoRef of (v?.photos ?? []) as string[]) {
        if (typeof photoRef !== 'string') continue;
        const name = extractStorageObjectName(photoRef, bucket);
        if (name) fileNames.add(name);
      }
    }

    const names = [...fileNames];
    if (names.length > 0) {
      await supabase.storage.from(bucket).remove(names);
    }
  } catch (_) {}
}

function extractStorageObjectName(stored: string, bucket: string): string | null {
  if (stored.startsWith(`${bucket}:`)) {
    return stored.slice(bucket.length + 1);
  }
  try {
    const u = new URL(stored);
    for (const marker of [
      `/object/public/${bucket}/`,
      `/object/sign/${bucket}/`,
      `/object/authenticated/${bucket}/`,
    ]) {
      const idx = u.pathname.indexOf(marker);
      if (idx === -1) continue;
      return decodeURIComponent(u.pathname.slice(idx + marker.length).split('?')[0]);
    }
  } catch {
    if (!stored.includes('://') && !stored.includes(':')) return stored;
  }
  return null;
}

function corsHeaders() {
  return {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Content-Type': 'application/json',
  };
}

