import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 阅读页的大图查看器 —— 点正文里的插图打开，支持双指缩放、双击放大、下拉关闭。
///
/// 【为什么不引 photo_view】
/// 放大/拖动/双击复位这几件事 `InteractiveViewer` 本身就做得很好，
/// 为了一个查看器多背一个依赖不划算（还多一层版本兼容风险）。
/// 唯一做不到的是「保存到相册」，那需要相册写入权限和另一个插件，
/// 这里先用「复制图片地址」替代，用户想存自己粘到浏览器下载就行。
///
/// 【下拉关闭为什么要限制在 scale == 1】
/// 放大之后图片通常比屏幕大，此时上下拖是在**平移看图的另一部分**，
/// 如果这时候也响应「下拉关闭」，用户根本没法看完整张长图。
/// 所以只在没有缩放时把下拉解释为「关闭」。
class ImageViewerPage extends StatefulWidget {
  const ImageViewerPage({
    Key? key,
    required this.url,
    this.title,
  }) : super(key: key);

  /// 图片地址（阅读页传进来的是已经拼好 token / 书源 header 的最终地址）。
  final String url;

  /// 可选的标题（默认是当前章节名）。
  final String? title;

  @override
  State<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<ImageViewerPage>
    with SingleTickerProviderStateMixin {
  final TransformationController _transform =
      TransformationController();

  /// 下拉关闭的位移量。
  double _dragDy = 0;

  /// 是否在双击动画中（此时屏蔽 InteractiveViewer 自己的手势，避免打架）。
  bool _animating = false;

  /// 当前是否处于放大状态。
  ///
  /// 【为什么要有这个状态】
  /// 「下拉关闭」是挂在外层 GestureDetector 上的竖向拖动手势，它和
  /// InteractiveViewer 内部的平移**抢同一个手势**。放大之后用户上下拖是想
  /// 看图的上半部分/下半部分，如果外层把竖向拖动吃掉，长图就永远看不全。
  /// 所以只在未放大时注册这个手势（见 build 里的 `onVerticalDragUpdate:`），
  /// 而手势注册发生在 arena 阶段、早于回调，只能靠「有没有传回调」控制，
  /// 不能靠回调里判断 scale —— 这就是这个字段存在的理由。
  bool _zoomedIn = false;

  static const double _maxScale = 6.0;
  static const double _minScale = 0.8;

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  /// 当前缩放倍数（变换矩阵对角线第一项就是 x 方向的缩放）。
  double get _scale => _transform.value.getMaxScaleOnAxis();

  /// 缩放/平移过程中同步 [_zoomedIn]，但**只在跨越阈值时才 setState** ——
  /// 交互回调每帧都来，无条件 rebuild 会把整棵树刷爆。
  void _syncZoomed() {
    final zoomed = _scale > 1.05;
    if (zoomed == _zoomedIn) return;
    if (!mounted) return;
    setState(() => _zoomedIn = zoomed);
  }

  void _resetScale() {
    _transform.value = Matrix4.identity();
    _syncZoomed();
  }

  /// 双击：放大到 2x（以双击点为锚），已放大则还原。
  void _onDoubleTap(TapDownDetails details) {
    if (_animating) return;
    final from = _transform.value.clone();
    Matrix4 to;
    if (_scale > 1.05) {
      to = Matrix4.identity();
    } else {
      // 以点击位置为中心放大：先平移让该点到原点，缩放，再平移回去。
      final pos = details.localPosition;
      to = Matrix4.identity()
        ..translate(pos.dx, pos.dy)
        ..scale(2.0)
        ..translate(-pos.dx, -pos.dy);
    }
    _animateTransform(from, to);
  }

  void _animateTransform(Matrix4 from, Matrix4 to) {
    _animating = true;
    // 手写插值：Matrix4Tween 只能线性插值矩阵元素，短时间内的观感差别很小，
    // 这样写省掉一个 AnimationController 的生命周期管理。
    const duration = Duration(milliseconds: 220);
    final controller = AnimationController(vsync: this, duration: duration);
    final tween = Matrix4Tween(begin: from, end: to);
    controller.addListener(() {
      if (!mounted) return;
      _transform.value = tween.evaluate(controller);
    });
    controller.addStatusListener((status) {
      if (status != AnimationStatus.completed) return;
      controller.dispose();
      _animating = false;
    });
    controller.forward();
  }

  /// 下拉关闭；只在未放大时生效（原因见 [_zoomedIn]）。
  void _onVerticalDragUpdate(DragUpdateDetails details) {
    setState(() => _dragDy += details.delta.dy);
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    // 拖过 120px 或者甩得够快就关闭；否则弹回原位。
    final flung = details.velocity.pixelsPerSecond.dy.abs() > 1200;
    if (_dragDy.abs() > 120 || (flung && _dragDy > 0)) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _dragDy = 0);
  }

  Future<void> _copyUrl() async {
    await Clipboard.setData(ClipboardData(text: widget.url));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('图片地址已复制')),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 拖得越远背景越透，给「松手即关闭」一个视觉反馈。
    final fade = (1 - _dragDy.abs() / 320).clamp(0.0, 1.0);
    return Scaffold(
      backgroundColor: Colors.black.withValues(alpha: fade),
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        title: widget.title == null ? null : Text(widget.title!),
        actions: [
          IconButton(
            icon: const Icon(Icons.link),
            tooltip: '复制图片地址',
            onPressed: _copyUrl,
          ),
        ],
      ),
      body: GestureDetector(
        onDoubleTapDown: _onDoubleTap,
        // 关键：放大后不注册竖向拖动，把平移完完整整让给 InteractiveViewer
        onVerticalDragUpdate: _zoomedIn ? null : _onVerticalDragUpdate,
        onVerticalDragEnd: _zoomedIn ? null : _onVerticalDragEnd,
        // 单击背景关闭 —— 和阅读页「点图片外面翻页」的习惯一致。
        onTap: () => Navigator.of(context).pop(),
        child: Transform.translate(
          offset: Offset(0, _dragDy),
          child: InteractiveViewer(
            transformationController: _transform,
            minScale: _minScale,
            maxScale: _maxScale,
            onInteractionUpdate: (_) => _syncZoomed(),
            onInteractionEnd: (_) => _syncZoomed(),
            child: Center(
              child: Image.network(
                widget.url,
                fit: BoxFit.contain,
                loadingBuilder: (context, child, progress) {
                  if (progress == null) return child;
                  return const Center(
                    child: CircularProgressIndicator(color: Colors.white70),
                  );
                },
                errorBuilder: (context, error, stack) => const Center(
                  child: Text('图片加载失败',
                      style: TextStyle(color: Colors.white70)),
                ),
              ),
            ),
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _ToolButton(
                icon: Icons.zoom_out,
                label: '缩小',
                onPressed: _scale > _minScale
                    ? () => _animateTransform(
                          _transform.value.clone(),
                          Matrix4.diagonal3Values(
                            (_scale / 1.5).clamp(_minScale, _maxScale),
                            (_scale / 1.5).clamp(_minScale, _maxScale),
                            1,
                          ),
                        )
                    : null,
              ),
              const SizedBox(width: 12),
              _ToolButton(
                icon: Icons.zoom_in,
                label: '放大',
                onPressed: _scale < _maxScale
                    ? () => _animateTransform(
                          _transform.value.clone(),
                          Matrix4.diagonal3Values(
                            (_scale * 1.5).clamp(_minScale, _maxScale),
                            (_scale * 1.5).clamp(_minScale, _maxScale),
                            1,
                          ),
                        )
                    : null,
              ),
              const SizedBox(width: 12),
              _ToolButton(
                icon: Icons.restore,
                label: '还原',
                onPressed: _scale == 1.0 ? null : _resetScale,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(label),
      style: TextButton.styleFrom(foregroundColor: Colors.white),
    );
  }
}
