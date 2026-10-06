import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'config/theme.dart';
import 'config/routes.dart';
import 'providers/theme_provider.dart';

class App extends StatelessWidget {
  const App({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeProvider>(
      builder: (context, themeProvider, _) => MaterialApp(
        title: 'Qread',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.lightTheme,
        darkTheme: AppTheme.darkTheme,
        themeMode: themeProvider.themeMode,
        initialRoute: '/',
        routes: AppRoutes.routes,
        onGenerateRoute: AppRoutes.onGenerateRoute,
        // 让页面能感知「上层路由被 pop、自己重新露出来」——
        // 书架靠它在从阅读页返回时重排列表（见 AppRoutes.appRouteObserver）。
        navigatorObservers: [appRouteObserver],
        // 兜底：没有 AppBar 的页面（阅读页、登录页等）不会自带
        // SystemUiOverlayStyle，这里统一给一份，保证系统手势条不会变黑。
        // 有 AppBar 的页面由 AppBarTheme.systemOverlayStyle 覆盖（同色）。
        builder: (context, child) {
          final isDark = Theme.of(context).brightness == Brightness.dark;
          return AnnotatedRegion<SystemUiOverlayStyle>(
            value:
                isDark ? AppTheme.darkOverlayStyle : AppTheme.lightOverlayStyle,
            child: child ?? const SizedBox.shrink(),
          );
        },
      ),
    );
  }
}
