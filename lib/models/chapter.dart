import 'package:json_annotation/json_annotation.dart';
import 'json_helpers.dart';

part 'chapter.g.dart';

@JsonSerializable()
class Chapter {
  @JsonKey(name: 'bookUrl')
  String? bookUrl;

  @JsonKey(name: 'title')
  String? title;

  @JsonKey(name: 'chapterIndex')
  int? chapterIndex;

  @JsonKey(name: 'isVolume')
  bool? isVolume;

  @JsonKey(name: 'isVip')
  bool? isVip;

  @JsonKey(name: 'resourceUrl')
  String? resourceUrl;

  @JsonKey(name: 'tag')
  String? tag;

  @JsonKey(name: 'wordCount')
  String? wordCount;

  @JsonKey(name: 'lastCheckTime')
  int? lastCheckTime;

  Chapter({
    this.bookUrl,
    this.title,
    this.chapterIndex,
    this.isVolume,
    this.isVip,
    this.resourceUrl,
    this.tag,
    this.wordCount,
    this.lastCheckTime,
  });

  factory Chapter.fromJson(Map<String, dynamic> json) => Chapter(
        bookUrl: toStringVal(json['bookUrl']),
        title: toStringVal(json['title']),
        // 服务端目录把序号放在 index 里，chapterIndex 只有老数据才有
        chapterIndex: toInt(json['chapterIndex']) ?? toInt(json['index']),
        isVolume: toBool(json['isVolume']),
        isVip: toBool(json['isVip']),
        resourceUrl: toStringVal(json['resourceUrl']),
        tag: toStringVal(json['tag']),
        wordCount: toStringVal(json['wordCount']),
        lastCheckTime: toInt(json['lastCheckTime']),
      );

  Map<String, dynamic> toJson() => _$ChapterToJson(this);
}
