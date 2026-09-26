import 'dart:math';
import 'package:flutter/material.dart';
import '../../features/ads/banner_ad_widget.dart';

/// 2列グリッド表示に、リスト表示と同じ間隔（2〜5件ごと）で広告を挟み込む。
/// 広告はグリッドセルの中ではなく、前後のカード群とは別の全幅の行として挿入する
/// （バナー広告は横長のため、狭い1セルに収めると潰れて見えてしまうため）。
List<Widget> buildAdInterleavedGridSlivers<T>({
  required List<T> items,
  required Widget Function(BuildContext context, T item) itemBuilder,
  EdgeInsetsGeometry gridPadding =
      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
}) {
  // 固定シード: build()のたびに広告位置が変わって画面がちらつくのを防ぐ
  // （間隔(2〜5件ごと)の見た目のランダム感は保ちつつ、同じ件数なら常に同じ配置にする）。
  final rng = Random(42);
  final slivers = <Widget>[];
  var buffer = <T>[];
  int nextAdAt = 2 + rng.nextInt(4);
  int count = 0;
  var adInserted = false;

  void flushBuffer() {
    if (buffer.isEmpty) return;
    final chunk = List<T>.of(buffer);
    slivers.add(
      SliverPadding(
        padding: gridPadding,
        sliver: SliverGrid(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            childAspectRatio: 3 / 4,
          ),
          delegate: SliverChildBuilderDelegate(
            (context, i) => itemBuilder(context, chunk[i]),
            childCount: chunk.length,
          ),
        ),
      ),
    );
    buffer = [];
  }

  for (final item in items) {
    buffer.add(item);
    count++;
    if (count >= nextAdAt) {
      flushBuffer();
      slivers.add(const SliverToBoxAdapter(child: InlineBannerAdCard()));
      adInserted = true;
      count = 0;
      nextAdAt = 2 + rng.nextInt(4);
    }
  }
  flushBuffer();

  // 件数が少なくて自然な間隔に届かなかった場合も、最低1件は広告を表示する
  if (items.isNotEmpty && !adInserted) {
    slivers.add(const SliverToBoxAdapter(child: InlineBannerAdCard()));
  }

  return slivers;
}

/// リスト表示用: 2〜5件ごとに広告マーカー('ad')を挟み込んだリストを返す。
/// itemBuilder 側で `item == 'ad'` のとき InlineBannerAdCard を表示する。
List<dynamic> interleaveItemsWithAds<T>(List<T> items) {
  // 固定シード: build()のたびに広告位置が変わって画面がちらつくのを防ぐ。
  final rng = Random(42);
  final result = <dynamic>[];
  int nextAdAt = 2 + rng.nextInt(4);
  int count = 0;
  var adInserted = false;
  for (final item in items) {
    result.add(item);
    count++;
    if (count >= nextAdAt) {
      result.add('ad');
      adInserted = true;
      count = 0;
      nextAdAt = 2 + rng.nextInt(4);
    }
  }

  // 件数が少なくて自然な間隔に届かなかった場合も、最低1件は広告を表示する
  if (items.isNotEmpty && !adInserted) {
    result.add('ad');
  }

  return result;
}
