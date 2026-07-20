// ============================================================
// Edge Function: ops-alert
// ------------------------------------------------------------
// YAEH 運営アラートの中継 & 自動ヘルスチェック。
//
// 使い方は2通り:
//   1) 通知中継   : 外部(監視・Crashlytics連携など)から POST で
//                   { "title": "...", "message": "...", "level": "warn|error|info" }
//                   を投げると Slack / LINE に転送する。
//   2) ヘルスチェック: POST { "action": "health" } を pg_cron などから
//                   定期実行すると、DBの異常を検知して必要時のみ通知する。
//
// セキュリティ:
//   - x-ops-secret ヘッダ が環境変数 OPS_ALERT_SECRET と一致しないと 401。
//   - DB参照は service_role キーを使用（RLSをバイパスして集計）。
//
// 必要な環境変数 (supabase secrets set ...):
//   OPS_ALERT_SECRET           … この関数を叩くための共有シークレット
//   SUPABASE_URL               … (自動付与)
//   SUPABASE_SERVICE_ROLE_KEY  … (自動付与)
//   SLACK_WEBHOOK_URL          … Slack Incoming Webhook（任意）
//   LINE_NOTIFY_TOKEN          … LINE Notify トークン（任意）
// ============================================================

import { serve } from 'https://deno.land/std@0.224.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const OPS_ALERT_SECRET = Deno.env.get('OPS_ALERT_SECRET') ?? '';
const SLACK_WEBHOOK_URL = Deno.env.get('SLACK_WEBHOOK_URL') ?? '';
const LINE_NOTIFY_TOKEN = Deno.env.get('LINE_NOTIFY_TOKEN') ?? '';

// ---- ヘルスチェックの閾値 ----
const TH_PENDING_REPORTS = 5; // 未処理通報がこの件数を超えたら警告
const TH_CRITICAL_FLAGS = 1; // critical フラグが1件でもあれば警告
const TH_NO_ENCOUNTER_HOURS = 6; // 直近この時間すれ違いが0なら警告（バックエンド停止の疑い）

type Level = 'info' | 'warn' | 'error';

serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors() });

  // --- 認証（共有シークレット） ---
  const secret = req.headers.get('x-ops-secret') ?? '';
  if (!OPS_ALERT_SECRET || secret !== OPS_ALERT_SECRET) {
    return json({ error: 'unauthorized' }, 401);
  }

  let body: Record<string, unknown> = {};
  try {
    body = await req.json();
  } catch {
    // body 無しでも health として扱えるように
  }

  try {
    if (body.action === 'health') {
      const result = await runHealthCheck();
      return json(result);
    }

    // 通知中継モード
    const title = String(body.title ?? 'YAEH アラート');
    const message = String(body.message ?? '');
    const level = (String(body.level ?? 'info') as Level);
    await notify(level, title, message);
    return json({ ok: true });
  } catch (e) {
    console.error('[ops-alert]', e);
    return json({ error: String(e) }, 500);
  }
});

// ============================================================
// ヘルスチェック本体
// ============================================================
async function runHealthCheck() {
  const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
  const issues: string[] = [];

  // 1) 未処理通報の件数
  const { count: pendingReports } = await supabase
    .from('reports')
    .select('*', { count: 'exact', head: true })
    .eq('status', 'pending');
  if ((pendingReports ?? 0) >= TH_PENDING_REPORTS) {
    issues.push(`🚩 未処理の通報が ${pendingReports} 件あります（要確認）`);
  }

  // 2) critical モデレーションフラグ
  const { count: criticalFlags } = await supabase
    .from('moderation_flags')
    .select('*', { count: 'exact', head: true })
    .eq('status', 'open')
    .eq('severity', 'critical');
  if ((criticalFlags ?? 0) >= TH_CRITICAL_FLAGS) {
    issues.push(`🛑 重大(critical)な自動検知フラグが ${criticalFlags} 件あります`);
  }

  // 3) 直近すれ違いが0 = バックエンド停止の疑い
  const since = new Date(Date.now() - TH_NO_ENCOUNTER_HOURS * 3600 * 1000).toISOString();
  const { count: recentEncounters } = await supabase
    .from('encounters')
    .select('*', { count: 'exact', head: true })
    .gt('time', since);
  if ((recentEncounters ?? 0) === 0) {
    issues.push(
      `⚠️ 直近${TH_NO_ENCOUNTER_HOURS}時間すれ違いが0件。検知/バックエンド停止の可能性`,
    );
  }

  if (issues.length > 0) {
    await notify('warn', 'YAEH ヘルスチェック異常', issues.join('\n'));
    return { ok: false, issues, notified: true };
  }
  return { ok: true, issues: [], notified: false };
}

// ============================================================
// 通知（Slack / LINE 両対応 / 設定されている方だけ送る）
// ============================================================
async function notify(level: Level, title: string, message: string) {
  const emoji = level === 'error' ? '🔴' : level === 'warn' ? '🟠' : '🔵';
  const text = `${emoji} *${title}*\n${message}`;

  const tasks: Promise<unknown>[] = [];

  if (SLACK_WEBHOOK_URL) {
    tasks.push(
      fetch(SLACK_WEBHOOK_URL, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ text }),
      }),
    );
  }

  if (LINE_NOTIFY_TOKEN) {
    tasks.push(
      fetch('https://notify-api.line.me/api/notify', {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${LINE_NOTIFY_TOKEN}`,
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: new URLSearchParams({ message: `\n${emoji} ${title}\n${message}` }),
      }),
    );
  }

  if (tasks.length === 0) {
    console.warn('[ops-alert] 通知先(Slack/LINE)が未設定です:', text);
    return;
  }
  await Promise.allSettled(tasks);
}

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), { status, headers: cors() });
}

function cors() {
  return {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers':
      'authorization, x-client-info, apikey, content-type, x-ops-secret',
    'Content-Type': 'application/json',
  };
}
