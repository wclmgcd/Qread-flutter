import 'cache_store_base.dart';

/// 浏览器端的实现：**内存 Map**。
///
/// 【为什么不做 IndexedDB 持久化】
/// 1. 缓存里的东西（章节正文、书架、发现页、书源列表）**全都是能重建的** ——
///    源站和后端随时能再取一次。丢了只影响首屏速度，不会丢用户数据。
/// 2. 章节正文体积大（一本几百章），塞进 IndexedDB 要自己处理配额、
///    版本迁移、异步事务，代码量和出错面都不小。
/// 3. 真正的用户数据（登录态、阅读进度、设置）走的是 `shared_preferences`，
///    它在 Web 上本来就持久化（localStorage / IndexedDB），不受这里影响。
///
/// 所以浏览器端用「刷新即失效」的内存缓存，换取零额外依赖、零迁移负担。
CacheStore createCacheStore() => _MemoryCacheStore();

class _MemoryCacheStore implements CacheStore {
  final Map<String, String> _files = <String, String>{};

  @override
  Future<String?> readText(String path) async => _files[path];

  @override
  Future<void> writeText(String path, String data) async {
    _files[path] = data;
  }

  @override
  Future<List<String>> listNames(String dir) async {
    final prefix = dir.endsWith('/') ? dir : '$dir/';
    return <String>[
      for (final key in _files.keys)
        if (key.startsWith(prefix) &&
            !key.substring(prefix.length).contains('/'))
          key.substring(prefix.length),
    ];
  }

  @override
  Future<void> deleteTree(String path) async {
    final prefix = path.endsWith('/') ? path : '$path/';
    _files.removeWhere((key, _) => key == path || key.startsWith(prefix));
  }

  @override
  Future<void> deleteAll() async {
    _files.clear();
  }
}
