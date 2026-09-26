import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show RealtimeChannel;
import '../../../core/constants/app_colors.dart';
import '../../../shared/widgets/photo_viewer_screen.dart';
import '../../../shared/widgets/report_dialog.dart';
import '../../../shared/widgets/signed_storage_image.dart';
import '../../../shared/widgets/simple_profile_view_screen.dart';
import '../../../shared/widgets/yahe_app_bar.dart';
import '../../auth/presentation/auth_provider.dart';
import '../../../shared/widgets/invite_to_board_sheet.dart';
import '../../boards/presentation/board_detail_screen.dart';
import '../../profile/data/user_repository.dart' show blockedUserIdsProvider;
import '../data/group_repository.dart';
import '../models/group_message_model.dart';
import 'group_detail_screen.dart';

class GroupChatScreen extends ConsumerStatefulWidget {
  final String groupId;
  final String groupName;
  const GroupChatScreen(
      {super.key, required this.groupId, required this.groupName});

  @override
  ConsumerState<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends ConsumerState<GroupChatScreen> {
  final _repo = GroupRepository();
  final _textCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  List<GroupMessageModel> _messages = [];
  RealtimeChannel? _channel;
  bool _loading = true;
  bool _loadError = false;
  bool _sending = false;
  bool _loadingOlder = false;
  bool _hasMoreOlder = true;

  @override
  void initState() {
    super.initState();
    _load();
    _channel = _repo.subscribeToGroupMessages(widget.groupId, _refresh);
    _scrollCtrl.addListener(_onScroll);
  }

  @override
  void dispose() {
    _channel?.unsubscribe();
    _textCtrl.dispose();
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollCtrl.hasClients || _loadingOlder || !_hasMoreOlder) return;
    if (_scrollCtrl.position.pixels <= 200) {
      _loadOlderMessages();
    }
  }

  Future<void> _loadOlderMessages() async {
    if (_messages.isEmpty) return;
    setState(() => _loadingOlder = true);
    try {
      final older = await _repo.fetchGroupMessages(
        widget.groupId,
        before: _messages.first.createdAt,
      );
      if (!mounted) return;
      final oldExtent =
          _scrollCtrl.hasClients ? _scrollCtrl.position.maxScrollExtent : 0.0;
      final oldOffset = _scrollCtrl.hasClients ? _scrollCtrl.position.pixels : 0.0;
      setState(() {
        if (older.isEmpty) _hasMoreOlder = false;
        _messages = [...older, ..._messages];
        _loadingOlder = false;
      });
      if (older.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!_scrollCtrl.hasClients) return;
          final newExtent = _scrollCtrl.position.maxScrollExtent;
          _scrollCtrl.jumpTo(oldOffset + (newExtent - oldExtent));
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingOlder = false);
    }
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loadError = false);
    try {
      final messages = await _repo.fetchGroupMessages(widget.groupId);
      await _repo.markGroupRead(widget.groupId);
      if (mounted) {
        setState(() {
          _messages = messages;
          _loading = false;
        });
        _scrollToBottom();
      }
    } catch (e) {
      // try/catchが無く、通信断や退会直後のRLS拒否で例外が投げられると
      // _loadingがtrueのまま復帰不能（ローディング固定）になっていた。
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError = true;
        });
      }
    }
  }

  Future<void> _refresh() async {
    try {
      // 毎回全件取り直すと、メッセージ数が多いグループほど新着のたびに
      // 重くなっていたため、既に読み込み済みの続きだけを取得して追記する。
      if (_messages.isEmpty) {
        final messages = await _repo.fetchGroupMessages(widget.groupId);
        if (mounted) setState(() => _messages = messages);
      } else {
        final newer = await _repo.fetchGroupMessages(
          widget.groupId,
          after: _messages.last.createdAt,
        );
        if (newer.isNotEmpty && mounted) {
          final existingIds = _messages.map((m) => m.messageId).toSet();
          final toAppend =
              newer.where((m) => !existingIds.contains(m.messageId));
          setState(() => _messages = [..._messages, ...toAppend]);
        }
      }
      await _repo.markGroupRead(widget.groupId);
      if (mounted) _scrollToBottom();
    } catch (_) {
      // Realtimeコールバックからの呼び出しは誰もawaitしていないため、
      // 例外を投げると未捕捉のFutureエラーになる。ここは失敗しても
      // 次のイベントで再試行されるため静かに無視する。
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _send({String? presetText, bool isQuickReply = false}) async {
    final text = presetText ?? _textCtrl.text.trim();
    if (text.isEmpty) return;
    if (presetText == null) _textCtrl.clear();
    setState(() => _sending = true);
    try {
      await _repo.sendGroupMessage(widget.groupId, text,
          isQuickReply: isQuickReply);
      await _refresh();
    } catch (e) {
      if (mounted) {
        final msg = e.toString().contains('ng_word_detected')
            ? '不適切な可能性がある内容のため送信できませんでした'
            : e.toString().contains('rate_limited')
                ? '送信が集中しています。少し待ってから送信してください'
                : '送信に失敗しました';
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(msg)));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _sendPhoto() async {
    final picked = await ImagePicker().pickMultiImage(imageQuality: 85);
    if (picked.isEmpty) return;
    final myId = ref.read(authNotifierProvider).value?.userId;
    if (myId == null) return;
    setState(() => _sending = true);
    try {
      var failed = 0;
      for (final xFile in picked) {
        try {
          await _repo.sendGroupPhoto(widget.groupId, myId, File(xFile.path));
        } catch (_) {
          failed++;
        }
      }
      await _refresh();
      if (failed > 0 && mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$failed件の写真の送信に失敗しました')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _inviteGroupToBoard() async {
    final myId = ref.read(authNotifierProvider).value?.userId;
    if (myId == null) return;
    final members = await _repo.fetchMembers(widget.groupId);
    final targetIds =
        members.map((m) => m.userId).where((id) => id != myId).toList();
    if (targetIds.isEmpty) return;
    if (!mounted) return;
    await showInviteToBoardSheet(context, ref,
        targetUserIds: targetIds, chatGroupId: widget.groupId);
  }

  @override
  Widget build(BuildContext context) {
    final myId = ref.watch(authNotifierProvider).value?.userId;
    final group = ref.watch(groupDetailProvider(widget.groupId)).value;
    final expiresAt = group?.expiresAt;
    final isExpired = group?.isExpired ?? false;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: YaheAppBar(
        title: widget.groupName,
        // イベント/ツーリング募集から自動作成された参加者チャット(expiresAt != null)は、
        // グループ管理画面（退会・参加モード変更等）を出さない。ここから退会すると
        // イベント自体には参加したままになり（leave_board_postと違い連動しない）、
        // 逆に主催者が参加モードをinvite_only→openに変更すると参加者限定チャットに
        // 部外者が入れてしまう抜け穴になっていたため。イベント自体からの退出は
        // 掲示板の詳細画面（辞退ボタン）で行う。
        actions: [
          if (expiresAt == null)
            IconButton(
              icon: const Icon(Icons.groups_outlined),
              tooltip: 'グループ管理',
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => GroupDetailScreen(groupId: widget.groupId)),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          if (expiresAt != null)
            Container(
              width: double.infinity,
              color: isExpired
                  ? AppColors.error.withOpacity(0.1)
                  : AppColors.warning.withOpacity(0.1),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                isExpired
                    ? 'このチャットは終了しました（新しいメッセージは送れません）'
                    : '期間限定チャットです。${DateFormat('M月d日 HH:mm').format(expiresAt)}に終了します',
                style: TextStyle(
                  color: isExpired ? AppColors.error : AppColors.warning,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          // 募集(イベント/ツーリング)から自動作成された参加者チャットは、
          // 既に特定のイベントに紐づいた期間限定チャットのため、
          // 「イベントに誘う」ボタンは意味を持たない（expiresAtの有無で判定）。
          if (expiresAt == null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _inviteGroupToBoard,
                  icon: const Icon(Icons.event_available_outlined, size: 16),
                  label: const Text('ツーリング・イベントに誘う',
                      style: TextStyle(fontSize: 13)),
                ),
              ),
            ),
          Expanded(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(color: AppColors.primary))
                : _loadError
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('読み込みに失敗しました',
                                style: TextStyle(color: AppColors.textMuted)),
                            const SizedBox(height: 12),
                            OutlinedButton(
                              onPressed: () {
                                setState(() => _loading = true);
                                _load();
                              },
                              child: const Text('再試行'),
                            ),
                          ],
                        ),
                      )
                    : _messages.isEmpty
                        ? const Center(
                            child: Text('まだメッセージがありません',
                                style: TextStyle(color: AppColors.textMuted)))
                        : ListView.builder(
                            controller: _scrollCtrl,
                            padding: const EdgeInsets.all(16),
                            itemCount: _messages.length + (_loadingOlder ? 1 : 0),
                            itemBuilder: (context, i) {
                              if (_loadingOlder && i == 0) {
                                return const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 12),
                                  child: Center(
                                    child: SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: AppColors.primary),
                                    ),
                                  ),
                                );
                              }
                              final index = _loadingOlder ? i - 1 : i;
                              return _GroupMessageBubble(
                                message: _messages[index],
                                isMe: _messages[index].senderId == myId,
                              );
                            },
                          ),
          ),
          SafeArea(
            top: false,
            child: isExpired
                ? const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    child: Text(
                      'このチャットは終了しました',
                      style:
                          TextStyle(color: AppColors.textMuted, fontSize: 13),
                      textAlign: TextAlign.center,
                    ),
                  )
                : Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.photo_camera_outlined,
                              color: AppColors.textMuted),
                          onPressed: _sending ? null : _sendPhoto,
                        ),
                        Expanded(
                          child: TextField(
                            controller: _textCtrl,
                            minLines: 1,
                            maxLines: 4,
                            decoration: const InputDecoration(
                              hintText: 'メッセージを入力',
                              contentPadding: EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 10),
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        IconButton(
                          icon: _sending
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.send,
                                  color: AppColors.primary),
                          onPressed: _sending ? null : () => _send(),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _GroupMessageBubble extends ConsumerWidget {
  final GroupMessageModel message;
  final bool isMe;
  const _GroupMessageBubble({required this.message, required this.isMe});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bgColor = isMe ? AppColors.primary : AppColors.surface;
    final textColor = isMe ? Colors.white : AppColors.textPrimary;

    // ブロック中の相手のメッセージ・プロフィール導線は、グループ共有中でも
    // グレーアウト・非表示にする（多層防御。閲覧権限自体はcan_view_user()側で制御）。
    final blockedIds =
        ref.watch(blockedUserIdsProvider).value ?? const <String>{};
    final isBlockedSender = !isMe && blockedIds.contains(message.senderId);

    final isBoardInvite =
        message.contentType == GroupMessageContentType.boardInvite;
    final isPhoto = message.contentType == GroupMessageContentType.photo;

    Widget content;
    if (message.isDeleted) {
      content = Text('メッセージは削除されました',
          style: TextStyle(
              color: textColor.withOpacity(0.6),
              fontSize: 13,
              fontStyle: FontStyle.italic));
    } else if (isBlockedSender) {
      content = const Text('ブロック中のユーザーのメッセージです',
          style: TextStyle(
              color: AppColors.textMuted, fontSize: 13, fontStyle: FontStyle.italic));
    } else if (isPhoto) {
      content = ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 220, maxHeight: 280),
          child: SignedStorageImage(
            storedReference: message.photoPath ?? '',
            defaultBucket: 'group-chat-photos',
            width: 220,
            fit: BoxFit.contain,
          ),
        ),
      );
    } else if (isBoardInvite) {
      content = Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.event_available_outlined, size: 18, color: textColor),
          const SizedBox(width: 6),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  isMe ? 'グループを誘いました' : 'グループが誘われました',
                  style: TextStyle(
                      color: textColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  message.relatedPostId != null
                      ? (message.body ?? '')
                      : 'この募集は削除されました',
                  style: TextStyle(
                      color: textColor,
                      fontSize: 14,
                      fontWeight: FontWeight.w600),
                ),
                if (message.relatedPostId != null) ...[
                  const SizedBox(height: 2),
                  Text('タップして詳細を見る',
                      style: TextStyle(
                          color: textColor.withOpacity(0.7), fontSize: 11)),
                ],
              ],
            ),
          ),
        ],
      );
    } else {
      content = Text(message.body ?? '',
          style: TextStyle(color: textColor, fontSize: 14, height: 1.4));
    }

    Widget bubble = Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      constraints:
          BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.6),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(14),
        border: isMe ? null : Border.all(color: AppColors.border),
      ),
      child: content,
    );

    VoidCallback? onTap;
    if (!message.isDeleted && !isBlockedSender) {
      if (isBoardInvite && message.relatedPostId != null) {
        onTap = () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) =>
                      BoardDetailScreen(postId: message.relatedPostId!)),
            );
      } else if (isPhoto && message.photoPath != null) {
        onTap = () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => PhotoViewerScreen(
                    storedReference: message.photoPath!,
                    bucket: 'group-chat-photos'),
              ),
            );
      }
    }

    if (!message.isDeleted) {
      bubble = GestureDetector(
        onTap: onTap,
        onLongPress: isMe
            ? () => _showOwnGroupMessageActionSheet(context, message)
            : () => _showGroupMessageReportSheet(context, message),
        child: bubble,
      );
    }

    if (isMe) {
      return Align(alignment: Alignment.centerRight, child: bubble);
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: isBlockedSender
                ? null
                : () => showUserProfile(context, ref, message.senderId),
            child: Padding(
              padding: const EdgeInsets.only(top: 2, right: 8),
              child: _Avatar(
                  avatarUrl: message.senderAvatarUrl,
                  nickname: message.senderNickname ?? 'U'),
            ),
          ),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                GestureDetector(
                  onTap: isBlockedSender
                      ? null
                      : () => showUserProfile(context, ref, message.senderId),
                  child: Padding(
                    padding: const EdgeInsets.only(left: 2, bottom: 2),
                    child: Text(
                      message.senderNickname ?? '名無し',
                      style: const TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 11,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
                bubble,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> _showOwnGroupMessageActionSheet(
    BuildContext context, GroupMessageModel message) async {
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.surface,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.undo, color: AppColors.error),
            title: const Text('送信を取り消す'),
            onTap: () async {
              Navigator.pop(sheetContext);
              try {
                await GroupRepository().unsendGroupMessage(message.messageId,
                    photoPath: message.photoPath);
              } catch (_) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('取り消しに失敗しました')),
                  );
                }
              }
            },
          ),
        ],
      ),
    ),
  );
}

Future<void> _showGroupMessageReportSheet(
    BuildContext context, GroupMessageModel message) async {
  final isPhoto = message.contentType == GroupMessageContentType.photo;
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.surface,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.flag_outlined, color: AppColors.error),
            title: Text(isPhoto ? 'この写真を通報' : 'このメッセージを通報'),
            onTap: () {
              Navigator.pop(sheetContext);
              showReportDialog(
                context,
                targetType: isPhoto ? 'photo' : 'group_message',
                groupMessageId: message.messageId,
              );
            },
          ),
        ],
      ),
    ),
  );
}

class _Avatar extends StatelessWidget {
  final String? avatarUrl;
  final String nickname;
  const _Avatar({this.avatarUrl, required this.nickname});

  @override
  Widget build(BuildContext context) {
    if (avatarUrl != null && avatarUrl!.isNotEmpty) {
      return ClipOval(
        child: SignedStorageImage(
          storedReference: avatarUrl!,
          defaultBucket: 'profile-photos',
          width: 32,
          height: 32,
          fit: BoxFit.cover,
        ),
      );
    }
    return CircleAvatar(
      radius: 16,
      backgroundColor: AppColors.primary.withOpacity(0.15),
      child: Text(
        nickname.isNotEmpty ? nickname.substring(0, 1).toUpperCase() : 'U',
        style: const TextStyle(
            color: AppColors.primary,
            fontSize: 13,
            fontWeight: FontWeight.w800),
      ),
    );
  }
}
