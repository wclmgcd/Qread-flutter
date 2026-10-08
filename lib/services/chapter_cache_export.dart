import 'dart:typed_data';

import '../models/replace_rule.dart';
import 'chapter_markup.dart';
import 'local_cache_service.dart';
import 'replace_engine.dart';

/// 章节缓存导出的**纯逻辑**：拼文本、体积格式化、文件名收敛。
///
/// 【为什么单独一个文件】这里全是字符串处理、**不依赖 Flutter**，
/// 于是可以放进本地探针工程用真实代码对拍（本机没有 Flutter SDK，
/// 见技能 `flutter-dart-local-validation` §8.5）。
/// 页面（`general_settings_page.dart`）里只留 UI 和文件 IO。
class ChapterCacheExport {
  ChapterCacheExport._();

  /// 书与书、书头与正文之间的分隔线。
  static final String separator = '=' * 40;

  /// 一本书导出成的分节文本。
  ///
  /// 形状：
  /// ```
  /// 书名
  /// 共 N 章
  /// 导出时间：2026-10-08 14:30
  /// 作者：xxx
  ///
  /// ========================================
  ///
  /// 第一章 xxx
  ///
  /// 正文……
  /// ```
  ///
  /// 【段首缩进在这里统一】正文的缩进交给 [normalizeIndent] —— 同一本书的
  /// 三份缓存变体缩进各不相同（0 / 2 / 4 个全角），导出的 txt 必须长一个样。
  static String buildBookSection({
    required String bookName,
    String? author,
    required List<CachedChapter> chapters,
    required String exportedAt,
  }) {
    final buffer = StringBuffer()
      ..writeln(bookName)
      ..writeln('共 ${chapters.length} 章')
      ..writeln('导出时间：$exportedAt');
    final trimmedAuthor = author?.trim();
    if (trimmedAuthor != null && trimmedAuthor.isNotEmpty) {
      buffer.writeln('作者：$trimmedAuthor');
    }
    buffer
      ..writeln()
      ..writeln(separator)
      ..writeln();

    for (final chapter in chapters) {
      buffer
        ..writeln(chapterTitle(chapter))
        ..writeln()
        // 段首缩进统一成两个全角（见 [normalizeIndent]），再去掉正文自带的
        // 尾换行 —— 不然会和下面那句 `writeln()` 叠出两行空行。
        ..writeln(normalizeIndent(chapter.content).trimRight())
        ..writeln();
    }
    return buffer.toString();
  }

  /// 章节标题。缓存里没存标题（这次改动之前写的缓存）就用「第 N 章」兜底。
  static String chapterTitle(CachedChapter chapter) {
    final title = chapter.title.trim();
    if (title.isNotEmpty) return title;
    return '第 ${chapter.index + 1} 章';
  }

  /// 多本书之间空两行，避免上一本的末尾和下一本的书名粘在一起。
  static String joinBookSections(Iterable<String> sections) =>
      sections.join('\n\n');

  // -------------------------------------------------------------- 导出排版

  /// 段落首行缩进 —— 两个全角空格 `\u3000\u3000`。
  ///
  /// 【为什么是它】中文小说的段首缩进就是这个。阅读器渲染时也自己补两个全角
  /// （`PaginationEngine.defaultFirstLineIndent = 2`），导出和阅读观感一致。
  static const String paragraphIndent = '\u3000\u3000';

  /// 把正文的**段首缩进统一成** [paragraphIndent]。
  ///
  /// 【为什么导出前必须做这一步】同一本书的三份缓存变体，缩进是三个样：
  ///   - `replace_off`（未净化）：源站正文自带缩进，**源头自己就不齐** ——
  ///     实测《华娱情报王》第一章 89 行里 82 行是 4 个全角、7 行是 2 个；
  ///   - `replace_on`（服务端净化）：服务端套规则前会
  ///     `lines().joinToString("\n"){ it.trim() }`，缩进被吃光 → 0 个；
  ///   - `replace_on_<指纹>`（本地净化）：客户端**不** trim（`ReplaceEngine.apply`
  ///     的 `trimLines` 默认 false），保留源站的 4 / 2 个。
  ///
  /// 于是用户把「替换净化」一开一关，导出的 txt 就在 0 / 2 / 4 之间跳 ——
  /// 这正是「有时空两格、有时不空、有时空 4 格」的根因。在这里一刀切齐。
  ///
  /// 【只动行首】
  ///   - 空行、纯空白行（含「插图被 [ChapterMarkup.stripImages] 删掉之后只剩
  ///     缩进」的那种行）保持**空**，不补缩进；
  ///   - 行中、行尾的字符一个都不动（行中的全角空格是正文，不是缩进）；
  ///   - 顺带把 `\r\n` 收敛成 `\n`。
  ///
  /// 一个 `trim()` 就够：Dart 的 `String.trim()` 把全角空格 `\u3000` 也算空白，
  /// 半角、全角、制表、`\r` 一起管住（探针里有一条专门钉死这个前提）。
  ///
  /// 【只影响导出】阅读器不看正文里的缩进 —— `PaginationEngine` 会先
  /// `line.replaceAll(_whitespace, ' ').trim()` 再自己补两个全角。
  static String normalizeIndent(String text) {
    if (text.isEmpty) return text;
    final lines = text.split('\n');
    final buffer = StringBuffer();
    for (var i = 0; i < lines.length; i++) {
      if (i > 0) buffer.write('\n');
      final body = lines[i].trim();
      if (body.isEmpty) continue; // 空行保持空
      buffer
        ..write(paragraphIndent)
        ..write(body);
    }
    return buffer.toString();
  }

  /// 人类可读的体积。
  ///
  /// 【阈值取 10 才降精度】`1.0 KB` / `12 KB` 比 `1.00 KB` / `12.34 KB`
  /// 更好读；单位越大越不需要小数。
  static String formatBytes(int bytes) {
    if (bytes < 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(kb < 10 ? 1 : 0)} KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
    return '${(mb / 1024).toStringAsFixed(2)} GB';
  }

  /// 把书名收敛成各平台都能落盘的文件名。
  ///
  /// 三步：
  ///   1. 控制字符（含换行 / 制表）换成空格 —— 书名里出现它们只可能是脏数据；
  ///   2. Windows / macOS 的非法字符（`\ / : * ? " < > |`）换成 `_`
  ///      —— 书名里带「第1章：xxx」这类冒号很常见，不处理在 Windows 上直接
  ///      存不下来；
  ///   3. 连续空白折叠成一个空格并去掉首尾。
  ///
  /// 最后限长 60 字符（超长文件名在部分文件系统上会被截断或直接失败），
  /// 全空则兜一个默认名。
  static String sanitizeFileName(String raw) {
    final cleaned = raw
        .replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ')
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final limited = cleaned.length > 60 ? cleaned.substring(0, 60) : cleaned;
    return limited.isEmpty ? 'qread_导出' : limited;
  }

  /// 导出时间戳文案（本地时间，分钟精度就够）。
  static String timestampLabel(DateTime now) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)} '
        '${two(now.hour)}:${two(now.minute)}';
  }

  /// 给 UTF-8 字节加 BOM（`EF BB BF`）。
  ///
  /// 【为什么要加】中文 txt 不加 BOM 时，一部分阅读器和旧版记事本会按 GBK
  /// 猜编码，整本书变乱码。三个字节的 BOM 能让它们稳定识别成 UTF-8；
  /// 现代编辑器（VSCode / 新版记事本 / 主流手机阅读器）都会自动忽略它。
  static Uint8List withUtf8Bom(List<int> utf8Bytes) {
    final out = Uint8List(utf8Bytes.length + 3);
    out[0] = 0xEF;
    out[1] = 0xBB;
    out[2] = 0xBF;
    out.setRange(3, out.length, utf8Bytes);
    return out;
  }

  // ------------------------------------------------------------ 导出前净化

  /// 「未净化」的缓存在导出时能不能**补跑**一次本地净化。
  ///
  /// 【为什么放在这里而不是页面里】这是本功能的**核心规则**（用户明确要求
  /// 「导出的是替换净化后的内容」），有四个前置条件，全埋在页面的 `State`
  /// 里就只能靠手点验证。挪成纯函数之后可以逐条打表（见探针
  /// `bin/probe_cache.dart`），而且和 `formatBytes` / `sanitizeFileName`
  /// 一样不依赖 Flutter。
  ///
  /// 四个条件缺一不可：
  ///   - [engineIsLocal]：服务端净化没法在客户端补跑（规则在服务端）；
  ///   - [globalUseReplaceRule]：全局净化关着，用户本来就不想要净化后的正文；
  ///   - [bookUseReplaceRule]：这本书自己关掉了净化；`null` = 未知（老缓存
  ///     没有这份元信息），按「跟随全局」处理，不当成关闭；
  ///   - [ruleCount] > 0：规则为空时跑了等于没跑。
  static bool canPurifyLocally({
    required bool engineIsLocal,
    required bool globalUseReplaceRule,
    required bool? bookUseReplaceRule,
    required int ruleCount,
  }) {
    if (!engineIsLocal) return false;
    if (!globalUseReplaceRule) return false;
    if (bookUseReplaceRule == false) return false;
    return ruleCount > 0;
  }

  /// 导出前把一本书的章节「净化补齐」。
  ///
  /// 【关键不变量：绝不能净化两遍】已经净化过的缓存（[alreadyPurified]）
  /// 原样带走；只有未净化的那一份、且允许补跑时，才过一次
  /// [ReplaceEngine]。像「`。` → `。\n`」这种规则跑两遍会凭空多出一倍
  /// 空行 —— 探针里有一条专门钉死这件事。
  ///
  /// 【最后一步会把 `<img>` 全删掉】段评标记在缓存层就已经拆进 `.cmt`
  /// sidecar 了（见 `ChapterMarkup`），这里再补一刀是清掉**正文真插图**的
  /// `<img src="https://...webp,{...}">` —— 导出的是一份给人读的 txt，
  /// 图片地址（还挂着一段 JSON）留在里面只是噪声。用户的原话是「只留下文字」。
  ///
  /// 返回补跑了几章、以及最终仍是未净化状态的章数（给用户看的提示用）。
  static ({List<CachedChapter> chapters, int purifiedOnTheFly, int leftRaw})
      prepareChapters({
    required List<CachedChapter> cached,
    required bool alreadyPurified,
    required bool canPurifyLocally,
    required List<ReplaceRule> rules,
    required String bookName,
    required String bookOrigin,
  }) {
    var purifiedOnTheFly = 0;
    var leftRaw = 0;
    final out = <CachedChapter>[];
    for (final chapter in cached) {
      var body = chapter.content;
      var purified = alreadyPurified;
      if (!purified && canPurifyLocally) {
        body = ReplaceEngine.apply(
          content: body,
          rules: rules,
          bookName: bookName,
          bookOrigin: bookOrigin,
          forTitle: false,
        ).content;
        purified = true;
        purifiedOnTheFly++;
      }
      if (!purified) leftRaw++;
      out.add(CachedChapter(
        index: chapter.index,
        title: chapter.title,
        content: ChapterMarkup.stripImages(body),
      ));
    }
    return (
      chapters: out,
      purifiedOnTheFly: purifiedOnTheFly,
      leftRaw: leftRaw,
    );
  }
}
