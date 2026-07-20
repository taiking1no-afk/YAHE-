import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/constants/app_colors.dart';
import 'auth_provider.dart';

class AuthScreen extends ConsumerWidget {
  const AuthScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authNotifierProvider);
    final isSigningIn = ref.watch(signInInProgressProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: MediaQuery.of(context).size.height -
                  MediaQuery.of(context).padding.top -
                  MediaQuery.of(context).padding.bottom,
            ),
            child: Column(
              children: [
                const SizedBox(height: 48),
                _Logo(),
                const SizedBox(height: 16),
                _Tagline(),
                const SizedBox(height: 48),
                _GoogleSignInButton(
                  enabled: !isSigningIn,
                  onTap: () =>
                      ref.read(authNotifierProvider.notifier).signInWithGoogle(),
                ),
                const SizedBox(height: 12),
                if (defaultTargetPlatform == TargetPlatform.iOS)
                  _AppleSignInButton(
                    enabled: !isSigningIn,
                    onTap: () =>
                        ref.read(authNotifierProvider.notifier).signInWithApple(),
                  ),
                if (isSigningIn) ...[
                  const SizedBox(height: 20),
                  const CircularProgressIndicator(color: AppColors.primary),
                ],
                if (authState.hasError && !isSigningIn)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(
                      'ログインに失敗しました。もう一度お試しください。',
                      style: const TextStyle(color: AppColors.error, fontSize: 13),
                      textAlign: TextAlign.center,
                    ),
                  ),
                const SizedBox(height: 32),
                _PrivacyNote(),
                const SizedBox(height: 32),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Logo extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 80,
          height: 80,
          decoration: BoxDecoration(
            color: AppColors.primary,
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Center(
            child: Text(
              'S',
              style: TextStyle(
                color: Colors.white,
                fontSize: 44,
                fontWeight: FontWeight.w900,
                letterSpacing: -2,
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          'YAHE',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 36,
            fontWeight: FontWeight.w900,
            letterSpacing: 8,
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'すれ違い',
          style: TextStyle(
            color: AppColors.textSecondary,
            fontSize: 16,
            letterSpacing: 4,
          ),
        ),
      ],
    );
  }
}

class _Tagline extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return const Text(
      '公道での偶然の出会いを、\n仲間との繋がりへ。',
      style: TextStyle(
        color: AppColors.textMuted,
        fontSize: 14,
        height: 1.8,
      ),
      textAlign: TextAlign.center,
    );
  }
}

class _GoogleSignInButton extends StatelessWidget {
  final VoidCallback onTap;
  final bool enabled;
  const _GoogleSignInButton({required this.onTap, this.enabled = true});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: OutlinedButton(
        onPressed: enabled ? onTap : null,
        style: OutlinedButton.styleFrom(
          side: const BorderSide(color: AppColors.border),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          backgroundColor: AppColors.surfaceCard,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _GoogleIcon(),
            const SizedBox(width: 12),
            const Text(
              'Googleでログイン',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GoogleIcon extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        border: Border.all(color: AppColors.border),
      ),
      alignment: Alignment.center,
      child: const Text(
        'G',
        style: TextStyle(
          color: Color(0xFF4285F4),
          fontWeight: FontWeight.w900,
          fontSize: 13,
        ),
      ),
    );
  }
}

class _AppleSignInButton extends StatelessWidget {
  final VoidCallback onTap;
  final bool enabled;
  const _AppleSignInButton({required this.onTap, this.enabled = true});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: ElevatedButton(
        onPressed: enabled ? onTap : null,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.white,
          foregroundColor: Colors.black,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: const [
            Icon(Icons.apple, size: 22, color: Colors.black),
            SizedBox(width: 10),
            Text(
              'Appleでログイン',
              style: TextStyle(
                color: Colors.black,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PrivacyNote extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return const Text(
      'ログインすることで利用規約・プライバシーポリシーに同意したことになります',
      style: TextStyle(color: AppColors.textMuted, fontSize: 11),
      textAlign: TextAlign.center,
    );
  }
}
