import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show RealtimeChannel;
import '../../../core/constants/app_colors.dart';
import '../../../shared/models/user_model.dart';
import '../../../shared/widgets/invite_to_board_sheet.dart';
import '../../../shared/widgets/photo_viewer_screen.dart';
import '../../../shared/widgets/report_dialog.dart';
import '../../../shared/widgets/signed_storage_image.dart';
import '../../../shared/widgets/yahe_app_bar.dart';
import '../../auth/presentation/auth_provider.dart';
import '../../boards/presentation/board_detail_screen.dart';
import '../../match/data/match_repository.dart';
import '../../match/presentation/match_detail_screen.dart';
import '../../profile/data/user_repository.dart';
import '../../../shared/providers/global_realtime_providers.dart';
import '../data/chat_repository.dart';
import '../models/chat_message_model.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ChatRoomScreen extends ConsumerStatefulWidget {
  final String matchId;
  final String otherUserId;
  final String otherNickname;
  const ChatRoomScreen({
    super.key,
    required this.matchId,
    required this.otherUserId,
    required this.otherNickname,
  });

  @override
  ConsumerState<ChatRoomScreen> createState() => _ChatRoomScreenState();
}

class _ChatRoomScreenState extends ConsumerState<ChatRoomScreen> {
  final _repo = ChatRepository();
  final _textCtrl = TextEditingController();
  final _textFocusNode = FocusNode();
  final _scrollCtrl = ScrollController();
  List<ChatMessageModel> _messages = [];
  String? _threadId;
  RealtimeChannel? _channel;
  bool _loading = true;
  bool _loadError = false;
  bool _sending = false;
  UserModel? _otherUser;
  Timer? _threadPollTimer;
  bool _matchDissolved = false;
  bool _loadingOlder = false;
  bool _hasMoreOlder = true;

  @override
  void initState() {
    super.initState();
    _load();
    _loadOtherUser();
    _loadMatchStatus();
    _scrollCtrl.addListener(_onScroll);
  }

  void _onScroll() {
    // 一番上（過去方向）近くまでスクロールしたら、さらに古いメッセージを読み込む
    if (!_scrollCtrl.hasClients || _loadingOlder || !_hasMoreOlder) return;
    if (_scrollCtrl.position.pixels <= 200) {
      _loadOlderMessages();
    }
  }

  Future<void> _loadOlderMessages() async {
    if (_threadId == null || _messages.isEmpty) return;
    setState(() => _loadingOlder = true);
    try {
      final older = await _repo.fetchMessages(
        _threadId!,
        before: _messages.first.createdAt,
      );
      if (!mounted) return;
      // 先頭に挿入すると、挿入した分だけ既存の表示位置がずれて
      // 読んでいた場所が飛んでしまうため、挿入前後のスクロール量の差分だけ
      // 補正して見た目の位置を維持する。
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

  /// 既に読み込み済みの続きだけを取得して末尾へ追記する
  /// （毎回全件取り直すと履歴が多いマッチほど遅くなるため）。
  Future<void> _appendNewMessages() async {
    if (_threadId == null) return;
    if (_messages.isEmpty) {
      final messages = await _repo.fetchMessages(_threadId!);
      if (mounted) setState(() => _messages = messages);
      return;
    }
    final newer = await _repo.fetchMessages(
      _threadId!,
      after: _messages.last.createdAt,
    );
    if (newer.isEmpty || !mounted) return;
    final existingIds = _messages.map((m) => m.messageId).toSet();
    final toAppend = newer.where((m) => !existingIds.contains(m.messageId));
    setState(() => _messages = [..._messages, ...toAppend]);
  }

  Future<void> _loadMatchStatus() async {
    try {
      final myId = ref.read(authNotifierProvider).value?.userId;
      if (myId == null) return;
      final match = await MatchRepository().fetchMatch(widget.matchId, myId);
      if (mounted) setState(() => _matchDissolved = match?.isDissolved ?? false);
    } catch (_) {}
  }

  Future<void> _dissolveMatch() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('マッチを解除しますか？'),
        content: const Text(
          '解除すると新しいメッセージは送れなくなりますが、これまでのチャット履歴は残ります。'
          '再び相互にいいねすると、同じ相手と再マッチできます。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.error),
            child: const Text('解除する'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await MatchRepository().dissolveMatch(widget.matchId);
      if (mounted) setState(() => _matchDissolved = true);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('マッチを解除しました')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('エラーが発生しました')));
      }
    }
  }

  Future<void> _loadOtherUser() async {
    try {
      final user = await UserRepository().fetchUser(widget.otherUserId);
      if (mounted) setState(() => _otherUser = user);
    } catch (_) {}
  }

  Future<void> _openOtherProfile() async {
    final myId = ref.read(authNotifierProvider).value?.userId;
    if (myId == null) return;
    final match = await MatchRepository().fetchMatch(widget.matchId, myId);
    if (match == null || !mounted) return;
    Navigator.push(context,
        MaterialPageRoute(builder: (_) => MatchDetailScreen(match: match)));
  }

  void _openPhotoHistory() {
    final photos = _messages
        .where((m) =>
            m.contentType == ChatContentType.photo && m.photoPath != null)
        .toList();
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => _PhotoHistoryScreen(photos: photos)),
    );
  }

  Future<void> _blockUser() async {
    final myId = ref.read(authNotifierProvider).value?.userId;
    if (myId == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('ブロックしますか？'),
        content: const Text('このユーザーのすれ違い・マッチが表示されなくなります。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('キャンセル')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.error),
            child: const Text('ブロック'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await UserRepository().block(myId, widget.otherUserId);
      invalidateAfterBlockChange(ref);
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('ブロックしました')));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('エラーが発生しました')));
      }
    }
  }

  @override
  void dispose() {
    _channel?.unsubscribe();
    _threadPollTimer?.cancel();
    _textCtrl.dispose();
    _textFocusNode.dispose();
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    super.dispose();
  }

  // クイック返信は即送信せず、いい感じの下書き文を入力欄に入れて
  // 編集・送信可否を任意にする（そのまま送るボタンではなくする）。
  void _applyQuickReplyDraft(String draft) {
    _textCtrl.text = draft;
    _textCtrl.selection =
        TextSelection.collapsed(offset: _textCtrl.text.length);
    _textFocusNode.requestFocus();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loadError = false);
    try {
      final threadId = await _repo.getThreadId(widget.matchId);
      if (threadId != null) {
        final messages = await _repo.fetchMessages(threadId);
        final myId = ref.read(authNotifierProvider).value?.userId;
        if (myId != null) await _repo.markRead(threadId, myId);
        if (mounted) {
          setState(() {
            _threadId = threadId;
            _messages = messages;
            _loading = false;
          });
          _subscribe(threadId);
          _scrollToBottom();
        }
      } else {
        if (mounted) setState(() => _loading = false);
        // まだどちらも送信しておらずスレッドが無い状態。threadIdが無いと
        // Realtime購読を開始できないため、このままでは相手が先に最初の
        // 1通を送っても自分の画面には気づけなかった（自分が送るまで無反応）。
        // スレッドが作られるまで軽くポーリングして検知する。
        _pollForNewThread();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError = true;
        });
      }
    }
  }

  void _pollForNewThread() {
    _threadPollTimer?.cancel();
    _threadPollTimer =
        Timer.periodic(const Duration(seconds: 5), (timer) async {
      if (!mounted || _threadId != null) {
        timer.cancel();
        return;
      }
      try {
        final threadId = await _repo.getThreadId(widget.matchId);
        if (threadId == null) return;
        timer.cancel();
        final messages = await _repo.fetchMessages(threadId);
        final myId = ref.read(authNotifierProvider).value?.userId;
        if (myId != null) await _repo.markRead(threadId, myId);
        if (!mounted) return;
        setState(() {
          _threadId = threadId;
          _messages = messages;
        });
        _subscribe(threadId);
        _scrollToBottom();
      } catch (_) {
        // 次の周期で再試行する
      }
    });
  }

  void _subscribe(String threadId) {
    _channel?.unsubscribe();
    _channel = _repo.subscribeToThread(threadId, () async {
      await _appendNewMessages();
      final myId = ref.read(authNotifierProvider).value?.userId;
      if (myId != null) await _repo.markRead(threadId, myId);
      if (mounted) _scrollToBottom();
    });
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

  Future<void> _afterSend() async {
    // 初回送信でスレッドが新規作成された場合、threadIdを取得して購読を開始する
    if (_threadId == null) {
      final threadId = await _repo.getThreadId(widget.matchId);
      if (threadId != null && mounted) {
        setState(() => _threadId = threadId);
        _subscribe(threadId);
      }
    }
    if (_threadId != null) {
      await _appendNewMessages();
      _scrollToBottom();
    }
  }

  Future<void> _send(Future<void> Function() sendFn) async {
    setState(() => _sending = true);
    try {
      await sendFn();
      await _afterSend();
    } catch (e, st) {
      debugPrint('[ChatRoom] send failed: $e\n$st');
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

  Future<void> _sendText() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty) return;
    // 送信前に入力欄をクリアすると、NGワード判定やネットワークエラーで
    // 送信に失敗した際に「送信に失敗しました」とだけ出て入力内容が
    // 失われてしまっていた。送信が成功してからクリアする。
    setState(() => _sending = true);
    try {
      await _repo.sendText(widget.matchId, text);
      _textCtrl.clear();
      await _afterSend();
    } catch (e, st) {
      debugPrint('[ChatRoom] send failed: $e\n$st');
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
    final picked = await ImagePicker()
        .pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (picked == null) return;
    final myId = ref.read(authNotifierProvider).value?.userId;
    if (myId == null) return;
    await _send(() => _repo.sendPhoto(widget.matchId, myId, File(picked.path)));
  }

  @override
  Widget build(BuildContext context) {
    final myId = ref.watch(authNotifierProvider).value?.userId;
    final isBlocked =
        (ref.watch(blockedUserIdsProvider).value ?? const <String>{})
            .contains(widget.otherUserId);
    final isBlockedByOther =
        ref.watch(blockedByUserProvider(widget.otherUserId)).value ?? false;
    final contactBlocked = isBlocked || isBlockedByOther;
    final inputDisabled = contactBlocked || _matchDissolved;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: YaheAppBar(
        title: widget.otherNickname,
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            color: AppColors.surface,
            onSelected: (value) {
              if (value == 'photos') _openPhotoHistory();
              if (value == 'block') _blockUser();
              if (value == 'dissolve') _dissolveMatch();
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'photos',
                child: Row(
                  children: [
                    Icon(Icons.photo_library_outlined,
                        color: AppColors.textSecondary, size: 18),
                    SizedBox(width: 10),
                    Text('送信した写真'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: isBlocked ? null : 'block',
                enabled: !isBlocked,
                child: Row(
                  children: [
                    Icon(Icons.block,
                        color:
                            isBlocked ? AppColors.textMuted : AppColors.error,
                        size: 18),
                    const SizedBox(width: 10),
                    Text(
                      isBlocked ? 'ブロック済み' : 'ブロック',
                      style: TextStyle(
                          color: isBlocked
                              ? AppColors.textMuted
                              : AppColors.error),
                    ),
                  ],
                ),
              ),
              if (!_matchDissolved)
                const PopupMenuItem(
                  value: 'dissolve',
                  child: Row(
                    children: [
                      Icon(Icons.heart_broken_outlined,
                          color: AppColors.error, size: 18),
                      SizedBox(width: 10),
                      Text('マッチを解除', style: TextStyle(color: AppColors.error)),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (_matchDissolved)
            Container(
              width: double.infinity,
              color: AppColors.textMuted.withOpacity(0.08),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: const Row(
                children: [
                  Icon(Icons.heart_broken_outlined,
                      color: AppColors.textMuted, size: 16),
                  SizedBox(width: 8),
                  Text(
                    'マッチは解消されています。過去のメッセージのみ閲覧できます',
                    style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 12,
                        fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            )
          else if (contactBlocked)
            Container(
              width: double.infinity,
              color: AppColors.textMuted.withOpacity(0.08),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.block, color: AppColors.textMuted, size: 16),
                  const SizedBox(width: 8),
                  Text(
                    isBlockedByOther ? 'ブロックされています' : 'ブロック中',
                    style: const TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 12,
                        fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          if (!_matchDissolved)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: contactBlocked
                      ? null
                      : () => showInviteToBoardSheet(
                            context,
                            ref,
                            targetUserIds: [widget.otherUserId],
                            chatMatchId: widget.matchId,
                          ),
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
                              final isMe = _messages[index].senderId == myId;
                              return _MessageBubble(
                                message: _messages[index],
                                isMe: isMe,
                                avatarUrl: isMe ? null : _otherUser?.avatarUrl,
                                nickname: isMe ? '' : widget.otherNickname,
                                onTapAvatar: isMe ? null : _openOtherProfile,
                              );
                            },
                          ),
          ),
          if (!inputDisabled)
            _QuickReplyRow(
              onTap: _applyQuickReplyDraft,
            ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: inputDisabled
                  ? Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      alignment: Alignment.center,
                      child: Text(
                        _matchDissolved
                            ? 'マッチが解消されているためメッセージを送信できません'
                            : 'ブロック中のためメッセージを送信できません',
                        style: const TextStyle(
                            color: AppColors.textMuted, fontSize: 13),
                      ),
                    )
                  : Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.photo_camera_outlined,
                              color: AppColors.textMuted),
                          onPressed: _sending ? null : _sendPhoto,
                        ),
                        Expanded(
                          child: TextField(
                            controller: _textCtrl,
                            focusNode: _textFocusNode,
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
                          onPressed: _sending ? null : _sendText,
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

class _QuickReplyRow extends StatelessWidget {
  final ValueChanged<String> onTap;
  const _QuickReplyRow({required this.onTap});

  // ボタンの表示ラベルと、タップ時に入力欄へ入れる下書き文を分ける。
  // そのまま送信するのではなく、ここから編集・送信を任意にする。
  static const _options = [
    (label: '車について聞く', draft: 'お車素敵ですね！どんな車に乗っているんですか？'),
    (label: 'カスタムについて聞く', draft: 'カスタムしている部分にこだわりがあれば教えてください！'),
    (label: '今度走りませんか？', draft: 'もしよければ今度一緒に走りませんか？'),
  ];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: _options.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) => OutlinedButton(
          onPressed: () => onTap(_options[i].draft),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            visualDensity: VisualDensity.compact,
            minimumSize: const Size(0, 0),
          ),
          child: Text(_options[i].label, style: const TextStyle(fontSize: 12)),
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final ChatMessageModel message;
  final bool isMe;
  final String? avatarUrl;
  final String nickname;
  final VoidCallback? onTapAvatar;
  const _MessageBubble({
    required this.message,
    required this.isMe,
    this.avatarUrl,
    this.nickname = '',
    this.onTapAvatar,
  });

  @override
  Widget build(BuildContext context) {
    final bgColor = isMe ? AppColors.primary : AppColors.surface;
    final textColor = isMe ? Colors.white : AppColors.textPrimary;

    Widget content;
    if (message.isDeleted) {
      content = Text('メッセージは削除されました',
          style: TextStyle(
              color: textColor.withOpacity(0.6),
              fontSize: 13,
              fontStyle: FontStyle.italic));
    } else {
    switch (message.contentType) {
      case ChatContentType.photo:
        content = ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220, maxHeight: 280),
            child: SignedStorageImage(
              storedReference: message.photoPath ?? '',
              defaultBucket: 'chat-photos',
              width: 220,
              fit: BoxFit.contain,
            ),
          ),
        );
        break;
      case ChatContentType.sns:
        content = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.link, size: 14, color: textColor),
            const SizedBox(width: 4),
            Text(message.body ?? '',
                style: TextStyle(color: textColor, fontSize: 14)),
          ],
        );
        break;
      case ChatContentType.boardInvite:
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
                    isMe ? '誘いました' : '誘われました',
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
        break;
      case ChatContentType.quickReply:
      case ChatContentType.text:
        content = Text(message.body ?? '',
            style: TextStyle(color: textColor, fontSize: 14, height: 1.4));
        break;
    }
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
    if (!message.isDeleted) {
      if (message.contentType == ChatContentType.boardInvite &&
          message.relatedPostId != null) {
        onTap = () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) =>
                      BoardDetailScreen(postId: message.relatedPostId!)),
            );
      } else if (message.contentType == ChatContentType.photo &&
          message.photoPath != null) {
        onTap = () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => PhotoViewerScreen(
                    storedReference: message.photoPath!,
                    bucket: 'chat-photos'),
              ),
            );
      }
    }

    if (!message.isDeleted) {
      bubble = GestureDetector(
        onTap: onTap,
        onLongPress: isMe
            ? () => _showOwnMessageActionSheet(context, message)
            : () => _showMessageReportSheet(context, message),
        child: bubble,
      );
    }

    if (isMe) {
      return Align(alignment: Alignment.centerRight, child: bubble);
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: onTapAvatar,
          child: Padding(
            padding: const EdgeInsets.only(top: 2, right: 8),
            child: _SenderAvatar(avatarUrl: avatarUrl, nickname: nickname),
          ),
        ),
        Flexible(child: bubble),
      ],
    );
  }
}

Future<void> _showOwnMessageActionSheet(
    BuildContext context, ChatMessageModel message) async {
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
                await ChatRepository().unsendMessage(message.messageId,
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

Future<void> _showMessageReportSheet(
    BuildContext context, ChatMessageModel message) async {
  final isPhoto = message.contentType == ChatContentType.photo;
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
                targetType: isPhoto ? 'photo' : 'chat_message',
                chatMessageId: message.messageId,
              );
            },
          ),
        ],
      ),
    ),
  );
}

class _SenderAvatar extends StatelessWidget {
  final String? avatarUrl;
  final String nickname;
  const _SenderAvatar({this.avatarUrl, required this.nickname});

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

class _PhotoHistoryScreen extends StatelessWidget {
  final List<ChatMessageModel> photos;
  const _PhotoHistoryScreen({required this.photos});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: const YaheAppBar(title: '送信した写真'),
      body: photos.isEmpty
          ? const Center(
              child: Text('まだ写真がありません',
                  style: TextStyle(color: AppColors.textMuted)))
          : GridView.builder(
              padding: const EdgeInsets.all(12),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
              ),
              itemCount: photos.length,
              itemBuilder: (context, i) => ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SignedStorageImage(
                  storedReference: photos[i].photoPath ?? '',
                  defaultBucket: 'chat-photos',
                  fit: BoxFit.cover,
                ),
              ),
            ),
    );
  }
}
