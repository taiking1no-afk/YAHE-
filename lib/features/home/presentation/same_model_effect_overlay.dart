import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../core/constants/app_colors.dart';

/// 同車種すれ違いを検知した際に画面を光らせる演出。
/// [SameModelEffectOverlayState.play] を呼ぶと、グロー＋バナーが
/// フェードイン→ホールド→フェードアウトする。
class SameModelEffectOverlay extends StatefulWidget {
  const SameModelEffectOverlay({super.key});

  @override
  State<SameModelEffectOverlay> createState() => SameModelEffectOverlayState();
}

class SameModelEffectOverlayState extends State<SameModelEffectOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );
  late final Animation<double> _opacity = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 0, end: 1), weight: 25),
    TweenSequenceItem(tween: ConstantTween(1), weight: 40),
    TweenSequenceItem(tween: Tween(begin: 1, end: 0), weight: 35),
  ]).animate(_controller);
  late final Animation<double> _scale = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 0.85, end: 1.05), weight: 30),
    TweenSequenceItem(tween: Tween(begin: 1.05, end: 1.0), weight: 70),
  ]).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));

  String _label = '';

  Future<void> play({String label = '同車種だ！'}) async {
    if (_controller.isAnimating) return;
    _label = label;
    HapticFeedback.heavyImpact();
    SystemSound.play(SystemSoundType.alert);
    await _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          if (_opacity.value <= 0) return const SizedBox.shrink();
          return Opacity(
            opacity: _opacity.value,
            child: Stack(
              children: [
                // 画面全体を覆う放射状のグロー
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: Alignment.topCenter,
                        radius: 1.4,
                        colors: [
                          const Color(0xFFFFC107).withOpacity(0.35),
                          const Color(0xFFFFC107).withOpacity(0.0),
                        ],
                      ),
                    ),
                  ),
                ),
                // バナー
                Align(
                  alignment: const Alignment(0, -0.55),
                  child: Transform.scale(
                    scale: _scale.value,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceCard,
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(color: const Color(0xFFFFC107), width: 2),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFFFFC107).withOpacity(0.6),
                            blurRadius: 24,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('✨', style: TextStyle(fontSize: 20)),
                          const SizedBox(width: 8),
                          Text(
                            _label,
                            style: const TextStyle(
                              color: Color(0xFFB28704),
                              fontSize: 18,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(width: 8),
                          const Text('✨', style: TextStyle(fontSize: 20)),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
