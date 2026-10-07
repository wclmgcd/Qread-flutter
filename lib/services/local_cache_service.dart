import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class LocalCacheService {
  static LocalCacheService? _instance;

  LocalCacheService._();

  static LocalCacheService get instance => _instance ??= LocalCacheService._();

  Future<Directory> _rootDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}local_cache');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  String scopedKey(String raw) => _fnv1a64(raw);

  Future<void> saveJson(String key, Object data) async {
    final file = await _jsonFile(key);
    await file.writeAsString(const JsonEncoder().convert(data), flush: true);
  }

  Future<List<dynamic>?> readJsonList(String key) async {
    final file = await _jsonFile(key);
    if (!await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      return decoded is List ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> readJsonObject(String key) async {
    final file = await _jsonFile(key);
    if (!await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) {
        return decoded.map(
          (key, value) => MapEntry(key.toString(), value),
        );
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> writeChapterContent({
    required String bookUrl,
    required int chapterIndex,
    required bool useReplaceRule,
    required String content,
  }) async {
    final file = await _chapterFile(bookUrl, chapterIndex, useReplaceRule);
    await file.parent.create(recursive: true);
    await file.writeAsString(content, flush: true);
  }

  Future<String?> readChapterContent({
    required String bookUrl,
    required int chapterIndex,
    required bool useReplaceRule,
  }) async {
    final file = await _chapterFile(bookUrl, chapterIndex, useReplaceRule);
    if (!await file.exists()) return null;
    try {
      return await file.readAsString();
    } catch (_) {
      return null;
    }
  }

  Future<void> pruneChapterCache({
    required String bookUrl,
    required bool useReplaceRule,
    required Set<int> keepIndices,
  }) async {
    final directory = await _chapterDir(bookUrl, useReplaceRule);
    if (!await directory.exists()) return;
    final entries = await directory.list().toList();
    for (final entry in entries) {
      if (entry is! File) continue;
      final name = entry.uri.pathSegments.last;
      final index = int.tryParse(name.replaceAll('.txt', ''));
      if (index == null || keepIndices.contains(index)) continue;
      await entry.delete();
    }
  }

  Future<void> clearAllCaches() async {
    final root = await _rootDir();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  }

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
  Future<void> clearBookChapterCache(String bookUrl) async {
    final root = await _rootDir();
    final dir = Directory(
      '${root.path}${Platform.pathSeparator}reader${Platform.pathSeparator}${scopedKey(bookUrl)}',
    );
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  Future<File> _jsonFile(String key) async {
    final root = await _rootDir();
    return File('${root.path}${Platform.pathSeparator}$key.json');
  }

  Future<Directory> _chapterDir(String bookUrl, bool useReplaceRule) async {
    final root = await _rootDir();
    final hashed = scopedKey(bookUrl);
    final replaceFlag = useReplaceRule ? 'replace_on' : 'replace_off';
    return Directory(
      '${root.path}${Platform.pathSeparator}reader${Platform.pathSeparator}$hashed${Platform.pathSeparator}$replaceFlag',
    );
  }

  Future<File> _chapterFile(
    String bookUrl,
    int chapterIndex,
    bool useReplaceRule,
  ) async {
    final dir = await _chapterDir(bookUrl, useReplaceRule);
    return File(
      '${dir.path}${Platform.pathSeparator}$chapterIndex.txt',
    );
  }

  String _fnv1a64(String input) {
    const offsetBasis = 0xcbf29ce484222325;
    const prime = 0x100000001b3;
    var hash = offsetBasis;
    for (final unit in utf8.encode(input)) {
      hash ^= unit;
      hash = (hash * prime) & 0xFFFFFFFFFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }
}
