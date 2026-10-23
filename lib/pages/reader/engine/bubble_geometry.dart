import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'models.dart';
import 'svg_path.dart';

/// 段评气泡的几何形状。
///
/// 书源把气泡做成内联 SVG 塞进正文，官方客户端直接照着 SVG 画。
/// 这里把 SVG 里的 `<path d>` 解析成 Path 并算出紧包围盒，
/// 渲染时按包围盒等比缩放，形状/比例才能和后端 Web 端一致。
///
/// 【分页也要用】气泡的真实宽度由 path 包围盒决定，各书源比例不同
/// （兜底形状约 1.31、番茄/大灰狼系约 1.47），分页引擎必须用同一份
/// 几何预留宽度，否则段末行会被气泡挤得换行、整页溢出被裁。
class BubbleGeometry {
  const BubbleGeometry({
    required this.path,
    required this.bounds,
    this.textX,
    this.textY,
    this.textSize,
  });

  final Path path;

  /// path 的紧包围盒（SVG 原始坐标）
  final Rect bounds;

  /// SVG `<text>` 的锚点与字号（同样是 SVG 原始坐标）
  final double? textX;
  final double? textY;
  final double? textSize;

  /// 书源 SVG 缺失时的兜底形状。
  ///
  /// 取自段评书源实际下发的 SVG：一个 32×32、圆角 4 的方框，
  /// 左侧带一条小尾巴（path 最左到 x=8），数字居中在方框里。
  static const String fallbackPathData =
      'M44 48 Q48 48 48 44 L48 20 Q48 16 44 16 L20 16 Q16 16 16 20 L16 24 '
      'S16 28 10 30 Q6 32 10 34 Q16 36 16 38 L16 44 Q16 48 20 48 Z';

  static final BubbleGeometry _fallback = _build(
    fallbackPathData,
    textX: 32,
    textY: 38,
    textSize: 18,
  );

  static final Map<String, BubbleGeometry> _cache = {};

  /// 按 SVG 源码取几何；解析不了就用兜底形状。
  static BubbleGeometry of(String? svg) {
    if (svg == null || svg.trim().isEmpty) return _fallback;
    final cached = _cache[svg];
    if (cached != null) return cached;

    final geo = _parse(svg) ?? _fallback;
    // 书源数量有限，缓存不会无限增长；但仍设个上限防止异常内容撑爆内存。
    if (_cache.length < 64) _cache[svg] = geo;
    return geo;
  }

  static BubbleGeometry? _parse(String svg) {
    // 【书源差异】SVG 的引号风格不统一：
    //   - 起点 / 番茄系：双引号  <path d="M44 48 ...">
    //   - 晋江段评版等：单引号  <path d='M224 149 ...'>
    // 只认双引号会让晋江系解析不到 path → 退化成兜底方框、数字位置也错。
    final pathMatch =
        RegExp(r'''<path[^>]*\sd\s*=\s*["']([^"']+)["']''').firstMatch(svg);
    if (pathMatch == null) return null;

    final textMatch = RegExp(r'<text([^>]*)>', caseSensitive: false)
        .firstMatch(svg);
    double? tx, ty, ts;
    if (textMatch != null) {
      final attrs = textMatch.group(1)!;
      tx = _attr(attrs, 'x');
      ty = _attr(attrs, 'y');
      ts = _attr(attrs, 'font-size');
    }

    // 部分书源把图形包在 <g transform="rotate(90 512 512) scale(1 1.2)"> 里
    // （晋江段评版的竖版气泡图标）。不处理的话气泡会画成躺倒/拉伸错误的形状。
    final matrix = _parseTransform(svg);

    return _build(
      pathMatch.group(1)!,
      textX: tx,
      textY: ty,
      textSize: ts,
      matrix: matrix,
    );
  }

  static double? _attr(String attrs, String name) {
    final m = RegExp('$name\\s*=\\s*["\']([^"\']+)["\']').firstMatch(attrs);
    if (m == null) return null;
    return double.tryParse(m.group(1)!.trim());
  }

  /// 解析 `<g transform="...">` 的变换矩阵（SVG 语义：从左到右依次应用）。
  ///
  /// 只支持段评气泡里实际会出现的 translate / scale / rotate / matrix，
  /// 遇到不认识的函数就跳过；一个都解析不到时返回 null（调用方不做变换）。
  static Matrix4? _parseTransform(String svg) {
    final g = RegExp(
      r'''<g[^>]*\btransform\s*=\s*["']([^"']+)["']''',
      caseSensitive: false,
    ).firstMatch(svg);
    if (g == null) return null;

    final m = Matrix4.identity();
    var applied = false;
    final fnRe = RegExp(r'([A-Za-z]+)\s*\(([^)]*)\)');
    for (final match in fnRe.allMatches(g.group(1)!)) {
      final fn = match.group(1)!.toLowerCase();
      final args = match
          .group(2)!
          .split(RegExp(r'[\s,]+'))
          .where((s) => s.isNotEmpty)
          .map((s) => double.tryParse(s) ?? 0.0)
          .toList();
      final step = Matrix4.identity();
      switch (fn) {
        case 'translate':
          step.translate(
            args.isNotEmpty ? args[0] : 0.0,
            args.length > 1 ? args[1] : 0.0,
          );
          break;
        case 'scale':
          final sx = args.isNotEmpty ? args[0] : 1.0;
          step.scale(sx, args.length > 1 ? args[1] : sx);
          break;
        case 'rotate':
          final rad = (args.isNotEmpty ? args[0] : 0.0) * math.pi / 180.0;
          if (args.length >= 3) {
            final cx = args[1], cy = args[2];
            step.translate(cx, cy);
            step.rotateZ(rad);
            step.translate(-cx, -cy);
          } else {
            step.rotateZ(rad);
          }
          break;
        case 'matrix':
          if (args.length >= 6) {
            step.setEntry(0, 0, args[0]);
            step.setEntry(0, 1, args[2]);
            step.setEntry(0, 3, args[4]);
            step.setEntry(1, 0, args[1]);
            step.setEntry(1, 1, args[3]);
            step.setEntry(1, 3, args[5]);
          }
          break;
        default:
          continue;
      }
      m.multiply(step);
      applied = true;
    }
    return applied ? m : null;
  }

  static BubbleGeometry _build(
    String pathData, {
    double? textX,
    double? textY,
    double? textSize,
    Matrix4? matrix,
  }) {
    var path = SvgPathParser.parse(pathData);
    if (path == null) {
      // 解析失败：退回兜底 path；兜底也失败就用一个空 Path（调用方有保护）
      final fb = SvgPathParser.parse(fallbackPathData);
      if (fb != null && pathData != fallbackPathData) {
        return _build(fallbackPathData, textX: 32, textY: 38, textSize: 18);
      }
      return BubbleGeometry(
        path: Path(),
        bounds: const Rect.fromLTWH(0, 0, 32, 32),
        textX: textX,
        textY: textY,
        textSize: textSize,
      );
    }
    // 把 <g transform> 烘焙进 path 本身，后面的包围盒/绘制就无需再关心它
    if (matrix != null) {
      path = path.transform(matrix.storage);
    }
    var bounds = path.getBounds();
    if (bounds.width <= 0 || bounds.height <= 0) {
      bounds = const Rect.fromLTWH(0, 0, 32, 32);
    }

    // 书源 SVG 没给 <text> 时，按「尾巴在左边」的规律把方框推出来：
    // 方框是正方形，边长等于包围盒高度，剩下的宽度就是尾巴。
    var tx = textX;
    var ty = textY;
    var ts = textSize;
    if (tx == null || ty == null || ts == null) {
      final tail = (bounds.width - bounds.height).clamp(0.0, bounds.width);
      final bodyLeft = bounds.left + tail;
      ts = bounds.height * 0.5625;
      tx = bodyLeft + bounds.height / 2;
      // SVG 的 y 是文字基线；方框垂直居中 ≈ 基线在中心下方 0.35em
      ty = bounds.top + bounds.height / 2 + ts * 0.35;
    } else if (matrix != null) {
      // 文字锚点与字号也要跟着变换，否则数字会飘到气泡外
      final s = matrix.storage;
      final nx = s[0] * tx + s[4] * ty + s[12];
      final ny = s[1] * tx + s[5] * ty + s[13];
      tx = nx;
      ty = ny;
      ts = ts * matrix.getMaxScaleOnAxis();
    }

    return BubbleGeometry(
      path: path,
      bounds: bounds,
      textX: tx,
      textY: ty,
      textSize: ts,
    );
  }
}

/// 行内气泡（含与前面文字的 0.3em 间距）的实际排版宽度。
///
/// 分页引擎预留宽度、渲染端画出气泡，两端都必须用它：
/// 书源 SVG 的方框/尾巴比例并不统一，按固定比例预留会让气泡在
/// 段末行放不下、被挤到下一行，而分页没有为这一行算高度，
/// 整页就会溢出、底部那行被裁掉。
double inlineCommentBubbleWidth(String? svg, double fontSize) {
  final metrics = CommentBubbleMetrics(fontSize);
  final geo = BubbleGeometry.of(svg);
  final scale = metrics.side / geo.bounds.height;
  return geo.bounds.width * scale + metrics.inlineGap;
}
