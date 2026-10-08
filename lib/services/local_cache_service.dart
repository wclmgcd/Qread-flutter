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
    String? chapterTitle,
  }) async {
    final dir = _chapterDir(bookUrl, useReplaceRule, ruleFingerprint);
    await _store.writeText('$dir/$chapterIndex.txt', content);
    // 章节标题单独存一个 `.title` 小文件。
    //
    // 【为什么不塞进 meta.json】那样每写一章都要「读整个 JSON → 改 → 写回」，
    // 而且标题会越攒越多、还得额外写一套按章节裁剪的逻辑。放成同级小文件之后，
    // 它和正文**同生共死** —— `pruneChapterCache` 按章节号删，标题自然跟着走。
    //
    // 【为什么不用 `<index>.title.txt`】那样 `pruneChapterCache` 里
    // `name.replaceAll('.txt','')` 会得到 `'3.title'`，解析不出章节号就被误删。
    final title = chapterTitle?.trim();
    if (title != null && title.isNotEmpty) {
      await _store.writeText('$dir/$chapterIndex.title', title);
    }
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
      final index = _chapterIndexOf(name);
      if (index == null || keepIndices.contains(index)) continue;
      await _store.deleteTree('$dir/$name');
    }
  }

  /// 从缓存文件名里取章节号：`3.txt` → 3、`3.title` → 3、其它 → null。
  static int? _chapterIndexOf(String fileName) {
    if (fileName.endsWith('.txt')) {
      return int.tryParse(fileName.substring(0, fileName.length - 4));
    }
    if (fileName.endsWith('.title')) {
      return int.tryParse(fileName.substring(0, fileName.length - 6));
    }
    return null;
  }

  Future<void> clearAllCaches() => _store.deleteAll();

  // ---------------------------------------------------------- 书籍元信息

  /// 章节缓存的书籍元信息：`reader/<哈希>/meta.json`。
  ///
  /// 【为什么需要它】目录名只有 `md5(bookUrl)`，光看目录根本不知道该显示什么
  /// 书名。「常规设置 → 缓存管理」要列「读的每一本书的章节缓存」，就得有人
  /// 把书 URL 和书名记在旁边。**放在书级目录（不是变体目录）下**，
  /// 所以 `pruneChapterCache` 那个只在变体目录里扫的逻辑碰不到它。
  static const String _kBookMeta = 'meta.json';
  static const String _readerRoot = 'reader';

  /// 记下/更新一本书的元信息（阅读器写章节缓存时顺带调）。
  ///
  /// 内容没变就不写盘 —— 这个方法每缓存一章都会被调一次，白写没必要。
  Future<void> writeChapterBookMeta({
    required String bookUrl,
    String? name,
    String? author,
    String? origin,
    bool? useReplaceRule,
  }) async {
    final path = '$_readerRoot/${scopedKey(bookUrl)}/$_kBookMeta';
    Map<String, dynamic> meta = const <String, dynamic>{};
    final raw = await _store.readText(path);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          meta = decoded.map((k, v) => MapEntry('$k', v));
        }
      } catch (_) {
        // 元信息坏了就当没有，下面整份重写。
      }
    }

    final next = <String, dynamic>{
      'bookUrl': bookUrl,
      if (name != null && name.isNotEmpty) 'name': name,
      if (author != null && author.isNotEmpty) 'author': author,
      if (origin != null && origin.isNotEmpty) 'origin': origin,
      if (useReplaceRule != null) 'useReplaceRule': useReplaceRule,
    };
    final changed = meta.length != next.length ||
        next.entries.any((e) => meta[e.key] != e.value);
    if (!changed) return;
    next['updatedAt'] = DateTime.now().millisecondsSinceEpoch;
    await _store.writeText(path, jsonEncode(next));
  }

  Future<Map<String, dynamic>?> _readBookMeta(String hash) async {
    final raw = await _store.readText('$_readerRoot/$hash/$_kBookMeta');
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return decoded.map((k, v) => MapEntry('$k', v));
    } catch (_) {}
    return null;
  }

  // -------------------------------------------------------- 缓存清单 / 导出

  /// 列出所有有章节缓存的书（按占用体积降序）。
  ///
  /// 【变体目录是怎么认出来的】[`_chapterDir`] 生成的名字只有三种形态：
  /// `replace_off` / `replace_on` / `replace_on_<指纹>`。
  /// 认不出来的目录一律跳过（将来加了别的缓存也不会被误当成章节缓存）。
  Future<List<ChapterCacheBook>> listChapterCacheBooks() async {
    final result = <ChapterCacheBook>[];
    for (final hash in await _store.listDirs(_readerRoot)) {
      final bookDir = '$_readerRoot/$hash';
      final variants = <ChapterCacheVariant>[];
      for (final dirName in await _store.listDirs(bookDir)) {
        final parsed = _parseVariantDirName(dirName);
        if (parsed == null) continue;
        final indices = <int>[];
        for (final fileName in await _store.listNames('$bookDir/$dirName')) {
          if (!fileName.endsWith('.txt')) continue;
          final index = _chapterIndexOf(fileName);
          if (index != null) indices.add(index);
        }
        indices.sort();
        variants.add(ChapterCacheVariant(
          dirName: dirName,
          flavor: parsed.$1,
          fingerprint: parsed.$2,
          indices: indices,
          bytes: await _store.sizeOf('$bookDir/$dirName'),
        ));
      }
      if (variants.isEmpty) continue;

      final meta = await _readBookMeta(hash);
      final metaUseReplace = meta?['useReplaceRule'];
      result.add(ChapterCacheBook(
        hash: hash,
        variants: variants,
        bookUrl: meta?['bookUrl']?.toString(),
        name: meta?['name']?.toString(),
        author: meta?['author']?.toString(),
        origin: meta?['origin']?.toString(),
        useReplaceRule: metaUseReplace is bool ? metaUseReplace : null,
      ));
    }
    result.sort((a, b) => b.totalBytes.compareTo(a.totalBytes));
    return result;
  }

  /// `replace_off` → (raw, null)、`replace_on` → (server, null)、
  /// `replace_on_<指纹>` → (local, 指纹)；其它返回 null。
  static (ChapterCacheFlavor, String?)? _parseVariantDirName(String dirName) {
    if (dirName == 'replace_off') {
      return (ChapterCacheFlavor.raw, null);
    }
    if (dirName == 'replace_on') {
      return (ChapterCacheFlavor.purifiedServer, null);
    }
    const localPrefix = 'replace_on_';
    if (dirName.startsWith(localPrefix)) {
      final fingerprint = dirName.substring(localPrefix.length);
      if (fingerprint.isEmpty) return null;
      return (ChapterCacheFlavor.purifiedLocal, fingerprint);
    }
    return null;
  }

  /// 读出一个变体下的全部章节（按章节号升序）。读不到的文件跳过。
  Future<List<CachedChapter>> readChapterCacheVariant({
    required String bookHash,
    required ChapterCacheVariant variant,
  }) async {
    final dir = '$_readerRoot/$bookHash/${variant.dirName}';
    final out = <CachedChapter>[];
    for (final index in variant.indices) {
      final content = await _store.readText('$dir/$index.txt');
      if (content == null || content.isEmpty) continue;
      final title = await _store.readText('$dir/$index.title');
      out.add(CachedChapter(
        index: index,
        title: title?.trim() ?? '',
        content: content,
      ));
    }
    return out;
  }

  /// 删掉某本书的**全部**章节缓存（所有变体 + 元信息一起）。
  Future<void> deleteChapterCacheBook(String bookHash) {
    return _store.deleteTree('$_readerRoot/$bookHash');
  }

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
    return _store.deleteTree('$_readerRoot/${scopedKey(bookUrl)}');
  }
}

/// 章节缓存变体的「净化来源」—— 由目录名反推。
enum ChapterCacheFlavor {
  /// 本地净化引擎产出的（目录名 `replace_on_<指纹>`）。
  purifiedLocal('净化后 · 本地规则'),

  /// 服务端净化产出的（目录名 `replace_on`）。
  purifiedServer('净化后 · 服务端'),

  /// 没净化过的原样正文（目录名 `replace_off`）。
  raw('未净化');

  const ChapterCacheFlavor(this.label);

  final String label;

  bool get isPurified => this != ChapterCacheFlavor.raw;
}

/// 一本书在**某个变体目录**下的缓存。
class ChapterCacheVariant {
  const ChapterCacheVariant({
    required this.dirName,
    required this.flavor,
    required this.fingerprint,
    required this.indices,
    required this.bytes,
  });

  /// 目录名，如 `replace_on_ab12cd34ef`。
  final String dirName;

  final ChapterCacheFlavor flavor;

  /// 本地净化时的规则指纹；服务端净化 / 未净化时为 null。
  final String? fingerprint;

  /// 已缓存的章节号，**升序**。
  final List<int> indices;

  final int bytes;

  int get chapterCount => indices.length;
}

/// 「常规设置 → 缓存管理」里的一行：一本书 + 它名下的所有章节缓存变体。
class ChapterCacheBook {
  ChapterCacheBook({
    required this.hash,
    required this.variants,
    this.bookUrl,
    this.name,
    this.author,
    this.origin,
    this.useReplaceRule,
  });

  /// `reader/<hash>` 里那个哈希（= md5(bookUrl)）。
  final String hash;

  final List<ChapterCacheVariant> variants;

  /// 【为什么这几个字段不是 final】`meta.json` 是**这次改动之后**才开始写的，
  /// 老缓存里没有它 —— 那时只有目录名（哈希），拿不到书名。调用方（缓存管理页）
  /// 会在有登录态时去书架里按哈希反查一次书名，然后把结果回填到这里。
  String? bookUrl;
  String? name;
  String? author;
  String? origin;

  /// 书级净化开关（缓存写入时记下的）。null = 未知（老缓存没有这份元信息）。
  bool? useReplaceRule;

  int get totalBytes => variants.fold(0, (sum, v) => sum + v.bytes);
  int get totalChapters => variants.fold(0, (sum, v) => sum + v.chapterCount);

  /// 展示名：优先书名；拿不到就用哈希兜底（老缓存没有 meta.json）。
  String get displayName {
    final n = name?.trim();
    if (n != null && n.isNotEmpty) return n;
    return '未知书籍（${hash.substring(0, 8)}）';
  }

  /// 导出时优先用哪一份变体。
  ///
  /// 排序（[currentFingerprint] = 当前本地规则的指纹）：
  ///   1. 本地净化 + **当前**指纹 —— 就是阅读器现在会命中的那份
  ///   2. 服务端净化 —— 也是净化过的
  ///   3. 本地净化 + 其它指纹 —— 净化过，只是规则旧了
  ///   4. 未净化 —— 最后才退到它
  /// 同一档里取章数多的（内容更全）。
  ChapterCacheVariant? preferred({String? currentFingerprint}) {
    if (variants.isEmpty) return null;
    int rank(ChapterCacheVariant v) {
      switch (v.flavor) {
        case ChapterCacheFlavor.purifiedLocal:
          final fp = v.fingerprint;
          final isCurrent =
              fp != null && currentFingerprint != null && fp == currentFingerprint;
          return isCurrent ? 0 : 2;
        case ChapterCacheFlavor.purifiedServer:
          return 1;
        case ChapterCacheFlavor.raw:
          return 3;
      }
    }

    final sorted = List<ChapterCacheVariant>.of(variants)
      ..sort((a, b) {
        final byRank = rank(a).compareTo(rank(b));
        if (byRank != 0) return byRank;
        return b.chapterCount.compareTo(a.chapterCount);
      });
    return sorted.first;
  }
}

/// 从缓存里读出来的一章。
class CachedChapter {
  const CachedChapter({
    required this.index,
    required this.title,
    required this.content,
  });

  final int index;
  final String title;
  final String content;
}
