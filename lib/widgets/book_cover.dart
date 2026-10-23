import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../services/api_service.dart';

/// 书籍封面：支持普通 URL（走服务端代理）、`/assets/images/...` 服务端上传
/// 封面（编辑页「上传图片」经 `/uploadimage` 落盘）和 `data:image/...;base64,`
/// 内联封面（上传前的本地预览）。
class BookCover extends StatelessWidget {
  const BookCover({
    Key? key,
    this.url,
    this.sourceUrl,
    this.width,
    this.height,
    this.radius = 8,
    this.fit = BoxFit.cover,
    this.placeholder,
  }) : super(key: key);

  final String? url;
  final String? sourceUrl;
  final double? width;
  final double? height;
  final double radius;
  final BoxFit fit;
  final Widget? placeholder;

  @override
  Widget build(BuildContext context) {
    final raw = url?.trim() ?? '';
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: width,
        height: height,
        child: raw.isEmpty ? _placeholder() : _content(raw),
      ),
    );
  }

  Widget _content(String raw) {
    final src = _unwrapProxy(raw);
    if (src.startsWith('data:image')) {
      try {
        final comma = src.indexOf(',');
        final bytes = base64Decode(src.substring(comma + 1));
        return Image.memory(
          bytes,
          fit: fit,
          width: width,
          height: height,
          gaplessPlayback: true,
        );
      } catch (_) {
        return _placeholder();
      }
    }
    final proxied = ApiService.instance
        .getCoverProxyUrl(src, sourceUrl: sourceUrl);
    if (proxied.isEmpty) return _placeholder();
    return CachedNetworkImage(
      imageUrl: proxied,
      fit: fit,
      width: width,
      height: height,
      placeholder: (_, __) => _placeholder(),
      errorWidget: (_, __, ___) => _placeholder(),
    );
  }

  /// 服务端开了 `user.proxypng` 时封面会被改写成
  /// `baseurl/proxypng?url=<原地址>`（data URI 也在里面），先把原地址解回来。
  String _unwrapProxy(String raw) {
    const marker = 'baseurl/proxypng?url=';
    final at = raw.indexOf(marker);
    if (at < 0) return raw;
    try {
      return Uri.decodeComponent(raw.substring(at + marker.length));
    } catch (_) {
      return raw;
    }
  }

  Widget _placeholder() =>
      placeholder ??
      Container(
        color: const Color(0xFFE8EDF2),
        alignment: Alignment.center,
        child: const Icon(
          Icons.menu_book_outlined,
          color: Color(0xFF9AA5B1),
          size: 36,
        ),
      );
}
