import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/japan_prefectures.dart';
import '../../../core/utils/geocoding_service.dart';
import '../../../shared/widgets/signed_storage_image.dart';
import '../../../shared/widgets/yahe_app_bar.dart';
import '../data/board_repository.dart';
import '../models/board_post_model.dart';

const _capacityOptions = [2, 3, 4, 5, 6, 8, 10, 15, 20, 30, 50, 100];

class CreateBoardPostScreen extends StatefulWidget {
  /// 指定すると編集モードになり、内容を上書き更新する（新規作成はしない）。
  final BoardPostModel? editPost;
  const CreateBoardPostScreen({super.key, this.editPost});

  @override
  State<CreateBoardPostScreen> createState() => _CreateBoardPostScreenState();
}

class _CreateBoardPostScreenState extends State<CreateBoardPostScreen> {
  late final _titleCtrl = TextEditingController(text: widget.editPost?.title);
  late final _detailCtrl = TextEditingController(text: widget.editPost?.detail);
  late final _placeCtrl =
      TextEditingController(text: widget.editPost?.meetingPlaceText);
  late final _routeCtrl =
      TextEditingController(text: widget.editPost?.routeDetail);
  final _searchCtrl = TextEditingController();
  final _mapController = MapController();

  late BoardPostType _postType =
      widget.editPost?.postType ?? BoardPostType.touring;
  late BoardPostMode _mode = widget.editPost?.mode ?? BoardPostMode.smallGroup;
  late BoardVisibility _visibility =
      widget.editPost?.visibility ?? BoardVisibility.open;
  late DateTime? _scheduledAt = widget.editPost?.scheduledAt;
  late String? _prefecture = widget.editPost?.prefecture;
  late int? _capacity = widget.editPost?.capacity;
  late LatLng? _pickedLatLng = (widget.editPost?.meetingLat != null &&
          widget.editPost?.meetingLng != null)
      ? LatLng(widget.editPost!.meetingLat!, widget.editPost!.meetingLng!)
      : null;
  bool _saving = false;
  bool _searching = false;
  List<GeocodingResult> _searchResults = [];
  BoardPostModel? _overlappingPost;
  int _overlapCheckToken = 0;
  final _picker = ImagePicker();
  File? _newImageFile;
  bool _imageRemoved = false;

  bool get _isEditing => widget.editPost != null;

  @override
  void initState() {
    super.initState();
    if (_isEditing) _checkOverlap();
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _detailCtrl.dispose();
    _placeCtrl.dispose();
    _routeCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    try {
      final xFile = await _picker.pickImage(
          source: ImageSource.gallery, imageQuality: 85, maxWidth: 1600);
      if (xFile == null) return;
      setState(() {
        _newImageFile = File(xFile.path);
        _imageRemoved = false;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('写真の選択に失敗しました')));
      }
    }
  }

  void _removeImage() {
    setState(() {
      _newImageFile = null;
      _imageRemoved = true;
    });
  }

  Future<void> _pickDateTime() async {
    final date = await showDatePicker(
      context: context,
      initialDate: DateTime.now().add(const Duration(days: 1)),
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return;
    final time =
        await showTimePicker(context: context, initialTime: TimeOfDay.now());
    if (time == null) return;
    setState(() {
      _scheduledAt =
          DateTime(date.year, date.month, date.day, time.hour, time.minute);
    });
    _checkOverlap();
  }

  Future<void> _searchSpot() async {
    final query = _searchCtrl.text.trim();
    if (query.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() => _searching = true);
    final results = await GeocodingService.search(query);
    if (!mounted) return;
    setState(() {
      _searchResults = results;
      _searching = false;
    });
    if (results.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('見つかりませんでした。別のキーワードでお試しください')),
      );
    }
  }

  void _selectSearchResult(GeocodingResult result) {
    setState(() {
      _pickedLatLng = result.latLng;
      _searchResults = [];
      _searchCtrl.text = result.displayName;
    });
    _mapController.move(result.latLng, 15);
    _checkOverlap();
  }

  /// 同じ日・近い場所（1km以内、または集合場所テキストが一致）で開催予定の
  /// 他の募集がないかを確認し、あれば注意書きを表示する。
  Future<void> _checkOverlap() async {
    final token = ++_overlapCheckToken;
    final scheduledAt = _scheduledAt;
    final placeText = _placeCtrl.text.trim();
    if (scheduledAt == null || (_pickedLatLng == null && placeText.isEmpty)) {
      if (mounted) setState(() => _overlappingPost = null);
      return;
    }

    try {
      final candidates = await BoardRepository().fetchPostsOnDate(
        scheduledAt,
        excludePostId: widget.editPost?.postId,
      );
      if (!mounted || token != _overlapCheckToken) return;

      const distanceCalc = Distance();
      BoardPostModel? match;
      for (final c in candidates) {
        var sameSpot = false;
        if (_pickedLatLng != null &&
            c.meetingLat != null &&
            c.meetingLng != null) {
          final meters = distanceCalc(
              _pickedLatLng!, LatLng(c.meetingLat!, c.meetingLng!));
          if (meters <= 1000) sameSpot = true;
        }
        if (!sameSpot &&
            placeText.isNotEmpty &&
            (c.meetingPlaceText ?? '').trim().isNotEmpty) {
          final a = placeText.toLowerCase();
          final b = c.meetingPlaceText!.trim().toLowerCase();
          if (a == b || a.contains(b) || b.contains(a)) sameSpot = true;
        }
        if (sameSpot) {
          match = c;
          break;
        }
      }
      setState(() => _overlappingPost = match);
    } catch (_) {}
  }

  Future<void> _create() async {
    if (_titleCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('タイトルを入力してください')));
      return;
    }
    setState(() => _saving = true);
    try {
      if (_isEditing) {
        final postId = widget.editPost!.postId;
        String? imagePath = _imageRemoved ? null : widget.editPost?.imagePath;
        if (_newImageFile != null) {
          imagePath =
              await BoardRepository().uploadPostImage(postId, _newImageFile!) ??
                  imagePath;
        }
        await BoardRepository().updatePost(
          postId: postId,
          postType: _postType,
          title: _titleCtrl.text.trim(),
          detail:
              _detailCtrl.text.trim().isEmpty ? null : _detailCtrl.text.trim(),
          mode: _postType == BoardPostType.touring ? _mode : null,
          meetingPlaceText:
              _placeCtrl.text.trim().isEmpty ? null : _placeCtrl.text.trim(),
          meetingLat: _pickedLatLng?.latitude,
          meetingLng: _pickedLatLng?.longitude,
          routeDetail:
              _routeCtrl.text.trim().isEmpty ? null : _routeCtrl.text.trim(),
          scheduledAt: _scheduledAt,
          capacity: _capacity,
          visibility: _visibility,
          prefecture: _prefecture,
          imagePath: imagePath,
        );
      } else {
        final postId = await BoardRepository().createPost(
          postType: _postType,
          title: _titleCtrl.text.trim(),
          detail:
              _detailCtrl.text.trim().isEmpty ? null : _detailCtrl.text.trim(),
          mode: _postType == BoardPostType.touring ? _mode : null,
          meetingPlaceText:
              _placeCtrl.text.trim().isEmpty ? null : _placeCtrl.text.trim(),
          meetingLat: _pickedLatLng?.latitude,
          meetingLng: _pickedLatLng?.longitude,
          routeDetail:
              _routeCtrl.text.trim().isEmpty ? null : _routeCtrl.text.trim(),
          scheduledAt: _scheduledAt,
          capacity: _capacity,
          visibility: _visibility,
          prefecture: _prefecture,
        );
        if (_newImageFile != null) {
          final imagePath =
              await BoardRepository().uploadPostImage(postId, _newImageFile!);
          if (imagePath != null) {
            await BoardRepository().updatePostImage(postId, imagePath);
          }
        }
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${_isEditing ? '更新' : '投稿'}に失敗しました: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: YaheAppBar(title: _isEditing ? '募集を編集' : '募集を投稿'),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text('種類',
              style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          SegmentedButton<BoardPostType>(
            segments: const [
              ButtonSegment(
                  value: BoardPostType.touring, label: Text('ツーリング募集')),
              ButtonSegment(
                  value: BoardPostType.event, label: Text('イベント・オフ会')),
            ],
            selected: {_postType},
            onSelectionChanged: (s) => setState(() => _postType = s.first),
          ),
          if (_postType == BoardPostType.touring) ...[
            const SizedBox(height: 12),
            const Text('規模',
                style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            SegmentedButton<BoardPostMode>(
              segments: const [
                ButtonSegment(
                    value: BoardPostMode.smallGroup, label: Text('少人数')),
                ButtonSegment(
                    value: BoardPostMode.largeGroup, label: Text('大人数')),
              ],
              selected: {_mode},
              onSelectionChanged: (s) => setState(() => _mode = s.first),
            ),
          ],
          const SizedBox(height: 16),
          const Text('写真（任意）',
              style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          _ImagePicker(
            newFile: _newImageFile,
            existingPath: _imageRemoved ? null : widget.editPost?.imagePath,
            onPick: _pickImage,
            onRemove: _removeImage,
          ),
          const SizedBox(height: 16),
          const Text('タイトル',
              style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          TextField(controller: _titleCtrl, maxLength: 60),
          const SizedBox(height: 12),
          const Text('詳細',
              style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          TextField(controller: _detailCtrl, maxLines: 4, maxLength: 500),
          const SizedBox(height: 12),
          const Text('日時',
              style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _pickDateTime,
            icon: const Icon(Icons.event),
            label:
                Text(_scheduledAt == null ? '日時を選択' : _scheduledAt.toString()),
          ),
          const SizedBox(height: 12),
          const Text('開催地域（都道府県）',
              style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: _prefecture,
            decoration: const InputDecoration(hintText: '選択してください'),
            items: [
              for (final p in {
                ...japanPrefectures,
                if (_prefecture != null && _prefecture!.isNotEmpty)
                  _prefecture!,
              })
                DropdownMenuItem(value: p, child: Text(p)),
            ],
            onChanged: (v) => setState(() => _prefecture = v),
          ),
          const SizedBox(height: 4),
          const Text('選択すると、同じ地域を設定したユーザーにおすすめ表示されます',
              style: TextStyle(color: AppColors.textMuted, fontSize: 11)),
          const SizedBox(height: 12),
          const Text('集合場所（テキスト）',
              style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          TextField(
            controller: _placeCtrl,
            decoration: const InputDecoration(hintText: '例：〇〇パーキングエリア'),
            onEditingComplete: _checkOverlap,
            onTapOutside: (_) {
              FocusScope.of(context).unfocus();
              _checkOverlap();
            },
          ),
          const SizedBox(height: 8),
          const Text('地図でスポットを検索して集合場所を指定（任意）',
              style: TextStyle(color: AppColors.textMuted, fontSize: 11)),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  decoration: const InputDecoration(
                    hintText: '例：東京タワー、〇〇サービスエリア',
                    prefixIcon: Icon(Icons.search),
                    isDense: true,
                  ),
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _searchSpot(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                icon: _searching
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.search),
                onPressed: _searching ? null : _searchSpot,
              ),
            ],
          ),
          if (_searchResults.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(top: 6),
              constraints: const BoxConstraints(maxHeight: 200),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.border),
              ),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: _searchResults.length,
                separatorBuilder: (_, __) =>
                    const Divider(height: 1, color: AppColors.border),
                itemBuilder: (context, i) {
                  final r = _searchResults[i];
                  return ListTile(
                    dense: true,
                    leading: const Icon(Icons.place_outlined,
                        color: AppColors.primary),
                    title: Text(r.displayName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13)),
                    onTap: () => _selectSearchResult(r),
                  );
                },
              ),
            ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              height: 180,
              child: FlutterMap(
                mapController: _mapController,
                options: MapOptions(
                  initialCenter:
                      _pickedLatLng ?? const LatLng(35.6812, 139.7671),
                  initialZoom: _pickedLatLng != null ? 15 : 11,
                  onTap: (tapPos, latLng) {
                    setState(() {
                      _pickedLatLng = latLng;
                      _searchResults = [];
                    });
                    _checkOverlap();
                  },
                ),
                children: [
                  TileLayer(
                    urlTemplate:
                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'jp.nozawataiki.yahe',
                  ),
                  if (_pickedLatLng != null)
                    MarkerLayer(markers: [
                      Marker(
                        point: _pickedLatLng!,
                        width: 32,
                        height: 32,
                        child: const Icon(Icons.location_pin,
                            color: AppColors.primary, size: 32),
                      ),
                    ]),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          const Text('地図を直接タップしても集合場所を指定できます',
              style: TextStyle(color: AppColors.textMuted, fontSize: 11)),
          if (_overlappingPost != null) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.warning.withOpacity(0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.warning.withOpacity(0.4)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.warning_amber_rounded,
                      color: AppColors.warning, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '同じ日・近い場所で「${_overlappingPost!.title}」が開催予定です。日程やスポットが重ならないかご確認ください。',
                      style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 12,
                          height: 1.5),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (_postType == BoardPostType.touring) ...[
            const SizedBox(height: 12),
            const Text('ルート（任意）',
                style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            TextField(controller: _routeCtrl, maxLines: 3, maxLength: 300),
          ],
          const SizedBox(height: 12),
          const Text('定員（任意・無制限なら未選択のまま）',
              style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          DropdownButtonFormField<int?>(
            initialValue: _capacity,
            decoration: const InputDecoration(hintText: '無制限'),
            items: [
              const DropdownMenuItem<int?>(value: null, child: Text('無制限')),
              for (final c
                  in {..._capacityOptions, if (_capacity != null) _capacity!}
                      .toList()
                    ..sort())
                DropdownMenuItem<int?>(value: c, child: Text('$c人')),
            ],
            onChanged: (v) => setState(() => _capacity = v),
          ),
          const SizedBox(height: 16),
          const Text('参加方法',
              style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          for (final v in BoardVisibility.values)
            RadioListTile<BoardVisibility>(
              value: v,
              // ignore: deprecated_member_use
              groupValue: _visibility,
              // ignore: deprecated_member_use
              onChanged: (val) =>
                  setState(() => _visibility = val ?? BoardVisibility.open),
              title: Text(v.label),
              subtitle: v == BoardVisibility.inviteOnly
                  ? const Text(
                      '招待制のイベントは、参加者以外には表示されません',
                      style:
                          TextStyle(color: AppColors.textMuted, fontSize: 11),
                    )
                  : null,
              activeColor: AppColors.primary,
              contentPadding: EdgeInsets.zero,
            ),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: _saving ? null : _create,
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : Text(_isEditing ? '更新する' : '投稿する'),
          ),
        ],
      ),
    );
  }
}

class _ImagePicker extends StatelessWidget {
  final File? newFile;
  final String? existingPath;
  final VoidCallback onPick;
  final VoidCallback onRemove;
  const _ImagePicker({
    required this.newFile,
    required this.existingPath,
    required this.onPick,
    required this.onRemove,
  });

  bool get _hasImage =>
      newFile != null || (existingPath != null && existingPath!.isNotEmpty);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPick,
      child: Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Container(
              width: double.infinity,
              height: 160,
              color: AppColors.surfaceCard,
              child: newFile != null
                  ? Image.file(newFile!,
                      width: double.infinity, height: 160, fit: BoxFit.cover)
                  : (existingPath != null && existingPath!.isNotEmpty)
                      ? SignedStorageImage(
                          storedReference: existingPath!,
                          defaultBucket: 'board-photos',
                          width: double.infinity,
                          height: 160,
                          fit: BoxFit.cover,
                        )
                      : const Center(
                          child: Icon(Icons.add_photo_alternate_outlined,
                              color: AppColors.textMuted, size: 36),
                        ),
            ),
          ),
          if (_hasImage)
            Positioned(
              right: 8,
              top: 8,
              child: GestureDetector(
                onTap: onRemove,
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: const BoxDecoration(
                      color: Colors.black54, shape: BoxShape.circle),
                  child: const Icon(Icons.close, color: Colors.white, size: 16),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
