/// 朗读引擎（HTTP TTS）
///
/// 对齐后端 `TTsController` 的 `/getalltts` 返回结构（web.model.HttpTts）。
/// 和 legado 的「朗读引擎」是同一套配置：`url` 里用 `{{speakText}}`、
/// `{{speakSpeed}}` 之类的模板占位。
///
/// 【客户端不需要自己拼 URL】后端 `/tts?id=&speakText=&speechRate=` 会拿 id
/// 去查引擎、替换模板、合成音频流直接返回，所以这里只做展示与增删改。
class TtsEngine {
  /// 数据库主键 = Md5(userid + name)。
  /// 删除（`/deltts`）和合成（`/tts`）都用这个字段。
  String? id;

  String name;
  String url;
  String? contentType;
  String? concurrentRate;
  String? loginUrl;
  String? loginUi;
  String? header;
  bool? enabledCookieJar;
  String? loginCheckJs;
  int? lastUpdateTime;

  TtsEngine({
    this.id,
    this.name = '',
    this.url = '',
    this.contentType,
    this.concurrentRate,
    this.loginUrl,
    this.loginUi,
    this.header,
    this.enabledCookieJar,
    this.loginCheckJs,
    this.lastUpdateTime,
  });

  bool get isEnabled => (name.trim().isNotEmpty && url.trim().isNotEmpty);

  factory TtsEngine.fromJson(Map<String, dynamic> json) => TtsEngine(
        id: json['id']?.toString(),
        name: json['name']?.toString() ?? '',
        url: json['url']?.toString() ?? '',
        contentType: json['contentType']?.toString(),
        concurrentRate: json['concurrentRate']?.toString(),
        loginUrl: json['loginUrl']?.toString(),
        loginUi: json['loginUi']?.toString(),
        header: json['header']?.toString(),
        enabledCookieJar: json['enabledCookieJar'] == true,
        loginCheckJs: json['loginCheckJs']?.toString(),
        lastUpdateTime:
            int.tryParse(json['lastUpdateTime']?.toString() ?? ''),
      );

  /// 提交给后端。带 [id] 表示更新，不带表示新增
  /// （后端 `addtts` 就是按 id 是否为空分流的）。
  Map<String, dynamic> toJson({bool withId = true}) => {
        if (withId && id != null && id!.isNotEmpty) 'id': id,
        'name': name,
        'url': url,
        'contentType': contentType ?? '',
        'concurrentRate': concurrentRate ?? '',
        'loginUrl': loginUrl ?? '',
        'loginUi': loginUi ?? '',
        'header': header ?? '',
        'enabledCookieJar': enabledCookieJar ?? false,
        'loginCheckJs': loginCheckJs ?? '',
      };

  /// 从导入的 JSON（legado 格式）构造，忽略库字段
  factory TtsEngine.fromImportJson(Map<String, dynamic> json) => TtsEngine(
        name: json['name']?.toString() ?? '',
        url: json['url']?.toString() ?? '',
        contentType: json['contentType']?.toString(),
        concurrentRate: json['concurrentRate']?.toString(),
        loginUrl: json['loginUrl']?.toString(),
        loginUi: json['loginUi']?.toString(),
        header: json['header']?.toString(),
        enabledCookieJar: json['enabledCookieJar'] == true,
        loginCheckJs: json['loginCheckJs']?.toString(),
      );

  /// 复制并覆盖部分字段。
  ///
  /// 编辑对话框只暴露 name/url/contentType/header 四项，其余字段
  /// （loginUrl、loginUi、loginCheckJs、enabledCookieJar、concurrentRate）
  /// 必须原样带回去，否则保存一次就会被清空。
  TtsEngine copyWith({
    String? id,
    String? name,
    String? url,
    String? contentType,
    String? concurrentRate,
    String? loginUrl,
    String? loginUi,
    String? header,
    bool? enabledCookieJar,
    String? loginCheckJs,
    int? lastUpdateTime,
  }) =>
      TtsEngine(
        id: id ?? this.id,
        name: name ?? this.name,
        url: url ?? this.url,
        contentType: contentType ?? this.contentType,
        concurrentRate: concurrentRate ?? this.concurrentRate,
        loginUrl: loginUrl ?? this.loginUrl,
        loginUi: loginUi ?? this.loginUi,
        header: header ?? this.header,
        enabledCookieJar: enabledCookieJar ?? this.enabledCookieJar,
        loginCheckJs: loginCheckJs ?? this.loginCheckJs,
        lastUpdateTime: lastUpdateTime ?? this.lastUpdateTime,
      );
}
