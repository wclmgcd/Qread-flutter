import 'dart:convert';

import '../config/constants.dart';

/// 正文插图的 `/imageDecode` 地址拼装。
///
/// 【为什么单独一个文件】这里全是纯字符串逻辑、**不依赖 Flutter**，
/// 于是可以在纯 Dart VM 里跑真实代码做本地验证（本机没有 Flutter SDK，
/// `api_service.dart` 拖着 dio / json_serializable，本地跑不起来）。
///
/// 官方客户端对应的是 main.dart.js 里的 `b2U`（发请求）和 `b2W`（拆 src）。
class ImageDecodeUrl {
  ImageDecodeUrl._();

  /// GET 请求行的长度上限。
  ///
  /// 【为什么必须有这个上限】
  /// 官方客户端用 **POST**，参数在 body 里，`book` 带多大都无所谓；
  /// 我们为了能用 `Image.network` 只能用 **GET**，所有参数都进请求行。
  /// 后端是 smart-http，请求行过大时它自己就报错、根本进不到业务代码：
  ///
  ///     DecoderException: readBuffer overflow.
  ///     The current TCP connection will be closed.
  ///     Please fix your HttpRequestProtocol#decode bug.
  ///     → HTTP 500
  ///
  /// 实测（真实后端 + 真实书源《华娱情报王》）：
  ///   请求行 6336 字符 → 200，拿到 87262 字节 image/webp
  ///   请求行 8336 字符 → 500 readBuffer overflow
  /// 取 3500 留足余量（反向代理、HTTP/2 头压缩都会再占一点）。
  static const int maxUrlLength = 3500;

  /// `book` 里体积可能很大的字段 —— 超限时按这个顺序优先丢掉。
  ///
  /// `intro` 是简介（可达数 KB）；`coverUrl` / `customCoverUrl` 可能是内联的
  /// `data:` base64 封面；`bookUrl` / `tocUrl` 在部分书源里也是 `data:;base64,`。
  static const List<String> heavyBookKeys = [
    'intro',
    'coverUrl',
    'customCoverUrl',
    'bookUrl',
    'tocUrl',
  ];

  /// 拆分书源给的图片 src（复刻官方 `b2W`）。
  ///
  /// 书源约定：`<img src="URL,{json}">` —— 逗号前是真实地址，逗号后的 json
  /// 里可能有 `headers`。含 `,`+`{`+`}` 才拆，拆失败就原样返回。
  ///
  /// `baseurl` 是书源占位符，换成 `<站点>/api/5`
  /// （官方用 `origin + "/api/5"`，等价于 [AppConstants.apiBase]）。
  static ({String url, Map<String, String> headers}) splitSrc(
    String src, {
    String? apiBase,
  }) {
    var raw = src.trim();
    if (raw.contains('baseurl')) {
      raw = raw.replaceAll('baseurl', apiBase ?? AppConstants.apiBase);
    }
    if (!raw.contains(',') || !raw.contains('{') || !raw.contains('}')) {
      return (url: raw, headers: const <String, String>{});
    }
    try {
      final comma = raw.indexOf(',');
      final url = raw.substring(0, comma).trim();
      final decoded = jsonDecode(raw.substring(comma + 1));
      final headers = <String, String>{};
      if (decoded is Map && decoded['headers'] is Map) {
        (decoded['headers'] as Map).forEach((k, v) {
          headers['$k'] = '$v';
        });
      }
      if (url.isEmpty) return (url: raw, headers: const <String, String>{});
      return (url: url, headers: headers);
    } catch (_) {
      return (url: raw, headers: const <String, String>{});
    }
  }

  /// 拼出 `/imageDecode` 的完整地址。src 取不到地址时返回空串。
  ///
  /// 参数与官方完全一致：`accessToken` / `url` / `bookSourceUrl` /
  /// `header` / `book`（顺序也一致，便于和抓到的官方请求逐字对拍）。
  ///
  /// [book] 传 `Book.toJson()` 的结果。它会按
  /// [fullBook] → 去掉 [heavyBookKeys] → 只留 name/origin → `{}`
  /// 依次降级，直到整个 URL 落进 [maxUrlLength]。
  ///
  /// 【为什么不能干脆不带 book】后端签名是
  /// `@Param("book") ibook: String?` —— Solon 的 `@Param` 是**必填**，
  /// 缺了这个参数直接 HTTP 400（实测：`book=` 空串 200，完全不传 400）。
  static String build({
    required String src,
    required String accessToken,
    String? bookSourceUrl,
    Map<String, dynamic>? book,
    String? apiBase,
  }) {
    final (url: imageUrl, headers: headers) = splitSrc(src, apiBase: apiBase);
    if (imageUrl.isEmpty) return '';
    final base = apiBase ?? AppConstants.apiBase;
    final prefix = '$base/imageDecode?';
    final fixed = <String, String>{
      'accessToken': accessToken,
      'url': imageUrl,
      'bookSourceUrl': bookSourceUrl ?? '',
      'header': jsonEncode(headers),
    };
    for (final candidate in bookCandidates(book)) {
      final full = '$prefix${encodeParams({...fixed, 'book': candidate})}';
      if (full.length <= maxUrlLength) return full;
    }
    // 兜底：连 `{}` 都放不下（几乎不可能），仍然带上 —— book 必填。
    return '$prefix${encodeParams({...fixed, 'book': '{}'})}';
  }

  /// 依次尝试的 `book` 取值，从「最全」到「最省」。
  static Iterable<String> bookCandidates(Map<String, dynamic>? book) sync* {
    if (book == null || book.isEmpty) {
      yield '{}';
      return;
    }
    yield jsonEncode(book);

    final light = Map<String, dynamic>.from(book)
      ..removeWhere((k, _) => heavyBookKeys.contains(k));
    yield jsonEncode(light);

    yield jsonEncode({
      if (book['name'] != null) 'name': book['name'],
      if (book['origin'] != null) 'origin': book['origin'],
    });

    yield '{}';
  }

  /// 查询串编码 —— 与 `api_service._encodeParams` 逐字一致。
  static String encodeParams(Map<String, String> params) {
    return params.entries
        .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
        .join('&');
  }
}
