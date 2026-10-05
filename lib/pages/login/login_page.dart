import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../config/constants.dart';
import '../../providers/user_provider.dart';
import '../../services/api_service.dart';
import '../../services/storage_service.dart';

/// 登录页（对齐官方 3.41「欢迎回来」整页登录）
///
/// 【修复】旧版只有「用户名 / 密码」两个输入框，**没有后端地址栏**：
/// 用户从书架点「去登录」进来后根本没法填自己的服务器地址，
/// 只能绕到「我的 → 用户登录」那个内嵌弹窗里去填，两个入口不一致。
/// 现在本页也带「后端」栏，并把地址持久化（与「我的」页共用同一份配置）。
class LoginPage extends StatefulWidget {
  const LoginPage({Key? key}) : super(key: key);

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _serverController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();

  static const _kRemember = 'login_remember';
  static const _kSavedUser = 'login_saved_username';
  static const _kSavedPass = 'login_saved_password';

  bool _isRegister = false;
  bool _obscurePassword = true;
  bool _remember = true;
  bool _busy = false;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _serverController.text = AppConstants.baseUrl;
    _loadRemembered();
  }

  @override
  void dispose() {
    _serverController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _loadRemembered() async {
    final storage = await StorageService.instance;
    final remember = storage.readBool(_kRemember) ?? true;
    if (!mounted) return;
    setState(() {
      _remember = remember;
      if (remember) {
        _usernameController.text = storage.readString(_kSavedUser) ?? '';
        _passwordController.text = storage.readString(_kSavedPass) ?? '';
      }
    });
  }

  /// 把用户填的地址归一化成「协议://主机[:端口]」。
  /// 用户可能直接粘 `https://reader.xxx.xyz/api/5`，也可能只写域名。
  String _normalizeBase(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return s;
    if (!s.startsWith('http://') && !s.startsWith('https://')) {
      s = 'https://$s';
    }
    s = s.replaceAll(RegExp(r'/api/\d+/?$', caseSensitive: false), '');
    s = s.replaceAll(RegExp(r'/api/?$', caseSensitive: false), '');
    s = s.replaceAll(RegExp(r'/+$'), '');
    return s;
  }

  Future<void> _submit() async {
    final server = _normalizeBase(_serverController.text);
    final username = _usernameController.text.trim();
    final password = _passwordController.text.trim();

    if (server.isEmpty) {
      setState(() => _errorText = '请填写后端地址');
      return;
    }
    if (username.isEmpty || password.isEmpty) {
      setState(() => _errorText = '请输入用户名和密码');
      return;
    }

    setState(() {
      _busy = true;
      _errorText = null;
    });

    // 先落地址再发请求，否则请求还打在旧地址上
    AppConstants.baseUrl = server;
    ApiService.instance.setBaseUrl(server);
    final storage = await StorageService.instance;
    await storage.setBaseUrl(server);

    final userProvider = context.read<UserProvider>();

    try {
      if (_isRegister) {
        final result = await ApiService.instance.register(username, password);
        if (!mounted) return;
        setState(() {
          if (result['isSuccess'] == true) {
            _isRegister = false;
            _errorText = '注册成功，请登录';
          } else {
            _errorText = '注册失败：${result['errorMsg'] ?? '未知错误'}';
          }
        });
        return;
      }

      final ok = await userProvider.login(username, password);
      if (!mounted) return;
      if (ok) {
        if (_remember) {
          await storage.setBool(_kRemember, true);
          await storage.setString(_kSavedUser, username);
          await storage.setString(_kSavedPass, password);
        } else {
          await storage.setBool(_kRemember, false);
          await storage.remove(_kSavedUser);
          await storage.remove(_kSavedPass);
        }
        if (mounted) Navigator.pop(context, true);
      } else {
        setState(() => _errorText = '登录失败，请检查地址或账号密码');
      }
    } catch (e) {
      if (mounted) setState(() => _errorText = '登录失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.maybePop(context),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Container(
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
            decoration: BoxDecoration(
              color: theme.cardColor,
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.06),
                  blurRadius: 20,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  _isRegister ? '注册账号' : '欢迎回来',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 26),
                _field(
                  controller: _serverController,
                  label: '后端',
                  icon: Icons.computer_outlined,
                  hint: 'https://reader.example.com',
                  keyboardType: TextInputType.url,
                ),
                _field(
                  controller: _usernameController,
                  label: '用户名',
                  icon: Icons.person_outline,
                ),
                _field(
                  controller: _passwordController,
                  label: '密码',
                  icon: Icons.lock_outline,
                  obscure: _obscurePassword,
                  suffix: IconButton(
                    icon: Icon(_obscurePassword
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined),
                    onPressed: () =>
                        setState(() => _obscurePassword = !_obscurePassword),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    SizedBox(
                      width: 24,
                      height: 24,
                      child: Checkbox(
                        value: _remember,
                        onChanged: (v) =>
                            setState(() => _remember = v ?? false),
                        materialTapTargetSize:
                            MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                    const SizedBox(width: 6),
                    const Text('记住密码', style: TextStyle(fontSize: 13)),
                    const Spacer(),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('轻阅读后端不提供找回密码，请联系服务端管理员'),
                                ),
                              ),
                      child: const Text('忘记密码',
                          style: TextStyle(fontSize: 13)),
                    ),
                    const Text('|', style: TextStyle(color: Colors.grey)),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                                _isRegister = !_isRegister;
                                _errorText = null;
                              }),
                      child: Text(
                        _isRegister ? '去登录' : '注册账号',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                ),
                if (_errorText != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    _errorText!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      color: _errorText!.contains('成功')
                          ? const Color(0xFF00A88F)
                          : Colors.red,
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                SizedBox(
                  height: 48,
                  child: FilledButton(
                    onPressed: _busy ? null : _submit,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF6FA8A0),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(24),
                      ),
                    ),
                    child: _busy
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Text(
                            _isRegister ? '注册' : '登录',
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    String? hint,
    bool obscure = false,
    Widget? suffix,
    TextInputType? keyboardType,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon),
        suffixIcon: suffix,
        border: const UnderlineInputBorder(),
      ),
    );
  }
}
