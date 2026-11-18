import 'package:json_annotation/json_annotation.dart';
import 'book.dart';
import 'book_source.dart';
import 'json_helpers.dart';

part 'search_result.g.dart';

@JsonSerializable()
class SearchResult {
  @JsonKey(name: 'bookUrl')
  String? bookUrl;

  @JsonKey(name: 'name')
  String? name;

  @JsonKey(name: 'author')
  String? author;

  @JsonKey(name: 'coverUrl')
  String? coverUrl;

  @JsonKey(name: 'intro')
  String? intro;

  @JsonKey(name: 'kind')
  String? kind;

  @JsonKey(name: 'latestChapterTitle')
  String? latestChapterTitle;

  @JsonKey(name: 'tocUrl')
  String? tocUrl;

  @JsonKey(name: 'origin')
  String? origin;

  @JsonKey(name: 'originName')
  String? originName;

  @JsonKey(name: 'wordCount')
  String? wordCount;

  @JsonKey(name: 'type', fromJson: normalizeBookType)
  int? type;

  SearchResult({
    this.bookUrl,
    this.name,
    this.author,
    this.coverUrl,
    this.intro,
    this.kind,
    this.latestChapterTitle,
    this.tocUrl,
    this.origin,
    this.originName,
    this.wordCount,
    this.type,
  });

  factory SearchResult.fromJson(Map<String, dynamic> json) => SearchResult(
        bookUrl: toStringVal(json['bookUrl']),
        name: toStringVal(json['name']),
        author: toStringVal(json['author']),
        coverUrl: toStringVal(json['coverUrl']),
        intro: toStringVal(json['intro']),
        kind: toStringVal(json['kind']),
        latestChapterTitle: toStringVal(json['latestChapterTitle']),
        tocUrl: toStringVal(json['tocUrl']),
        origin: toStringVal(json['origin']),
        originName: toStringVal(json['originName']),
        wordCount: toStringVal(json['wordCount']),
        type: normalizeBookType(json['type']),
      );

  /// 搜索/发现共用转换；仅在结果缺失类型且来源不冲突时使用已知书源。
  Book toBook({BookSource? source}) {
    final sourceUrl = source?.bookSourceUrl;
    final canUseSource = sourceUrl != null &&
        sourceUrl.isNotEmpty &&
        ((origin ?? '').isEmpty || origin == sourceUrl);
    return Book(
      bookUrl: bookUrl,
      name: name,
      author: author,
      coverUrl: coverUrl,
      intro: intro,
      kind: kind,
      latestChapterTitle: latestChapterTitle,
      tocUrl: tocUrl,
      origin: origin,
      originName: originName,
      wordCount: wordCount,
      type: normalizeBookType(type) ??
          (canUseSource ? bookTypeFromSource(source?.bookSourceType) : null) ??
          0,
      group: 0,
    );
  }

  Map<String, dynamic> toJson() => _$SearchResultToJson(this);
}
