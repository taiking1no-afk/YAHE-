import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import '../../core/constants/app_colors.dart';
import 'ad_service.dart';

/// インライン広告カード（タイムライン・マッチリスト埋め込み用）
class InlineBannerAdCard extends StatefulWidget {
  const InlineBannerAdCard({super.key});

  @override
  State<InlineBannerAdCard> createState() => _InlineBannerAdCardState();
}

class _InlineBannerAdCardState extends State<InlineBannerAdCard> {
  BannerAd? _ad;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _loadAd();
  }

  void _loadAd() {
    if (!AdService.canShowAds) return;
    final ad = BannerAd(
      adUnitId: AdService.bannerAdUnitId,
      size: AdSize.banner,
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdLoaded: (_) => setState(() => _loaded = true),
        onAdFailedToLoad: (ad, error) {
          ad.dispose();
          debugPrint('[Ad] failed: $error');
        },
      ),
    );
    ad.load();
    _ad = ad;
  }

  @override
  void dispose() {
    _ad?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded || _ad == null) {
      return const SizedBox(height: 60);
    }
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      height: 60,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      alignment: Alignment.center,
      child: AdWidget(ad: _ad!),
    );
  }
}

/// 画面下部の常時バナー広告
class BottomBannerAd extends StatefulWidget {
  const BottomBannerAd({super.key});

  @override
  State<BottomBannerAd> createState() => _BottomBannerAdState();
}

class _BottomBannerAdState extends State<BottomBannerAd> {
  BannerAd? _ad;
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ad == null) _loadAd();
  }

  Future<void> _loadAd() async {
    if (!AdService.canShowAds) return;
    // アダプティブバナーでデバイス幅に合わせる
    final width = MediaQuery.of(context).size.width.truncate();
    final size = await AdSize.getCurrentOrientationAnchoredAdaptiveBannerAdSize(width);
    if (size == null || !mounted) return;

    final ad = BannerAd(
      adUnitId: AdService.bannerAdUnitId,
      size: size,
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdLoaded: (_) {
          if (mounted) setState(() => _loaded = true);
        },
        onAdFailedToLoad: (ad, error) {
          ad.dispose();
          debugPrint('[BottomAd] failed: $error');
        },
      ),
    );
    await ad.load();
    if (mounted) {
      setState(() => _ad = ad);
    }
  }

  @override
  void dispose() {
    _ad?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded || _ad == null) return const SizedBox.shrink();
    return Container(
      color: AppColors.surface,
      width: double.infinity,
      height: _ad!.size.height.toDouble(),
      alignment: Alignment.center,
      child: AdWidget(ad: _ad!),
    );
  }
}
