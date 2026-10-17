import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// 扫码页 —— 扫二维码拿到原文后 `pop` 回上一页。
///
/// 【它的定位】
/// 这一页只负责「把画面里的码认出来、把字符串交出去」，**不解释内容**：
/// 扫到的是书源 JSON 还是下载链接，由调用方（书源管理页）决定怎么处理。
/// 这样同一页将来也能复用到「扫码登录」「扫码加订阅源」上。
///
/// 【为什么只用了 mobile_scanner 的一小部分 API】
/// 这个包 7.x 的 `switchCamera` 签名和老版本不一样（要传 `ToggleLensType` /
/// `SelectCamera`），运行时手电筒也没有稳定的公开方法。本页只用文档明确
/// 保证过的那部分：控制器 + `onDetect` + `start/stop` + `hasCameraPermission`。
/// 手电筒这类「锦上添花」宁可先不做，也不要押在会变的 API 上把编译搞红。
class QrScanPage extends StatefulWidget {
  const QrScanPage({
    Key? key,
    this.title = '扫码导入',
    this.hint = '把二维码放进取景框，识别后会自动导入',
    this.formats = const [BarcodeFormat.qrCode],
  }) : super(key: key);

  /// 标题栏文字。书源导入用「扫码导入」，将来别处复用可以换。
  final String title;

  /// 取景框下方的提示语。
  final String hint;

  /// 要识别的码制。默认只认二维码 —— 书源分享基本都是二维码，
  /// 收窄能少一些误识别（比如扫到商品条码弹出一堆乱码）。
  final List<BarcodeFormat> formats;

  @override
  State<QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<QrScanPage>
    with SingleTickerProviderStateMixin {
  late MobileScannerController _controller;

  /// 扫描线动画（纯装饰，用来提示「正在识别」）。
  late AnimationController _lineController;

  /// null = 权限还没出结果；true = 已授权；false = 被拒/不可用。
  bool? _hasPermission;

  /// onDetect 会高频回调（同一张码每秒好几次），不闸住的话会连 pop 好几次。
  bool _handled = false;

  /// 权限状态迟迟不出结果时的兜底（见 [_startPermissionTimeout]）。
  Timer? _permissionTimer;

  @override
  void initState() {
    super.initState();
    _controller = MobileScannerController(
      autoStart: true,
      formats: widget.formats,
    );
    // 权限状态是异步出来的（首次进入会弹系统授权框），监听它才能把
    // 「等待授权」和「被拒绝」两种界面区分开。
    _controller.addListener(_onControllerChanged);

    _lineController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat();
    _startPermissionTimeout();
  }

  /// 权限状态迟迟不出结果时的兜底。
  ///
  /// 【为什么需要】`hasCameraPermission` 是异步回来的，而首次进入会先弹系统
  /// 授权框 —— 用户可能把弹框晾在那儿好几分钟不点。若插件在此期间一直不更新
  /// 这个字段，界面就会永远停在「正在启动相机…」，用户只能杀进程。
  /// 这里给它一个上限，超时就切成「可重试」的状态，至少让用户能自己再试一次。
  void _startPermissionTimeout() {
    _permissionTimer?.cancel();
    _permissionTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted || _hasPermission != null) return;
      setState(() => _hasPermission = false);
    });
  }

  void _onControllerChanged() {
    if (!mounted) return;
    final permitted = _controller.value.hasCameraPermission;
    if (permitted != _hasPermission) {
      setState(() => _hasPermission = permitted);
    }
  }

  @override
  void dispose() {
    _permissionTimer?.cancel();
    _controller.removeListener(_onControllerChanged);
    // dispose 是异步的（要关相机），这里不能 await，交给它自己跑完。
    unawaited(_controller.dispose());
    _lineController.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    final raw = capture.barcodes.firstOrNull?.rawValue;
    if (raw == null || raw.isEmpty) return;
    _handled = true;
    // 先停相机再返回：不然 pop 的动画过程中相机还在跑，Android 上会有一闪。
    unawaited(_controller.stop());
    if (!mounted) return;
    Navigator.of(context).pop(raw);
  }

  /// 手动重试 —— 用户在系统授权框里点错之后，回来点这个按钮再要一次权限。
  Future<void> _retryPermission() async {
    setState(() => _hasPermission = null);
    _startPermissionTimeout();
    try {
      await _controller.start();
    } catch (_) {
      if (mounted) setState(() => _hasPermission = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(widget.title),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          _buildScanner(),
          if (_hasPermission != false) _buildMask(),
          if (_hasPermission == null) _buildWaiting(),
          if (_hasPermission == false) _buildPermissionDenied(),
        ],
      ),
    );
  }

  Widget _buildScanner() {
    // 只用 controller + onDetect 这两个文档明确保证过的参数：
    // 这个包 7.x 的 scanWindow / fit 之类签名一直没有稳定文档，押上去容易编译红。
    return MobileScanner(
      controller: _controller,
      onDetect: _onDetect,
    );
  }

  /// 取景框遮罩：四周压暗、中间镂空，加一条循环下移的扫描线。
  Widget _buildMask() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        // 取景框取短边的 68%，再受长边约束，避免宽屏上拉成一个长条。
        final side = (size.shortestSide * 0.68).clamp(0.0, size.width - 48);
        final rect = Rect.fromCenter(
          center: Offset(size.width / 2, size.height * 0.44),
          width: side,
          height: side,
        );
        return Stack(
          fit: StackFit.expand,
          children: [
            CustomPaint(
              painter: _ScanMaskPainter(window: rect),
            ),
            AnimatedBuilder(
              animation: _lineController,
              builder: (context, _) {
                final t = _lineController.value;
                return Positioned(
                  left: rect.left,
                  top: rect.top + (rect.height - 2) * t,
                  child: Container(
                    width: rect.width,
                    height: 2,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Colors.greenAccent.withValues(alpha: 0.05),
                          Colors.greenAccent,
                          Colors.greenAccent.withValues(alpha: 0.05),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
            Positioned(
              left: 24,
              right: 24,
              top: rect.bottom + 28,
              child: Text(
                widget.hint,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildWaiting() {
    return Container(
      color: Colors.black,
      alignment: Alignment.center,
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: Colors.white70),
          SizedBox(height: 16),
          Text('正在启动相机…',
              style: TextStyle(color: Colors.white70, fontSize: 13)),
        ],
      ),
    );
  }

  Widget _buildPermissionDenied() {
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.symmetric(horizontal: 32),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.no_photography_outlined,
              size: 56, color: Colors.white54),
          const SizedBox(height: 20),
          const Text(
            '没有相机权限，无法扫码',
            style: TextStyle(color: Colors.white, fontSize: 16),
          ),
          const SizedBox(height: 10),
          const Text(
            '请在系统设置里允许 Qread 使用相机；\n'
            '或者退回上一页，用「网络导入」把书源链接粘进来，效果是一样的。',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white54, fontSize: 13, height: 1.6),
          ),
          const SizedBox(height: 24),
          OutlinedButton.icon(
            onPressed: _retryPermission,
            icon: const Icon(Icons.refresh),
            label: const Text('重新尝试'),
            style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
          ),
        ],
      ),
    );
  }
}

/// 扫码遮罩：整屏压暗，中间挖一个圆角矩形，并描四个角。
class _ScanMaskPainter extends CustomPainter {
  const _ScanMaskPainter({required this.window});

  final Rect window;

  static const double _corner = 22;
  static const double _radius = 12;

  @override
  void paint(Canvas canvas, Size size) {
    // 整屏矩形挖掉取景框 —— PathOperation.difference 比 saveLayer 便宜得多。
    final mask = Path.combine(
      PathOperation.difference,
      Path()..addRect(Offset.zero & size),
      Path()
        ..addRRect(
          RRect.fromRectAndRadius(window, const Radius.circular(_radius)),
        ),
    );
    canvas.drawPath(mask, Paint()..color = const Color(0x99000000));

    final cornerPaint = Paint()
      ..color = Colors.greenAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;

    // 四个角各画两条短线，形成「取景框」的观感。
    // 【record 解构】_cornerOrigins() 返回的是 (Offset, double, double) 三元组，
    // 用模式解构一次拿全三个值。写成 `for (final c in ...)` 再去取 c.$1 当坐标
    // 会类型错位（$1 本身就是 Offset），CI 上就是那条 argument_type_not_assignable。
    for (final (origin, dx, dy) in _cornerOrigins()) {
      canvas.drawLine(
        origin,
        Offset(origin.dx + dx, origin.dy),
        cornerPaint,
      );
      canvas.drawLine(
        origin,
        Offset(origin.dx, origin.dy + dy),
        cornerPaint,
      );
    }
  }

  /// 四个角点，以及每个角往框内延伸的方向（x 偏移, y 偏移）。
  List<(Offset, double, double)> _cornerOrigins() {
    final l = window.left;
    final r = window.right;
    final t = window.top;
    final b = window.bottom;
    return [
      (Offset(l, t), _corner, _corner),
      (Offset(r, t), -_corner, _corner),
      (Offset(l, b), _corner, -_corner),
      (Offset(r, b), -_corner, -_corner),
    ];
  }

  @override
  bool shouldRepaint(covariant _ScanMaskPainter oldDelegate) =>
      oldDelegate.window != window;
}
