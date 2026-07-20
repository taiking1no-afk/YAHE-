import '../../features/home/models/passing_target.dart';

class SnsLink {
  final String platform;
  final String url;
  final String label;

  const SnsLink({
    required this.platform,
    required this.url,
    required this.label,
  });

  factory SnsLink.fromJson(Map<String, dynamic> json) => SnsLink(
        platform: json['platform'] as String,
        url: json['url'] as String,
        label: json['label'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'platform': platform,
        'url': url,
        'label': label,
      };
}

class UserModel {
  final String userId;
  final String authId;
  final String nickname;
  final String? area;
  final String? comment;
  final String? avatarUrl;
  final List<SnsLink> snsLinks;
  final bool anonymousMode;
  final String plan; // 'free' | 'pit_in' | 'gear_plus' | 'gear_r'（RevenueCat 購入プラン）
  final DateTime? trialEndsAt; // Gear+ イントロ/無料期間の終了日時
  final DateTime? gearPlusTrialUsedAt; // 初回お試し利用済み
  final String? premiumOverridePlan; // 運営付与プラン
  final DateTime? premiumOverrideExpiresAt;
  final String? premiumOverrideSource; // admin | influencer | test
  final bool isVerified; // Gear R 認証バッジ
  final String? verifiedLabel; // 認証バッジの表示ラベル（Gear R が自由設定）
  final bool isPrivate; // 鍵アカウント（true=鍵あり/相互いいねで開示, false=鍵なし/いいねで即開示）
  final DateTime? birthDate; // 生年月日（年齢確認）
  final DateTime? termsAgreedAt; // 規約同意日時
  final bool isSuspended; // 通報により自動停止されたユーザー
  final PassingTarget passingTarget; // すれ違いたい相手の種別
  final bool encounterTestMode; // テスト時の1日制限緩和（Supabase側フラグ）
  final DateTime createdAt;

  const UserModel({
    required this.userId,
    required this.authId,
    required this.nickname,
    this.area,
    this.comment,
    this.avatarUrl,
    required this.snsLinks,
    required this.anonymousMode,
    this.plan = 'free',
    this.trialEndsAt,
    this.gearPlusTrialUsedAt,
    this.premiumOverridePlan,
    this.premiumOverrideExpiresAt,
    this.premiumOverrideSource,
    this.isVerified = false,
    this.verifiedLabel,
    this.isPrivate = true,
    this.birthDate,
    this.termsAgreedAt,
    this.isSuspended = false,
    this.passingTarget = PassingTarget.both,
    this.encounterTestMode = false,
    required this.createdAt,
  });

  // 年齢確認・規約同意が完了しているか（未完なら入口でゲートする）
  bool get hasCompletedGate => birthDate != null && termsAgreedAt != null;

  bool get _overrideActive =>
      premiumOverridePlan != null &&
      (premiumOverrideExpiresAt == null ||
          premiumOverrideExpiresAt!.isAfter(DateTime.now()));

  /// Gear+ サブスクのイントロ/無料期間中か
  bool get isOnTrial =>
      plan == 'gear_plus' &&
      trialEndsAt != null &&
      trialEndsAt!.isAfter(DateTime.now());

  int? get trialDaysRemaining {
    if (!isOnTrial) return null;
    return trialEndsAt!.difference(DateTime.now()).inDays.clamp(0, 999);
  }

  bool get hasUsedGearPlusTrial => gearPlusTrialUsedAt != null;

  /// 日次ポップアップ対象: 未加入・お試し未利用・運営付与なし
  bool get shouldPromptGearPlusTrial =>
      plan == 'free' &&
      !hasUsedGearPlusTrial &&
      !_overrideActive &&
      effectivePlan == 'free';

  /// 機能制限判定用（購入 / トライアル / 運営付与を統合）
  String get effectivePlan {
    if (plan == 'gear_r' || (_overrideActive && premiumOverridePlan == 'gear_r')) {
      return 'gear_r';
    }
    if (plan == 'gear_plus' ||
        (_overrideActive && premiumOverridePlan == 'gear_plus')) {
      return 'gear_plus';
    }
    return 'free';
  }

  bool get isGearPlus => effectivePlan == 'gear_plus' || effectivePlan == 'gear_r';
  bool get isGearR => effectivePlan == 'gear_r';
  bool get isPremium => effectivePlan != 'free';

  /// 有料購入ではなくトライアル/付与のみでプレミアム利用中
  bool get isPremiumViaGrant => plan == 'free' && _overrideActive;

  factory UserModel.fromJson(Map<String, dynamic> json) => UserModel(
        userId: json['user_id'] as String,
        authId: json['auth_id'] as String,
        nickname: json['nickname'] as String,
        area: json['area'] as String?,
        comment: json['comment'] as String?,
        avatarUrl: json['avatar_url'] as String?,
        snsLinks: (json['sns_links'] as List<dynamic>? ?? [])
            .map((e) => SnsLink.fromJson(e as Map<String, dynamic>))
            .toList(),
        anonymousMode: json['anonymous_mode'] as bool? ?? false,
        plan: json['plan'] as String? ?? 'free',
        trialEndsAt: json['trial_ends_at'] != null
            ? DateTime.tryParse(json['trial_ends_at'] as String)
            : null,
        gearPlusTrialUsedAt: json['gear_plus_trial_used_at'] != null
            ? DateTime.tryParse(json['gear_plus_trial_used_at'] as String)
            : null,
        premiumOverridePlan: json['premium_override_plan'] as String?,
        premiumOverrideExpiresAt: json['premium_override_expires_at'] != null
            ? DateTime.tryParse(json['premium_override_expires_at'] as String)
            : null,
        premiumOverrideSource: json['premium_override_source'] as String?,
        isVerified: json['is_verified'] as bool? ?? false,
        verifiedLabel: json['verified_label'] as String?,
        isPrivate: json['is_private'] as bool? ?? true,
        birthDate: json['birth_date'] != null
            ? DateTime.tryParse(json['birth_date'] as String)
            : null,
        termsAgreedAt: json['terms_agreed_at'] != null
            ? DateTime.tryParse(json['terms_agreed_at'] as String)?.toLocal()
            : null,
        isSuspended: json['is_suspended'] as bool? ?? false,
        passingTarget: PassingTargetX.fromString(json['passing_target'] as String?),
        encounterTestMode: json['encounter_test_mode'] as bool? ?? false,
        createdAt: DateTime.parse(json['created_at'] as String).toLocal(),
      );

  UserModel copyWith({
    String? nickname,
    String? area,
    String? comment,
    String? avatarUrl,
    List<SnsLink>? snsLinks,
    bool? anonymousMode,
    String? plan,
    DateTime? trialEndsAt,
    DateTime? gearPlusTrialUsedAt,
    String? premiumOverridePlan,
    DateTime? premiumOverrideExpiresAt,
    String? premiumOverrideSource,
    bool? isVerified,
    String? verifiedLabel,
    bool? isPrivate,
    DateTime? birthDate,
    DateTime? termsAgreedAt,
    bool? isSuspended,
    PassingTarget? passingTarget,
    bool? encounterTestMode,
  }) =>
      UserModel(
        userId: userId,
        authId: authId,
        nickname: nickname ?? this.nickname,
        area: area ?? this.area,
        comment: comment ?? this.comment,
        avatarUrl: avatarUrl ?? this.avatarUrl,
        snsLinks: snsLinks ?? this.snsLinks,
        anonymousMode: anonymousMode ?? this.anonymousMode,
        plan: plan ?? this.plan,
        trialEndsAt: trialEndsAt ?? this.trialEndsAt,
        gearPlusTrialUsedAt: gearPlusTrialUsedAt ?? this.gearPlusTrialUsedAt,
        premiumOverridePlan: premiumOverridePlan ?? this.premiumOverridePlan,
        premiumOverrideExpiresAt:
            premiumOverrideExpiresAt ?? this.premiumOverrideExpiresAt,
        premiumOverrideSource:
            premiumOverrideSource ?? this.premiumOverrideSource,
        isVerified: isVerified ?? this.isVerified,
        verifiedLabel: verifiedLabel ?? this.verifiedLabel,
        isPrivate: isPrivate ?? this.isPrivate,
        birthDate: birthDate ?? this.birthDate,
        termsAgreedAt: termsAgreedAt ?? this.termsAgreedAt,
        isSuspended: isSuspended ?? this.isSuspended,
        passingTarget: passingTarget ?? this.passingTarget,
        encounterTestMode: encounterTestMode ?? this.encounterTestMode,
        createdAt: createdAt,
      );
}
