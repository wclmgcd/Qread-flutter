import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:qread/services/chapter_markup.dart';

/// 段评标记编解码的测试。
///
/// 【它守住的是什么】
/// 用户反馈：「缓存和导出要把 `<img src="data:image/svg+xml;base64...` 这种
/// 去掉吧，只留下文字」。那串 base64 是段评气泡的 SVG，单章上百个、几十 KB，
/// 缓存文件没法读、导出的 txt 更没法看。但它同时又是阅读器画段评气泡的
/// **唯一数据源** —— 直接删，段评会整章消失。
///
/// 所以做法是「正文与标记拆开放」：`.txt` 只存干净正文，`.cmt` sidecar 存
/// 标记原文 + 插入位置，阅读器读的时候无损还原。这里钉死的就是那条**可逆性**
/// 不变量：`expand(compact(x).text, sidecar) == x` 必须逐字节成立。
///
/// 【为什么这些用例能进 CI】
/// `chapter_markup.dart` 只 import `dart:convert`，零 Flutter 依赖，
/// `flutter test` 跑得起来。同一批断言在开发机上还有一个独立 Dart SDK 的
/// 版本，而且那边会拿**真实章节 / 真实导出产物**再对拍一次
/// （见 `flutter-dart-local-validation` 技能 §8.5）。
void main() {
  /// 造一个和书源真实格式一致的段评标记。
  String badge(int count) {
    final svg = '<svg viewBox="5 14 45 36" xmlns="http://www.w3.org/2000/svg">'
        '<path d="M44 48 L5 48 L5 14 Z" fill="none" stroke="#909090"/>'
        '<text x="25" y="31" font-size="18" fill="#909090">$count</text></svg>';
    final b64 = base64.encode(utf8.encode(svg));
    return '<img src="data:image/svg+xml;base64,$b64,'
        '{"style":"TEXT","type":"qd","click":"showCmt(1,2,$count,3)"}">';
  }

  const illustration =
      '<img src="https://aigcc.yuewen.com/imgChapter/xx_hd.webp,'
      '{"style":"FULL","type":"qd"}">';

  group('ChapterMarkup.compact：正文只留文字', () {
    test('段评标记被摘走，正文里不再有内联 SVG', () {
      final raw = '第一段。${badge(13)}接着写。\n第二段${badge(5)}结束。';
      final packed = ChapterMarkup.compact(raw);

      expect(packed.text.contains('data:image/svg+xml'), isFalse);
      expect(packed.text.contains('showCmt'), isFalse);
      expect(packed.text, '第一段。接着写。\n第二段结束。');
      expect(packed.sidecar.isNotEmpty, isTrue);
    });

    test('sidecar 条数 = 摘掉的标记数', () {
      final raw = '${badge(1)}a${badge(2)}b${badge(3)}';
      final packed = ChapterMarkup.compact(raw);
      final decoded = jsonDecode(packed.sidecar) as Map;
      expect((decoded['i'] as List).length, 3);
    });

    test('没有段评的章节：sidecar 是空串（不该白写一个文件）', () {
      final packed = ChapterMarkup.compact('这是一章没有任何段评的普通正文。');
      expect(packed.text, '这是一章没有任何段评的普通正文。');
      expect(packed.sidecar, isEmpty);
    });

    test('真插图的 <img> 要留在正文里（阅读器还得渲染它）', () {
      final packed = ChapterMarkup.compact('文字\n$illustration\n更多文字');
      expect(packed.text.contains('aigcc.yuewen.com'), isTrue);
    });
  });

  group('ChapterMarkup.expand：无损还原', () {
    test('【核心不变量】compact → expand 逐字节还原', () {
      final raw = '第一段。${badge(13)}接着写。\n'
          '第二段${badge(5)}中间${badge(7)}结束。\n'
          '$illustration\n'
          '第三段。';
      final packed = ChapterMarkup.compact(raw);
      expect(ChapterMarkup.expand(packed.text, packed.sidecar), raw);
    });

    test('还原后的标记仍能被引擎的整块正则匹配到', () {
      final raw = 'a${badge(9)}b';
      final packed = ChapterMarkup.compact(raw);
      final restored = ChapterMarkup.expand(packed.text, packed.sidecar);
      expect(ChapterMarkup.wholeTag.allMatches(restored).length, 1);
    });

    test('sidecar 为空 → 原样返回', () {
      expect(ChapterMarkup.expand('abc', ''), 'abc');
    });

    test('【哈希守卫】正文和 sidecar 不是同一次写的 → 原样返回，绝不乱插', () {
      final packed = ChapterMarkup.compact('甲${badge(1)}乙');
      expect(
        ChapterMarkup.expand('另一章完全不同的正文', packed.sidecar),
        '另一章完全不同的正文',
      );
    });

    test('sidecar 不是 JSON / 版本号不认识 → 原样返回', () {
      final packed = ChapterMarkup.compact('甲${badge(1)}乙');
      expect(ChapterMarkup.expand(packed.text, '不是 json'), packed.text);
      expect(
        ChapterMarkup.expand(packed.text, '{"v":99,"h":"x","n":1,"i":[]}'),
        packed.text,
      );
    });

    test('位置越界的 sidecar → 原样返回（宁可少气泡，也不能切坏正文）', () {
      final packed = ChapterMarkup.compact('甲${badge(1)}乙');
      final hash = (jsonDecode(packed.sidecar) as Map)['h'];
      final broken = '{"v":1,"h":"$hash","n":1,"i":[[999999,"x"]]}';
      expect(ChapterMarkup.expand(packed.text, broken), packed.text);
    });
  });

  group('ChapterMarkup.stripImages：导出纯文本', () {
    test('所有 <img> 都删掉（段评 + 真插图一起）', () {
      final raw = '文字${badge(3)}$illustration尾';
      final out = ChapterMarkup.stripImages(raw);
      expect(out.contains('<img'), isFalse);
      expect(out, '文字尾');
    });

    test('不误伤正文', () {
      expect(
        ChapterMarkup.stripImages('第一段。${badge(3)}接着写。'),
        '第一段。接着写。',
      );
    });
  });
}
