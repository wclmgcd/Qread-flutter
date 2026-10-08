import 'dart:convert';
import 'package:dio/dio.dart';
import '../config/constants.dart';
import '../models/book.dart';
import '../models/book_source.dart';
import '../models/rss_source.dart';
import '../models/rss_article.dart';
import '../models/search_result.dart';
import '../models/chapter.dart';
import '../models/book_group.dart';
import '../models/replace_rule.dart';
import '../models/tts_engine.dart';
// /getCookies、/saveCookies 的 cookie 载荷是 AES/CBC 加密的 hex（上游如此）
import 'aes_codec.dart';

class ApiService {
  static ApiService? _instance;
  late Dio _dio;

  /// 建连超时：15s。
  ///
  /// 对齐 legado 的 `HttpHelper.kt`（`connectTimeout(15, SECONDS)`）。
  /// 建连慢到这个程度基本就是网络本身不通，再等也没意义。
  static const Duration kConnectTimeout = Duration(seconds: 15);

  /// 收数据超时：60s。
  ///
  /// 【为什么从 15s 提到 60s】
  /// 用户报过 `DioException [receive timeout]: The request took longer than
  /// 0:00:15.000000 to receive data`。15s 对**首字节**是够的，但这里的
  /// `receiveTimeout` 卡的是「两次收到数据之间的间隔」——
  /// 而这套后端有大量**同步阻塞**的接口：
  ///   - `/getBookSourcesPage` 之后要按 md5 逐页拉 `/getBookSourcesNew`；
  ///   - 搜索 / 换源 / 章节列表是后端去抓目标站，慢站动辄十几秒；
  ///   - `java.startBrowserAwait` 这类动作后端会**干等用户关网页**
  ///     （后端 `ApiWebSocket.WaitForResponse` 默认等 120s）。
  /// 只要中途 15s 没有新字节，dio 就掐断 —— 用户看到的就是「严重网络连接失败」。
  ///
  /// legado 官方客户端给读超时的就是 **60s**（`readTimeout(60, SECONDS)`），
  /// 而写超时/建连超时都是 15s。这里按同一套来。
  static const Duration kReceiveTimeout = Duration(seconds: 60);

  /// 发数据超时：15s（同样对齐 legado 的 `writeTimeout(15, SECONDS)`）。
  static const Duration kSendTimeout = Duration(seconds: 15);

  ApiService._() {
    _dio = Dio(BaseOptions(
      baseUrl: AppConstants.apiBase,
      // dio 5 起 connectTimeout / receiveTimeout 的类型从 int 变成 Duration
      connectTimeout: kConnectTimeout,
      receiveTimeout: kReceiveTimeout,
      sendTimeout: kSendTimeout,
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
    ));
    _dio.interceptors
        .add(LogInterceptor(requestBody: true, responseBody: true));
    _dio.interceptors.add(InterceptorsWrapper(
      onResponse: (response, handler) {
        // 后端部分响应 content-type 为 text/plain，Dio 不自动 JSON 解码
        if (response.data is String) {
          try {
            response.data = jsonDecode(response.data as String);
          } catch (_) {
            // 非 JSON 字符串（如 appversion），保持原样
          }
        }
        handler.next(response);
      },
    ));
  }

  static ApiService get instance => _instance ??= ApiService._();

  void setToken(String token) {
    // 后端通过 accessToken 查询参数认证，不需要 Bearer header
  }

  void setBaseUrl(String url) {
    AppConstants.baseUrl = url;
    _dio.options.baseUrl = AppConstants.apiBase;
  }

  Options _plainTextBodyOptions() {
    return Options(
      contentType: Headers.textPlainContentType,
      responseType: ResponseType.json,
    );
  }

  Options _jsonBodyOptions() {
    return Options(
      contentType: Headers.jsonContentType,
      responseType: ResponseType.json,
    );
  }

  // ============ 本地书籍 ============

  /// 上传本地书（txt / epub / mobi / azw / azw3 / prc），后端解析、生成章节并入库。
  ///
  /// 返回体里 `data.books` 是书籍信息、`data.chapters` 是章节列表；
  /// 失败时 `isSuccess=false`，`errorMsg` 是可直接展示的中文
  /// （如「当前文件格式不支持」「不允许导入图书」）。
  ///
  /// 【为什么单独放宽超时】
  /// 全局 sendTimeout 是 15s、receiveTimeout 是 60s，那是给普通接口的。
  /// 这里一次要传整本书（几 MB），后端还要现场解压 mobi / 解析 epub、
  /// 生成章节并写缓存，耗时远大于普通请求，沿用全局值会误报超时。
  Future<Map<String, dynamic>> importBookPreview(
    String accessToken,
    String filePath,
    String fileName,
  ) async {
    final formData = FormData.fromMap({
      'file': await MultipartFile.fromFile(filePath, filename: fileName),
    });
    final resp = await _dio.post(
      '/importBookPreview',
      data: formData,
      queryParameters: {'accessToken': accessToken},
      options: Options(
        sendTimeout: const Duration(minutes: 2),
        receiveTimeout: const Duration(minutes: 2),
      ),
    );
    return resp.data;
  }

  // ============ 用户 ============

  Future<Map<String, dynamic>> login(String username, String password) async {
    final resp = await _dio.post('/login', data: {
      'username': username,
      'password': password,
    });
    return resp.data;
  }

  Future<Map<String, dynamic>> register(
      String username, String password) async {
    // 后端没有独立的注册接口，注册也走 /login
    final resp = await _dio.post('/login', data: {
      'username': username,
      'password': password,
    });
    return resp.data;
  }

  Future<Map<String, dynamic>> getUserInfo(String accessToken) async {
    final resp = await _dio.get('/getUserInfo', queryParameters: {
      'accessToken': accessToken,
    });
    return resp.data;
  }

  // ============ 书架 ============

  Future<Map<String, dynamic>> getBookshelfPage(String accessToken) async {
    final resp = await _dio.get('/getBookshelfPage', queryParameters: {
      'accessToken': accessToken,
    });
    return resp.data;
  }

  Future<List<Book>> getBookshelfNew(String accessToken,
      {String? md5, int page = 1}) async {
    final params = <String, dynamic>{
      'accessToken': accessToken,
      'page': page.toString(),
    };
    if (md5 != null) params['md5'] = md5;
    final resp = await _dio.get('/getBookshelfNew', queryParameters: params);
    final data = resp.data['data'];
    if (data is List) {
      return data.map((e) => Book.fromJson(e as Map<String, dynamic>)).toList();
    }
    return [];
  }

  Future<Map<String, dynamic>> saveBookProgress(
    String accessToken, {
    String? url,
    String? title,
    int? index,
    double? pos,
    String? isnew,
  }) async {
    final resp = await _dio.post('/saveBookProgress', queryParameters: {
      'accessToken': accessToken,
      if (url != null) 'url': url,
      if (title != null) 'title': title,
      if (index != null) 'index': index,
      if (pos != null) 'pos': pos,
      if (isnew != null) 'isnew': isnew,
    });
    return resp.data;
  }

  Future<String> getBookread(String accessToken, String url) async {
    final resp = await _dio.get('/getBookread', queryParameters: {
      'accessToken': accessToken,
      'url': url,
    });
    return resp.data['data']?.toString() ?? '';
  }

  Future<Map<String, dynamic>> addreadchapter(
      String accessToken, String readchapter, String url) async {
    final resp = await _dio.post('/addreadchapter', queryParameters: {
      'accessToken': accessToken,
      'readchapter': readchapter,
      'url': url,
    });
    return resp.data;
  }

  Future<Map<String, dynamic>> deleteBooks(
      String accessToken, List<String> ids) async {
    final resp = await _dio.post('/deleteBooks', data: ids);
    return resp.data;
  }

  // ============ 书籍 ============

  Future<Map<String, dynamic>> getBookInfo(
      String accessToken, String bookUrl, String sourceUrl) async {
    final resp = await _dio.get('/getBookinfo', queryParameters: {
      'accessToken': accessToken,
      'url': bookUrl,
      'source': sourceUrl,
    });
    return resp.data;
  }

  Future<List<Chapter>> getChapterList(
      String accessToken, String bookUrl, String sourceUrl) async {
    final resp = await _dio.get('/getChapterList', queryParameters: {
      'accessToken': accessToken,
      'url': bookUrl,
      'source': sourceUrl,
    });
    final data = resp.data['data'];
    if (data is List) {
      return data
          .map((e) => Chapter.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    return [];
  }

  Future<List<Chapter>> getChapterListNew(
    String accessToken,
    String bookUrl,
    String sourceUrl, {
    String? bookname,
    int? useReplaceRule,
    int? needRefresh,
  }) async {
    final resp = await _dio.get('/getChapterListNew', queryParameters: {
      'accessToken': accessToken,
      'url': bookUrl,
      'bookSourceUrl': sourceUrl,
      if (bookname != null) 'bookname': bookname,
      if (useReplaceRule != null) 'useReplaceRule': useReplaceRule,
      if (needRefresh != null) 'needRefresh': needRefresh,
    });
    final data = resp.data['data'];
    if (data is List) {
      return data
          .map((e) => Chapter.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    return [];
  }

  Future<String> getBookContent(String accessToken, String bookUrl,
      int chapterIndex, String sourceUrl) async {
    final resp = await _dio.get('/getBookContent', queryParameters: {
      'accessToken': accessToken,
      'url': bookUrl,
      'index': chapterIndex,
      'source': sourceUrl,
    });
    return resp.data['data']?.toString() ?? '';
  }

  /// 取正文。
  ///
  /// 【`type` 为什么默认 0 且必须发出去】
  /// 后端的净化判断是 `if (type == 0 && bookname 非空 && useReplaceRule == 1)`，
  /// 而 `type` 在 Kotlin 侧是可空 `Int?` —— **`null == 0` 是 false**，
  /// 所以只要客户端不发 `type`，「替换净化」就**永远不执行**。
  ///
  /// 注意别被后端内部骗了：取正文时它写的是 `type ?: 0`（null 当 0 用），
  /// 所以**不传 type 正文照样能拿到**，只是净化被静默跳过 —— 这正是这个 bug
  /// 藏了很久、看起来「功能正常只是净化没反应」的原因。
  ///
  /// 传 0 不改变缓存行为：`type != 1` 才走缓存，0 和 null 在这里等价。
  Future<Map<String, dynamic>> getBookContentNew(
    String accessToken,
    String bookUrl,
    int chapterIndex,
    String sourceUrl, {
    int type = 0,
    String? bookname,
    int? useReplaceRule,
  }) async {
    final resp = await _dio.get('/getBookContentNew', queryParameters: {
      'accessToken': accessToken,
      'url': bookUrl,
      'index': chapterIndex,
      'bookSourceUrl': sourceUrl,
      'type': type,
      if (bookname != null) 'bookname': bookname,
      if (useReplaceRule != null) 'useReplaceRule': useReplaceRule,
    });
    return resp.data['data'] ?? {};
  }

  // ============ 段评 / 书源交互 ============

  /// 执行书源里的一个 JS 表达式并取回它解析出的 URL。
  ///
  /// 段评就是靠这个：正文气泡带着 `click: "showCmt(...)"`，
  /// 客户端把 `<js>showCmt(...)</js>` 交给后端执行，
  /// 书源 JS 内部会调 `java.startBrowserDp/startBrowser`，
  /// 后端再把要打开的网页通过 WebSocket 推回来。
  Future<String> getOpenUrl(
    String accessToken, {
    required String bookSourceUrl,
    required String url,
    String? bookurl,
  }) async {
    final resp = await _dio.get('/getopenurl', queryParameters: {
      'accessToken': accessToken,
      'bookSourceUrl': bookSourceUrl,
      'url': url,
      if (bookurl != null) 'bookurl': bookurl,
    });
    return resp.data['data']?.toString() ?? '';
  }

  /// 给后端的 WebView / 浏览器请求回执，释放服务端 `WaitForResponse`。
  Future<void> saveHtml(String accessToken,
      {required String id, String html = ''}) async {
    await _dio.post('/savehtml', queryParameters: {
      'accessToken': accessToken,
      'id': id,
      'html': html,
    });
  }

  /// 放掉后端正在等待的一次客户端回执（`WaitForResponse(id)`）。
  ///
  /// 后端有一批推送是**阻塞等回执**的：`get` / `head` / `post` / `webview` /
  /// `getVerificationCode` / `getWebViewUA` / `getVerificationCodeusePhone`。
  /// 我们没实现这些（官方 Web 客户端也只弹一句「不支持」），但**必须回一个空响应**，
  /// 否则书源 JS 里那次调用要干等 120s 才超时 —— 用户看到的就是「点了没反应」。
  Future<void> noCookies(String accessToken, {required String id}) async {
    await _dio.get('/noCookies', queryParameters: {
      'accessToken': accessToken,
      'id': id,
    });
  }

  // ============ 搜索 ============

  Future<List<SearchResult>> searchBook(String accessToken, String keyword,
      {String? bookSourceUrl, int page = 1}) async {
    final params = <String, dynamic>{
      'accessToken': accessToken,
      'key': keyword,
      'page': page,
    };
    if (bookSourceUrl != null) params['bookSourceUrl'] = bookSourceUrl;
    final resp = await _dio.get('/searchBook', queryParameters: params);
    final data = resp.data['data'];
    if (data is List) {
      return data
          .map((e) => SearchResult.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    return [];
  }

  // ============ 发现 ============

  Future<Map<String, dynamic>> getExplore(
      String accessToken, String sourceUrl, String exploreUrl,
      {int page = 1}) async {
    final resp = await _dio.get('/exploreBook', queryParameters: {
      'accessToken': accessToken,
      'bookSourceUrl': sourceUrl,
      'page': page,
      'ruleFindUrl': exploreUrl,
    });
    return resp.data;
  }

  Future<Map<String, dynamic>> getBookSourcesExploreUrl(
      String accessToken, String bookSourceUrl,
      {int need = 1}) async {
    final resp = await _dio.get('/getBookSourcesExploreUrl', queryParameters: {
      'accessToken': accessToken,
      'bookSourceUrl': bookSourceUrl,
      'need': need,
    });
    return resp.data;
  }

  // ============ 书源 ============

  Future<Map<String, dynamic>> getBookSourcesPage(String accessToken) async {
    final resp = await _dio.get('/getBookSourcesPage', queryParameters: {
      'accessToken': accessToken,
    });
    return resp.data;
  }

  Future<List<BookSource>> getBookSourcesNew(String accessToken,
      {String? md5, int page = 1}) async {
    final params = <String, dynamic>{
      'accessToken': accessToken,
      'page': page.toString(),
    };
    if (md5 != null) params['md5'] = md5;
    final resp = await _dio.get('/getBookSourcesNew', queryParameters: params);
    final json = resp.data;
    if (json['isSuccess'] == true && json['data'] is List) {
      return (json['data'] as List)
          .map((e) => BookSource.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    return [];
  }

  /// Fallback: 直接获取书源列表（无缓存）
  Future<List<BookSource>> getBookSources(String accessToken) async {
    final resp = await _dio.get('/getBookSources', queryParameters: {
      'accessToken': accessToken,
    });
    final json = resp.data;
    if (json['isSuccess'] == true && json['data'] is List) {
      return (json['data'] as List)
          .map((e) => BookSource.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    return [];
  }

  Future<bool> getCanSource(String accessToken) async {
    final resp = await _dio.get('/getcansource', queryParameters: {
      'accessToken': accessToken,
    });
    final json = resp.data;
    // 后端有权限时返回 {"isSuccess": true}（无 data 字段）
    // 无权限时返回 {"isSuccess": false, "errorMsg": "CAN_NOT"}
    if (json['isSuccess'] == true) {
      return true;
    }
    return false;
  }

  Future<Map<String, dynamic>> saveBookSources(
      String accessToken, String content) async {
    final resp = await _dio.post('/saveBookSources',
        queryParameters: {'accessToken': accessToken},
        data: content,
        options: _plainTextBodyOptions());
    return resp.data;
  }

  Future<Map<String, dynamic>> saveBookSourcesV2(
    String accessToken, {
    String? group,
    required String source,
    String? urls,
  }) async {
    final resp = await _dio.post('/saveBookSourcesv2', queryParameters: {
      'accessToken': accessToken,
      if (group != null) 'group': group,
      'source': source,
      if (urls != null) 'urls': urls,
    });
    return resp.data;
  }

  Future<Map<String, dynamic>> saveBookSource(
      String accessToken, String content) async {
    final resp = await _dio.post('/saveBookSource',
        queryParameters: {'accessToken': accessToken},
        data: content,
        options: _plainTextBodyOptions());
    return resp.data;
  }

  Future<Map<String, dynamic>> getbookSources(
      String accessToken, String id) async {
    final resp = await _dio.get('/getbookSources', queryParameters: {
      'accessToken': accessToken,
      'id': id,
    });
    return resp.data;
  }

  Future<Map<String, dynamic>> editbookSources(String accessToken,
      {String? id, required String json}) async {
    final resp = await _dio.post('/editbookSources',
        queryParameters: {'accessToken': accessToken},
        data: {'id': id, 'json': json});
    return resp.data;
  }

  Future<Map<String, dynamic>> delbookSource(
      String accessToken, String id) async {
    final resp = await _dio.post('/delbookSource', queryParameters: {
      'accessToken': accessToken,
      'id': id,
    });
    return resp.data;
  }

  Future<Map<String, dynamic>> delbookSources(
      String accessToken, List<String> ids) async {
    final resp = await _dio.post('/delbookSources',
        queryParameters: {'accessToken': accessToken},
        data: ids,
        options: _jsonBodyOptions());
    return resp.data;
  }

  Future<Map<String, dynamic>> stopbookSource(String accessToken, String id,
      {required int st}) async {
    final resp = await _dio.post('/stopbookSource', queryParameters: {
      'accessToken': accessToken,
      'id': id,
      'st': st,
    });
    return resp.data;
  }

  Future<Map<String, dynamic>> stopbookSources(
      String accessToken, List<String> ids) async {
    final resp = await _dio.post('/stopbookSources',
        queryParameters: {'accessToken': accessToken},
        data: ids,
        options: _jsonBodyOptions());
    return resp.data;
  }

  Future<Map<String, dynamic>> startbookSources(
      String accessToken, List<String> ids) async {
    final resp = await _dio.post('/startbookSources',
        queryParameters: {'accessToken': accessToken},
        data: ids,
        options: _jsonBodyOptions());
    return resp.data;
  }

  Future<Map<String, dynamic>> stopbookSourceExplores(
      String accessToken, List<String> ids) async {
    final resp = await _dio.post('/stopbookSourceExplores',
        queryParameters: {'accessToken': accessToken},
        data: ids,
        options: _jsonBodyOptions());
    return resp.data;
  }

  Future<Map<String, dynamic>> startbookSourceExplores(
      String accessToken, List<String> ids) async {
    final resp = await _dio.post('/startbookSourceExplores',
        queryParameters: {'accessToken': accessToken},
        data: ids,
        options: _jsonBodyOptions());
    return resp.data;
  }

  Future<Map<String, dynamic>> topSource(String accessToken, String id) async {
    final resp = await _dio.post('/topSource', queryParameters: {
      'accessToken': accessToken,
      'id': id,
    });
    return resp.data;
  }

  Future<Map<String, dynamic>> bottomSource(
      String accessToken, String id) async {
    final resp = await _dio.post('/bottomSource', queryParameters: {
      'accessToken': accessToken,
      'id': id,
    });
    return resp.data;
  }

  Future<Map<String, dynamic>> topallSource(
      String accessToken, List<String> ids) async {
    final resp = await _dio.post('/topallSource',
        queryParameters: {'accessToken': accessToken},
        data: ids,
        options: _jsonBodyOptions());
    return resp.data;
  }

  Future<Map<String, dynamic>> bottomallSource(
      String accessToken, List<String> ids) async {
    final resp = await _dio.post('/bottomallSource',
        queryParameters: {'accessToken': accessToken},
        data: ids,
        options: _jsonBodyOptions());
    return resp.data;
  }

  Future<Map<String, dynamic>> editsourcegroup(
    String accessToken, {
    required String st,
    String? group,
    required List<String> ids,
  }) async {
    final resp = await _dio.post('/editsourcegroup',
        queryParameters: {
          'accessToken': accessToken,
          'st': st,
          if (group != null) 'group': group,
        },
        data: ids,
        options: _jsonBodyOptions());
    return resp.data;
  }

  Future<Map<String, dynamic>> getbookSourcejson(
      String accessToken, List<String> ids) async {
    final resp = await _dio.post('/getbookSourcejson',
        queryParameters: {'accessToken': accessToken},
        data: ids,
        options: _jsonBodyOptions());
    return resp.data;
  }

  Future<Map<String, dynamic>> getSourcesloginui(
    String accessToken, {
    String? url,
    String? bookurl,
    String? chapter,
  }) async {
    final resp = await _dio.get('/getSourcesloginui', queryParameters: {
      'accessToken': accessToken,
      if (url != null) 'url': url,
      if (bookurl != null) 'bookurl': bookurl,
      if (chapter != null) 'chapter': chapter,
    });
    return resp.data;
  }

  // ============ RSS ============

  Future<Map<String, dynamic>> getRssSourcesPage(String accessToken) async {
    final resp = await _dio.get('/getRssSourcessPage', queryParameters: {
      'accessToken': accessToken,
    });
    return resp.data;
  }

  Future<List<RssSource>> getRssSourcesNew(String accessToken,
      {String? md5, int page = 1}) async {
    final params = <String, dynamic>{
      'accessToken': accessToken,
      'page': page.toString(),
    };
    if (md5 != null) params['md5'] = md5;
    final resp = await _dio.get('/getRssSourcessNew', queryParameters: params);
    final json = resp.data;
    if (json['isSuccess'] == true && json['data'] is List) {
      return (json['data'] as List)
          .map((e) => RssSource.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    return [];
  }

  /// Fallback: 直接获取RSS源列表（无缓存）
  Future<List<RssSource>> getRssSources(String accessToken) async {
    final raw = await getRssSourcesRaw(accessToken);
    final json = raw['json'];
    final data = json['data'];
    final sourcesList = data is Map ? data['sources'] : data;
    if (json['isSuccess'] == true && sourcesList is List) {
      return sourcesList
          .map((e) => RssSource.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    return [];
  }

  Future<Map<String, dynamic>> getRssSourcesRaw(String accessToken) async {
    final resp = await _dio.get('/getRssSourcess', queryParameters: {
      'accessToken': accessToken,
    });
    final json = resp.data;
    final data = json['data'];
    final canEdit = data is Map ? data['can'] == true : false;
    return {
      'json': json,
      'canEdit': canEdit,
    };
  }

  Future<bool> getRssCanEdit(String accessToken) async {
    final raw = await getRssSourcesRaw(accessToken);
    return raw['canEdit'] == true;
  }

  Future<List<RssArticle>> getRssArticles(String accessToken, String sourceId,
      {String? sortUrl, int page = 1}) async {
    final params = <String, dynamic>{
      'accessToken': accessToken,
      'id': sourceId,
      'page': page,
    };
    if (sortUrl != null) params['sortUrl'] = sortUrl;
    final resp = await _dio.get('/getArticles', queryParameters: params);
    final data = resp.data['data'];
    final articles = data is Map ? data['articles'] : data;
    if (articles is List) {
      return articles
          .map((e) => RssArticle.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    return [];
  }

  Future<Map<String, dynamic>> getRssArticlesPage(
    String accessToken,
    String sourceId, {
    required String sortUrl,
    required String sortName,
    int page = 1,
  }) async {
    final resp = await _dio.get('/getArticles', queryParameters: {
      'accessToken': accessToken,
      'id': sourceId,
      'sortUrl': sortUrl,
      'sortName': sortName,
      'page': page,
    });
    return resp.data;
  }

  Future<Map<String, dynamic>> getRssType(String accessToken, String id) async {
    final resp = await _dio.get('/getRssType', queryParameters: {
      'accessToken': accessToken,
      'id': id,
    });
    return resp.data;
  }

  Future<List<Map<String, String>>> getRsssortUrls(
      String accessToken, String id) async {
    final resp = await _dio.get('/getRsssortUrls', queryParameters: {
      'accessToken': accessToken,
      'id': id,
    });
    final data = resp.data['data'];
    if (data is List) {
      return data.map((e) {
        final item = e as Map;
        return {
          'sortName': item['sortName']?.toString() ?? '',
          'sortUrl': item['sortUrl']?.toString() ?? '',
        };
      }).toList();
    }
    return [];
  }

  Future<Map<String, dynamic>> getRssContent(
    String accessToken, {
    required String id,
    required String article,
  }) async {
    final resp = await _dio.get('/getRssContent', queryParameters: {
      'accessToken': accessToken,
      'id': id,
      'article': article,
    });
    return resp.data;
  }

  Future<bool> rssshouldOverrideUrlLoading(
    String accessToken, {
    required String id,
    required String url,
  }) async {
    final resp =
        await _dio.get('/rssshouldOverrideUrlLoading', queryParameters: {
      'accessToken': accessToken,
      'id': id,
      'url': url,
    });
    final data = resp.data['data'];
    if (data is bool) return data;
    if (data is String) return data == 'true' || data == '1';
    if (data is num) return data != 0;
    return false;
  }

  Future<Map<String, dynamic>> getRssLoginInfo(
      String accessToken, String id) async {
    final resp = await _dio.get('/getRssLoginInfo', queryParameters: {
      'accessToken': accessToken,
      'id': id,
    });
    return resp.data;
  }

  Future<Map<String, dynamic>> putRssLoginInfo(
      String accessToken, String id, String info) async {
    final resp = await _dio.post('/putRssLoginInfo', queryParameters: {
      'accessToken': accessToken,
      'id': id,
      'info': info,
    });
    return resp.data;
  }

  Future<Map<String, dynamic>> rssaction(
      String accessToken, String id, String action) async {
    final resp = await _dio.post('/rssaction', queryParameters: {
      'accessToken': accessToken,
      'id': id,
      'action': action,
    });
    return resp.data;
  }

  Future<Map<String, dynamic>> getRssVariable(
      String accessToken, String id) async {
    final resp = await _dio.get('/getRssVariable', queryParameters: {
      'accessToken': accessToken,
      'id': id,
    });
    return resp.data;
  }

  Future<Map<String, dynamic>> setRssVariable(
      String accessToken, String id, String info) async {
    final resp = await _dio.post('/setRssVariable', queryParameters: {
      'accessToken': accessToken,
      'id': id,
      'info': info,
    });
    return resp.data;
  }

  Future<String> fetchRemoteText(String url,
      {Map<String, String>? headers}) async {
    final resp = await Dio(BaseOptions(
      // 这里拉的是**第三方**地址（书源 JSON 的下载链接），不是自家后端，
      // 慢站很常见，所以用同一套「建连 15s / 收数据 60s」。
      connectTimeout: kConnectTimeout,
      receiveTimeout: kReceiveTimeout,
      sendTimeout: kSendTimeout,
      responseType: ResponseType.plain,
      followRedirects: true,
      headers: headers,
    )).get<String>(url);
    return resp.data?.toString() ?? '';
  }

  Future<Map<String, dynamic>> saveRssSources(String accessToken,
      {String? source, String? urls}) async {
    final resp = await _dio.post('/saveRssSources',
        queryParameters: {
          'accessToken': accessToken,
          if (source != null) 'source': source,
          if (urls != null) 'urls': urls,
        },
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          responseType: ResponseType.json,
        ));
    return resp.data;
  }

  Future<Map<String, dynamic>> deleteRssSources(
      String accessToken, List<String> urls) async {
    final resp = await _dio.post('/delRssSources', queryParameters: {
      'accessToken': accessToken,
      'urls': urls.join(','),
    });
    return resp.data;
  }

  Future<Map<String, dynamic>> editRssSources(String accessToken,
      {String? id, required String json}) async {
    final resp = await _dio.post('/editRssSources',
        queryParameters: {'accessToken': accessToken},
        data: {'id': id, 'json': json},
        options: _jsonBodyOptions());
    return resp.data;
  }

  Future<Map<String, dynamic>> delRssSource(
      String accessToken, String id) async {
    final resp = await _dio.post('/delRssSource', queryParameters: {
      'accessToken': accessToken,
      'id': id,
    });
    return resp.data;
  }

  Future<Map<String, dynamic>> delRssSources(
      String accessToken, List<String> ids) async {
    final resp = await _dio.post('/delRssSources',
        queryParameters: {'accessToken': accessToken},
        data: ids,
        options: _jsonBodyOptions());
    return resp.data;
  }

  Future<Map<String, dynamic>> stopRssSource(String accessToken, String id,
      {required int st}) async {
    final resp = await _dio.post('/stopRssSource', queryParameters: {
      'accessToken': accessToken,
      'id': id,
      'st': st,
    });
    return resp.data;
  }

  Future<Map<String, dynamic>> startRssSources(
      String accessToken, List<String> ids) async {
    final resp = await _dio.post('/startRssSources',
        queryParameters: {'accessToken': accessToken},
        data: ids,
        options: _jsonBodyOptions());
    return resp.data;
  }

  Future<Map<String, dynamic>> stopRssSources(
      String accessToken, List<String> ids) async {
    final resp = await _dio.post('/stopRssSources',
        queryParameters: {'accessToken': accessToken},
        data: ids,
        options: _jsonBodyOptions());
    return resp.data;
  }

  Future<Map<String, dynamic>> topRssSource(
      String accessToken, String id) async {
    final resp = await _dio.post('/topRssSource', queryParameters: {
      'accessToken': accessToken,
      'id': id,
    });
    return resp.data;
  }

  Future<Map<String, dynamic>> bottomRssSource(
      String accessToken, String id) async {
    final resp = await _dio.post('/bottomRssSource', queryParameters: {
      'accessToken': accessToken,
      'id': id,
    });
    return resp.data;
  }

  Future<Map<String, dynamic>> topallrssSource(
      String accessToken, List<String> ids) async {
    final resp = await _dio.post('/topallrssSource',
        queryParameters: {'accessToken': accessToken},
        data: ids,
        options: _jsonBodyOptions());
    return resp.data;
  }

  Future<Map<String, dynamic>> bottomallrssSource(
      String accessToken, List<String> ids) async {
    final resp = await _dio.post('/bottomallrssSource',
        queryParameters: {'accessToken': accessToken},
        data: ids,
        options: _jsonBodyOptions());
    return resp.data;
  }

  Future<Map<String, dynamic>> editrsssourcegroup(
    String accessToken, {
    required String st,
    required String group,
    required List<String> ids,
  }) async {
    final resp = await _dio.post('/editrsssourcegroup',
        queryParameters: {
          'accessToken': accessToken,
          'st': st,
          'group': group,
        },
        data: ids,
        options: _jsonBodyOptions());
    return resp.data;
  }

  Future<Map<String, dynamic>> getRssSourcejson(
      String accessToken, List<String> ids) async {
    final resp = await _dio.post('/getRssSourcejson',
        queryParameters: {'accessToken': accessToken},
        data: ids,
        options: _jsonBodyOptions());
    return resp.data;
  }

  Future<Map<String, dynamic>> getRssSourcesloginui(
      String accessToken, String url) async {
    final resp = await _dio.get('/getRssSourcesloginui', queryParameters: {
      'accessToken': accessToken,
      'url': url,
    });
    return resp.data;
  }

  // ============ 书源登录 / 变量 / 动作 ============

  Future<Map<String, dynamic>> getSourcesLoginInfo(
      String accessToken, String bookSourceUrl) async {
    final resp = await _dio.get('/getLoginInfo', queryParameters: {
      'accessToken': accessToken,
      'bookSourceUrl': bookSourceUrl,
    });
    return resp.data;
  }

  Future<Map<String, dynamic>> putSourcesLoginInfo(
      String accessToken, String bookSourceUrl, String info) async {
    final resp = await _dio.post('/putLoginInfo', queryParameters: {
      'accessToken': accessToken,
      'bookSourceUrl': bookSourceUrl,
      'info': info,
    });
    return resp.data;
  }

  Future<Map<String, dynamic>> sourcesAction(
    String accessToken, {
    required String bookSourceUrl,
    required String action,
    String? info,
    bool? chapter,
    String? bookurl,
  }) async {
    final params = <String, dynamic>{
      'accessToken': accessToken,
      'bookSourceUrl': bookSourceUrl,
      'action': action,
    };
    if (info != null) params['info'] = info;
    if (chapter != null) params['chapter'] = chapter;
    if (bookurl != null) params['bookurl'] = bookurl;
    final resp = await _dio.post('/action', queryParameters: params);
    return resp.data;
  }

  Future<Map<String, dynamic>> getSourcesVariable(
      String accessToken, String bookSourceUrl) async {
    final resp = await _dio.get('/getVariable', queryParameters: {
      'accessToken': accessToken,
      'bookSourceUrl': bookSourceUrl,
    });
    return resp.data;
  }

  Future<Map<String, dynamic>> setSourcesVariable(
      String accessToken, String bookSourceUrl, String info) async {
    final resp = await _dio.post('/setVariable', queryParameters: {
      'accessToken': accessToken,
      'bookSourceUrl': bookSourceUrl,
      'info': info,
    });
    return resp.data;
  }

  // ============ 分组 ============

  Future<List<BookGroup>> getBookGroups(String accessToken) async {
    final resp = await _dio.get('/getgroup', queryParameters: {
      'accessToken': accessToken,
    });
    final data = resp.data['data'];
    if (data is List) {
      return data
          .map((e) => BookGroup.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    return [];
  }

  Future<List<BookGroup>> getgroupNew(String accessToken, String md5) async {
    final resp = await _dio.get('/getgroupNew', queryParameters: {
      'accessToken': accessToken,
      'md5': md5,
    });
    final data = resp.data['data'];
    if (data is List) {
      return data
          .map((e) => BookGroup.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    return [];
  }

  Future<Map<String, dynamic>> addgroup(String accessToken, String name) async {
    final resp = await _dio.post('/addgroup', queryParameters: {
      'accessToken': accessToken,
      'name': name,
    });
    return resp.data;
  }

  Future<Map<String, dynamic>> delgroup(String accessToken, String name) async {
    final resp = await _dio.post('/delgroup', queryParameters: {
      'accessToken': accessToken,
      'name': name,
    });
    return resp.data;
  }

  Future<Map<String, dynamic>> editgroup(
      String accessToken, String oldname, String newname) async {
    final resp = await _dio.post('/editgroup', queryParameters: {
      'accessToken': accessToken,
      'oldname': oldname,
      'newname': newname,
    });
    return resp.data;
  }

  Future<Map<String, dynamic>> ordergroup(
      String accessToken, List<String> groups) async {
    final resp = await _dio.post('/ordergroup', queryParameters: {
      'accessToken': accessToken,
      'groups': groups,
    });
    return resp.data;
  }

  Future<Map<String, dynamic>> setgroup(String accessToken,
      {String? name, required String url}) async {
    final resp = await _dio.post('/setgroup', queryParameters: {
      'accessToken': accessToken,
      if (name != null) 'name': name,
      'url': url,
    });
    return resp.data;
  }

  Future<Map<String, dynamic>> setgroups(String accessToken,
      {String? name, required List<String> ids}) async {
    final resp = await _dio.post('/setgroups',
        queryParameters: {
          'accessToken': accessToken,
          if (name != null) 'name': name,
        },
        data: ids);
    return resp.data;
  }

  // ============ 替换规则 ============

  Future<Map<String, dynamic>> getReplaceRulesPage(String accessToken) async {
    final resp = await _dio.get('/getReplaceRulesPage', queryParameters: {
      'accessToken': accessToken,
    });
    return resp.data;
  }

  Future<List<ReplaceRule>> getReplaceRulesNew(
    String accessToken, {
    String? md5,
    int page = 1,
  }) async {
    final params = <String, dynamic>{
      'accessToken': accessToken,
      'page': page.toString(),
    };
    if (md5 != null) params['md5'] = md5;
    final resp = await _dio.get('/getReplaceRulesNew', queryParameters: params);
    final data = resp.data['data'];
    if (data is List) {
      return data
          .whereType<Map>()
          .map((e) => ReplaceRule.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    }
    return [];
  }

  Future<String?> getDefaultReplaceRule(String accessToken) async {
    final resp = await _dio.get('/getdefaultrule', queryParameters: {
      'accessToken': accessToken,
    });
    return resp.data['data']?.toString();
  }

  /// 一次把**全部**净化规则拉回来（先问总页数，再逐页取）。
  ///
  /// 【为什么要抽到这一层】
  /// 原来这段分页逻辑写在 `ReplaceRuleProvider.loadRules` 里，只有「净化规则
  /// 管理」页面会调。但客户端本地净化引擎是在**读正文时**跑的，那时也必须
  /// 手里有规则 —— 于是阅读页也要能拉一次，两边再各写一份分页逻辑迟早会走岔。
  Future<List<ReplaceRule>> fetchAllReplaceRules(String accessToken) async {
    final pageData = await getReplaceRulesPage(accessToken);
    final data = pageData['data'] ?? pageData;
    final md5 = (data is Map) ? data['md5']?.toString() : null;
    final totalPages =
        (data is Map ? int.tryParse(data['page']?.toString() ?? '1') : 1) ?? 1;

    final fetched = <ReplaceRule>[];
    for (var page = 1; page <= totalPages; page++) {
      final pageRules = await getReplaceRulesNew(
        accessToken,
        md5: md5,
        page: page,
      );
      if (pageRules.isEmpty) break;
      fetched.addAll(pageRules);
    }
    fetched.sort((a, b) => a.order.compareTo(b.order));
    return fetched;
  }

  Future<Map<String, dynamic>> addReplaceRule(
    String accessToken,
    ReplaceRule rule,
  ) async {
    final resp = await _dio.post(
      '/addReplaceRule',
      queryParameters: {'accessToken': accessToken},
      data: rule.toServerJson(),
      options: _jsonBodyOptions(),
    );
    return resp.data;
  }

  Future<Map<String, dynamic>> saveReplaceRuleRaw(
    String accessToken,
    String content,
  ) async {
    final resp = await _dio.post(
      '/saverule',
      queryParameters: {'accessToken': accessToken},
      data: content,
      options: _plainTextBodyOptions(),
    );
    return resp.data;
  }

  Future<Map<String, dynamic>> saveReplaceRulesRaw(
    String accessToken,
    String content,
  ) async {
    final resp = await _dio.post(
      '/saverules',
      queryParameters: {'accessToken': accessToken},
      data: content,
      options: _plainTextBodyOptions(),
    );
    return resp.data;
  }

  // ============ 浏览历史 / 搜索历史（跨端同步） ============
  //
  // 这两份数据原来是纯本地的（SharedPreferences），换设备就没了。
  // 现在落到服务端，iOS / 安卓 / 浏览器 / Windows 读的是同一份。
  // 客户端仍保留本地缓存做离线兜底，见 BrowsingHistoryService。

  /// 拉取服务端的浏览历史。每条是 Book 的 JSON 原文。
  Future<List<String>> getBrowsingHistory(String accessToken) async {
    final resp = await _dio.get('/getBrowsingHistory', queryParameters: {
      'accessToken': accessToken,
    });
    final data = resp.data['data'];
    if (data is List) {
      return data
          .map((e) => e.toString())
          .where((s) => s.isNotEmpty)
          .toList(growable: false);
    }
    return const [];
  }

  /// 上传一条浏览历史。`bookJson` 是 Book 的 JSON 原文 ——
  /// 服务端只从中取 `bookUrl` 当键，其余原样存，两边字段不用对齐。
  Future<void> addBrowsingHistory(String accessToken, String bookJson) async {
    await _dio.post(
      '/addBrowsingHistory',
      queryParameters: {'accessToken': accessToken},
      data: bookJson,
      options: _plainTextBodyOptions(),
    );
  }

  Future<void> delBrowsingHistory(String accessToken, String bookUrl) async {
    await _dio.post('/delBrowsingHistory', queryParameters: {
      'accessToken': accessToken,
      'bookUrl': bookUrl,
    });
  }

  Future<void> clearBrowsingHistory(String accessToken) async {
    await _dio.post('/clearBrowsingHistory', queryParameters: {
      'accessToken': accessToken,
    });
  }

  /// 批量上传本地历史 —— 老版本客户端首次升级时用（本地几十条、服务端还空着）。
  Future<void> pushBrowsingHistory(
      String accessToken, List<String> bookJsons) async {
    final list = <dynamic>[];
    for (final json in bookJsons) {
      try {
        list.add(jsonDecode(json));
      } catch (_) {
        // 单条坏了就跳过，不要把整批上传带崩
      }
    }
    if (list.isEmpty) return;
    await _dio.post(
      '/pushBrowsingHistory',
      queryParameters: {'accessToken': accessToken},
      data: jsonEncode(list),
      options: _plainTextBodyOptions(),
    );
  }

  Future<List<String>> getSearchHistory(String accessToken) async {
    final resp = await _dio.get('/getSearchHistory', queryParameters: {
      'accessToken': accessToken,
    });
    final data = resp.data['data'];
    if (data is List) {
      return data
          .map((e) => e.toString())
          .where((s) => s.isNotEmpty)
          .toList(growable: false);
    }
    return const [];
  }

  Future<void> addSearchHistory(String accessToken, String keyword) async {
    await _dio.post('/addSearchHistory', queryParameters: {
      'accessToken': accessToken,
      'keyword': keyword,
    });
  }

  Future<void> delSearchHistory(String accessToken, String keyword) async {
    await _dio.post('/delSearchHistory', queryParameters: {
      'accessToken': accessToken,
      'keyword': keyword,
    });
  }

  Future<void> clearSearchHistory(String accessToken) async {
    await _dio.post('/clearSearchHistory', queryParameters: {
      'accessToken': accessToken,
    });
  }

  Future<Map<String, dynamic>> topReplaceRule(
      String accessToken, String id) async {
    final resp = await _dio.post('/topReplaceRule', queryParameters: {
      'accessToken': accessToken,
      'id': id,
    });
    return resp.data;
  }

  Future<Map<String, dynamic>> stopReplaceRule(
    String accessToken,
    String id, {
    required int st,
  }) async {
    final resp = await _dio.post('/stopReplaceRules', queryParameters: {
      'accessToken': accessToken,
      'id': id,
      'st': st,
    });
    return resp.data;
  }

  Future<Map<String, dynamic>> stopReplaceRulesByIds(
    String accessToken,
    List<String> ids,
  ) async {
    final resp = await _dio.post(
      '/stopReplaceRulesbyIds',
      queryParameters: {'accessToken': accessToken},
      data: ids,
      options: _jsonBodyOptions(),
    );
    return resp.data;
  }

  Future<Map<String, dynamic>> startReplaceRulesByIds(
    String accessToken,
    List<String> ids,
  ) async {
    final resp = await _dio.post(
      '/startReplaceRulesbyIds',
      queryParameters: {'accessToken': accessToken},
      data: ids,
      options: _jsonBodyOptions(),
    );
    return resp.data;
  }

  Future<Map<String, dynamic>> deleteReplaceRule(
      String accessToken, String id) async {
    final resp = await _dio.post('/delReplaceRule', queryParameters: {
      'accessToken': accessToken,
      'id': id,
    });
    return resp.data;
  }

  Future<Map<String, dynamic>> deleteReplaceRules(
    String accessToken,
    List<String> ids,
  ) async {
    final resp = await _dio.post(
      '/delReplaceRules',
      queryParameters: {'accessToken': accessToken},
      data: ids,
      options: _jsonBodyOptions(),
    );
    return resp.data;
  }

  Future<dynamic> updateUseReplaceRule(
    String accessToken, {
    required String url,
    required int useReplaceRule,
  }) async {
    final resp = await _dio.get('/updateuseReplaceRule', queryParameters: {
      'accessToken': accessToken,
      'url': url,
      'useReplaceRule': useReplaceRule,
    });
    return resp.data;
  }

  // ============ 书籍操作 ============

  Future<Map<String, dynamic>> saveBook(String accessToken, Book book,
      {int useReplaceRule = 0}) async {
    final resp = await _dio.post('/saveBook',
        queryParameters: {
          'accessToken': accessToken,
          'useReplaceRule': useReplaceRule,
        },
        data: book.toJson());
    return resp.data;
  }

  Future<Map<String, dynamic>> deleteBook(String accessToken, Book book) async {
    final resp = await _dio.post('/deleteBook',
        queryParameters: {
          'accessToken': accessToken,
        },
        data: book.toJson());
    return resp.data;
  }

  Future<Map<String, dynamic>> refreshBook(
      String accessToken, String bookUrl) async {
    final resp = await _dio.get('/refreshBook', queryParameters: {
      'accessToken': accessToken,
      'bookurl': bookUrl,
    });
    return resp.data;
  }

  Future<Map<String, dynamic>> changeBookType(
      String accessToken, String bookUrl, int type) async {
    final resp = await _dio.get('/changebooktype', queryParameters: {
      'accessToken': accessToken,
      'bookUrl': bookUrl,
      'type': type,
    });
    return resp.data;
  }

  // ============ 书签 ============

  Future<Map<String, dynamic>> addBookmark(String accessToken,
      {required String url,
      required String name,
      required int index,
      required double pos}) async {
    final resp = await _dio.post('/addbookmark', queryParameters: {
      'accessToken': accessToken,
      'url': url,
      'name': name,
      'index': index,
      'pos': pos,
    });
    return resp.data;
  }

  Future<List<Map<String, dynamic>>> getBookmarks(
      String accessToken, String url) async {
    final resp = await _dio.get('/getbookmark', queryParameters: {
      'accessToken': accessToken,
      'url': url,
    });
    final data = resp.data['data'];
    if (data is List) {
      return data.cast<Map<String, dynamic>>();
    }
    return [];
  }

  Future<Map<String, dynamic>> deleteBookmark(
      String accessToken, String id) async {
    final resp = await _dio.post('/delbookmark', queryParameters: {
      'accessToken': accessToken,
      'id': id,
    });
    return resp.data;
  }

  // ============ 换源 / 书籍详情 ============

  /// 换源：把书架里 [bookUrl] 这本书切到 [newUrl]。
  ///
  /// 对应后端 `/setBookSource`（ReadController）。后端会拿新 url 重新抓
  /// 书籍信息、覆盖书架记录，并通过 WebSocket 广播通知其它端刷新。
  Future<Map<String, dynamic>> setBookSource(
    String accessToken, {
    required String bookUrl,
    required String newUrl,
    required String bookSourceUrl,
  }) async {
    final resp = await _dio.get('/setBookSource', queryParameters: {
      'accessToken': accessToken,
      'bookUrl': bookUrl,
      'newUrl': newUrl,
      'bookSourceUrl': bookSourceUrl,
    });
    return resp.data;
  }

  /// 按 url 取书籍详情（后端 `/getBookinfo2`）
  ///
  /// 注意：另一个 `/getBookinfo` 要求把整个 SearchBook 作为 body 传，
  /// 参数不全时后端直接抛 NOT_BANK，所以这里用按 url 的那个。
  Future<Map<String, dynamic>> getBookInfoByUrl(
      String accessToken, String url) async {
    final resp = await _dio.get('/getBookinfo2', queryParameters: {
      'accessToken': accessToken,
      'url': url,
    });
    return resp.data;
  }

  /// 导入书架备份（书架菜单「备份导入」）
  ///
  /// 后端 `/saveBooks` 的 body 就是备份文件的原始 JSON 文本。
  Future<Map<String, dynamic>> saveBooks(
      String accessToken, String content) async {
    final resp = await _dio.post(
      '/saveBooks',
      queryParameters: {'accessToken': accessToken},
      data: content,
      options: Options(contentType: Headers.jsonContentType),
    );
    return resp.data;
  }

  // ==================== 朗读引擎（TTS） ====================

  /// 全部朗读引擎
  Future<List<TtsEngine>> getAllTts(String accessToken) async {
    final resp = await _dio.get('/getalltts', queryParameters: {
      'accessToken': accessToken,
    });
    final json = resp.data;
    if (json['isSuccess'] == true && json['data'] is List) {
      return (json['data'] as List)
          .map((e) => TtsEngine.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    }
    return [];
  }

  /// 新增 / 更新一个朗读引擎（带 id 即更新，后端 `addtts` 按此分流）
  Future<Map<String, dynamic>> addTts(
      String accessToken, TtsEngine engine) async {
    final resp = await _dio.post(
      '/addtts',
      queryParameters: {'accessToken': accessToken},
      data: engine.toJson(),
      options: _jsonBodyOptions(),
    );
    return Map<String, dynamic>.from(resp.data as Map);
  }

  /// 删除一个朗读引擎
  Future<Map<String, dynamic>> delTts(String accessToken, String id) async {
    final resp = await _dio.get('/deltts', queryParameters: {
      'accessToken': accessToken,
      'id': id,
    });
    return Map<String, dynamic>.from(resp.data as Map);
  }

  /// 批量导入朗读引擎（content 是 JSON 数组字符串）
  ///
  /// 后端 `savettss(@Body content: String)` 收的是**原始文本**，所以要按
  /// 项目里同类接口（`/saveBookSources`）的范式用 text/plain 发，
  /// 不能用 application/json —— 那样 Solon 会尝试反序列化而不是直接取字符串。
  Future<Map<String, dynamic>> saveTtsList(
      String accessToken, String content) async {
    final resp = await _dio.post(
      '/savettss',
      queryParameters: {'accessToken': accessToken},
      data: content,
      options: _plainTextBodyOptions(),
    );
    return Map<String, dynamic>.from(resp.data as Map);
  }

  /// 服务端配置里的默认朗读引擎
  Future<String?> getDefaultTts(String accessToken) async {
    final resp = await _dio.get('/getdefaulttts', queryParameters: {
      'accessToken': accessToken,
    });
    final data = resp.data['data'];
    return data?.toString();
  }

  /// 服务端合成的音频地址。
  ///
  /// 后端 `/tts` 会按 id 取出引擎、把 `{{speakText}}` / `{{speakSpeed}}`
  /// 等模板替换好、再流式返回音频，所以客户端不用自己拼引擎 URL。
  String ttsAudioUrl(
    String accessToken,
    String id,
    String text, {
    double rate = 5,
  }) {
    final params = {
      'accessToken': accessToken,
      'id': id,
      'speakText': text,
      'speechRate': rate.toString(),
    };
    return '${AppConstants.apiBase}/tts?${_encodeParams(params)}';
  }

  /// 通过网址直接添加书籍（书架菜单「添加网址」）
  Future<Map<String, dynamic>> urlSaveBook(
      String accessToken, String url) async {
    final resp = await _dio.get('/urlsaveBook', queryParameters: {
      'accessToken': accessToken,
      'url': url,
    });
    return resp.data;
  }

  // ============ cookie / cache 清理 ============

  /// 清理所有书源 cookie（书源管理 ⋮ 菜单）
  Future<Map<String, dynamic>> cleanCookies(String accessToken) async {
    final resp = await _dio
        .get('/cleancookies', queryParameters: {'accessToken': accessToken});
    return resp.data;
  }

  /// 读取某个站点在**服务端**保存的 cookie（上游 `/getCookies`）。
  ///
  /// 后端落盘的 key 是 `NetworkUtils.getSubDomain(url)`（可注册域名，
  /// `www.qidian.com` → `qidian.com`），所以 [url] 传书源的 `bookSourceUrl`
  /// 或 `loginUrl` 都行 —— 只要同属一个站点即可。
  ///
  /// 返回值是**解密后的明文** `"a=1; b=2"`。后端这一层的载荷是
  /// `EncryptUtils.aesEncode` 出来的 hex，这里用 [AesCodec] 解开；
  /// 服务端没有该站点 cookie 时返回空串（不是 null）。
  Future<String> getCookies(String accessToken, String url) async {
    final resp = await _dio.get('/getCookies', queryParameters: {
      'accessToken': accessToken,
      'url': url,
    });
    final raw = resp.data['data']?.toString() ?? '';
    if (raw.isEmpty) return '';
    return AesCodec.decrypt(raw);
  }

  /// 把客户端 WebView 里的 cookie 写回服务端（上游 `/saveCookies`）。
  ///
  /// [cookie] 是**明文** `"a=1; b=2"`，加密在这里做：后端收到会先
  /// `EncryptUtils.aesDecrypted` 再落盘，直接传明文会被解成乱码。
  /// 传空串等于清掉该站点的 cookie，所以调用方要先判空。
  Future<Map<String, dynamic>> saveCookies(
    String accessToken,
    String url,
    String cookie,
  ) async {
    final resp = await _dio.post('/saveCookies', queryParameters: {
      'accessToken': accessToken,
      'url': url,
      'cookie': AesCodec.encrypt(cookie),
    });
    return Map<String, dynamic>.from(resp.data as Map);
  }

  /// 清理所有书源缓存（书源管理 ⋮ 菜单）
  Future<Map<String, dynamic>> cleanCaches(String accessToken) async {
    final resp = await _dio
        .get('/cleancaches', queryParameters: {'accessToken': accessToken});
    return resp.data;
  }

  /// 某本书是否可清缓存（书籍信息页「清除缓存」）
  Future<Map<String, dynamic>> getCanCache(
      String accessToken, String url) async {
    final resp = await _dio.get('/getcancache', queryParameters: {
      'accessToken': accessToken,
      'url': url,
    });
    return resp.data;
  }

  /// 本地缓存条目列表（书籍信息页「本地缓存」）
  Future<List<Map<String, dynamic>>> getCanCacheList(
      String accessToken) async {
    final resp = await _dio
        .get('/getcancachelist', queryParameters: {'accessToken': accessToken});
    final data = resp.data['data'];
    if (data is List) return data.cast<Map<String, dynamic>>();
    return [];
  }

  Future<Map<String, dynamic>> delCache(String accessToken, String id) async {
    final resp = await _dio.get('/delCache', queryParameters: {
      'accessToken': accessToken,
      'id': id,
    });
    return resp.data;
  }

  // ============ 封面代理 ============

  String getCoverProxyUrl(String? coverUrl, {String? sourceUrl}) {
    if (coverUrl == null || coverUrl.isEmpty) return '';
    final params = <String, String>{'url': coverUrl};
    if (sourceUrl != null) params['source'] = sourceUrl;
    return '${AppConstants.apiBase}/proxypng?${_encodeParams(params)}';
  }

  // ============ 正文插图（官方 /imageDecode） ============

  /// 拆分书源给的图片 src。
  ///
  /// 书源约定：`<img src="URL,{json}">` —— 逗号前是真实地址，逗号后的 json
  /// 里可能有 `headers`。官方客户端在 main.dart.js 的 `b2W` 里做的就是这件事：
  /// 含 `,`+`{`+`}` 才拆，拆失败就原样返回。
  ///
  /// `baseurl` 是书源的占位符，要换成 `<站点>/api/5`
  /// （官方用 `origin + "/api/5"`，等价于 [AppConstants.apiBase]）。
  static ({String url, Map<String, String> headers}) splitImageSrc(String src) {
    var raw = src.trim();
    if (raw.contains('baseurl')) {
      raw = raw.replaceAll('baseurl', AppConstants.apiBase);
    }
    if (!raw.contains(',') || !raw.contains('{') || !raw.contains('}')) {
      return (url: raw, headers: const <String, String>{});
    }
    try {
      final comma = raw.indexOf(',');
      final url = raw.substring(0, comma).trim();
      final decoded = jsonDecode(raw.substring(comma + 1));
      final headers = <String, String>{};
      if (decoded is Map && decoded['headers'] is Map) {
        (decoded['headers'] as Map).forEach((k, v) {
          headers['$k'] = '$v';
        });
      }
      if (url.isEmpty) return (url: raw, headers: const <String, String>{});
      return (url: url, headers: headers);
    } catch (_) {
      return (url: raw, headers: const <String, String>{});
    }
  }

  /// 正文插图的完整地址 —— 官方 `/imageDecode`。
  ///
  /// 【为什么不是 /proxypng】`/proxypng` 只「转发 + 缓存」，**不解密**。
  /// 阅文系的插图（`aigcc.yuewen.com/imgChapter/...`）是加密的，必须由后端
  /// 用书源的 `ruleContent.imageDecode` 规则解密后才是一张正常的图；
  /// 直接转发拿到的是乱码 —— 表现就是「书源里有图，App 里一张都没有」。
  ///
  /// 参数与官方完全一致：`url` / `bookSourceUrl` / `header` / `book`
  /// （见官方 main.dart.js 的 `b2U`）。
  String imageDecodeUrl(
    String src, {
    required String accessToken,
    String? bookSourceUrl,
    String? bookJson,
  }) {
    final (url: url, headers: headers) = splitImageSrc(src);
    if (url.isEmpty) return '';
    final params = <String, String>{
      'accessToken': accessToken,
      'url': url,
      'bookSourceUrl': bookSourceUrl ?? '',
      'header': jsonEncode(headers),
    };
    if (bookJson != null && bookJson.isNotEmpty) {
      params['book'] = bookJson;
    }
    return '${AppConstants.apiBase}/imageDecode?${_encodeParams(params)}';
  }

  String _encodeParams(Map<String, String> params) {
    return params.entries
        .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
        .join('&');
  }
}
