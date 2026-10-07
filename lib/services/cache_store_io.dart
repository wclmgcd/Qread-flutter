import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'cache_store_base.dart';

/// 原生端（Android / iOS / Windows / macOS / Linux）的实现：真实文件系统。
///
/// 缓存根目录 = `getApplicationSupportDirectory()/local_cache`，
/// 与改造之前完全一致，所以升级后**老缓存仍然能命中**，不会白丢一次。
CacheStore createCacheStore() => _IoCacheStore();

class _IoCacheStore implements CacheStore {
  Directory? _root;

  Future<Directory> _rootDir() async {
    final cached = _root;
    if (cached != null) return cached;
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}local_cache');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _root = dir;
    return dir;
  }

  /// 把统一的 `/` 路径换成当前平台的分隔符，并拼到根目录下
  Future<String> _fullPath(String path) async {
    final root = await _rootDir();
    final local = path.replaceAll('/', Platform.pathSeparator);
    return '${root.path}${Platform.pathSeparator}$local';
  }

  @override
  Future<String?> readText(String path) async {
    final file = File(await _fullPath(path));
    if (!await file.exists()) return null;
    try {
      return await file.readAsString();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> writeText(String path, String data) async {
    final file = File(await _fullPath(path));
    await file.parent.create(recursive: true);
    await file.writeAsString(data, flush: true);
  }

  @override
  Future<List<String>> listNames(String dir) async {
    final directory = Directory(await _fullPath(dir));
    if (!await directory.exists()) return const [];
    final entries = await directory.list().toList();
    return <String>[
      for (final entry in entries)
        if (entry is File) entry.uri.pathSegments.last,
    ];
  }

  @override
  Future<void> deleteTree(String path) async {
    final full = await _fullPath(path);
    // 【必须先判类型】`deleteTree` 既可能收到目录（整本缓存），
    // 也可能收到单个文件（pruneChapterCache 就是逐个删 `.txt`）。
    // 对文件调 `Directory.delete` 会抛 FileSystemException。
    final type = await FileSystemEntity.type(full);
    if (type == FileSystemEntityType.notFound) return;
    if (type == FileSystemEntityType.directory) {
      await Directory(full).delete(recursive: true);
    } else {
      await File(full).delete();
    }
  }

  @override
  Future<void> deleteAll() async {
    // 用缓存的 _root 直接删，避免为了删一个目录再去问一次 path_provider
    final root = _root;
    _root = null;
    final dir = root ??
        Directory(
          '${(await getApplicationSupportDirectory()).path}'
          '${Platform.pathSeparator}local_cache',
        );
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }
}
