import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/utils/image_crop_helper.dart';
import '../../../shared/widgets/signed_storage_image.dart';
import '../../../shared/widgets/yahe_app_bar.dart';
import '../data/group_repository.dart';
import '../models/group_model.dart';

class CreateGroupScreen extends StatefulWidget {
  final GroupModel? editGroup;
  const CreateGroupScreen({super.key, this.editGroup});

  @override
  State<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends State<CreateGroupScreen> {
  late final _nameCtrl = TextEditingController(text: widget.editGroup?.name);
  late final _descCtrl =
      TextEditingController(text: widget.editGroup?.description);
  late GroupJoinMode _joinMode =
      widget.editGroup?.joinMode ?? GroupJoinMode.open;
  late bool _inviteRestrictedToLeader =
      widget.editGroup?.inviteRestrictedToLeader ?? false;
  final _picker = ImagePicker();
  File? _newIconFile;
  bool _iconRemoved = false;
  bool _saving = false;

  bool get _isEditing => widget.editGroup != null;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickIcon() async {
    try {
      final xFile = await _picker.pickImage(
          source: ImageSource.gallery, imageQuality: 90);
      if (xFile == null) return;
      if (!mounted) return;
      final cropped = await cropSquareImage(context, xFile.path);
      if (cropped == null) return;
      setState(() {
        _newIconFile = cropped;
        _iconRemoved = false;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('写真の選択に失敗しました')));
      }
    }
  }

  void _removeIcon() {
    setState(() {
      _newIconFile = null;
      _iconRemoved = true;
    });
  }

  Future<void> _save() async {
    if (_nameCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('グループ名を入力してください')),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      if (_isEditing) {
        final groupId = widget.editGroup!.groupId;
        String? iconUrl = _iconRemoved ? null : widget.editGroup?.iconUrl;
        if (_newIconFile != null) {
          iconUrl =
              await GroupRepository().uploadGroupIcon(groupId, _newIconFile!) ??
                  iconUrl;
        }
        await GroupRepository().updateGroup(
          groupId: groupId,
          name: _nameCtrl.text.trim(),
          description:
              _descCtrl.text.trim().isEmpty ? null : _descCtrl.text.trim(),
          joinMode: _joinMode,
          iconUrl: iconUrl,
          inviteRestrictedToLeader: _inviteRestrictedToLeader,
        );
      } else {
        final groupId = await GroupRepository().createGroup(
          name: _nameCtrl.text.trim(),
          description:
              _descCtrl.text.trim().isEmpty ? null : _descCtrl.text.trim(),
          joinMode: _joinMode,
          inviteRestrictedToLeader: _inviteRestrictedToLeader,
        );
        if (_newIconFile != null) {
          final iconUrl =
              await GroupRepository().uploadGroupIcon(groupId, _newIconFile!);
          if (iconUrl != null) {
            await GroupRepository().updateGroupIcon(groupId, iconUrl);
          }
        }
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${_isEditing ? '更新' : '作成'}に失敗しました: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final existingIconUrl = _iconRemoved ? null : widget.editGroup?.iconUrl;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: YaheAppBar(title: _isEditing ? 'グループを編集' : 'グループを作成'),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Center(
            child: _GroupIconPicker(
              newFile: _newIconFile,
              existingUrl: existingIconUrl,
              onTap: _pickIcon,
              onRemove: (_newIconFile != null ||
                      (existingIconUrl != null && existingIconUrl.isNotEmpty))
                  ? _removeIcon
                  : null,
            ),
          ),
          const SizedBox(height: 24),
          const Text('グループ名',
              style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          TextField(controller: _nameCtrl, maxLength: 50),
          const SizedBox(height: 12),
          const Text('説明',
              style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          TextField(controller: _descCtrl, maxLines: 4, maxLength: 300),
          const SizedBox(height: 16),
          const Text('参加方法',
              style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          for (final mode in GroupJoinMode.values)
            RadioListTile<GroupJoinMode>(
              value: mode,
              // ignore: deprecated_member_use
              groupValue: _joinMode,
              // ignore: deprecated_member_use
              onChanged: (v) =>
                  setState(() => _joinMode = v ?? GroupJoinMode.open),
              title: Text(mode.label),
              subtitle: Text(
                  switch (mode) {
                    GroupJoinMode.open => '誰でも自由に参加できます',
                    GroupJoinMode.inviteOnly => '招待された人だけが参加できます',
                    GroupJoinMode.approval => '参加申請をオーナーが承認します',
                  },
                  style: const TextStyle(fontSize: 12)),
              activeColor: AppColors.primary,
              contentPadding: EdgeInsets.zero,
            ),
          if (_joinMode == GroupJoinMode.inviteOnly)
            SwitchListTile(
              value: _inviteRestrictedToLeader,
              onChanged: (v) => setState(() => _inviteRestrictedToLeader = v),
              title: const Text('リーダー制にする'),
              subtitle: const Text(
                'オンにすると、メンバーの招待・除名はオーナーとリーダーのみが行えます。\nオフの場合は、メンバー全員が招待・除名できます。',
                style: TextStyle(fontSize: 12),
              ),
              activeColor: AppColors.primary,
              contentPadding: EdgeInsets.zero,
            ),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : Text(_isEditing ? '更新する' : '作成する'),
          ),
        ],
      ),
    );
  }
}

class _GroupIconPicker extends StatelessWidget {
  final File? newFile;
  final String? existingUrl;
  final VoidCallback onTap;
  final VoidCallback? onRemove;
  const _GroupIconPicker(
      {required this.newFile,
      required this.existingUrl,
      required this.onTap,
      this.onRemove});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        children: [
          Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.primary, width: 2),
            ),
            child: ClipOval(child: _content()),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: AppColors.primary,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
              ),
              child:
                  const Icon(Icons.camera_alt, size: 14, color: Colors.white),
            ),
          ),
          if (onRemove != null)
            Positioned(
              left: 0,
              bottom: 0,
              child: GestureDetector(
                onTap: onRemove,
                child: Container(
                  width: 24,
                  height: 24,
                  decoration: const BoxDecoration(
                      color: Colors.black54, shape: BoxShape.circle),
                  child: const Icon(Icons.close, color: Colors.white, size: 14),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _content() {
    if (newFile != null) {
      return Image.file(newFile!, width: 88, height: 88, fit: BoxFit.cover);
    }
    if (existingUrl != null && existingUrl!.isNotEmpty) {
      return SignedStorageImage(
        storedReference: existingUrl!,
        defaultBucket: 'group-photos',
        width: 88,
        height: 88,
        fit: BoxFit.cover,
      );
    }
    return const ColoredBox(
      color: AppColors.surfaceCard,
      child: Icon(Icons.group, color: AppColors.primary, size: 36),
    );
  }
}
