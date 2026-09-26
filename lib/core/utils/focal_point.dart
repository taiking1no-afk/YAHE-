import 'package:flutter/material.dart';

/// 正規化座標(0.0〜1.0、0.5=中央)を Flutter の Alignment(-1.0〜1.0) に変換する。
Alignment focalAlignment(double x, double y) =>
    Alignment(x.clamp(0.0, 1.0) * 2 - 1, y.clamp(0.0, 1.0) * 2 - 1);
