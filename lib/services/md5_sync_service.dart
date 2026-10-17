import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一条 md5 变化：[msg] 是消息类型（bookmd5/sourcemd5/...），[md5] 是新值
/// （gonggao 时是公告文本本身），[bookurl] 仅 `read`（阅读进度）消息携带。
class Md5Change {
  const Md5Change(this.msg, this.md5, this.bookurl);

  final String msg;
  final String md5;
  final String bookurl;
}

/// md5 族推送的「本地快照比对 → 广播变化」。
///
/// 【协议】连上 WS 后服务端在 onOpen 里把当前各类数据的 md5 全推一遍
/// （init/bookmd5/sourcemd5/rssmd5/replacemd5/tssmd5/groundmd5/source/
/// allowchange/gonggao）；之后任意端改了数据，服务端 `NotifyBase` 给该用户
/// 的**其它连接**推新 md5（发起方 token 被跳过）。客户端的职责：记住上次值，
/// 变了就刷新对应数据 —— 「另一台设备加了本书，这台书架自己变」就是这么来的。
///
/// 【存储】按 token 维度存 SharedPreferences，键 `ws_md5_<scope>_<msg>`，
/// scope 是 token 的 md5（区分账号/服务端，又避免 token 明文落盘）。
///
/// 【首次只见不广播】第一次连上时本地没有快照，存下即可；这时各页面本来就
/// 在自己加载，不需要再刷一遍。
class Md5SyncService {
  Md5SyncService._();
  static final Md5SyncService instance = Md5SyncService._();

  static const Set<String> md5Msgs = {
    'init',
    'bookmd5',
    'sourcemd5',
    'rssmd5',
    'replacemd5',
    'tssmd5',
    'groundmd5',
    'source',
    'allowchange',
    'gonggao',
    'read',
  };

  static bool isMd5Message(String msg) => md5Msgs.contains(msg);

  String _scope = '';

  final _changesCtrl = StreamController<Md5Change>.broadcast();
  Stream<Md5Change> get changes => _changesCtrl.stream;

  /// 绑定当前登录 token。connect 时调；空 token → 不比对不存储（避免串号）。
  void bindToken(String token) {
    _scope = token.isEmpty ? '' : md5.convert(utf8.encode(token)).toString();
  }

  /// 断开/登出时调，防止下一个账号用到上一个账号的 scope。
  void reset() => _scope = '';

  /// 比对并落盘；有变化则广播。调用前先用 [isMd5Message] 过滤。
  Future<void> onMessage(String msg, String md5Value, String bookurl) async {
    if (md5Value.isEmpty || _scope.isEmpty) return;

    // 服务端推 sourcemd5/rssmd5 时会顺手拼上 user.source
    // （InitConfig.kt: md5 + user.source），变成 33 位；source 开关本身
    // 翻动时尾巴变、前 32 位数据 md5 不变。只比前 32 位，否则每次开关
    // 书源总开关都会误报「书源变了」。
    final normalized =
        (msg == 'sourcemd5' || msg == 'rssmd5') && md5Value.length > 32
            ? md5Value.substring(0, 32)
            : md5Value;

    final prefs = await SharedPreferences.getInstance();
    final key = 'ws_md5_${_scope}_$msg';
    final old = prefs.getString(key);
    if (old == normalized) return;
    await prefs.setString(key, normalized);
    // 首次只见存档，不刷 —— 页面自己正在加载
    if (old == null) return;
    if (_changesCtrl.isClosed) return;
    _changesCtrl.add(Md5Change(msg, normalized, bookurl));
  }
}
