import 'package:flutter/material.dart';
import '../../core/constants/app_colors.dart';

class TermsScreen extends StatelessWidget {
  const TermsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('利用規約')),
      body: const SingleChildScrollView(
        padding: EdgeInsets.all(20),
        child: _LegalContent(sections: _termsSections),
      ),
    );
  }
}

const _termsSections = [
  _Section(
    title: '第1条（適用）',
    body: '本規約は、YAHE（以下「本アプリ」）の利用に関する条件を定めるものです。ユーザーは本規約に同意のうえ、本アプリを利用するものとします。',
  ),
  _Section(
    title: '第2条（利用登録）',
    body: 'ユーザーは、Apple IDまたはGoogleアカウントを使用してログインすることにより、利用登録が完了します。\n\n以下に該当する方は利用登録をお断りする場合があります。\n・虚偽の情報を申告した場合\n・過去に利用停止処分を受けた場合\n・その他、運営が不適切と判断した場合',
  ),
  _Section(
    title: '第3条（禁止事項）',
    body: 'ユーザーは以下の行為を行ってはなりません。\n\n・他のユーザーへの嫌がらせ、誹謗中傷\n・わいせつ・暴力的なコンテンツの投稿\n・他人になりすます行為\n・本アプリの運営を妨害する行為\n・法令に違反する行為\n・本アプリを商業目的で利用する行為（別途許可がある場合を除く）',
  ),
  _Section(
    title: '第4条（位置情報の取り扱い）',
    body: '本アプリはすれ違い検知のために位置情報を使用します。位置情報の座標は、近傍判定のために「最新位置のみ」を一時保存します（直近約10秒の判定に使用）。RLSにより他人からは閲覧できず、検知停止時には削除されます。すれ違い時刻のみが記録されます。\n\nプライバシーゾーン設定エリア内では、すれ違いの記録を行いません。',
  ),
  _Section(
    title: '第5条（免責事項）',
    body: '本アプリは、ユーザー間のトラブルについて一切の責任を負いません。また、本アプリの提供に不具合が生じた場合でも、それによって生じた損害について責任を負いません。',
  ),
  _Section(
    title: '第6条（サービスの変更・停止）',
    body: '運営は、ユーザーへの事前通知なく、本アプリの内容を変更し、または本アプリの提供を停止することができます。',
  ),
  _Section(
    title: '第7条（規約の変更）',
    body: '運営は、必要と判断した場合には、ユーザーに通知することなく本規約を変更することができます。変更後の利用規約は、本アプリ内に掲載した時点から効力を生じます。',
  ),
  _Section(
    title: '第8条（準拠法・裁判管轄）',
    body: '本規約の解釈にあたっては、日本法を準拠法とします。本アプリに関して紛争が生じた場合には、運営の所在地を管轄する裁判所を専属的合意管轄とします。',
  ),
];

class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('プライバシーポリシー')),
      body: const SingleChildScrollView(
        padding: EdgeInsets.all(20),
        child: _LegalContent(sections: _privacySections),
      ),
    );
  }
}

const _privacySections = [
  _Section(
    title: '1. 収集する情報',
    body: '本アプリが収集する情報は以下のとおりです。\n\n【アカウント情報】\n・ニックネーム、居住エリア（任意）、一言コメント（任意）\n・登録したSNSリンク（任意）\n\n【車両情報】\n・メーカー、車種、年式、カスタム内容\n・愛車写真（ナンバープレートは手動で隠してください）\n\n【行動情報】\n・すれ違い時刻（座標は近傍判定のために最新位置のみ一時利用し、他人には閲覧できません）\n・いいね・マッチング履歴',
  ),
  _Section(
    title: '2. 位置情報',
    body: '位置情報はすれ違い検知にのみ使用します。\n\n・GPS座標は近傍判定のために最新位置のみ一時利用します（直近約10秒の判定に使用）\n・RLSにより他人には閲覧できません\n・検知停止時には座標データを削除します\n・すれ違い時刻のみ記録します\n・プライバシーゾーン設定エリア内では検知を行いません\n・バックグラウンドでの位置情報取得はすれ違い検知に限定されます\n・Bluetooth（BLE）ではすれ違い検知のため端末識別子を近傍に送信します。第三者が専用機器で受信する可能性があります',
  ),
  _Section(
    title: '3. 情報の利用目的',
    body: '収集した情報は以下の目的で利用します。\n\n・本アプリのサービス提供\n・すれ違い検知・マッチング機能の提供\n・不正利用の防止\n・サービス改善・統計分析（個人を特定しない形式）',
  ),
  _Section(
    title: '4. 第三者への提供',
    body: '以下の場合を除き、収集した個人情報を第三者に提供することはありません。\n\n・ユーザー本人の同意がある場合\n・法令に基づく場合\n・人の生命・身体・財産の保護のために必要な場合',
  ),
  _Section(
    title: '5. 情報開示の段階',
    body: '他のユーザーへの情報開示は以下の3段階で管理されます。\n\n【段階1：すれ違い直後】\n愛車写真・車種・タグ・すれ違い時刻\n\n【段階2：片方いいね後】\n段階1と同一（追加開示なし）\n\n【段階3：相互いいね後】\nニックネーム・居住エリア（任意）・SNSリンク・コメント',
  ),
  _Section(
    title: '6. 広告',
    body: '本アプリはGoogle AdMobを使用した広告を表示します。広告表示のためにデバイス識別子が使用される場合があります。広告のパーソナライズはデバイスの設定から変更できます。',
  ),
  _Section(
    title: '7. セキュリティ',
    body: 'データの保存にはSupabase（PostgreSQL）を使用しています。Row Level Securityにより、ユーザーは自分のデータのみアクセス可能です。',
  ),
  _Section(
    title: '8. お問い合わせ',
    body: 'プライバシーに関するお問い合わせは、設定画面の「お問い合わせ」からご連絡ください。',
  ),
];

// ============================================================
// 特定商取引法に基づく表記（有料サブスク提供のため必須）
// ============================================================
class CommercialTransactionScreen extends StatelessWidget {
  const CommercialTransactionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('特定商取引法に基づく表記')),
      body: const SingleChildScrollView(
        padding: EdgeInsets.all(20),
        child: _LegalContent(sections: _commerceSections),
      ),
    );
  }
}

const _commerceSections = [
  _Section(
    title: '販売事業者',
    body: '野澤太紀',
  ),
  _Section(
    title: '運営統括責任者',
    body: '野澤太紀',
  ),
  _Section(
    title: '所在地',
    body: 'お問い合わせ先までご請求いただければ、遅滞なく開示いたします。',
  ),
  _Section(
    title: '連絡先',
    body: 'お問い合わせは、設定画面の「お問い合わせ」からご連絡ください。\n\nメール：taiking1.no@gmail.com\n電話番号：ご請求いただければ遅滞なく開示いたします。',
  ),
  _Section(
    title: '販売価格',
    body: '各プランの価格は、アプリ内の購入画面に表示される金額（消費税込み）に準じます。\n\n・Gear+（月額）：購入画面に表示される金額',
  ),
  _Section(
    title: '商品代金以外の必要料金',
    body: 'インターネット接続に必要な通信料はお客様のご負担となります。',
  ),
  _Section(
    title: '支払方法・支払時期',
    body: 'Apple App Store（App内課金）を通じて決済されます。支払時期は各ストアの定めによります。\n\n・サブスクリプションは、期間終了の24時間以上前に解約しない限り自動更新されます。',
  ),
  _Section(
    title: 'サービスの提供時期',
    body: '決済完了後、ただちにご利用いただけます。',
  ),
  _Section(
    title: 'キャンセル・解約・返金',
    body: 'サブスクリプションは、App Storeの「サブスクリプション」管理画面からいつでも解約できます。解約後は次回更新日以降、無料プランに移行します。\n\nデジタルコンテンツの性質上、購入後の返金は原則お受けできません。返金は各ストアの返金ポリシーに従います。',
  ),
];

// 共通ウィジェット
class _LegalContent extends StatelessWidget {
  final List<_Section> sections;
  const _LegalContent({required this.sections});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '最終更新日：2026年5月17日',
          style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
        ),
        const SizedBox(height: 20),
        ...sections.map((s) => Padding(
              padding: const EdgeInsets.only(bottom: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.title,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Text(
                      s.body,
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 13,
                        height: 1.7,
                      ),
                    ),
                  ),
                ],
              ),
            )),
        const SizedBox(height: 40),
      ],
    );
  }
}

class _Section {
  final String title;
  final String body;
  const _Section({required this.title, required this.body});
}
