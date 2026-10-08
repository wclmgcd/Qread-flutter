import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:qread/services/chapter_cache_export.dart';
import 'package:qread/services/export_delivery.dart';
import 'package:qread/services/local_cache_service.dart';

/// 「导出文件」这条链路的测试。
///
/// 【它守住的是什么】
/// 用户在 Android 上点「导出」曾经直接报错：
/// ```
/// 导出失败：UnimplementedError: getSavePath() has not been implemented.
/// ```
/// 原因是 `file_selector` 的 `getSaveLocation()` 在 Android / iOS / Web 上
/// **根本没实现**（官方支持表里这三端都是 ❌），只有 Linux / macOS / Windows
/// 支持。修复办法是移动端改走自建的分享通道。
///
/// 所以这里最重要的一条断言就是：**Android / iOS 绝不能再落到「另存为」**。
/// 一旦有人「顺手统一一下」把移动端也接回 getSaveLocation，这里会立刻红。
///
/// 【为什么这些用例能进 CI】
/// `export_delivery.dart` 与 `chapter_cache_export.dart` 都不 import Flutter
/// 的 UI 层（前者零 Flutter 依赖），所以 `flutter test` 跑得起来。
/// 同一批断言在开发机上还有一个独立 Dart SDK 的版本（见
/// `flutter-dart-local-validation` 技能 §8.5）。
void main() {
  group('resolveExportDelivery：按平台分派导出方式', () {
    test('桌面三端走「另存为」', () {
      for (final host in const [
        ExportHost.linux,
        ExportHost.macOS,
        ExportHost.windows,
      ]) {
        expect(
          resolveExportDelivery(host),
          ExportDelivery.saveDialog,
          reason: '${host.name} 上 file_selector 的 getSaveLocation 是实现了的',
        );
      }
    });

    test('【核心】Android / iOS 必须走分享面板，不能走「另存为」', () {
      // 这两端调 getSaveLocation() 会抛 UnimplementedError，就是本次的 bug。
      for (final host in const [ExportHost.android, ExportHost.iOS]) {
        final delivery = resolveExportDelivery(host);
        expect(delivery, ExportDelivery.shareSheet, reason: host.name);
        expect(
          delivery,
          isNot(ExportDelivery.saveDialog),
          reason: '${host.name} 上 getSavePath() 没实现，再走「另存为」就是崩',
        );
      }
    });

    test('网页版 / Fuchsia / 未知平台 → 如实说不支持，而不是假装能做', () {
      for (final host in const [
        ExportHost.web,
        ExportHost.fuchsia,
        ExportHost.unknown,
      ]) {
        expect(
          resolveExportDelivery(host),
          ExportDelivery.unsupported,
          reason: host.name,
        );
      }
    });

    test('每个 ExportHost 都有归宿（没有漏网的分支）', () {
      for (final host in ExportHost.values) {
        // 不抛异常即可；顺带确保返回值是三个合法值之一。
        expect(
          ExportDelivery.values,
          contains(resolveExportDelivery(host)),
          reason: host.name,
        );
      }
    });
  });

  group('withUtf8Bom：中文 txt 的编码标记', () {
    test('在正文前插入 EF BB BF，正文原样可解回', () {
      final bytes = ChapterCacheExport.withUtf8Bom(utf8.encode('华娱情报王'));
      expect(bytes.length, utf8.encode('华娱情报王').length + 3);
      expect(bytes[0], 0xEF);
      expect(bytes[1], 0xBB);
      expect(bytes[2], 0xBF);
      expect(utf8.decode(bytes.sublist(3)), '华娱情报王');
    });

    test('空内容只留 BOM（不越界、不抛异常）', () {
      expect(ChapterCacheExport.withUtf8Bom(const []), hasLength(3));
    });

    test('不就地改写传入的列表', () {
      final source = utf8.encode('abc');
      ChapterCacheExport.withUtf8Bom(source);
      expect(source, utf8.encode('abc'));
    });
  });

  group('sanitizeFileName：导出文件名要能落盘', () {
    test('ASCII 非法字符换成下划线', () {
      expect(
        ChapterCacheExport.sanitizeFileName('a/b\\c:d*e?f"g<h>i|j'),
        'a_b_c_d_e_f_g_h_i_j',
      );
    });

    test('全角冒号是合法文件名字符，要留着', () {
      // Windows 只禁 ASCII 的 : * ? " < > | \ /
      expect(ChapterCacheExport.sanitizeFileName('第1章：开始'), '第1章：开始');
    });

    test('换行 / 制表折叠成空格，首尾空白去掉', () {
      expect(ChapterCacheExport.sanitizeFileName('书名\n带\t换行'), '书名 带 换行');
      expect(ChapterCacheExport.sanitizeFileName('   书名   '), '书名');
    });

    test('全空兜默认名；超长截到 60', () {
      expect(ChapterCacheExport.sanitizeFileName('   '), 'qread_导出');
      expect(ChapterCacheExport.sanitizeFileName('书' * 100), hasLength(60));
    });
  });

  group('formatBytes：体积显示', () {
    test('各单位边界', () {
      expect(ChapterCacheExport.formatBytes(0), '0 B');
      expect(ChapterCacheExport.formatBytes(-1), '0 B');
      expect(ChapterCacheExport.formatBytes(1023), '1023 B');
      expect(ChapterCacheExport.formatBytes(1024), '1.0 KB');
      expect(ChapterCacheExport.formatBytes(10240), '10 KB');
      expect(ChapterCacheExport.formatBytes(1048576), '1.0 MB');
      expect(ChapterCacheExport.formatBytes(1073741824), '1.00 GB');
    });
  });

  // 用户反馈原话：「还有一个排版，导出的 txt 有时是首行空两格，但净化或取消
  // 净化后，有时是不空格，有时空 4 格，一起修复了」。
  //
  // 根因是三份缓存变体的缩进本来就不同：未净化那份是源站给的（实测 82 行 4 个
  // 全角 + 7 行 2 个），服务端净化那份被 `it.trim()` 吃成 0 个，本地净化那份
  // 又原样保留。这一组把「导出的 txt 段段都是两个全角」钉死。
  group('normalizeIndent：导出的段首缩进统一成两个全角空格', () {
    const indent = ChapterCacheExport.paragraphIndent;

    test('paragraphIndent 就是两个全角空格', () {
      expect(indent, '\u3000\u3000');
      expect(indent.length, 2);
    });

    test('【核心】0 / 2 / 4 个全角 → 一律 2 个', () {
      expect(ChapterCacheExport.normalizeIndent('第一段。'), '$indent第一段。');
      expect(
        ChapterCacheExport.normalizeIndent('$indent第一段。'),
        '$indent第一段。',
      );
      expect(
        ChapterCacheExport.normalizeIndent('\u3000\u3000\u3000\u3000第一段。'),
        '$indent第一段。',
      );
    });

    test('半角空格 / 制表符 / 混着来的缩进 → 一律 2 个全角', () {
      expect(ChapterCacheExport.normalizeIndent('    第一段。'), '$indent第一段。');
      expect(ChapterCacheExport.normalizeIndent('\t第一段。'), '$indent第一段。');
      expect(
        ChapterCacheExport.normalizeIndent('\u3000 \t\u3000第一段。'),
        '$indent第一段。',
      );
    });

    test('空行保持空 —— 不补缩进（否则会多出一堆「只有空白的行」）', () {
      expect(
        ChapterCacheExport.normalizeIndent('甲。\n\n乙。'),
        '$indent甲。\n\n$indent乙。',
      );
      // 纯空白行：插图被 stripImages 删掉之后只剩缩进的那种行
      expect(
        ChapterCacheExport.normalizeIndent('甲。\n\u3000\u3000\u3000\u3000\n乙。'),
        '$indent甲。\n\n$indent乙。',
      );
      expect(ChapterCacheExport.normalizeIndent('\u3000\u3000'), '');
    });

    test('行中 / 行尾：行中的全角是正文不能动，行尾空白要去掉', () {
      expect(
        ChapterCacheExport.normalizeIndent('$indent甲\u3000乙'),
        '$indent甲\u3000乙',
      );
      expect(ChapterCacheExport.normalizeIndent('$indent甲。  '), '$indent甲。');
    });

    test('CRLF 收敛成 LF（服务端返回的正文带 \\r）', () {
      expect(
        ChapterCacheExport.normalizeIndent('甲。\r\n乙。'),
        '$indent甲。\n$indent乙。',
      );
    });

    test('空串 / 纯换行不抛异常', () {
      expect(ChapterCacheExport.normalizeIndent(''), '');
      expect(ChapterCacheExport.normalizeIndent('\n'), '\n');
    });

    test('【前提】Dart 的 String.trim() 认全角空格 —— 不认的话上面全挂', () {
      expect('\u3000\u3000'.trim(), isEmpty);
      expect('\u3000\u3000\u3000\u3000'.trim(), isEmpty);
    });

    test('【端到端】同一份 txt 里三章缩进完全一致', () {
      final section = ChapterCacheExport.buildBookSection(
        bookName: '华娱情报王',
        chapters: const [
          // 服务端净化过的那一份：缩进被 trim 光了
          CachedChapter(index: 0, title: '第一章', content: '甲。\n乙。'),
          // 源站本来就带 2 个全角
          CachedChapter(index: 1, title: '第二章', content: '$indent丙。'),
          // 未净化的那一份：源站给的 4 个全角
          CachedChapter(
            index: 2,
            title: '第三章',
            content: '\u3000\u3000\u3000\u3000丁。',
          ),
        ],
        exportedAt: '2026-10-08 16:00',
      );
      expect(section, contains('$indent甲。\n$indent乙。'));
      expect(section, contains('$indent丙。'));
      expect(section, contains('$indent丁。'));
      expect(section, isNot(contains('\u3000\u3000\u3000\u3000')));
      expect(section, isNot(contains('\n甲。')), reason: '不能有没有缩进的正文行');
      expect(section, isNot(contains('\n丙。')));
    });

    test('【不叠空行】正文自带的尾换行不会和 writeln 叠成两行空行', () {
      final section = ChapterCacheExport.buildBookSection(
        bookName: '书',
        chapters: const [
          CachedChapter(index: 0, title: '第一章', content: '甲。\n'),
        ],
        exportedAt: '2026-10-08 16:00',
      );
      expect(section.endsWith('$indent甲。\n\n'), isTrue, reason: section);
      expect(section.endsWith('\n\n\n'), isFalse);
    });
  });
}
