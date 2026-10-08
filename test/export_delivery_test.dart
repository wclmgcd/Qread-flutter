import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:qread/services/chapter_cache_export.dart';
import 'package:qread/services/export_delivery.dart';

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
}
