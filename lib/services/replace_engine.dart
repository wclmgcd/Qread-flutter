import '../models/replace_rule.dart';

/// 一条规则没跑成功的原因。
class ReplaceFailure {
  final ReplaceRule rule;

  /// `timeout` / `unsafe-pattern` / `invalid-pattern` / `error` / `server-only`。
  final String kind;

  final String message;

  const ReplaceFailure(this.rule, this.kind, this.message);

  @override
  String toString() => '$kind(${rule.displayName}): $message';
}

/// 一次净化的结果。
class ReplaceOutcome {
  /// 净化后的正文。
  final String content;

  /// **真正改动过正文**的规则 —— 照官方语义只记这些
  /// （官方是 `if (!J.p(k, b1)) { ... m.push(rule) }`）。
  final List<ReplaceRule> applied;

  /// 没跑成功的规则，具体原因看 [ReplaceFailure.kind]。
  ///
  /// 注意**不要**一看到 failure 就去禁用规则：目前只有 `timeout` 该被禁用
  /// （官方是 `if (i.a === l.a && i.y) A.N6(l.a, "0")`，见 `ReaderProvider`
  /// 里那段 `where(kind == 'timeout')`）；`server-only` 是**合法**规则，
  /// 只是本地跑不了，跳过就好。
  final List<ReplaceFailure> failures;

  /// 上报日志，已按官方规则截到最近 [ReplaceEngine.maxLogEntries] 条。
  final List<String> logs;

  final int elapsedMilliseconds;

  const ReplaceOutcome({
    required this.content,
    required this.applied,
    required this.failures,
    required this.logs,
    required this.elapsedMilliseconds,
  });

  bool get changed => applied.isNotEmpty;

  bool get hasFailure => failures.isNotEmpty;
}

/// 客户端「替换净化」引擎 —— 官方客户端那段逻辑的 Dart 移植。
///
/// 【为什么要有这个东西】
/// 官方客户端（Android APK / iOS IPA / web）**三端都自带一套本地净化引擎**，
/// 净化是在客户端算的，根本不依赖后端。而本仓库的上游
/// `WEP-56/Qread-flutter`（自称「轻阅读 flutter 复现版」）把这块整段漏掉了，
/// 只把 `useReplaceRule` 传给服务端 —— 于是「原版能用、复现版不能用」。
///
/// 【逻辑是怎么拿到手的】
/// 不是猜的：官方 web 产物 `main.dart.js` 是 dart2js 输出，**控制流是明文的**，
/// 把 `\uXXXX` 反转义后可以逐行读。下面每条注释都标了对应的原文。
///
/// ```js
/// g = n.x.Of(b4);
/// s = n.a.dy ? 3 : 5;                      // 书级开关开着才走本地引擎
/// f = J.eA($.hq, new A.bdQ(n));            // 全局规则表按当前书过滤
/// A.K("正则数量" + f.length);
/// for (l of f) {
///   a = !l.z ? A.cm(text, l.d, l.e)                              // 非正则
///            : await A.aKH(text, l.d, l.e, new A.bd(1000 * l.Q)); // 正则 + 超时
///   if (!J.p(a, text)) { m.push(rule); text = a; }                // 只记改动过的
/// }
/// catch (e) {
///   if (e instanceof A.MM) for (i of $.hq) if (i.a === l.a && i.y) A.N6(l.a, "0");
///   h = "替换净化: " + A.o(e); $.vM.push(h); while ($.vM.length > 10) B.b.fw($.vM, 0);
/// }
/// ```
/// 字段对应：`l.a`=id、`l.d`=pattern、`l.e`=replacement、`l.y`=isEnabled、
/// `l.z`=isRegex、`l.Q`=timeoutMillisecond（**单位是秒**，`1000 * l.Q` 才到毫秒）。
///
/// 【和官方**有意不同**的一处：超时】
/// 官方跑在 JS 上，正则可以交给 worker / 计时器掐掉。Dart 的 `RegExp` 是
/// **同步**的，一旦进去就没法从外面中断 —— 没有等价的超时机制。这里的替代方案是：
///   1. 先做**危险模式静态检测**（`(x+)+` 这类回溯爆炸的经典写法直接跳过），
///      这是真正会把 UI 卡死的元凶，而且检测是零成本的；
///   2. 每条规则**计时**，超过 `timeoutMillisecond` 就记成 `timeout` 失败，
///      由调用方禁用 —— 也就是说「跑得慢的规则只会拖慢第一次，
///      之后就被摘掉了」，不会每次都卡。
///
/// 这个类**不 import Flutter**，纯 Dart，所以能直接跑 `flutter test`。
class ReplaceEngine {
  ReplaceEngine._();

  /// 官方日志前缀（`h = "替换净化: " + A.o(e)`）。
  /// 注意冒号后面**有一个空格** —— 这是它作为「指纹」的特征。
  static const String logPrefix = '替换净化: ';

  /// 官方日志环形缓冲上限（`while ($.vM.length > 10) B.b.fw($.vM, 0)`）。
  static const int maxLogEntries = 10;

  /// 嵌套量词：一个「自身带量词的分组」外面又套了量词，例如 `(a+)+`、`(\w*)*`、
  /// `(x+){2,}`。这是回溯爆炸最经典的写法 —— 一旦命中，正则引擎的复杂度会从
  /// 线性退化到指数级，几十个字符就能把主线程卡死。
  ///
  /// 只做这一条，不追求完备：更隐蔽的（如 `(a|a)+`）检测不出来，
  /// 但那些在真实规则里极少见，而 `(x+)+` 系是绝大多数卡死事故的来源。
  static final RegExp _nestedQuantifier = RegExp(
    r'\((?:\\.|[^()\\])*[*+](?:\\.|[^()\\])*\)\s*(?:[*+]|\{\d+,\d*\})',
  );

  /// 服务端净化支持、本地不支持的替换规则前缀。
  ///
  /// `replacement` 以它开头时，服务端会交给 Rhino 执行；本地没有 JS 引擎，
  /// 只能整条跳过 —— 见 [apply] 里那段 `@js:` 判断。
  static const String _jsPrefix = '@js:';

  /// 对正文（或章节标题）跑一遍净化。
  ///
  /// [forTitle] 决定用哪一半规则：`true` 只跑 `scopeTitle` 的，
  /// `false` 只跑 `scopeContent` 的 —— 和服务端 `getChapterListNew` /
  /// `getBookContentNew` 两处的 `filter { it.scopeContent }` / `{ it.scopeTitle }`
  /// 是同一套语义。
  ///
  /// [trimLines] 见下面那段长注释，默认 `false`。
  static ReplaceOutcome apply({
    required String content,
    required Iterable<ReplaceRule> rules,
    required String bookName,
    required String bookOrigin,
    bool forTitle = false,
    bool trimLines = false,
  }) {
    // 顺序有意义（前一条的结果是后一条的输入），必须按 ruleorder 来。
    final ordered = rules.toList()..sort((a, b) => a.order.compareTo(b.order));

    var text = trimLines ? _trimEachLine(content) : content;
    final applied = <ReplaceRule>[];
    final failures = <ReplaceFailure>[];
    final logs = <String>[];
    final total = Stopwatch()..start();

    for (final rule in ordered) {
      // matchesScope 里已经含 isEnabled / scopeTitle / scopeContent /
      // scope / excludeScope 五项判断，和服务端那段 Kotlin filter 一一对应。
      if (!rule.matchesScope(
        bookName: bookName,
        bookOrigin: bookOrigin,
        forTitle: forTitle,
      )) {
        continue;
      }
      if (rule.pattern.isEmpty) continue;

      // 【服务端专属】replacement 以 `@js:` 开头时，服务端会把它交给 Rhino 执行，
      // 本地没有 JS 引擎 —— 整条跳过。以前是**静默出错**：非正则分支会把整段
      // JS 源码当字面量插进正文，正则分支则连 `$1` 一起原样留下，既不报错也看不出来。
      if (rule.replacement.startsWith(_jsPrefix)) {
        failures.add(ReplaceFailure(
          rule,
          'server-only',
          'replacement 以 @js: 开头，本地无 JS 引擎，已跳过',
        ));
        _push(logs, '规则「${rule.displayName}」用 @js: 替换，本地无 JS 引擎，已跳过（服务端净化可用）');
        continue;
      }

      final before = text;
      final watch = Stopwatch()..start();

      if (!rule.isRegex) {
        // 官方非正则分支：`A.cm(text, pattern, replacement)`，纯字符串替换。
        text = text.replaceAll(rule.pattern, rule.replacement);
        watch.stop();
      } else {
        final RegExp regexp;
        try {
          // 【不要开 multiLine】官方跑的是 JS 的 `new RegExp(pattern, 'g')`，
          // 没有 `m` 标志，`^` / `$` 只匹配整串首尾。Dart 的 RegExp 默认
          // multiLine 也是 false，这里保持默认才等价。
          regexp = RegExp(rule.pattern);
        } on FormatException catch (e) {
          failures.add(ReplaceFailure(rule, 'invalid-pattern', e.message));
          _push(logs, '规则「${rule.displayName}」正则非法：${e.message}');
          continue;
        }

        final unsafe = _unsafeReason(rule.pattern);
        if (unsafe != null) {
          failures.add(ReplaceFailure(rule, 'unsafe-pattern', unsafe));
          _push(logs, '规则「${rule.displayName}」$unsafe');
          continue;
        }

        try {
          text = _replaceRegex(text, regexp, rule.replacement);
        } catch (e) {
          watch.stop();
          failures.add(ReplaceFailure(rule, 'error', '$e'));
          _push(logs, '$e');
          continue;
        }
        watch.stop();
      }

      if (rule.timeoutMillisecond > 0 &&
          watch.elapsedMilliseconds > rule.timeoutMillisecond) {
        failures.add(
          ReplaceFailure(
            rule,
            'timeout',
            '${watch.elapsedMilliseconds}ms > ${rule.timeoutMillisecond}ms',
          ),
        );
        _push(
          logs,
          '规则「${rule.displayName}」耗时 ${watch.elapsedMilliseconds}ms，'
              '超过 ${rule.timeoutMillisecond}ms，已停用',
        );
      }

      // 官方是 `if (!J.p(k, b1))`（`J.p` = 相等比较）—— 只记真正改动过的规则。
      if (text != before) applied.add(rule);
    }

    total.stop();
    return ReplaceOutcome(
      content: text,
      applied: applied,
      failures: failures,
      logs: logs,
      elapsedMilliseconds: total.elapsedMilliseconds,
    );
  }

  /// 逐行去掉首尾空白 —— 对应服务端那句
  /// `re = re.lines().joinToString("\n") { it.trim() }`。
  ///
  /// 【⚠️ 官方客户端**没有**这一步，所以默认不启用】
  /// 2026-10 拿线上真实章节 + 真实规则做过端到端对拍（同一章、同一条规则，
  /// 一条非正则字面量、一条正则带 `$1`）：
  ///
  /// | | 服务端 | 本地引擎（本文件） |
  /// |---|---|---|
  /// | 逐行 trim | **做** | 不做（默认） |
  /// | 去掉空白后逐字比对 | — | **完全一致** |
  ///
  /// 也就是说：本引擎的逻辑和服务端**一位不差**，唯一的差别就是这个 trim。
  /// 而官方三端客户端的本地引擎里都**没有** trim（是从 `main.dart.js` 的明文
  /// 逻辑里读出来的），说明「trim 是服务端自己加的额外清理」。
  ///
  /// 中文网文普遍用全角空格 `\u3000\u3000` 做段首缩进 —— trim 会把缩进一起吃掉。
  /// 所以默认跟随官方客户端**不 trim**：既忠实，阅读体验也更好。
  /// 想让本地结果和服务端逐字一致，把 `trimLines` 传 true 即可。
  static String _trimEachLine(String content) =>
      content.split('\n').map((line) => line.trim()).join('\n');

  /// 正则替换。
  ///
  /// 【⚠️ 这里不能用 Dart 的 `String.replaceAll(RegExp, String)`】
  /// 实测（Dart 3.13）：`'第12章'.replaceAll(RegExp(r'第(\d+)章'), r'[$1]')`
  /// 得到的是 **`[$1]`** —— Dart **不会**展开 `$1` 这种分组引用，
  /// 它把 replacement 当纯字面量。而阅读的规则集里 `$1` / `$2` 用得极多
  /// （「第(\d+)章」→「第$1章」这类），照搬 `replaceAll` 会让**一大批规则
  /// 静默失效**：不报错、不抛异常，只是替换结果里原样留着 `$1`。
  ///
  /// 官方引擎跑在 JS 上，用的是 `String.prototype.replace`，`$` 有完整语义，
  /// 所以这里按 **JS 规范**自己实现一遍：
  ///   `$$` → 字面 `$`；`$&` → 整个匹配；`` $` `` → 匹配前的内容；
  ///   `$'` → 匹配后的内容；`$n` / `$nn` → 第 n 个捕获组。
  /// 分组号超出范围时（如只有 1 个组却写 `$9`）**原样保留 `$9`** ——
  /// 这一点 JS 也是这么做的，不是抛异常。
  static String _replaceRegex(String input, RegExp regexp, String replacement) {
    if (!replacement.contains(_dollarChar)) {
      return input.replaceAll(regexp, replacement);
    }
    return input.replaceAllMapped(
      regexp,
      (match) => _jsExpandReplacement(match, replacement),
    );
  }

  static const String _dollarChar = r'$';
  static const int _codeDollar = 0x24;
  static const int _codeAmp = 0x26;
  static const int _codeBacktick = 0x60;
  static const int _codeQuote = 0x27;
  static const int _codeZero = 0x30;
  static const int _codeNine = 0x39;

  static bool _isDigit(int code) => code >= _codeZero && code <= _codeNine;

  static String _jsExpandReplacement(Match match, String replacement) {
    final out = StringBuffer();
    final length = replacement.length;
    var i = 0;
    while (i < length) {
      final code = replacement.codeUnitAt(i);
      // `$` 出现在末尾（后面没字符了）→ 按 JS 就是字面量 `$`。
      if (code != _codeDollar || i == length - 1) {
        out.writeCharCode(code);
        i++;
        continue;
      }
      final next = replacement.codeUnitAt(i + 1);
      switch (next) {
        case _codeDollar:
          out.writeCharCode(_codeDollar);
          i += 2;
          continue;
        case _codeAmp:
          out.write(match.group(0) ?? '');
          i += 2;
          continue;
        case _codeBacktick:
          out.write(match.input.substring(0, match.start));
          i += 2;
          continue;
        case _codeQuote:
          out.write(match.input.substring(match.end));
          i += 2;
          continue;
      }
      if (_isDigit(next)) {
        // JS 先试两位（$12），两位不是合法分组号再退成一位（$1 + 字面 '2'）。
        var groupIndex = next - _codeZero;
        var consumed = 1;
        if (i + 2 < length) {
          final third = replacement.codeUnitAt(i + 2);
          if (_isDigit(third)) {
            final two = groupIndex * 10 + (third - _codeZero);
            if (two >= 1 && two <= match.groupCount) {
              groupIndex = two;
              consumed = 2;
            }
          }
        }
        if (groupIndex >= 1 && groupIndex <= match.groupCount) {
          out.write(match.group(groupIndex) ?? '');
          i += 1 + consumed;
          continue;
        }
        // 分组不存在 → 原样输出 `$`，数字留到下一轮按字面量写出。
        out.writeCharCode(_codeDollar);
        i++;
        continue;
      }
      // `$` 后面跟着不认识的东西（`$x`、`$-`…）→ JS 也是原样保留。
      out.writeCharCode(_codeDollar);
      i++;
    }
    return out.toString();
  }

  static String? _unsafeReason(String pattern) {
    if (_nestedQuantifier.hasMatch(pattern)) {
      return '含嵌套量词（形如 (x+)+ ），可能触发正则回溯爆炸，已跳过';
    }
    return null;
  }

  /// 官方：`$.vM.push(h); while ($.vM.length > 10) $.vM.shift();`
  static void _push(List<String> logs, String message) {
    logs.add('$logPrefix$message');
    while (logs.length > maxLogEntries) {
      logs.removeAt(0);
    }
  }
}
