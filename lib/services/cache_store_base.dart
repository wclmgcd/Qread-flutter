/// 本地缓存的「文件层」抽象 —— 全项目只有这一层跟平台绑定。
///
/// 【为什么必须单独抽出来】
/// 原来 `LocalCacheService` 直接 `import 'dart:io'`（`File` / `Directory`），
/// 并用 `path_provider` 取应用目录。这两样在 Web 上都不存在，于是
/// `flutter build web` **在编译期就失败**（`dart:io` 在 Web 上不可用），
/// 整个项目出不了网页版 —— 而网页版是「浏览器端也能同步历史」的唯一前提。
///
/// 把「读写文件」收敛成这一个接口之后，各平台各给一份实现：
///   - `cache_store_io.dart`  → 真实文件系统（Android / iOS / Windows / macOS / Linux）
///   - `cache_store_web.dart` → 内存 Map（浏览器，刷新页面即失效）
/// 上层 `LocalCacheService` 的公开 API 一个都不用改。
///
/// 【这个文件为什么不带任何 import】
/// 它是「抽象」与「实现」的共同依赖。把接口单独放一个文件，
/// 可以避免 `cache_store.dart`（条件导入实现）和实现文件之间形成
/// 循环 import —— 循环虽然合法，但会让条件导入的解析变得难以推理。
///
/// 【路径约定】统一用 `/` 分隔，由实现自己决定要不要换成 `Platform.pathSeparator`。
abstract class CacheStore {
  /// 读一个文本文件；不存在或读失败返回 null（缓存读不到不是错误）。
  Future<String?> readText(String path);

  /// 写一个文本文件，父目录会自动建。
  Future<void> writeText(String path, String data);

  /// 列出某个目录下的**直接**文件名（不含子目录）；目录不存在返回空表。
  Future<List<String>> listNames(String dir);

  /// 列出某个目录下的**直接**子目录名；目录不存在返回空表。
  ///
  /// 【为什么要它】「常规设置 → 缓存管理」要枚举 `reader/<书哈希>/` 下面
  /// 有哪些变体目录（`replace_off` / `replace_on` / `replace_on_<指纹>`），
  /// 才知道这本书到底缓存了几份、分别是不是净化过的。
  Future<List<String>> listDirs(String dir);

  /// 某个路径占用的字节数。
  ///
  /// 传文件就是它自己的大小；传目录则**递归累加**里面所有文件的大小。
  /// 路径不存在返回 0（缓存统计不到不该报错）。
  ///
  /// 【为什么按字节而不是按文件数】缓存管理页要显示「这本书占了多少空间」，
  /// 用户关心的是体积。
  Future<int> sizeOf(String path);

  /// 删除一个文件或一整个目录（递归）。目标不存在时静默返回。
  Future<void> deleteTree(String path);

  /// 清掉整个缓存根目录。
  Future<void> deleteAll();
}
