import 'package:dio/dio.dart';

/// 把异常翻译成用户能看懂的一句话。
///
/// 【为什么要这个】
/// 各个 provider 原本一律 `_error = e.toString()`，于是网络出问题时整页红字是：
///
///   DioException [receive timeout]: The request took longer than
///   0:00:15.000000 to receive data. It was aborted. To get rid of this
///   exception, try raising the RequestOptions.receiveTimeout above the
///   duration of 0:00:15.000000 or improve the response time of the server.
///
/// 用户只能把它截图发过来问「严重网络连接失败」。这段话是给**开发者**看的，
/// 不该出现在界面上 —— 它甚至建议用户去改 `RequestOptions.receiveTimeout`。
///
/// 【原则：只翻译「传输层」错误】
/// 业务错误（后端返回 `errorMsg`、自己 `throw Exception('内容不是合法的 JSON')`）
/// 原样透出 —— 那些信息本来就是写给用户看的，翻译反而会丢信息。
/// 只有 dio 的传输层异常才换成中文短句。
String friendlyError(Object error) {
  if (error is DioException) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
        return '连接服务器超时，请检查网络或「服务器地址」设置';
      case DioExceptionType.sendTimeout:
        return '发送请求超时，请重试';
      case DioExceptionType.receiveTimeout:
        // 后端有不少同步阻塞的接口（逐页拉书源、后端代抓目标站、
        // startBrowserAwait 干等用户关网页），慢的时候确实会超。
        return '服务器响应超时，请稍后重试';
      case DioExceptionType.connectionError:
        return '无法连接到服务器，请检查网络或「服务器地址」设置';
      case DioExceptionType.badCertificate:
        return '服务器证书校验失败';
      case DioExceptionType.cancel:
        return '请求已取消';
      case DioExceptionType.badResponse:
        final code = error.response?.statusCode;
        if (code == null) return '服务器返回异常';
        if (code == 401 || code == 403) return '登录已失效，请重新登录（HTTP $code）';
        if (code == 404) return '接口不存在（HTTP 404），可能是服务器版本过旧';
        if (code >= 500) return '服务器内部错误（HTTP $code）';
        return '服务器返回异常（HTTP $code）';
      // 【必须用 default 收口，不要列举到 unknown 为止】
      // dio 每新增一个枚举值，写死全部 case 的 switch 就会因「不再穷尽」
      // 直接编译失败 —— 5.11 新增 transformTimeout 时就是这样：
      //
      //   lib/services/error_text.dart:22:19: Error: The type 'DioExceptionType'
      //   is not exhaustively matched by the switch cases since it doesn't
      //   match 'DioExceptionType.transformTimeout'.
      //
      // 而 pubspec 写的是 `dio: ^5.7.0`，CI 会自动拉到范围内的最新版，
      // 本地却可能停在旧版 —— 这种错只会在 CI 上出现。
      // 同时也不能写死 `case DioExceptionType.transformTimeout`，
      // 因为它在 5.7.0 里还不存在，写死会让旧版解析失败。
      // 所以：unknown 以及以后新增的类型，统一走 default 落到下面的兜底。
      default:
        break;
    }
    // unknown：多半是 SocketException / HandshakeException 这类被包了一层。
    // 拿 message 兜底，仍然比整段 DioException 好读。
    final msg = error.message?.trim();
    if (msg != null && msg.isNotEmpty) return '网络请求失败：$msg';
    return '网络请求失败';
  }
  return error.toString();
}

/// 把后端返回的 `errorMsg` 翻译成用户能看懂的一句话。
///
/// 后端大部分错误消息本身就是中文（「当前文件格式不支持」），原样展示即可；
/// 只有少数是**给程序看的英文常量**（`NOT_BANK` 之类），
/// 直接摆到界面上用户会一头雾水，所以在这里做一层替换。
String friendlyServerMessage(String? message) {
  final msg = message?.trim() ?? '';
  if (msg.isEmpty) return '操作失败';
  switch (msg) {
    case 'NOT_BANK':
      return '没有选到文件，请重新选择';
    case 'SUCCESS':
      return '成功';
    default:
      return msg;
  }
}
