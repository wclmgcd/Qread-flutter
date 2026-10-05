import 'dart:ui';

/// 极简 SVG `<path d="...">` 解析器。
///
/// 【为什么需要它】
/// 段评书源把评论气泡做成内联 SVG 塞进正文：
/// ```
/// <img src="data:image/svg+xml;base64,<svg .../>,{"click":"showCmt(...)"}">
/// ```
/// SVG 里的 `<path d>` 就是气泡的形状（一个圆角方框 + 左侧小尾巴）。
/// 官方客户端直接把这个 SVG 画出来，所以我们也要按同一份几何来画，
/// 否则气泡形状/大小会和后端 Web 端对不上。
///
/// 【支持范围】
/// 支持 M/m L/l H/h V/v C/c S/s Q/q T/t A/a Z/z（A 退化为直线，
/// 因为气泡里不会出现圆弧）。曲线用 Flutter 的
/// `quadraticBezierTo` / `cubicBezierTo` 原样交给引擎，不做采样，
/// 因此缩放后依然平滑。
///
/// 【解析结果】
/// 返回的 Path 坐标仍是 SVG 原始坐标系（未做任何缩放/平移），
/// 由调用方用 `getBounds()` 求出紧包围盒后再缩放。
class SvgPathParser {
  static final RegExp _token = RegExp(
    r'([MmLlHhVvCcSsQqTtAaZz])|(-?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?)',
  );

  /// 把 path 的 `d` 属性解析成 Path；无法解析时返回 null。
  static Path? parse(String? d) {
    if (d == null || d.trim().isEmpty) return null;

    final tokens = <Object>[];
    for (final m in _token.allMatches(d)) {
      final cmd = m.group(1);
      if (cmd != null) {
        tokens.add(cmd);
      } else {
        final v = double.tryParse(m.group(2)!);
        if (v != null) tokens.add(v);
      }
    }
    if (tokens.isEmpty) return null;

    final path = Path();
    var i = 0;
    var cmd = '';
    // 当前点 / 子路径起点
    double cx = 0, cy = 0, sx = 0, sy = 0;
    // 上一个三次/二次曲线的控制点（S/T 的反射要用）
    double? lastCubicX, lastCubicY, lastQuadX, lastQuadY;
    var prev = '';
    var moved = false;

    double next() {
      if (i >= tokens.length || tokens[i] is! double) {
        throw const FormatException('svg path: 参数不足');
      }
      return tokens[i++] as double;
    }

    try {
      while (i < tokens.length) {
        if (tokens[i] is String) {
          cmd = tokens[i] as String;
          i++;
        } else if (cmd.isEmpty) {
          return null;
        } else if (cmd == 'M') {
          // 隐式重复：M 之后的多组坐标当作 L
          cmd = 'L';
        } else if (cmd == 'm') {
          cmd = 'l';
        }

        final rel = cmd == cmd.toLowerCase();
        switch (cmd.toUpperCase()) {
          case 'M':
            var x = next(), y = next();
            if (rel) {
              x += cx;
              y += cy;
            }
            cx = x;
            cy = y;
            sx = x;
            sy = y;
            path.moveTo(x, y);
            moved = true;
            lastCubicX = lastCubicY = lastQuadX = lastQuadY = null;
            break;

          case 'L':
            var x = next(), y = next();
            if (rel) {
              x += cx;
              y += cy;
            }
            if (!moved) {
              path.moveTo(cx, cy);
              moved = true;
            }
            path.lineTo(x, y);
            cx = x;
            cy = y;
            lastCubicX = lastCubicY = lastQuadX = lastQuadY = null;
            break;

          case 'H':
            var x = next();
            if (rel) x += cx;
            if (!moved) {
              path.moveTo(cx, cy);
              moved = true;
            }
            path.lineTo(x, cy);
            cx = x;
            lastCubicX = lastCubicY = lastQuadX = lastQuadY = null;
            break;

          case 'V':
            var y = next();
            if (rel) y += cy;
            if (!moved) {
              path.moveTo(cx, cy);
              moved = true;
            }
            path.lineTo(cx, y);
            cy = y;
            lastCubicX = lastCubicY = lastQuadX = lastQuadY = null;
            break;

          case 'C':
            var c1x = next(), c1y = next();
            var c2x = next(), c2y = next();
            var x = next(), y = next();
            if (rel) {
              c1x += cx;
              c1y += cy;
              c2x += cx;
              c2y += cy;
              x += cx;
              y += cy;
            }
            if (!moved) {
              path.moveTo(cx, cy);
              moved = true;
            }
            path.cubicTo(c1x, c1y, c2x, c2y, x, y);
            lastCubicX = c2x;
            lastCubicY = c2y;
            lastQuadX = lastQuadY = null;
            cx = x;
            cy = y;
            break;

          case 'S':
            var c2x = next(), c2y = next();
            var x = next(), y = next();
            if (rel) {
              c2x += cx;
              c2y += cy;
              x += cx;
              y += cy;
            }
            // 前一条是三次曲线才做反射，否则第一个控制点就是当前点
            final reflect = (prev == 'C' ||
                    prev == 'c' ||
                    prev == 'S' ||
                    prev == 's') &&
                lastCubicX != null;
            final c1x = reflect ? 2 * cx - lastCubicX! : cx;
            final c1y = reflect ? 2 * cy - lastCubicY! : cy;
            if (!moved) {
              path.moveTo(cx, cy);
              moved = true;
            }
            path.cubicTo(c1x, c1y, c2x, c2y, x, y);
            lastCubicX = c2x;
            lastCubicY = c2y;
            lastQuadX = lastQuadY = null;
            cx = x;
            cy = y;
            break;

          case 'Q':
            var qx = next(), qy = next();
            var x = next(), y = next();
            if (rel) {
              qx += cx;
              qy += cy;
              x += cx;
              y += cy;
            }
            if (!moved) {
              path.moveTo(cx, cy);
              moved = true;
            }
            path.quadraticBezierTo(qx, qy, x, y);
            lastQuadX = qx;
            lastQuadY = qy;
            lastCubicX = lastCubicY = null;
            cx = x;
            cy = y;
            break;

          case 'T':
            var x = next(), y = next();
            if (rel) {
              x += cx;
              y += cy;
            }
            final reflect = (prev == 'Q' ||
                    prev == 'q' ||
                    prev == 'T' ||
                    prev == 't') &&
                lastQuadX != null;
            final qx = reflect ? 2 * cx - lastQuadX! : cx;
            final qy = reflect ? 2 * cy - lastQuadY! : cy;
            if (!moved) {
              path.moveTo(cx, cy);
              moved = true;
            }
            path.quadraticBezierTo(qx, qy, x, y);
            lastQuadX = qx;
            lastQuadY = qy;
            lastCubicX = lastCubicY = null;
            cx = x;
            cy = y;
            break;

          case 'A':
            // rx ry x-rotation large-arc sweep x y
            next();
            next();
            next();
            next();
            next();
            var x = next(), y = next();
            if (rel) {
              x += cx;
              y += cy;
            }
            if (!moved) {
              path.moveTo(cx, cy);
              moved = true;
            }
            path.lineTo(x, y);
            lastCubicX = lastCubicY = lastQuadX = lastQuadY = null;
            cx = x;
            cy = y;
            break;

          case 'Z':
            path.close();
            cx = sx;
            cy = sy;
            lastCubicX = lastCubicY = lastQuadX = lastQuadY = null;
            break;

          default:
            return null;
        }
        prev = cmd;
      }
    } catch (_) {
      return null;
    }

    return path;
  }
}
