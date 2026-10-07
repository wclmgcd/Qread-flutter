/// 本地缓存存储层的入口：对外只暴露 [CacheStore] 和 [createCacheStore]。
///
/// 具体用哪份实现由 `dart.library.js_interop` 在**编译期**决定 ——
/// 另一份的代码不会被编进产物里（Web 产物里不会出现 `dart:io`，
/// 原生产物里不会出现内存实现）。
library;

import 'cache_store_base.dart';
import 'cache_store_io.dart'
    if (dart.library.js_interop) 'cache_store_web.dart' as impl;

export 'cache_store_base.dart';

CacheStore createCacheStore() => impl.createCacheStore();
