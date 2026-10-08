import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/replace_rule.dart';

/// 「替换净化」规则的**本地副本**。
///
/// 【为什么必须有这一层】
/// 本地净化引擎是在**读正文的那一刻**跑的，那时手里必须已经攥着规则。
/// 而规则现在只在「我的 → 净化规则管理」页面里才拉一次 —— 用户没进过那个
/// 页面就一条规则都没有，本地引擎等于空转，表现和「净化没生效」一模一样。
/// 所以这里做三件事：
///   1. 每次从服务端拉到规则，就落一份到 SharedPreferences；
///   2. 阅读页发现内存里没有规则时，直接读这份副本；
///   3. 维护一个**规则指纹**，给章节正文缓存当版本号。
///
/// 对应官方那段逻辑（`main.dart.js`，同样是明文可读的）：
/// ```js
/// "book_catarule:" + f.a + "," + f.dx                 // 官方按书缓存规则
/// A.eZ("book_catarule:...", B.n.de(A.E(["md5", $.mK, "list", a8, "rules", m])))
/// A.K("读取净化缓存成功")
/// ```
/// 官方把**按书过滤后**的规则连同全局 md5 一起缓存。我们简化成「缓存全量规则
/// + 一个全局指纹」—— 过滤是纯函数（[ReplaceRule.matchesScope]），每次现算
/// 比维护 N 份按书副本更不容易出错，代价只是内存里多存一份规则表。
class ReplaceRuleStore {
  ReplaceRuleStore._();

  static final ReplaceRuleStore instance = ReplaceRuleStore._();

  static const String _kRules = 'app_replace_rules_json';
  static const String _kFingerprint = 'app_replace_rules_fingerprint';

  List<ReplaceRule> _rules = const <ReplaceRule>[];
  String _fingerprint = '';
  bool _loaded = false;
  bool _syncedThisSession = false;

  List<ReplaceRule> get rules => _rules;

  bool get loaded => _loaded;

  /// 本次运行是否已经**成功**同步过一次规则。
  ///
  /// 【为什么要这个】阅读页在开书时会检查「本地有没有规则，没有就拉一次」。
  /// 而「用户本来就没有规则」和「上次没拉到」在结果上都是空 —— 不加这个标记，
  /// 一个没有规则的用户每开一本书都要白发两次请求。失败时不置位，
  /// 所以下次开书还会重试，不会因为一次网络抖动就永久放弃。
  bool get syncedThisSession => _syncedThisSession;

  bool get isEmpty => _rules.isEmpty;

  /// 有没有「作用于章节标题」的启用规则。
  ///
  /// 【为什么要这个快速判断】章节列表动辄几千章，本地引擎是**逐条标题**跑一遍
  /// 规则的。绝大多数用户一条标题规则都没有（`scopeTitle` 默认是 false），
  /// 这种情况整个循环可以直接跳过 —— 不然每开一本书都要白白跑几千次
  /// 「排序 + 过滤 + 一个都没命中」。
  bool get hasTitleRules =>
      _rules.any((rule) => rule.isEnabled && rule.scopeTitle);

  /// 规则集指纹（10 位 MD5 前缀）。空规则集返回空串。
  ///
  /// 【两个用途】
  /// 1. 章节正文缓存的目录名 —— 规则一变，指纹就变，旧缓存自动用不上，
  ///    不需要任何显式的「清理缓存」动作；
  /// 2. 判断本地副本是不是还和内存里的那份一致。
  String get fingerprint => _fingerprint;

  /// 从本地读回规则副本。重复调用只真正读一次（`force` 可强制重读）。
  Future<void> load({bool force = false}) async {
    if (_loaded && !force) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _rules = _decode(prefs.getString(_kRules));
      _fingerprint = _computeFingerprint(_rules);
    } catch (_) {
      _rules = const <ReplaceRule>[];
      _fingerprint = '';
    }
    _loaded = true;
  }

  /// 用服务端最新的一份覆盖本地副本。
  Future<void> save(List<ReplaceRule> rules) async {
    _rules = List<ReplaceRule>.unmodifiable(rules);
    _fingerprint = _computeFingerprint(_rules);
    _loaded = true;
    _syncedThisSession = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kRules,
        jsonEncode(_rules.map((rule) => rule.toExportJson()).toList()),
      );
      await prefs.setString(_kFingerprint, _fingerprint);
    } catch (_) {
      // 本地副本只是加速器，写失败不影响本次净化（内存里那份已经更新了）。
    }
  }

  /// 把「执行超时」的规则在**本地副本**里禁用掉。
  ///
  /// 官方对应 `if (i.a === l.a && i.y) A.N6(l.a, "0")` —— 超时的规则直接置为
  /// 停用，避免每次读新章节都再卡一遍。
  ///
  /// 【为什么只改本地、不写服务端】
  /// 官方的规则本来就存在本地，所以它改了就是改了。我们的规则在服务端，
  /// 而这是「读正文」这条路径 —— 在用户只是想看小说的时候顺手改掉他云端的
  /// 规则配置，太激进了。所以只在本机停用，下次用户在规则管理页主动刷新时，
  /// 会回到服务端的真实状态（那时候也能看到是谁被停用了）。
  Future<void> disableLocally(Iterable<String> ids) async {
    final targets = ids.where((id) => id.isNotEmpty).toSet();
    if (targets.isEmpty) return;
    var changed = false;
    final next = <ReplaceRule>[];
    for (final rule in _rules) {
      if (targets.contains(rule.id) && rule.isEnabled) {
        next.add(rule.copyWith(isEnabled: false));
        changed = true;
      } else {
        next.add(rule);
      }
    }
    if (!changed) return;
    _rules = List<ReplaceRule>.unmodifiable(next);
    _fingerprint = _computeFingerprint(_rules);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kRules,
        jsonEncode(_rules.map((rule) => rule.toExportJson()).toList()),
      );
      await prefs.setString(_kFingerprint, _fingerprint);
    } catch (_) {}
  }

  static List<ReplaceRule> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return const <ReplaceRule>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <ReplaceRule>[];
      return decoded
          .whereType<Map>()
          .map((item) => ReplaceRule.fromJson(Map<String, dynamic>.from(item)))
          .toList(growable: false);
    } catch (_) {
      return const <ReplaceRule>[];
    }
  }

  /// 指纹只取「会影响净化结果」的字段。
  ///
  /// 【为什么不用 `jsonEncode(rules).hashCode`】`Object.hashCode` 在不同进程、
  /// 不同平台上都不保证稳定（Dart Web 上是随机数种子），而这个指纹要落盘、
  /// 要当目录名，必须跨次启动一致。MD5 满足这一点，而且 crypto 本来就是
  /// 直接依赖（见 pubspec 注释）。
  static String _computeFingerprint(List<ReplaceRule> rules) {
    if (rules.isEmpty) return '';
    final buffer = StringBuffer();
    for (final rule in rules) {
      buffer
        ..write(rule.id ?? '')
        ..write('\u0001')
        ..write(rule.pattern)
        ..write('\u0001')
        ..write(rule.replacement)
        ..write('\u0001')
        ..write(rule.isEnabled ? '1' : '0')
        ..write('\u0001')
        ..write(rule.isRegex ? '1' : '0')
        ..write('\u0001')
        ..write(rule.scope ?? '')
        ..write('\u0001')
        ..write(rule.excludeScope ?? '')
        ..write('\u0001')
        ..write(rule.scopeTitle ? '1' : '0')
        ..write('\u0001')
        ..write(rule.scopeContent ? '1' : '0')
        ..write('\u0001')
        ..write(rule.timeoutMillisecond.toString())
        ..write('\u0001')
        ..write(rule.order.toString())
        ..write('\n');
    }
    final digest = md5.convert(utf8.encode(buffer.toString())).toString();
    return digest.substring(0, 10);
  }
}
