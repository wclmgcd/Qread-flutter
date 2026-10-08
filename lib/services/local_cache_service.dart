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

  /// 章节缓存的目录：`reader/<bookUrl 的哈希>/replace_{on,off}[_<规则指纹>]`。
  ///
  /// 【为什么原来只有「有没有应用净化」两级不够】
  /// 目录里**不带规则版本**，所以「替换净化」规则一变，旧缓存就过期了 ——
  /// 原来只能靠调用方显式调 [clearBookChapterCache] 兜着，一旦漏调（或者规则
  /// 是在**另一台设备 / 网页端**改的），正文看起来就毫无变化。
  ///
  /// 现在多带一个可选的 [ruleFingerprint]：客户端本地净化引擎每次都用当前
  /// 规则集的指纹当目录后缀，**规则一变目录名就变，旧缓存天然用不上**，
  /// 不依赖任何显式清理动作。
  ///
  /// 【谁传什么】
  /// - 净化关掉 → `replace_off`，不传指纹
  /// - 服务端净化 → `replace_on`，不传指纹（规则版本在服务端，客户端看不见）
  /// - 本地净化 → `replace_on_<指纹>`
  /// 三种目录互不干扰，所以「切执行端 / 改规则」都不会读到另一份的残留。
  String _chapterDir(String bookUrl, bool useReplaceRule, String? ruleFingerprint) {
    final hashed = scopedKey(bookUrl);
    final replaceFlag = useReplaceRule ? 'replace_on' : 'replace_off';
    final suffix = (ruleFingerprint == null || ruleFingerprint.isEmpty)
        ? ''
        : '_$ruleFingerprint';
    return 'reader/$hashed/$replaceFlag$suffix';
  }

  Future<void> writeChapterContent({
    required String bookUrl,
    required int chapterIndex,
    required bool useReplaceRule,
    required String content,
    String? ruleFingerprint,
  }) {
    return _store.writeText(
      '${_chapterDir(bookUrl, useReplaceRule, ruleFingerprint)}/$chapterIndex.txt',
      content,
    );
  }

  Future<String?> readChapterContent({
    required String bookUrl,
    required int chapterIndex,
    required bool useReplaceRule,
    String? ruleFingerprint,
  }) {
    return _store.readText(
      '${_chapterDir(bookUrl, useReplaceRule, ruleFingerprint)}/$chapterIndex.txt',
    );
  }

  Future<void> pruneChapterCache({
    required String bookUrl,
    required bool useReplaceRule,
    required Set<int> keepIndices,
    String? ruleFingerprint,
  }) async {
    final dir = _chapterDir(bookUrl, useReplaceRule, ruleFingerprint);
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
  /// 【为什么还需要它（不是有规则指纹了吗）】
  /// 规则指纹只对**本地净化**那条路有效 —— 那是客户端自己算的，指纹算得出来。
  /// 走**服务端净化**时，规则版本在服务端，客户端根本看不见，目录名里只能
  /// 写个固定的 `replace_on`，所以规则一改仍然会读到旧正文。用户在阅读页点
  /// 「过滤」（规则写到服务端）之后就属于这种，必须显式清一次。
  Future<void> clearBookChapterCache(String bookUrl) {
    return _store.deleteTree('reader/${scopedKey(bookUrl)}');
  }
}
