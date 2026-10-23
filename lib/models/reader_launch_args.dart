import 'book.dart';

/// 打开阅读页时可选的落点。
///
/// 不传 [chapterIndex] 时走原来的逻辑（服务端进度 + 本地页级进度）；
/// 传了就按指定章节/位置打开 —— 目录、书签跳转靠它压过「上次读到哪」。
class ReaderLaunchArgs {
  final Book book;
  final int? chapterIndex;
  final int chapterPosition;
  final bool openAtEnd;

  const ReaderLaunchArgs({
    required this.book,
    this.chapterIndex,
    this.chapterPosition = 0,
    this.openAtEnd = false,
  });
}
