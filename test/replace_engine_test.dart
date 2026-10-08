import 'package:flutter_test/flutter_test.dart';
import 'package:qread/models/replace_rule.dart';
import 'package:qread/services/replace_engine.dart';

/// 本地净化引擎的行为测试。
///
/// 这里**只测引擎本身**（`ReplaceEngine` 不依赖 Flutter，纯 Dart），
/// 不测 `ReaderProvider` 里「归谁净化」的路由逻辑 —— 那部分要连服务端，
/// 放到手工验证里做。
///
/// 【这些用例都在真实 Dart 上跑过】
/// 开发机上没有 Flutter SDK，所以先用一个只含 `models/` + `replace_engine.dart`
/// 的最小工程 + 独立 Dart SDK 把同一批断言跑通，再搬进来。
/// 顺带发现并修掉了一个会让**一大批规则静默失效**的坑：Dart 的
/// `String.replaceAll(RegExp, String)` **不展开 `$1`**，详见
/// `$ 语义` 那一组。
///
/// 【一个没覆盖到的点：真正的正则超时】
/// 没法构造「确定会超时、但又不会把测试进程挂死」的正则：Dart 的 `RegExp`
/// 是同步的，一旦真的回溯爆炸就掐不断，测试自己会先卡死。所以这里退一步，
/// 用「大输入 + 1ms 阈值」验证**计时与记账**这条链路是通的
/// （见 `超时会被记录为 failure`）。回溯爆炸本身由
/// `危险正则会被静态拦下` 覆盖。
///
/// 【写这个文件时踩的坑】Dart 里普通字符串中的 `$` 必须转义或写成原始字符串，
/// 所以下面凡是含 `$` 的**测试名**都用了 `r'...'`。
void main() {
  ReplaceOutcome run(
    String content,
    List<ReplaceRule> rules, {
    String bookName = '测试书',
    String bookOrigin = 'https://example.com',
    bool forTitle = false,
  }) {
    return ReplaceEngine.apply(
      content: content,
      rules: rules,
      bookName: bookName,
      bookOrigin: bookOrigin,
      forTitle: forTitle,
    );
  }

  group('非正则规则', () {
    test('字面量替换', () {
      final outcome = run('夜晚的风', [
        const ReplaceRule(id: '1', pattern: '夜晚', replacement: '★'),
      ]);
      expect(outcome.content, '★的风');
      expect(outcome.applied.length, 1);
      expect(outcome.failures, isEmpty);
    });

    test(r'非正则路径下 $1 是字面量（不做分组展开）', () {
      final outcome = run('xax', [
        const ReplaceRule(
          id: '1',
          pattern: 'a',
          replacement: r'$1',
          isRegex: false,
        ),
      ]);
      expect(outcome.content, r'x$1x');
    });

    test('pattern 为空直接跳过', () {
      final outcome = run('原文', [
        const ReplaceRule(id: '1', pattern: '', replacement: 'X'),
      ]);
      expect(outcome.content, '原文');
      expect(outcome.applied, isEmpty);
    });
  });

  group(r'$ 语义（对齐 JS 的 String.prototype.replace）', () {
    String rep(String input, String pattern, String replacement) {
      return run(input, [
        ReplaceRule(
          id: '1',
          pattern: pattern,
          replacement: replacement,
        ),
      ]).content;
    }

    // 【为什么这一组特别重要】
    // Dart 的 `replaceAll(RegExp, String)` **不展开 `$1`** —— 实测
    // `'第12章'.replaceAll(RegExp(r'第(\d+)章'), r'[$1]')` 得到的是 `[$1]`。
    // 阅读的规则集里 `$1` / `$2` 用得极多，如果照搬 replaceAll，会让一大批
    // 规则**静默失效**（不报错，只是正文里原样留着 `$1`）。
    // 所以引擎自己实现了 JS 那套语义，这一组就是它的验收标准。
    test(r'$1 展开为第 1 个捕获组', () {
      expect(rep('第12章 开端', r'第(\d+)章', r'[$1]'), '[12] 开端');
    });

    test(r'$4$3$2$1 多分组倒序', () {
      expect(rep('abcd', r'(a)(b)(c)(d)', r'$4$3$2$1'), 'dcba');
    });

    test(r'$12 两位优先：只有 2 组时退成 $1 + 字面 2', () {
      expect(rep('ab', r'(a)(b)', r'$12'), 'a2');
    });

    test(r'$0 / $9 / $99 越界时原样保留（JS 也是这个行为）', () {
      expect(rep('a', r'(a)', r'$0'), r'$0');
      expect(rep('a', r'(a)', r'$99'), r'$99');
      expect(rep('abc', 'b', r'<$9>'), r'a<$9>c');
    });

    test(r'$$ 变成字面 $', () {
      expect(rep('xax', 'a', r'$$'), r'x$x');
    });

    test(r'$& 是整个匹配', () {
      expect(rep('abc', 'b', r'<$&>'), r'a<b>c');
    });

    test(r"$` 是匹配前的内容，$' 是匹配后的内容", () {
      expect(rep('abc', 'b', r'[$`]'), r'a[a]c');
      expect(rep('abc', 'b', r"[$']"), r"a[c]c");
    });

    test(r'末尾单独的 $ 是字面量', () {
      expect(rep('abc', 'b', r'$'), r'a$c');
    });

    test(r'$ 后跟不认识的东西时原样保留', () {
      expect(rep('abc', 'b', r'<$x>'), r'a<$x>c');
      expect(rep('a', r'(a)', r'${1}'), r'${1}');
    });

    test(r'没匹配上时 replacement 里的 $ 不该被碰', () {
      expect(rep('abc', 'z', r'$1'), 'abc');
    });
  });

  group('正则规则', () {
    test('默认不开启 multiLine（和 JS 的 new RegExp(p, "g") 一致）', () {
      // 没开 multiLine 时 `^` / `$` 只认整串首尾，而 `.` 不跨行 →
      // `^.+$` 在「标题\n正文」上**匹配不到**。开了 multiLine 会变成 'X\nX'。
      final outcome = run('标题\n正文', [
        const ReplaceRule(
          id: '1',
          pattern: r'^.+$',
          replacement: 'X',
          isRegex: true,
        ),
      ]);
      expect(outcome.content, '标题\n正文');
      expect(outcome.applied, isEmpty);
    });

    test('中文 pattern 正常', () {
      final outcome = run('第一章 开端 第一章', [
        const ReplaceRule(
          id: '1',
          pattern: '第一章',
          replacement: '楔子',
          isRegex: true,
        ),
      ]);
      expect(outcome.content, '楔子 开端 楔子');
    });

    test('正则非法记为 invalid-pattern，正文不动', () {
      final outcome = run('原文', [
        const ReplaceRule(id: '1', pattern: r'([', replacement: 'X'),
      ]);
      expect(outcome.content, '原文');
      expect(outcome.failures.single.kind, 'invalid-pattern');
    });

    test('危险正则（嵌套量词）会被静态拦下', () {
      for (final pattern in <String>[r'(a+)+', r'(\w*)*', r'(x+){2,}', r'(.+)+']) {
        final outcome = run('aaaaa', [
          ReplaceRule(id: '1', pattern: pattern, replacement: 'X'),
        ]);
        expect(outcome.content, 'aaaaa', reason: '$pattern 不该被执行');
        expect(outcome.failures.single.kind, 'unsafe-pattern');
      }
    });

    test('安全的量词写法不会被误伤', () {
      // `(第[0-9]+章)` 的量词在**分组内部**、分组本身没有量词 —— 安全。
      final outcome = run('第1章 第2章', [
        const ReplaceRule(
          id: '1',
          pattern: r'(第[0-9]+章)',
          replacement: r'<$1>',
          isRegex: true,
        ),
      ]);
      expect(outcome.content, '<第1章> <第2章>');
      expect(outcome.failures, isEmpty);
    });

    test('(ab)+ 这类分组量词不算危险', () {
      final outcome = run('abab', [
        const ReplaceRule(
          id: '1',
          pattern: r'(ab)+',
          replacement: 'X',
          isRegex: true,
        ),
      ]);
      expect(outcome.content, 'X');
      expect(outcome.failures, isEmpty);
    });
  });

  group('执行顺序', () {
    test('按 ruleorder 从小到大依次套用', () {
      final outcome = run('x', [
        const ReplaceRule(id: '2', pattern: 'y', replacement: 'z', order: 1),
        const ReplaceRule(id: '1', pattern: 'x', replacement: 'y', order: 0),
      ]);
      // order 0 先把 x→y，order 1 再把 y→z。顺序反了只会得到 'y'。
      expect(outcome.content, 'z');
      expect(outcome.applied.map((r) => r.id).toList(), ['1', '2']);
    });
  });

  group('作用域过滤', () {
    test('isEnabled=false 不参与', () {
      final outcome = run('夜晚', [
        const ReplaceRule(
          id: '1',
          pattern: '夜晚',
          replacement: '★',
          isEnabled: false,
        ),
      ]);
      expect(outcome.content, '夜晚');
    });

    test('scopeContent=false 的规则不作用于正文，但作用于标题', () {
      const rule = ReplaceRule(
        id: '1',
        pattern: '开端',
        replacement: '★',
        scopeContent: false,
        scopeTitle: true,
      );
      expect(run('开端', [rule]).content, '开端');
      expect(run('开端', [rule], forTitle: true).content, '★');
    });

    test('scope 不包含本书时跳过', () {
      const rule = ReplaceRule(
        id: '1',
        pattern: '夜晚',
        replacement: '★',
        scope: '另一本书',
      );
      expect(run('夜晚', [rule]).content, '夜晚');
      expect(run('夜晚', [rule], bookName: '另一本书').content, '★');
    });

    test('excludeScope 命中本书时跳过', () {
      const rule = ReplaceRule(
        id: '1',
        pattern: '夜晚',
        replacement: '★',
        excludeScope: '测试书',
      );
      expect(run('夜晚', [rule]).content, '夜晚');
    });

    test('scope 里写书源地址也能命中', () {
      const rule = ReplaceRule(
        id: '1',
        pattern: '夜晚',
        replacement: '★',
        scope: 'https://example.com',
      );
      expect(run('夜晚', [rule]).content, '★');
    });

    test('scope 只有空白字符时视为全局', () {
      const rule = ReplaceRule(
        id: '1',
        pattern: '夜晚',
        replacement: '★',
        scope: '   ',
      );
      expect(run('夜晚', [rule]).content, '★');
    });
  });

  group('applied / failures 记账', () {
    test('没匹配上的规则不进 applied', () {
      final outcome = run('夜晚', [
        const ReplaceRule(id: '1', pattern: '白天', replacement: '★'),
      ]);
      expect(outcome.applied, isEmpty);
      expect(outcome.changed, isFalse);
    });

    test('结果没变的规则不进 applied', () {
      final outcome = run('夜晚', [
        const ReplaceRule(id: '1', pattern: '夜晚', replacement: '★'),
        // 第二条把 ★ 换成 ★ —— 结果没变，不该进 applied。
        const ReplaceRule(id: '2', pattern: '★', replacement: '★'),
      ]);
      expect(outcome.content, '★');
      expect(outcome.applied.map((r) => r.id).toList(), ['1']);
    });

    test('超时会被记录为 failure（大输入 + 1ms 阈值）', () {
      final huge = List<String>.filled(300000, 'a').join();
      final outcome = run(huge, [
        const ReplaceRule(
          id: '1',
          pattern: 'a',
          replacement: 'b',
          timeoutMillisecond: 1,
        ),
      ]);
      expect(outcome.content.length, huge.length);
      expect(outcome.failures.single.kind, 'timeout');
    });

    test('timeoutMillisecond=0 表示不检查超时', () {
      final huge = List<String>.filled(300000, 'a').join();
      final outcome = run(huge, [
        const ReplaceRule(
          id: '1',
          pattern: 'a',
          replacement: 'b',
          timeoutMillisecond: 0,
        ),
      ]);
      expect(outcome.failures, isEmpty);
    });
  });

  group('trimLines（服务端多做的那一步）', () {
    // 服务端在套规则前会 `re.lines().joinToString("\n"){ it.trim() }`，
    // 官方客户端没有这一步 —— 所以默认 false。这一组验证开关真的起作用，
    // 以及它只影响「逐行首尾空白」，不会动到正文内容。
    const content = '　　　　第一段\n第二段  \n\u3000第三段';

    test('默认不 trim：段首全角缩进原样保留', () {
      final outcome = run(content, const <ReplaceRule>[]);
      expect(outcome.content, content);
    });

    test('trimLines=true 时逐行去掉首尾空白', () {
      final outcome = ReplaceEngine.apply(
        content: content,
        rules: const <ReplaceRule>[],
        bookName: '测试书',
        bookOrigin: 'https://example.com',
        trimLines: true,
      );
      expect(outcome.content, '第一段\n第二段\n第三段');
    });

    test('trim 发生在套规则之前（和服务端顺序一致）', () {
      // 这条规则只在「行首还是全角空格」时才会命中。
      //   trim 先跑 → 空格已经没了 → 不命中 → 'abc'
      //   规则先跑 → 命中 → 'Xabc'
      // 两种顺序结果不同，所以这一条能证明顺序。
      const rule = ReplaceRule(id: '1', pattern: r'^\u3000', replacement: 'X');
      final trimmed = ReplaceEngine.apply(
        content: '\u3000abc',
        rules: const [rule],
        bookName: '测试书',
        bookOrigin: 'https://example.com',
        trimLines: true,
      );
      final notTrimmed = ReplaceEngine.apply(
        content: '\u3000abc',
        rules: const [rule],
        bookName: '测试书',
        bookOrigin: 'https://example.com',
      );
      expect(trimmed.content, 'abc');
      expect(notTrimmed.content, 'Xabc');
    });
  });

  group('日志', () {
    test(r'前缀是官方的「替换净化: 」（冒号后带一个空格）', () {
      final outcome = run('原文', [
        const ReplaceRule(id: '1', pattern: r'([', replacement: 'X'),
      ]);
      expect(ReplaceEngine.logPrefix, '替换净化: ');
      expect(outcome.logs.single.startsWith(ReplaceEngine.logPrefix), isTrue);
    });

    test(r'环形缓冲上限 10 条（和官方 while ($.vM.length > 10) 一致）', () {
      final rules = [
        for (var i = 0; i < 15; i++)
          ReplaceRule(id: '$i', name: 'R$i', pattern: r'([', replacement: 'X'),
      ];
      final outcome = run('原文', rules);
      expect(outcome.failures.length, 15);
      expect(outcome.logs.length, ReplaceEngine.maxLogEntries);
      // 留下的是**最近** 10 条：最早那条（R0）被挤掉，R5 起还在，R14 是最新。
      expect(outcome.logs.last.contains('R14'), isTrue);
      expect(outcome.logs.first.contains('R5'), isTrue);
    });
  });

  group('边界', () {
    test('没有规则时原样返回', () {
      final outcome = run('原文', const <ReplaceRule>[]);
      expect(outcome.content, '原文');
      expect(outcome.applied, isEmpty);
      expect(outcome.logs, isEmpty);
    });

    test('空正文不炸', () {
      final outcome = run('', [
        const ReplaceRule(id: '1', pattern: 'a', replacement: 'b'),
      ]);
      expect(outcome.content, '');
    });

    test('规则把正文清空', () {
      final outcome = run('abc', [
        const ReplaceRule(
          id: '1',
          pattern: r'.+',
          replacement: '',
          isRegex: true,
        ),
      ]);
      expect(outcome.content, '');
    });

    test('模型默认 isRegex=true', () {
      expect(const ReplaceRule(id: '1').isRegex, isTrue);
    });
  });
}
