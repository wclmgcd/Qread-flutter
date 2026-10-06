import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../config/constants.dart';
import '../../config/routes.dart';
import '../../models/book.dart';
import '../../providers/theme_provider.dart';
import '../../providers/user_provider.dart';
import '../../services/api_service.dart';
import '../../services/browsing_history_service.dart';
import '../../services/reading_stats_service.dart';
import '../../services/storage_service.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({Key? key}) : super(key: key);

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> with WidgetsBindingObserver {
  ReadingStatsSnapshot _stats =
      const ReadingStatsSnapshot(totalSeconds: 0, todaySeconds: 0);
  bool _statsLoaded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadStats();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadStats();
    }
  }

  Future<void> _loadStats() async {
    final stats = await ReadingStatsService.instance.loadStats();
    if (!mounted) return;
    setState(() {
      _stats = stats;
      _statsLoaded = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final userProvider = context.watch<UserProvider>();
    final themeProvider = context.watch<ThemeProvider>();
    final isDark = themeProvider.isDark(context);

    return Scaffold(
      body: ListView(
        padding: EdgeInsets.zero,
        children: [
          _buildHeader(userProvider, themeProvider, isDark),
          // 卡片压在 header 底边上，做出 3.41 那种「卡片嵌在头图里」的层次。
          //
          // 上移量必须**明显小于** header 的底部留白（现 26），否则卡片会盖住
          // 头图里的「轻阅读用户」胶囊 —— 这正是之前「我的界面有遮挡」的原因
          // （原来 -26 对 -28，只差 2px，稍有渲染误差就压上去了）。
          Transform.translate(
            offset: const Offset(0, -18),
            child: Column(
              children: [
                _buildCommonSection(),
                const SizedBox(height: 10),
                _buildAdvancedSection(),
                // 整列上移后底部会空出 18px，补一点回来
                const SizedBox(height: 6),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(
    UserProvider userProvider,
    ThemeProvider themeProvider,
    bool isDark,
  ) {
    final username = userProvider.username?.trim();
    final loggedIn = userProvider.isLoggedIn;
    // 3.41 这里显示的是原样的用户名（admin），不是全大写 —— 全大写会让
    // 字母显得更宽，在窄屏上更容易被省略号截断。
    final title = loggedIn && username != null && username.isNotEmpty
        ? username
        : '立即登录';

    return Container(
      // 整体比原来矮一截（280 → 214）：头像和文字都小了一号，
      // 再留 280 就会在头图下方堆出一大片空白。
      height: 214,
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 26),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF63BBFF),
            Color(0xFF3395F2),
          ],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 右上角：设置 + 深浅切换。
            // 3.41 这里只有一个齿轮（深浅切换收在设置页里），本项目保留成并排
            // 两个图标，免得把已有的开关藏起来。
            Align(
              alignment: Alignment.topRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.settings_outlined,
                        color: Colors.white, size: 23),
                    tooltip: '设置',
                    onPressed: () =>
                        Navigator.pushNamed(context, '/settings/general'),
                  ),
                  IconButton(
                    icon: Icon(
                      isDark
                          ? Icons.light_mode_rounded
                          : Icons.dark_mode_rounded,
                      color: Colors.white,
                      size: 23,
                    ),
                    tooltip: isDark ? '切换浅色模式' : '切换深色模式',
                    onPressed: themeProvider.toggleLightDark,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 2),
            InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () => _showUserManager(userProvider),
              child: Row(
                children: [
                  _ProfileAvatar(
                    username: userProvider.username,
                    loggedIn: loggedIn,
                    size: 72,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        // 身份胶囊 —— 对齐 3.41 的「轻阅读用户」
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 5),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            loggedIn ? '轻阅读用户' : '登录后端可多端同步',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        // 阅读统计原来占着那颗胶囊，现在胶囊给了身份，
                        // 统计改成下面一行小字，功能不丢
                        if (loggedIn) ...[
                          const SizedBox(height: 6),
                          Text(
                            _buildStatsText(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.85),
                              fontSize: 11.5,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCommonSection() {
    return _ProfilePanel(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 18),
      child: Row(
        children: [
          Expanded(
            child: _QuickActionCard(
              icon: Icons.history_rounded,
              accent: const Color(0xFF66B6FF),
              title: '浏览历史',
              onTap: _showBrowsingHistorySheet,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _QuickActionCard(
              icon: Icons.menu_book_rounded,
              accent: const Color(0xFF58C06A),
              title: '阅读偏好',
              onTap: () =>
                  Navigator.pushNamed(context, AppRoutes.readingPreference),
            ),
          ),
          const SizedBox(width: 10),
          // 3.41 这一格是「反馈帮助」，原来放的是「常规设置」；
          // 常规设置现在从右上角的齿轮进（和 3.41 一致）。
          Expanded(
            child: _QuickActionCard(
              icon: Icons.feedback_outlined,
              accent: const Color(0xFFFFB84F),
              title: '反馈帮助',
              onTap: _showFeedbackDialog,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAdvancedSection() {
    return _ProfilePanel(
      child: Column(
        children: [
          // 顺序对齐 3.41：书源管理 / 替换净化 / 朗读引擎 / 关于我们
          _ProfileMenuTile(
            item: _ProfileMenuItem(
              icon: Icons.source_outlined,
              accent: const Color(0xFF66B6FF),
              title: '书源管理',
              onTap: () => Navigator.pushNamed(context, '/sourceManage'),
            ),
          ),
          _menuDivider(),
          _ProfileMenuTile(
            item: _ProfileMenuItem(
              icon: Icons.cleaning_services_outlined,
              accent: const Color(0xFFAC7CFF),
              title: '替换净化',
              onTap: () => Navigator.pushNamed(context, '/replaceRules'),
            ),
          ),
          _menuDivider(),
          _ProfileMenuTile(
            item: _ProfileMenuItem(
              icon: Icons.record_voice_over_outlined,
              accent: const Color(0xFF4FC3C7),
              title: '朗读引擎',
              onTap: () => Navigator.pushNamed(context, AppRoutes.ttsEngines),
            ),
          ),
          _menuDivider(),
          _ProfileMenuTile(
            item: _ProfileMenuItem(
              icon: Icons.info_outline_rounded,
              accent: const Color(0xFF58C06A),
              title: '关于我们',
              subtitle: 'Qread v${AppConstants.appVersion}',
              onTap: () => showAboutDialog(
                context: context,
                applicationName: AppConstants.appName,
                applicationVersion: AppConstants.appVersion,
                applicationLegalese: 'Qread',
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 菜单分组里的分隔线。indent 要和 _ProfileMenuTile 的图标盒右边缘对齐。
  Widget _menuDivider() => Divider(
        height: 1,
        color: Theme.of(context).dividerColor.withValues(alpha: 0.15),
        indent: 76,
        endIndent: 18,
      );

  String _buildStatsText() {
    final today = _formatDuration(_stats.todaySeconds);
    final total = _formatDuration(_stats.totalSeconds);
    if (!_statsLoaded) {
      return '正在同步本地统计';
    }
    return '今日阅读 $today · 总阅读 $total';
  }

  String _formatDuration(int seconds) {
    final minutes = (seconds / 60).floor();
    if (minutes < 60) {
      return '$minutes 分钟';
    }
    final hours = minutes ~/ 60;
    final remain = minutes % 60;
    if (remain == 0) {
      return '$hours 小时';
    }
    return '$hours 小时 $remain 分';
  }

  /// 「反馈帮助」弹窗（对齐 3.41 的样式：标题 + 描述框 + 整宽「上报」）。
  ///
  /// 【为什么不真的上报】后端没有反馈上报接口 ——
  /// `web/controller/api/` 下只有 User / Book / Bookshelf / Rss / Tts 等控制器，
  /// 没有 Feedback 相关端点。所以这里点「上报」是把描述（带上 App 版本）
  /// 复制到剪贴板，让用户粘到反馈渠道去，而不是弹一个假的「上报成功」。
  /// 等后端加了接口再换成真正的 POST 即可。
  Future<void> _showFeedbackDialog() async {
    final controller = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('反馈帮助'),
        contentPadding: const EdgeInsets.fromLTRB(24, 10, 24, 0),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '问题描述（乱码、不完整等等）',
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(dialogContext).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: controller,
              maxLines: 5,
              minLines: 4,
              decoration: const InputDecoration(
                hintText: '问题描述（乱码、不完整等等）',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
        actions: [
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () async {
                final text = controller.text.trim();
                if (text.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('请先填写问题描述')),
                  );
                  return;
                }
                final payload =
                    'Qread v${AppConstants.appVersion}\n---\n$text';
                await Clipboard.setData(ClipboardData(text: payload));
                if (!mounted) return;
                Navigator.pop(dialogContext);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('已复制到剪贴板，粘贴到反馈渠道即可'),
                  ),
                );
              },
              child: const Text('上报'),
            ),
          ),
        ],
      ),
    );
    controller.dispose();
  }

  Future<void> _showUserManager(UserProvider userProvider) async {
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.55),
      builder: (dialogContext) => ChangeNotifierProvider.value(
        value: userProvider,
        child: const _UserManagerDialog(),
      ),
    );
    if (mounted) {
      _loadStats();
    }
  }

  Future<void> _showBrowsingHistorySheet() async {
    final history = await BrowsingHistoryService.instance.loadHistory();
    if (!mounted) return;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(sheetContext).size.height * 0.72,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '浏览历史',
                        style: Theme.of(sheetContext).textTheme.titleLarge,
                      ),
                    ),
                    Text(
                      '${history.length} 本',
                      style: Theme.of(sheetContext).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              Expanded(
                child: history.isEmpty
                    ? const Center(child: Text('还没有浏览历史'))
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(14, 0, 14, 16),
                        itemCount: history.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (_, index) =>
                            _HistoryBookTile(book: history[index]),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _UserManagerDialog extends StatefulWidget {
  const _UserManagerDialog();

  @override
  State<_UserManagerDialog> createState() => _UserManagerDialogState();
}

class _UserManagerDialogState extends State<_UserManagerDialog> {
  final TextEditingController _serverController =
      TextEditingController(text: AppConstants.baseUrl);
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _showLoginForm = false;
  bool _obscurePassword = true;
  String? _errorText;

  @override
  void dispose() {
    _serverController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final userProvider = context.watch<UserProvider>();
    final showLoginForm = !userProvider.isLoggedIn || _showLoginForm;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      child: Container(
        padding: const EdgeInsets.fromLTRB(26, 24, 26, 24),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(28),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    showLoginForm ? '用户登录' : '用户管理',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded, size: 34),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            Divider(
              height: 28,
              color: Theme.of(context).dividerColor.withValues(alpha: 0.18),
            ),
            if (showLoginForm)
              _buildLoginForm(context, userProvider)
            else
              _buildUserCard(context, userProvider),
          ],
        ),
      ),
    );
  }

  Widget _buildUserCard(BuildContext context, UserProvider userProvider) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: Theme.of(context)
                .colorScheme
                .surfaceContainerHighest
                .withValues(alpha: 0.22),
            borderRadius: BorderRadius.circular(22),
          ),
          child: Row(
            children: [
              _ProfileAvatar(
                username: userProvider.username,
                loggedIn: true,
                size: 86,
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      userProvider.username?.trim().toUpperCase() ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          Theme.of(context).textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                    ),
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE6F4FF),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Text(
                        '当前用户',
                        style: TextStyle(
                          color: Color(0xFF2F8CEB),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      AppConstants.baseUrl,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.color
                                ?.withValues(alpha: 0.62),
                          ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        FilledButton.icon(
          onPressed: () {
            setState(() {
              _showLoginForm = true;
              _errorText = null;
            });
          },
          icon: const Icon(Icons.person_add_alt_1_rounded),
          label: const Text('登录新用户'),
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(58),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
          ),
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: () async {
            await userProvider.logout();
            if (!mounted) return;
            setState(() {
              _showLoginForm = true;
              _errorText = null;
            });
          },
          icon: const Icon(Icons.logout_rounded, color: Color(0xFFFF564A)),
          label: const Text(
            '退出登录',
            style: TextStyle(
              color: Color(0xFFFF564A),
              fontWeight: FontWeight.w700,
            ),
          ),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(62),
            side: const BorderSide(color: Color(0xFFFF564A), width: 1.4),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(22),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLoginForm(BuildContext context, UserProvider userProvider) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _serverController,
          decoration: const InputDecoration(
            labelText: '后端地址',
            hintText: 'http://ip:port',
            prefixIcon: Icon(Icons.dns_rounded),
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _usernameController,
          decoration: const InputDecoration(
            labelText: '账号',
            prefixIcon: Icon(Icons.person_rounded),
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _passwordController,
          obscureText: _obscurePassword,
          decoration: InputDecoration(
            labelText: '密码',
            prefixIcon: const Icon(Icons.lock_rounded),
            suffixIcon: IconButton(
              icon: Icon(
                _obscurePassword
                    ? Icons.visibility_off_rounded
                    : Icons.visibility_rounded,
              ),
              onPressed: () {
                setState(() {
                  _obscurePassword = !_obscurePassword;
                });
              },
            ),
          ),
          onSubmitted: (_) => _submitLogin(userProvider),
        ),
        if (_errorText != null) ...[
          const SizedBox(height: 12),
          Text(
            _errorText!,
            style: const TextStyle(color: Colors.redAccent),
          ),
        ],
        const SizedBox(height: 20),
        FilledButton(
          onPressed:
              userProvider.loading ? null : () => _submitLogin(userProvider),
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(56),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
          ),
          child: userProvider.loading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(
                  userProvider.isLoggedIn ? '切换账号' : '立即登录',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700),
                ),
        ),
        if (userProvider.isLoggedIn) ...[
          const SizedBox(height: 12),
          TextButton(
            onPressed: () {
              setState(() {
                _showLoginForm = false;
                _errorText = null;
              });
            },
            child: const Text('返回当前用户'),
          ),
        ],
      ],
    );
  }

  Future<void> _submitLogin(UserProvider userProvider) async {
    final server = _serverController.text.trim();
    final username = _usernameController.text.trim();
    final password = _passwordController.text.trim();

    if (server.isEmpty || username.isEmpty || password.isEmpty) {
      setState(() {
        _errorText = '请输入后端地址、账号和密码';
      });
      return;
    }

    AppConstants.baseUrl = server;
    ApiService.instance.setBaseUrl(server);
    final storage = await StorageService.instance;
    await storage.setBaseUrl(server);

    final success = await userProvider.login(username, password);
    if (!mounted) return;

    if (success) {
      Navigator.pop(context);
    } else {
      setState(() {
        _errorText = '登录失败，请检查地址或账号密码';
      });
    }
  }
}

class _ProfilePanel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;

  const _ProfilePanel({
    required this.child,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(28),
      ),
      child: padding == null ? child : Padding(padding: padding!, child: child),
    );
  }
}

class _ProfileMenuItem {
  final IconData icon;
  final Color accent;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  const _ProfileMenuItem({
    required this.icon,
    required this.accent,
    required this.title,
    this.subtitle,
    required this.onTap,
  });
}

class _ProfileMenuTile extends StatelessWidget {
  final _ProfileMenuItem item;

  const _ProfileMenuTile({required this.item});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      // 整体比原来小一号（图标盒 56→44、标题 18→16、上下留白 8→4），
      // 一行的高度从 ~72 收到 ~58 —— 这是「我的界面文字调小一号」的主体。
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: item.accent.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Icon(item.icon, color: item.accent, size: 22),
      ),
      title: Text(
        item.title,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
      subtitle: item.subtitle == null
          ? null
          : Text(item.subtitle!, style: const TextStyle(fontSize: 12)),
      trailing: Icon(
        Icons.chevron_right_rounded,
        size: 20,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      onTap: item.onTap,
    );
  }
}

class _ProfileAvatar extends StatelessWidget {
  final String? username;
  final bool loggedIn;
  final double size;

  const _ProfileAvatar({
    required this.username,
    required this.loggedIn,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    final letter = (username?.trim().isNotEmpty ?? false)
        ? username!.trim().substring(0, 1).toUpperCase()
        : '';

    return Container(
      width: size,
      height: size,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.transparent,
        shape: BoxShape.circle,
        border:
            Border.all(color: Colors.white.withValues(alpha: 0.9), width: 2.4),
      ),
      child: DecoratedBox(
        decoration: const BoxDecoration(
          color: Color(0xFFF8FAFD),
          shape: BoxShape.circle,
        ),
        child: Center(
          child: loggedIn
              ? Text(
                  letter.isEmpty ? 'Q' : letter,
                  style: TextStyle(
                    color: const Color(0xFF2F8CEB),
                    fontSize: size * 0.38,
                    fontWeight: FontWeight.w700,
                  ),
                )
              : Icon(
                  Icons.person_outline_rounded,
                  color: const Color(0xFF2F8CEB),
                  size: size * 0.42,
                ),
        ),
      ),
    );
  }
}

class _QuickActionCard extends StatelessWidget {
  final IconData icon;
  final Color accent;
  final String title;
  final VoidCallback onTap;

  const _QuickActionCard({
    required this.icon,
    required this.accent,
    required this.title,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Column(
          children: [
            Container(
              // 图标盒 92→68、图标 42→30、标题 16→14，整体小一号
              height: 68,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(18),
              ),
              alignment: Alignment.center,
              child: Icon(icon, color: accent, size: 30),
            ),
            const SizedBox(height: 8),
            Text(
              title,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

class _HistoryBookTile extends StatelessWidget {
  final Book book;

  const _HistoryBookTile({required this.book});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final coverUrl = book.customCoverUrl ?? book.coverUrl;
    final placeholder = Container(
      width: 72,
      height: 96,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      alignment: Alignment.center,
      child: Icon(
        Icons.menu_book_rounded,
        color: theme.colorScheme.onSurfaceVariant,
        size: 30,
      ),
    );

    return Material(
      color: theme.cardColor,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () {
          Navigator.pop(context);
          Navigator.pushNamed(context, '/reader', arguments: book);
        },
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: theme.dividerColor.withValues(alpha: 0.12),
            ),
          ),
          child: Row(
            children: [
              if (coverUrl != null && coverUrl.isNotEmpty)
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: CachedNetworkImage(
                    imageUrl: ApiService.instance.getCoverProxyUrl(
                      coverUrl,
                      sourceUrl: book.origin,
                    ),
                    width: 72,
                    height: 96,
                    fit: BoxFit.cover,
                    errorWidget: (_, __, ___) => placeholder,
                  ),
                )
              else
                placeholder,
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      book.name ?? '',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    if ((book.author ?? '').trim().isNotEmpty)
                      Text(
                        book.author!.trim(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.textTheme.bodyMedium?.color
                              ?.withValues(alpha: 0.72),
                        ),
                      ),
                    if ((book.originName ?? '').trim().isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        '来源：${book.originName!.trim()}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.textTheme.bodyMedium?.color
                              ?.withValues(alpha: 0.72),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.chevron_right_rounded,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
