import 'package:flutter/material.dart';
import '../models/book.dart';
import '../models/chapter.dart';
import '../services/api_service.dart';
import '../services/app_settings.dart';
import '../services/local_cache_service.dart';
import '../services/error_text.dart';
import '../services/storage_service.dart';

class ReaderProvider extends ChangeNotifier {
  Book? _book;
  List<Chapter> _chapters = [];
  Set<int> _readChapters = {};
  bool _loadingChapters = false;
  String? _error;

  // Prefetch cache: chapterIndex -> content text
  final Map<int, String> _prefetchCache = {};

  /// 净化是否生效：**书级开关和全局开关都要开着**。
  ///
  /// 【为什么必须把全局开关也纳入】
  /// 「我的 → 阅读偏好 → 替换净化」那个总开关以前只写进 `AppSettings`，
  /// 而这里只看书级的 `book.useReplaceRule` —— 于是全局关掉之后毫无效果，
  /// 那个开关等于是个摆设（`AppSettings.useReplaceRule` 全仓只有 UI 在读）。
  bool get useReplaceRule =>
      (_book?.useReplaceRule != false) && AppSettings.instance.useReplaceRule;

  Book? get book => _book;
  List<Chapter> get chapters => _chapters;
  Set<int> get readChapters => _readChapters;
  bool get loadingChapters => _loadingChapters;
  String? get error => _error;

  void setBook(Book book) {
    _book = book;
    _chapters = [];
    _readChapters = {};
    _prefetchCache.clear();
    _error = null;
    notifyListeners();
  }

  Future<void> loadChapters(String accessToken,
      {bool loadInitialContent = true}) async {
    if (_book == null) return;

    _loadingChapters = true;
    _error = null;
    notifyListeners();

    try {
      // 【并行发这两个请求】章节列表和「已读章节」互不依赖，串行等于白白
      // 多等一个 RTT。打开书的首屏等待主要由这两个决定（正文另算）。
      final chaptersFuture = ApiService.instance.getChapterListNew(
        accessToken,
        _book!.bookUrl ?? '',
        _book!.origin ?? '',
        bookname: _book!.name,
        useReplaceRule: useReplaceRule ? 1 : 0,
      );
      final readFuture = _safeBookread(accessToken, _book!.bookUrl ?? '');

      _chapters = await chaptersFuture;

      final readStr = await readFuture;
      if (readStr.isNotEmpty) {
        _readChapters = readStr
            .split(',')
            .map((s) => int.tryParse(s.trim()) ?? -1)
            .where((i) => i >= 0)
            .toSet();
      }

      _loadingChapters = false;
      notifyListeners();
      if (loadInitialContent) {
        final initialIndex =
            (_book?.durChapterIndex ?? 0).clamp(0, _chapters.length - 1);
        await getChapterContent(accessToken, initialIndex);
      }
    } catch (e) {
      _error = friendlyError(e);
      _loadingChapters = false;
      notifyListeners();
    }
  }

  /// 读「已读章节」失败不该影响打开书 —— 兜成空串。
  Future<String> _safeBookread(String accessToken, String bookUrl) async {
    try {
      return await ApiService.instance.getBookread(accessToken, bookUrl);
    } catch (_) {
      return '';
    }
  }

  Future<String> getChapterContent(String accessToken, int chapterIndex) async {
    if (_book == null || chapterIndex < 0 || chapterIndex >= _chapters.length) {
      return '';
    }

    if (_prefetchCache.containsKey(chapterIndex)) {
      return _prefetchCache[chapterIndex]!;
    }

    final cachedContent = await _readCachedChapterContent(chapterIndex);
    if (cachedContent != null) {
      _prefetchCache[chapterIndex] = cachedContent;
      return cachedContent;
    }

    final data = await ApiService.instance.getBookContentNew(
      accessToken,
      _book!.bookUrl ?? '',
      chapterIndex,
      _book!.origin ?? '',
      bookname: _book!.name,
      // 【必须是 getter，不能写成 `_book!.useReplaceRule == false ? 0 : 1`】
      // 后者只看书级开关，全局开关（我的 → 阅读偏好 → 替换净化）就被绕过了 ——
      // 这正是「全局关掉净化却没反应」的原因。三处调用点必须统一。
      useReplaceRule: useReplaceRule ? 1 : 0,
    );
    final text = data['text']?.toString() ?? '';
    _prefetchCache[chapterIndex] = text;
    await _writeCachedChapterContent(chapterIndex, text);
    return text;
  }

  /// 供「书内全文搜索」使用：**只读**缓存 / 网络，不写入 `_prefetchCache`。
  ///
  /// 为什么不能直接用 `getChapterContent`：它会往 `_prefetchCache` 里塞内容，
  /// 而那个 map 只在 `prefetchAround` 里按「当前章前后几章」裁剪。全文搜索会
  /// 把整本书几千章都读一遍 —— 走 `getChapterContent` 就等于把几千章正文
  /// 全留在内存里。这里只读不存，搜完即弃。
  Future<String> peekChapterContent(String accessToken, int chapterIndex) async {
    if (_book == null ||
        chapterIndex < 0 ||
        chapterIndex >= _chapters.length) {
      return '';
    }

    final cached = await _readCachedChapterContent(chapterIndex);
    if (cached != null) return cached;

    final data = await ApiService.instance.getBookContentNew(
      accessToken,
      _book!.bookUrl ?? '',
      chapterIndex,
      _book!.origin ?? '',
      bookname: _book!.name,
      // 同 getChapterContent：走 getter，让全局开关也管到这里。
      useReplaceRule: useReplaceRule ? 1 : 0,
    );
    return data['text']?.toString() ?? '';
  }

  Future<void> markReadChapter(String accessToken, int chapterIndex) async {
    if (_book == null || chapterIndex < 0) return;
    _readChapters.add(chapterIndex);
    notifyListeners();
    try {
      await ApiService.instance.addreadchapter(
        accessToken,
        chapterIndex.toString(),
        _book!.bookUrl ?? '',
      );
    } catch (_) {}
  }

  Future<void> prefetchAround(String accessToken, int centerIndex) async {
    if (_book == null || _chapters.isEmpty) return;
    final storage = await StorageService.instance;
    final cacheCount = storage.readerChapterCacheCount;
    final keepIndices = <int>{};
    final prevCount = (cacheCount - 1) ~/ 2;
    final nextCount = cacheCount - 1 - prevCount;
    final startIndex = (centerIndex - prevCount).clamp(0, _chapters.length - 1);
    final lastIndex = (centerIndex + nextCount).clamp(0, _chapters.length - 1);
    for (var index = startIndex; index <= lastIndex; index++) {
      keepIndices.add(index);
      if (!_prefetchCache.containsKey(index)) {
        try {
          await getChapterContent(accessToken, index);
        } catch (_) {}
      }
    }

    _prefetchCache.removeWhere((key, _) => !keepIndices.contains(key));
    await _pruneChapterCaches(keepIndices);
  }

  Future<void> clearLocalChapterCache() async {
    _prefetchCache.clear();
  }

  /// 「替换净化」规则变了（用户在阅读页点了「过滤」）—— 本地缓存的正文必须作废。
  ///
  /// 【为什么需要这个】
  /// `getChapterContent` 是「命中缓存就直接返回，不再请求后端」，而缓存目录
  /// 只按 `replace_on` / `replace_off` 分，**不带规则版本**。于是：
  ///   1. 用户读到第 300 章 → 这一章按「当时的规则」缓存了下来；
  ///   2. 用户长按选字 →「过滤」→ 规则写进服务端；
  ///   3. 界面读的还是第 1 步那份缓存 → **正文毫无变化**。
  /// 用户看到的就是「过滤不起效」，其实规则早就生效了，只是客户端没重新取。
  ///
  /// 清掉之后由调用方重取当前章即可。
  Future<void> invalidateChapterCacheAfterReplaceRuleChange() async {
    _prefetchCache.clear();
    final bookUrl = _book?.bookUrl;
    if (bookUrl != null && bookUrl.isNotEmpty) {
      await LocalCacheService.instance.clearBookChapterCache(bookUrl);
    }
    notifyListeners();
  }

  Future<void> saveProgress(
    String accessToken, {
    required int chapterIndex,
    required double pos,
    String? chapterTitle,
  }) async {
    if (_book == null) return;
    final savedIndex = chapterIndex;
    final savedTitle = chapterTitle ??
        ((chapterIndex >= 0 && chapterIndex < _chapters.length)
            ? _chapters[chapterIndex].title
            : null) ??
        _book!.durChapterTitle;
    final savedPos = pos;

    // 【本地字段必须**先**改，再发网络请求】
    // `_book` 是书架通过路由参数传进来的**同一个对象**
    // （`BookCard` → `/reader` → `ReaderProvider.setBook`）。
    // 原来这里 new 了一个新实例把它替换掉，于是书架持有的那个对象从此再也
    // 收不到进度更新 —— 表现就是「从阅读页退回书架，刚看的书不会排到最前，
    // 得手动下拉刷新」。原地改字段 + notifyListeners 效果一样，但引用还连着。
    //
    // 顺序也很重要：退出阅读页时书架会在 `didPopNext()` 里立刻重排，
    // 如果等到 `await` 网络请求回来才写 durChapterTime，重排早就跑完了，
    // 排序仍然用的是旧时间。所以先写本地，网络请求失败也不影响排序。
    //
    // 顺带修掉一个副作用：原来那份拷贝漏了 durChapterTime / wordCount /
    // kind / imageDecode 等字段，每次存进度都会把它们抹成 null。
    final book = _book;
    if (book != null) {
      book.durChapterTitle = savedTitle;
      book.durChapterIndex = savedIndex;
      book.durChapterPos = savedPos.toInt();
      // 最近阅读时间用**毫秒**时间戳（后端是 `System.currentTimeMillis()`）。
      // 书架「最近阅读」排序就靠它。
      book.durChapterTime = DateTime.now().millisecondsSinceEpoch;
      notifyListeners();
    }

    try {
      await ApiService.instance.saveBookProgress(
        accessToken,
        url: book?.bookUrl,
        title: savedTitle,
        index: savedIndex,
        pos: savedPos,
      );
    } catch (_) {}
  }

  Future<String?> _readCachedChapterContent(int chapterIndex) async {
    if (_book?.bookUrl == null) return null;
    return LocalCacheService.instance.readChapterContent(
      bookUrl: _book!.bookUrl!,
      chapterIndex: chapterIndex,
      useReplaceRule: useReplaceRule,
    );
  }

  Future<void> _writeCachedChapterContent(int chapterIndex, String text) async {
    if (_book?.bookUrl == null || text.isEmpty) return;
    await LocalCacheService.instance.writeChapterContent(
      bookUrl: _book!.bookUrl!,
      chapterIndex: chapterIndex,
      useReplaceRule: useReplaceRule,
      content: text,
    );
  }

  Future<void> _pruneChapterCaches(Set<int> keepIndices) async {
    if (_book?.bookUrl == null) return;
    await LocalCacheService.instance.pruneChapterCache(
      bookUrl: _book!.bookUrl!,
      useReplaceRule: useReplaceRule,
      keepIndices: keepIndices,
    );
  }
}
