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

    // グループオーナー/イベント主催者を退会前に他のメンバー/参加者へ移譲する。
    // これを行わないと ON DELETE CASCADE で他人の参加履歴・チャット履歴まで
    // 巻き添えで消えてしまう（QA v1.106で発見・修正）。ベストエフォート。
    try {
      await supabase.rpc('prepare_account_deletion');
    } catch (_) {
      // 失敗しても退会処理自体は止めない
    }

    // 可能なら Storage の参照（object名）を先に掃除してから auth.users を削除する
    let storageCleanupCounts: Record<string, number> = {};
    let yaheUserId: string | null = null;
    try {
      const { data: publicUser } = await supabase
        .from('users')
        .select('user_id')
        .eq('auth_id', authUserId)
        .maybeSingle();

      yaheUserId = publicUser?.user_id ?? null;
      if (yaheUserId) {
        storageCleanupCounts = await cleanupStorageBestEffort(supabase, yaheUserId);
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

    // 削除完了確認：public.users 側の行がFKカスケードで実際に消えたかを確認する
    let verified = true;
    if (yaheUserId) {
      try {
        const { count } = await supabase
          .from('users')
          .select('user_id', { count: 'exact', head: true })
          .eq('user_id', yaheUserId);
        verified = (count ?? 0) === 0;
      } catch (_) {
        verified = false;
      }
    }

    return new Response(
      JSON.stringify({ ok: true, verified, storage_cleanup: storageCleanupCounts }),
      { headers: corsHeaders() },
    );
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
): Promise<Record<string, number>> {
  const counts: Record<string, number> = {};

  // profile-photos: ルートおよび userId 配下の avatar_* を削除
  try {
    const bucket = 'profile-photos';
    const roots = ['', yaheUserId];
    let removed = 0;
    for (const prefix of roots) {
      const { data: objects } = await supabase.storage.from(bucket).list(prefix);
      const toRemove = (objects ?? [])
        .map((o: any) => {
          const name = String(o?.name ?? '');
          if (!name) return null;
          if (prefix === '') {
            return name.startsWith(`avatar_${yaheUserId}_`) ? name : null;
          }
          return `${prefix}/${name}`;
        })
        .filter((n: string | null): n is string => n != null);
      if (toRemove.length > 0) {
        await supabase.storage.from(bucket).remove(toRemove);
        removed += toRemove.length;
      }
    }
    counts[bucket] = removed;
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

    // userId フォルダ直下も掃除
    try {
      const { data: folderObjs } = await supabase.storage.from(bucket).list(yaheUserId);
      for (const o of folderObjs ?? []) {
        const name = String(o?.name ?? '');
        if (name) fileNames.add(`${yaheUserId}/${name}`);
      }
    } catch (_) {}

    const names = [...fileNames];
    if (names.length > 0) {
      await supabase.storage.from(bucket).remove(names);
    }
    counts[bucket] = names.length;
  } catch (_) {}

  // chat-photos: {senderUserId}/{filename} 構造なので、フォルダごと削除でよい
  // （このフォルダは本人が送信した写真しか置かれない）
  try {
    const bucket = 'chat-photos';
    const { data: objects } = await supabase.storage.from(bucket).list(yaheUserId);
    const names = (objects ?? [])
      .map((o: any) => String(o?.name ?? ''))
      .filter((n: string) => n.length > 0)
      .map((n: string) => `${yaheUserId}/${n}`);
    if (names.length > 0) {
      await supabase.storage.from(bucket).remove(names);
    }
    counts[bucket] = names.length;
  } catch (_) {}

  // board-photos: board_posts.image_path（本人が主催する投稿分のみ）から抽出
  try {
    const bucket = 'board-photos';
    const { data: posts } = await supabase
      .from('board_posts')
      .select('image_path')
      .eq('organizer_id', yaheUserId)
      .not('image_path', 'is', null);

    const names = new Set<string>();
    for (const p of posts ?? []) {
      const name = extractStorageObjectName(String(p?.image_path ?? ''), bucket);
      if (name) names.add(name);
    }
    if (names.size > 0) {
      await supabase.storage.from(bucket).remove([...names]);
    }
    counts[bucket] = names.size;
  } catch (_) {}

  // group-photos: groups.icon_url（本人がオーナーのグループ分のみ）から抽出
  try {
    const bucket = 'group-photos';
    const { data: groups } = await supabase
      .from('groups')
      .select('icon_url')
      .eq('owner_id', yaheUserId)
      .not('icon_url', 'is', null);

    const names = new Set<string>();
    for (const g of groups ?? []) {
      const name = extractStorageObjectName(String(g?.icon_url ?? ''), bucket);
      if (name) names.add(name);
    }
    if (names.size > 0) {
      await supabase.storage.from(bucket).remove([...names]);
    }
    counts[bucket] = names.size;
  } catch (_) {}

  // group-chat-photos: {group_id}/{filename} の共有フォルダのため、フォルダ
  // ごと削除すると他メンバーの写真まで消えてしまう。group_messages.photo_path
  // WHERE sender_id=本人 で特定できる自分の投稿分のパスのみを個別に削除する。
  try {
    const bucket = 'group-chat-photos';
    const { data: messages } = await supabase
      .from('group_messages')
      .select('photo_path')
      .eq('sender_id', yaheUserId)
      .not('photo_path', 'is', null);

    const names = new Set<string>();
    for (const m of messages ?? []) {
      const name = extractStorageObjectName(String(m?.photo_path ?? ''), bucket);
      if (name) names.add(name);
    }
    if (names.size > 0) {
      await supabase.storage.from(bucket).remove([...names]);
    }
    counts[bucket] = names.size;
  } catch (_) {}

  return counts;
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

