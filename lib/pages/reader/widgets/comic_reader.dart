import 'package:flutter/material.dart';

class ComicReader extends StatefulWidget {
  const ComicReader({super.key, required this.images, required this.controller,
    required this.imageUrlBuilder, required this.onImageLongPress,
    required this.onShowChapters, required this.title, this.onPrevious,
    this.onNext, this.autoNext = true, this.initialOffset = 0, this.textColor});

  final List<String> images;
  final ScrollController controller;
  final String Function(String) imageUrlBuilder;
  final ValueChanged<String> onImageLongPress;
  final VoidCallback onShowChapters;
  final String title;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final bool autoNext;
  final double initialOffset;
  final Color? textColor;

  @override
  State<ComicReader> createState() => _ComicReaderState();
}

class _ComicReaderState extends State<ComicReader> {
  final Set<int> _loaded = {};
  bool _userDragging = false;
  bool _advancing = false;
  bool _restoring = true;
  double _overscroll = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _restore());
  }

  void _restore() {
    if (!mounted || !_restoring || !widget.controller.hasClients) return;
    final max = widget.controller.position.maxScrollExtent;
    final target = widget.initialOffset.clamp(0.0, max).toDouble();
    if ((widget.controller.offset - target).abs() > 1) {
      widget.controller.jumpTo(target);
    }
    if (widget.initialOffset <= max) _restoring = false;
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification is ScrollStartNotification && notification.dragDetails != null) {
      _userDragging = true;
      _restoring = false;
      _overscroll = 0;
    }
    if (notification is OverscrollNotification && _userDragging) {
      _overscroll = notification.overscroll > 0
          ? _overscroll + notification.overscroll : 0;
    }
    // 只有用户继续向下拉且图片均已加载才切章，图片变高不能触发切章。
    if (_overscroll >= 40 && widget.autoNext && !_advancing &&
        _loaded.length == widget.images.length && widget.images.isNotEmpty &&
        widget.onNext != null) {
      _advancing = true;
      widget.onNext!();
    }
    if (notification is ScrollEndNotification) {
      _userDragging = false;
      _overscroll = 0;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (_) {
        if (_restoring) WidgetsBinding.instance.addPostFrameCallback((_) => _restore());
        return false;
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: ListView.builder(
          controller: widget.controller,
          padding: EdgeInsets.zero,
          physics: const AlwaysScrollableScrollPhysics(parent: ClampingScrollPhysics()),
          itemCount: widget.images.length + 1,
          itemBuilder: (context, index) {
            if (index == widget.images.length) {
              return SafeArea(top: false, child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Column(children: [
                  Text(widget.images.isEmpty ? '本章没有可显示的漫画图片' : widget.title,
                    style: TextStyle(color: widget.textColor),
                    textAlign: TextAlign.center),
                  Wrap(alignment: WrapAlignment.center, children: [
                    TextButton(onPressed: widget.onPrevious, child: const Text('上一章')),
                    TextButton(onPressed: widget.onShowChapters, child: const Text('目录')),
                    TextButton(onPressed: widget.onNext, child: const Text('下一章')),
                  ]),
                ]),
              ));
            }
            return _ComicImage(
              key: ValueKey(index),
              url: widget.imageUrlBuilder(widget.images[index]),
              onLoaded: () => _loaded.add(index),
              onLongPress: widget.onImageLongPress,
            );
          },
        ),
      ),
    );
  }
}

class _ComicImage extends StatefulWidget {
  const _ComicImage({super.key, required this.url, required this.onLoaded,
    required this.onLongPress});
  final String url;
  final VoidCallback onLoaded;
  final ValueChanged<String> onLongPress;

  @override
  State<_ComicImage> createState() => _ComicImageState();
}

class _ComicImageState extends State<_ComicImage> {
  int _attempt = 0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPress: () => widget.onLongPress(widget.url),
      child: Image.network(
        widget.url,
        key: ValueKey(_attempt),
        width: double.infinity,
        fit: BoxFit.fitWidth,
        frameBuilder: (context, child, frame, synchronous) {
          if (frame != null || synchronous) {
            widget.onLoaded();
            return child;
          }
          return const AspectRatio(aspectRatio: 0.7,
            child: Center(child: CircularProgressIndicator()));
        },
        errorBuilder: (context, error, stack) => AspectRatio(
          aspectRatio: 0.7,
          child: Center(child: TextButton.icon(
            icon: const Icon(Icons.refresh),
            label: const Text('图片加载失败，点击重试'),
            onPressed: () async {
              await NetworkImage(widget.url).evict();
              if (mounted) setState(() => _attempt++);
            },
          )),
        ),
      ),
    );
  }
}
