import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'cache_store.dart';

/// 本地缓存（JSON 片段 + 章节正文）。
///
/// 【本文件不再直接碰文件系统】
/// 真正的读写全部委托给 [CacheStore]，由它在编译期按平台选实现：
/// 原生端走真实文件，浏览器端走内存。这样 `flutter build web` 才编得过 ——
/// 细节见 `cache_store.dart` 的注释。**对外 API 与改造前完全一致**，
/// 所有调用方无需改动。
class LocalCacheService {
  static LocalCacheService? _instance;

  LocalCacheService._();

  static LocalCacheService get instance => _instance ??= LocalCacheService._();

  final CacheStore _store = createCacheStore();

  /// 把任意字符串收敛成定长 key（MD5 十六进制，固定 32 字符）。
  /// 用途：bookUrl / accessToken 这类可能带 `?` `/` 的长串不能直接当路径。
  ///
  /// 【为什么不是手写 FNV-1a 64 位】
  /// 原来这里自己实现了 FNV-1a，用了 `0xcbf29ce484222325` 和
  /// `0xFFFFFFFFFFFFFFFF` 两个 64 位常量。原生端（AOT）一直没事，但
  /// `flutter build web` 是**编译期**就挂：
  ///   Error: The integer literal 0xcbf29ce484222325 can't be represented
  ///   exactly in JavaScript.
  /// 因为 dart2js 的数字就是 IEEE-754 双精度，安全整数只有 53 位，64 位
  /// 字面量直接拒收；就算绕开字面量、改成运行时算，乘积的低位也会被精度
  /// 吞掉，哈希退化成常量，碰撞率反而爆炸。所以这条路走不通。
  ///
  /// 换成 MD5 一次解决：纯 Dart 实现、不依赖平台整数宽度、web 与原生结果
  /// 完全一致。而且 crypto 本来就作为 web_socket_channel 的传递依赖在
  /// 依赖树里，提为直接依赖不会多装任何东西。
  ///
  /// 【副作用（可接受，不做迁移）】
  /// 摘要算法变了 → 之前落盘的缓存 key 全部对不上。但这里存的**全是本地
  /// 副本**（书源 / RSS / 发现页 / 书架列表 + 章节正文），丢了会自动回源
  /// 重拉，不是权威数据，所以不需要写迁移逻辑。
  String scopedKey(String raw) => md5.convert(utf8.encode(raw)).toString();

  Future<void> saveJson(String key, Object data) {
    return _store.writeText('$key.json', const JsonEncoder().convert(data));
  }

  Future<List<dynamic>?> readJsonList(String key) async {
    final raw = await _store.readText('$key.json');
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is List ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> readJsonObject(String key) async {
    final raw = await _store.readText('$key.json');
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value));
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  // -------------------------------------------------------------- 章节正文

  /// 章节缓存的目录：`reader/<bookUrl 的哈希>/replace_{on,off}`。
  ///
  /// 【注意这里**只有「有没有应用净化」两级，不带规则版本**】
  /// 所以「替换净化」规则一变，旧缓存就过期了 —— 必须显式调
  /// [clearBookChapterCache]，否则正文看起来毫无变化（见该方法注释）。
  String _chapterDir(String bookUrl, bool useReplaceRule) {
    final hashed = scopedKey(bookUrl);
    final replaceFlag = useReplaceRule ? 'replace_on' : 'replace_off';
    return 'reader/$hashed/$replaceFlag';
  }

  Future<void> writeChapterContent({
    required String bookUrl,
    required int chapterIndex,
    required bool useReplaceRule,
    required String content,
  }) {
    return _store.writeText(
      '${_chapterDir(bookUrl, useReplaceRule)}/$chapterIndex.txt',
      content,
    );
  }

  Future<String?> readChapterContent({
    required String bookUrl,
    required int chapterIndex,
    required bool useReplaceRule,
  }) {
    return _store.readText(
      '${_chapterDir(bookUrl, useReplaceRule)}/$chapterIndex.txt',
    );
  }

  Future<void> pruneChapterCache({
    required String bookUrl,
    required bool useReplaceRule,
    required Set<int> keepIndices,
  }) async {
    final dir = _chapterDir(bookUrl, useReplaceRule);
    for (final name in await _store.listNames(dir)) {
      final index = int.tryParse(name.replaceAll('.txt', ''));
      if (index == null || keepIndices.contains(index)) continue;
      await _store.deleteTree('$dir/$name');
    }
  }

  Future<void> clearAllCaches() => _store.deleteAll();

  /// 清掉某本书的**全部**章节缓存（`replace_on` 和 `replace_off` 两个目录一起）。
  ///
  /// 【什么时候必须调】
  /// 「替换净化」规则变了之后 —— 用户点了阅读页的「过滤」就属于这种。
  ///
  /// 【为什么】
  /// 缓存目录只按「有没有应用净化」分成 `replace_on` / `replace_off` 两级，
  /// **不带规则版本**。所以加规则之前缓存下来的正文里是**没有替换过**的文字，
  /// 而 `ReaderProvider.getChapterContent` 命中缓存就直接返回、不再请求后端 ——
  /// 表现就是「规则明明写进去了，正文一点变化都没有」。
  Future<void> clearBookChapterCache(String bookUrl) {
    return _store.deleteTree('reader/${scopedKey(bookUrl)}');
  }
}
