import 'dart:async';

import 'package:flutter/material.dart';
import '../models/book.dart';
import '../models/chapter.dart';
import '../services/api_service.dart';
import '../services/app_log.dart';
import '../services/app_settings.dart';
import '../services/local_cache_service.dart';
import '../services/error_text.dart';
import '../services/replace_engine.dart';
import '../services/replace_rule_store.dart';
import '../services/storage_service.dart';

/// 本次请求的净化**归谁负责**。
///
/// 【为什么是三态而不是一个 bool】
/// 如果既让服务端净化、又让本地引擎净化，正文会被**净化两遍** ——
/// `。` → `。\n` 这类规则会凭空多出一倍空行，而且极难看出是「跑了两遍」。
/// 所以先定一次「归谁管」，请求参数和后续处理都用同一个值，两边不可能都做。
enum _ReplaceRoute {
  /// 净化关掉了（全局开关或书级开关）。
  none,

  /// 交给服务端（`useReplaceRule=1`）。
  server,

  /// 交给客户端本地引擎（`useReplaceRule=0`，客户端自己算）。
  local,
}

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

  /// 本次请求的净化归谁负责。**每次请求只算一次，请求参数和后续处理共用它**。
  ///
  /// 三态的含义见 [_ReplaceRoute]。
  _ReplaceRoute get _replaceRoute {
    if (!useReplaceRule) return _ReplaceRoute.none;
    if (AppSettings.instance.replaceEngine == ReplaceEngine.server) {
      return _ReplaceRoute.server;
    }
    // 本地引擎要接管，但**手头一条规则都没有** —— 这时不能就这么放过去，
    // 用户会看到「开了净化却什么都没发生」。退回让服务端做，是这一层最重要
    // 的兜底：刚装好 App 还没同步过规则、离线、规则接口报错都走这里。
    if (ReplaceRuleStore.instance.isEmpty) return _ReplaceRoute.server;
    return _ReplaceRoute.local;
  }

  /// 发给服务端的净化开关 —— **只有归服务端管时才发 1**。
  int get _serverReplaceFlag => _replaceRoute == _ReplaceRoute.server ? 1 : 0;

  /// 章节缓存目录用的规则指纹：只有本地引擎才带。
  ///
  /// 带上它之后「规则一变、缓存自动作废」是**目录名层面**保证的，
  /// 不再依赖谁记得调 `clearBookChapterCache`。走服务端时规则版本在服务端、
  /// 客户端看不见，只能返回 null（目录仍是 `replace_on`）。
  String? get _cacheRuleFingerprint => _replaceRoute == _ReplaceRoute.local
      ? ReplaceRuleStore.instance.fingerprint
      : null;

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
      // 本地净化引擎是在读正文时跑的，那时手里必须已经有规则 —— 先把本地
      // 副本准备好（首次会顺带从服务端拉一次）。拿不到也不打断开书。
      await _ensureLocalRules(accessToken);
      final route = _replaceRoute;

      // 【并行发这两个请求】章节列表和「已读章节」互不依赖，串行等于白白
      // 多等一个 RTT。打开书的首屏等待主要由这两个决定（正文另算）。
      final chaptersFuture = ApiService.instance.getChapterListNew(
        accessToken,
        _book!.bookUrl ?? '',
        _book!.origin ?? '',
        bookname: _book!.name,
        useReplaceRule: route == _ReplaceRoute.server ? 1 : 0,
      );
      final readFuture = _safeBookread(accessToken, _book!.bookUrl ?? '');

      _chapters = await chaptersFuture;

      // 本地引擎接管时**章节标题也要自己净化**：服务端那半（`scopeTitle` 那组
      // 规则）我们已经不请求了，不做这一步，切到本地之后目录会突然不再净化。
      // 先问一句「有没有标题规则」—— 章节列表动辄几千条，没有就整个跳过。
      if (route == _ReplaceRoute.local &&
          ReplaceRuleStore.instance.hasTitleRules) {
        for (final chapter in _chapters) {
          final title = chapter.title;
          if (title == null || title.isEmpty) continue;
          chapter.title = _purifyLocally(title, forTitle: true);
        }
      }

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

    final route = _replaceRoute;
    final data = await ApiService.instance.getBookContentNew(
      accessToken,
      _book!.bookUrl ?? '',
      chapterIndex,
      _book!.origin ?? '',
      bookname: _book!.name,
      // 【必须是这一处算出来的 route，不能写成 `useReplaceRule ? 1 : 0`】
      // 那个写法只看「开关开没开」，不看「谁来执行」—— 结果是本地引擎开着时
      // 服务端也净化一遍，正文被净化两遍（`。` → `。\n` 会多出一倍空行）。
      useReplaceRule: route == _ReplaceRoute.server ? 1 : 0,
    );
    final raw = data['text']?.toString() ?? '';
    final text = route == _ReplaceRoute.local
        ? _purifyLocally(raw, forTitle: false)
        : raw;
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

    final route = _replaceRoute;
    final data = await ApiService.instance.getBookContentNew(
      accessToken,
      _book!.bookUrl ?? '',
      chapterIndex,
      _book!.origin ?? '',
      bookname: _book!.name,
      // 同 getChapterContent：只看 route，保证本地/服务端二选一。
      useReplaceRule: route == _ReplaceRoute.server ? 1 : 0,
    );
    final raw = data['text']?.toString() ?? '';
    return route == _ReplaceRoute.local
        ? _purifyLocally(raw, forTitle: false)
        : raw;
  }

  /// 保证本地有一份可用规则（本地净化引擎要用）。
  ///
  /// 顺序是「先读本地副本 → 空了再问服务端」：副本命中就一个请求都不用发，
  /// 这是绝大多数情况（规则很少变）。拿不到就静默放弃 —— 此时
  /// [_replaceRoute] 会自动退回服务端净化，不会让用户看到「净化没生效」。
  Future<void> _ensureLocalRules(String accessToken) async {
    if (AppSettings.instance.replaceEngine != ReplaceEngine.local) return;
    if (!useReplaceRule) return;
    final store = ReplaceRuleStore.instance;
    await store.load();
    if (!store.isEmpty) return;
    // 已经成功同步过一次（结果就是「没有规则」）→ 不必每开一本书都再问一遍。
    if (store.syncedThisSession) return;
    try {
      final rules = await ApiService.instance.fetchAllReplaceRules(accessToken);
      await store.save(rules);
    } catch (_) {
      // 拉失败就不置位，下次开书还会重试。
    }
  }

  /// 用本地引擎净化一段文本（正文或章节标题）。
  ///
  /// 返回净化后的文本；没有规则或没有任何规则命中时原样返回。
  ///
  /// 【失败规则的处理】超时的规则会在**本地副本**里被停用，对应官方那句
  /// `if (i.a === l.a && i.y) A.N6(l.a, "0")`。正则非法之类只记日志、
  /// 不动用户的规则 —— 官方的 `if (j instanceof A.MM)` 也只在超时才停用。
  String _purifyLocally(String text, {required bool forTitle}) {
    if (text.isEmpty) return text;
    final rules = ReplaceRuleStore.instance.rules;
    if (rules.isEmpty) return text;

    final outcome = ReplaceEngine.apply(
      content: text,
      rules: rules,
      bookName: _book?.name ?? '',
      bookOrigin: _book?.origin ?? '',
      forTitle: forTitle,
      // 【为什么是 false（= 不逐行 trim）】
      // 服务端在套规则前会 `re.lines().joinToString("\n"){ it.trim() }`，
      // 而官方客户端三端的本地引擎都没有这一步 —— 已用线上真实章节对拍确认：
      // 去掉空白后两边逐字一致，差的就是这个 trim。
      // 中文网文的段首缩进是全角空格 `\u3000\u3000`，trim 会连缩进一起吃掉，
      // 所以这里跟随官方客户端保留缩进。想让本地和服务端逐字一致就改成 true。
      trimLines: false,
    );

    for (final log in outcome.logs) {
      AppLog.add(log);
    }

    final timedOut = outcome.failures
        .where((failure) => failure.kind == 'timeout')
        .map((failure) => failure.rule.id)
        .whereType<String>()
        .toList();
    if (timedOut.isNotEmpty) {
      unawaited(ReplaceRuleStore.instance.disableLocally(timedOut));
    }

    return outcome.content;
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
  /// 【为什么还要传 accessToken 重新拉一次规则】
  /// 本地净化引擎用的是 [ReplaceRuleStore] 里那份**本地副本** —— 刚写进服务端
  /// 的新规则不在里面。不刷这一下，本地引擎就会拿旧规则去净化，
  /// 又变回「规则写进去了但正文没变」。传 null 就跳过（调用方拿不到 token 时）。
  Future<void> invalidateChapterCacheAfterReplaceRuleChange({
    String? accessToken,
  }) async {
    _prefetchCache.clear();
    if (accessToken != null &&
        accessToken.isNotEmpty &&
        AppSettings.instance.replaceEngine == ReplaceEngine.local) {
      try {
        final rules =
            await ApiService.instance.fetchAllReplaceRules(accessToken);
        await ReplaceRuleStore.instance.save(rules);
      } catch (_) {
        // 拉不到就用旧的本地副本，至少不比刷新前更差。
      }
    }
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
      ruleFingerprint: _cacheRuleFingerprint,
    );
  }

  Future<void> _writeCachedChapterContent(int chapterIndex, String text) async {
    if (_book?.bookUrl == null || text.isEmpty) return;
    await LocalCacheService.instance.writeChapterContent(
      bookUrl: _book!.bookUrl!,
      chapterIndex: chapterIndex,
      useReplaceRule: useReplaceRule,
      content: text,
      ruleFingerprint: _cacheRuleFingerprint,
    );
  }

  Future<void> _pruneChapterCaches(Set<int> keepIndices) async {
    if (_book?.bookUrl == null) return;
    await LocalCacheService.instance.pruneChapterCache(
      bookUrl: _book!.bookUrl!,
      useReplaceRule: useReplaceRule,
      keepIndices: keepIndices,
      ruleFingerprint: _cacheRuleFingerprint,
    );
  }
}
