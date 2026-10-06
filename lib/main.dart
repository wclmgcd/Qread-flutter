import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'app.dart';
import 'config/constants.dart';
import 'providers/user_provider.dart';
import 'providers/bookshelf_provider.dart';
import 'providers/discover_provider.dart';
import 'providers/rss_provider.dart';
import 'providers/rss_manage_provider.dart';
import 'providers/reader_provider.dart';
import 'providers/replace_rule_provider.dart';
import 'providers/source_manage_provider.dart';
import 'providers/theme_provider.dart';
import 'pages/reader/widgets/reader_fonts.dart';
import 'services/api_service.dart';
import 'services/app_settings.dart';
import 'services/storage_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 阅读字体预热。
  //
  // pubspec 里声明的字体是**懒加载**的：第一次有 TextStyle 用到某个 family
  // 时引擎才异步读 ttf。而分页是「一次性测量 + 缓存结果」，如果这次测量发生
  // 在字体读完之前，量到的是回退字体的行宽，断行会偏（正文里冒出
  // 「一句正常的话被断开」）。启动时就开始读，等用户点开书时基本已就绪。
  // 刻意不 await —— 不能为了字体拖慢启动；万一还没就绪，阅读页那边
  // 也有补排兜底（见 ReaderPage._ensureFontsThenRepaginate）。
  unawaited(ReaderFont.preload());
  final storage = await StorageService.instance;
  final savedBaseUrl = storage.baseUrl;
  if (savedBaseUrl != null && savedBaseUrl.isNotEmpty) {
    AppConstants.baseUrl = savedBaseUrl;
    ApiService.instance.setBaseUrl(savedBaseUrl);
  }
  // 阅读偏好（书架排序 / 夜间模式 / 简繁转换 …）要先读出来，
  // 否则书架首帧会按默认顺序闪一下再重排。
  await AppSettings.instance.load();
  runApp(const QreadApp());
}

class QreadApp extends StatelessWidget {
  const QreadApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => UserProvider()..init()),
        ChangeNotifierProvider(create: (_) => BookshelfProvider()),
        ChangeNotifierProvider(create: (_) => DiscoverProvider()),
        ChangeNotifierProvider(create: (_) => RssProvider()),
        ChangeNotifierProvider(create: (_) => RssManageProvider()),
        ChangeNotifierProvider(create: (_) => ReaderProvider()),
        ChangeNotifierProvider(create: (_) => SourceManageProvider()),
        ChangeNotifierProvider(create: (_) => ReplaceRuleProvider()),
        ChangeNotifierProvider(create: (_) => ThemeProvider()..init()),
        // 阅读偏好：书架排序 / 夜间模式 / 简繁转换 / 段评样式 …
        ChangeNotifierProvider.value(value: AppSettings.instance),
      ],
      child: const App(),
    );
  }
}
