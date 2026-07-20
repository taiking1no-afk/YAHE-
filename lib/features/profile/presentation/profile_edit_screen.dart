import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import '../../../shared/widgets/signed_storage_image.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_constants.dart';
import '../../../shared/models/user_model.dart';
import '../../auth/presentation/auth_provider.dart';
import '../data/user_repository.dart';

final _userRepoProvider = Provider<UserRepository>((ref) => UserRepository());

const _kBadgeNgWords = [
  // 誹謗中傷
  '死ね', '殺す', 'ころす', 'しね', 'くたばれ', 'きもい', 'キモい', 'きしょい',
  'ブス', 'ぶす', 'デブ', 'でぶ', 'ハゲ', 'はげ', 'ゴミ', 'ごみ', 'カス', 'かす',
  'クズ', 'くず', 'バカ', 'ばか', 'アホ', 'あほ', 'ガイジ', 'がいじ', '障害者',
  'キチガイ', 'きちがい', '池沼', 'チビ', 'ちび',
  // 差別・ヘイト
  '在日', 'チョン', 'シナ', 'ニガー', 'nigger', 'negro',
  // 性的表現
  'セックス', 'SEX', 'sex', 'エロ', 'えろ', 'AV', 'アダルト', 'ポルノ',
  'おっぱい', 'ちんこ', 'まんこ', 'オナニー',
  // 犯罪・違法
  '大麻', '覚醒剤', 'コカイン', 'ヘロイン', '麻薬', 'ドラッグ',
  // 詐欺・スパム
  '稼げる', '副業', '投資', '儲かる', 'LINE@', 'ライン@',
  // なりすまし防止
  '公式', '運営', 'YAHE運営', 'YAEH運営', '管理者', 'admin', 'Admin', 'ADMIN',
  'スタッフ', 'サポート',
];

// プラットフォームごとのURL情報
const _platformInfo = {
  'instagram': (
    prefix: 'https://www.instagram.com/',
    hint: 'ユーザー名を入力',
    example: 'yahe_official',
  ),
  'twitter_x': (
    prefix: 'https://x.com/',
    hint: 'ユーザー名を入力',
    example: 'yahe_official',
  ),
  'youtube': (
    prefix: 'https://www.youtube.com/@',
    hint: 'チャンネル名を入力',
    example: 'YaheOfficial',
  ),
  'tiktok': (
    prefix: 'https://www.tiktok.com/@',
    hint: 'ユーザー名を入力',
    example: 'yahe_official',
  ),
  'other': (
    prefix: '',
    hint: 'URLをそのまま入力',
    example: 'https://example.com',
  ),
};

class ProfileEditScreen extends ConsumerStatefulWidget {
  const ProfileEditScreen({super.key});

  @override
  ConsumerState<ProfileEditScreen> createState() => _ProfileEditScreenState();
}

class _ProfileEditScreenState extends ConsumerState<ProfileEditScreen> {
  final _nicknameCtrl = TextEditingController();
  final _areaCtrl = TextEditingController();
  final _commentCtrl = TextEditingController();
  final _badgeLabelCtrl = TextEditingController();
  List<SnsLink> _snsLinks = [];
  File? _newAvatarFile;
  bool _isSaving = false;
  final _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    final user = ref.read(authNotifierProvider).value;
    if (user != null) {
      _nicknameCtrl.text = user.nickname;
      _areaCtrl.text = user.area ?? '';
      _commentCtrl.text = user.comment ?? '';
      _badgeLabelCtrl.text = user.verifiedLabel ?? '';
      _snsLinks = List.from(user.snsLinks);
    }
  }

  @override
  void dispose() {
    _nicknameCtrl.dispose();
    _areaCtrl.dispose();
    _commentCtrl.dispose();
    _badgeLabelCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickAvatar() async {
    try {
      final xFile = await _picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 80,
        maxWidth: 400,   // アバターは小さめでOK
        maxHeight: 400,
      );
      if (xFile == null) return;
      setState(() => _newAvatarFile = File(xFile.path));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('写真の選択に失敗しました')));
      }
    }
  }

  String? _checkBadgeNgWord(String text) {
    final lower = text.toLowerCase();
    for (final ng in _kBadgeNgWords) {
      if (lower.contains(ng.toLowerCase())) return ng;
    }
    return null;
  }

  Future<void> _save() async {
    final user = ref.read(authNotifierProvider).value;
    if (user == null) return;
    if (_nicknameCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ニックネームを入力してください')),
      );
      return;
    }

    // 認証バッジのNGワードチェック
    final badgeText = _badgeLabelCtrl.text.trim();
    if (badgeText.isNotEmpty) {
      final ngWord = _checkBadgeNgWord(badgeText);
      if (ngWord != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('認証バッジに使用できない表現が含まれています：「$ngWord」')),
        );
        return;
      }
    }

    setState(() => _isSaving = true);
    try {
      final repo = ref.read(_userRepoProvider);

      // アバター画像アップロード（失敗してもプロフィール保存は続行）
      String? avatarUrl;
      bool avatarFailed = false;
      if (_newAvatarFile != null) {
        avatarUrl = await repo.uploadAvatar(user.userId, _newAvatarFile!);
        if (avatarUrl == null) avatarFailed = true;
      }

      await repo.updateProfile(
        userId: user.userId,
        nickname: _nicknameCtrl.text.trim(),
        area: _areaCtrl.text.trim(),
        comment: _commentCtrl.text.trim(),
        avatarUrl: avatarUrl,
        snsLinks: _snsLinks,
      );

      // 認証バッジラベルの保存（Gear Rユーザーのみ）
      if (user.isGearR) {
        await repo.updateVerifiedLabel(user.userId, badgeText);
      }

      ref.invalidate(authNotifierProvider);
      if (mounted) {
        if (avatarFailed) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('プロフィールを保存しました（画像のアップロードに失敗しました。Supabase Storage の設定を確認してください）'),
              duration: Duration(seconds: 5),
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('保存しました')),
          );
        }
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存に失敗しました: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('プロフィール編集'),
        actions: [
          TextButton(
            onPressed: _isSaving ? null : _save,
            child: _isSaving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
                  )
                : const Text('保存',
                    style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ─── アバター画像
            _SectionLabel('プロフィール画像'),
            const SizedBox(height: 12),
            _AvatarPicker(
              currentUrl: ref.watch(authNotifierProvider).value?.avatarUrl,
              newFile: _newAvatarFile,
              nickname: ref.watch(authNotifierProvider).value?.nickname ?? '',
              onTap: _pickAvatar,
            ),
            const SizedBox(height: 28),
            _SectionLabel('基本情報'),
            const SizedBox(height: 8),
            _Field(label: 'ニックネーム *', controller: _nicknameCtrl, hint: '例：タイキ'),
            const SizedBox(height: 12),
            _Field(label: '居住エリア（任意）', controller: _areaCtrl, hint: '例：東京都'),
            const SizedBox(height: 12),
            _Field(
              label: '一言コメント（任意）',
              controller: _commentCtrl,
              hint: '例：週末は峠走ってます',
              maxLines: 3,
            ),
            // ─── 認証バッジ（Gear Rのみ）
            if (ref.watch(authNotifierProvider).value?.isGearR == true) ...[
              const SizedBox(height: 28),
              _SectionLabel('認証バッジ'),
              const SizedBox(height: 4),
              const Text(
                'プロフィールに表示される認証ラベルを自由に設定できます',
                style: TextStyle(color: AppColors.textMuted, fontSize: 12),
              ),
              const SizedBox(height: 8),
              // プレビュー
              if (_badgeLabelCtrl.text.trim().isNotEmpty)
                Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF6C63FF).withOpacity(0.08),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFF6C63FF).withOpacity(0.3)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.verified, color: Color(0xFF6C63FF), size: 16),
                      const SizedBox(width: 6),
                      Text(
                        _badgeLabelCtrl.text.trim(),
                        style: const TextStyle(
                          color: Color(0xFF6C63FF),
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              TextField(
                controller: _badgeLabelCtrl,
                style: const TextStyle(color: AppColors.textPrimary),
                maxLength: 20,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  hintText: '例：インフルエンサー、ユーチューバー、ショップ',
                  helperText: '空欄にするとバッジが非表示になります',
                  helperStyle: TextStyle(color: AppColors.textMuted, fontSize: 11),
                ),
              ),
            ],

            const SizedBox(height: 28),

            // ─── SNSリンク
            Row(
              children: [
                const _SectionLabel('SNSリンク'),
                const SizedBox(width: 8),
                Text(
                  '${_snsLinks.length}件',
                  style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'マッチング後に相手に公開されます',
              style: TextStyle(color: AppColors.textMuted, fontSize: 12),
            ),
            const SizedBox(height: 12),

            // 登録済みリンク一覧
            if (_snsLinks.isEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.border),
                ),
                child: const Text(
                  'まだSNSリンクがありません',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              )
            else
              ..._snsLinks.asMap().entries.map((e) => _SnsLinkTile(
                    link: e.value,
                    onRemove: () => setState(() => _snsLinks.removeAt(e.key)),
                  )),

            const SizedBox(height: 10),

            // 追加ボタン
            OutlinedButton.icon(
              onPressed: () => _showAddDialog(context),
              icon: const Icon(Icons.add_link, size: 18),
              label: const Text('SNSアカウントを追加'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(double.infinity, 48),
                side: const BorderSide(color: AppColors.primary),
                foregroundColor: AppColors.primary,
              ),
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  void _showAddDialog(BuildContext context) {
    String selectedPlatform = AppConstants.snsPlatforms.first['key']!;
    final inputCtrl = TextEditingController();
    final labelCtrl = TextEditingController();

    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
            24, 24, 24, MediaQuery.of(ctx).viewInsets.bottom + 32),
        child: StatefulBuilder(
          builder: (ctx, setS) {
            final info = _platformInfo[selectedPlatform]!;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'SNSアカウントを追加',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 16),

                // プラットフォーム選択
                const Text('プラットフォーム',
                    style: TextStyle(color: AppColors.textMuted, fontSize: 12)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: AppConstants.snsPlatforms.map((p) {
                    final isSelected = selectedPlatform == p['key'];
                    return GestureDetector(
                      onTap: () {
                        setS(() {
                          selectedPlatform = p['key']!;
                          inputCtrl.clear();
                        });
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? AppColors.primary.withOpacity(0.1)
                              : AppColors.background,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: isSelected
                                ? AppColors.primary
                                : AppColors.border,
                            width: isSelected ? 1.5 : 1,
                          ),
                        ),
                        child: Text(
                          p['label']!,
                          style: TextStyle(
                            color: isSelected
                                ? AppColors.primary
                                : AppColors.textSecondary,
                            fontWeight: isSelected
                                ? FontWeight.w700
                                : FontWeight.normal,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),

                // URL入力（プラットフォームに合わせてプレフィックス表示）
                Text(
                  selectedPlatform == 'other' ? 'URL' : 'ユーザー名 / URL',
                  style:
                      const TextStyle(color: AppColors.textMuted, fontSize: 12),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: inputCtrl,
                  style: const TextStyle(color: AppColors.textPrimary),
                  keyboardType: info.prefix.isEmpty
                      ? TextInputType.url
                      : TextInputType.text,
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(
                    hintText: info.prefix.isNotEmpty
                        ? info.example
                        : info.hint,
                    prefixText: info.prefix.isNotEmpty ? info.prefix : null,
                    prefixStyle: const TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 13,
                    ),
                  ),
                ),

                const SizedBox(height: 12),

                // 表示名
                const Text('表示名（任意）',
                    style: TextStyle(color: AppColors.textMuted, fontSize: 12)),
                const SizedBox(height: 6),
                TextField(
                  controller: labelCtrl,
                  style: const TextStyle(color: AppColors.textPrimary),
                  decoration: const InputDecoration(
                    hintText: '例：メインアカウント、カスタム専用アカウント',
                  ),
                ),
                const SizedBox(height: 20),

                ElevatedButton(
                  onPressed: () {
                    final input = inputCtrl.text.trim();
                    if (input.isEmpty) return;
                    final url = info.prefix.isNotEmpty
                        ? '${info.prefix}$input'
                        : input;
                    setState(() {
                      _snsLinks.add(SnsLink(
                        platform: selectedPlatform,
                        url: url,
                        label: labelCtrl.text.trim(),
                      ));
                    });
                    Navigator.pop(ctx);
                  },
                  child: const Text('追加'),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(
          color: AppColors.textSecondary,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      );
}

class _Field extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String hint;
  final int maxLines;

  const _Field({
    required this.label,
    required this.controller,
    required this.hint,
    this.maxLines = 1,
  });

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style:
                  const TextStyle(color: AppColors.textMuted, fontSize: 12)),
          const SizedBox(height: 6),
          TextField(
            controller: controller,
            maxLines: maxLines,
            style: const TextStyle(color: AppColors.textPrimary),
            decoration: InputDecoration(hintText: hint),
          ),
        ],
      );
}

class _SnsLinkTile extends StatelessWidget {
  final SnsLink link;
  final VoidCallback onRemove;

  const _SnsLinkTile({required this.link, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    final platformLabel = AppConstants.snsPlatforms
        .firstWhere((p) => p['key'] == link.platform,
            orElse: () => {'label': 'SNS'})['label']!;

    final icon = switch (link.platform) {
      'instagram' => Icons.camera_alt_outlined,
      'twitter_x' => Icons.close,
      'youtube' => Icons.play_circle_outline,
      'tiktok' => Icons.music_note_outlined,
      _ => Icons.link,
    };

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
        leading: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: AppColors.primary.withOpacity(0.1),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: 18, color: AppColors.primary),
        ),
        title: Text(
          link.label.isNotEmpty ? '$platformLabel：${link.label}' : platformLabel,
          style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          link.url,
          style: const TextStyle(color: AppColors.primary, fontSize: 11),
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 開くボタン
            IconButton(
              icon: const Icon(Icons.open_in_new,
                  size: 18, color: AppColors.textMuted),
              onPressed: () async {
                final uri = Uri.tryParse(link.url);
                if (uri != null) {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                }
              },
            ),
            // 削除ボタン
            IconButton(
              icon: const Icon(Icons.delete_outline,
                  size: 18, color: AppColors.error),
              onPressed: onRemove,
            ),
          ],
        ),
      ),
    );
  }
}

class _AvatarPicker extends StatelessWidget {
  final String? currentUrl;
  final File? newFile;
  final String nickname;
  final VoidCallback onTap;

  const _AvatarPicker({
    required this.currentUrl,
    required this.newFile,
    required this.nickname,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: GestureDetector(
        onTap: onTap,
        child: Stack(
          children: [
            // アバター本体
            Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.primary, width: 2),
              ),
              child: ClipOval(child: _avatarContent()),
            ),
            // カメラアイコン（右下）
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: AppColors.primary,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                ),
                child: const Icon(Icons.camera_alt, size: 16, color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _avatarContent() {
    if (newFile != null) {
      return Image.file(newFile!, width: 100, height: 100, fit: BoxFit.cover);
    }
    if (currentUrl != null && currentUrl!.isNotEmpty) {
      return SignedStorageImage(
        storedReference: currentUrl!,
        defaultBucket: 'profile-photos',
        width: 100,
        height: 100,
        fit: BoxFit.cover,
        placeholder: _initials(),
      );
    }
    return _initials();
  }

  Widget _initials() {
    return Container(
      color: AppColors.primary.withOpacity(0.15),
      child: Center(
        child: Text(
          nickname.isNotEmpty ? nickname.substring(0, 1).toUpperCase() : 'U',
          style: const TextStyle(
            color: AppColors.primary,
            fontSize: 38,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    );
  }
}
