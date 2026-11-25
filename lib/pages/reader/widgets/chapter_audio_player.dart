import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../../../services/app_settings.dart';
import '../../../widgets/book_cover.dart';

class ChapterAudioPlayer extends StatefulWidget {
  const ChapterAudioPlayer({
    super.key,
    required this.url,
    required this.title,
    this.canSeek = true,
    this.autoPlay = false,
    this.initialPosition = Duration.zero,
    required this.onPosition,
    required this.onPlaying,
    required this.onComplete,
    this.onPrevious,
    this.onNext,
    required this.onShowChapters,
    this.unavailableReason,
    this.bookName = '',
    this.coverUrl,
    this.onBack,
    this.onRefresh,
    this.onTimer,
    this.onAddToShelf,
    this.onMore,
    this.inBookshelf = false,
    this.timerLabel = '定时',
  });

  final String url;
  final String title;
  final bool canSeek;
  final bool autoPlay;
  final Duration initialPosition;
  final ValueChanged<Duration> onPosition;
  final ValueChanged<bool> onPlaying;
  final VoidCallback onComplete;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final VoidCallback onShowChapters;
  final String? unavailableReason;
  final String bookName;
  final String? coverUrl;
  final VoidCallback? onBack;
  final VoidCallback? onRefresh;
  final VoidCallback? onTimer;
  final VoidCallback? onAddToShelf;
  final VoidCallback? onMore;
  final bool inBookshelf;
  final String timerLabel;

  @override
  ChapterAudioPlayerState createState() => ChapterAudioPlayerState();
}

class ChapterAudioPlayerState extends State<ChapterAudioPlayer>
    with WidgetsBindingObserver {
  AudioPlayer? _player;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Future<void> _operation = Future<void>.value();
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  double? _dragPosition;
  bool _disposed = false;
  bool _prepared = false;
  bool _loading = false;
  bool _failed = false;
  bool _playing = false;
  bool _completed = false;
  bool _wantsToPlay = false;
  int _intentVersion = 0;
  int _loadVersion = 0;

  bool get _active => mounted && !_disposed;
  bool get wantsToPlay => _wantsToPlay;

  bool get _hasAudio =>
      widget.url.trim().isNotEmpty &&
      (widget.unavailableReason?.trim().isEmpty ?? true);

  bool get _allowsPlayback =>
      AppSettings.instance.ttsBackground ||
      WidgetsBinding.instance.lifecycleState != AppLifecycleState.paused;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _position = widget.canSeek && widget.initialPosition > Duration.zero
        ? widget.initialPosition
        : Duration.zero;
    _wantsToPlay = _hasAudio && widget.autoPlay && _allowsPlayback;
    final intent = _intentVersion;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_active || !_hasAudio) return;
      unawaited(_enqueue(() async {
        await _prepare();
        await _resumeIfWanted(intent);
      }));
    });
  }

  Future<void> _enqueue(Future<void> Function() action) {
    _operation = _operation.then((_) async {
      if (!_active) return;
      try {
        await action();
      } catch (_) {
        _fail();
      }
    });
    return _operation;
  }

  AudioPlayer _createPlayer() {
    final player = AudioPlayer();
    _player = player;
    _subscriptions.addAll([
      player.onPlayerStateChanged.listen(
        _onPlayerState,
        onError: _onStreamError,
      ),
      player.onDurationChanged.listen(
        _onDuration,
        onError: _onStreamError,
      ),
      player.onPositionChanged.listen(
        _onPosition,
        onError: _onStreamError,
      ),
      player.onPlayerComplete.listen(
        (_) => _onComplete(),
        onError: _onStreamError,
      ),
      player.eventStream.listen(
        (_) {},
        onError: _onStreamError,
      ),
    ]);
    return player;
  }

  bool _validLoad(int version) =>
      _active && !_failed && version == _loadVersion;

  Future<void> _prepare() async {
    if (!_active || !_hasAudio || _prepared) return;
    final version = ++_loadVersion;
    setState(() {
      _loading = true;
      _failed = false;
      _completed = false;
      _dragPosition = null;
    });
    try {
      final url = widget.url.trim();
      final uri = Uri.tryParse(url);
      if (uri == null ||
          (uri.scheme != 'http' && uri.scheme != 'https') ||
          uri.host.isEmpty) {
        _fail();
        return;
      }
      final player = _player ?? _createPlayer();
      await player.setAudioContext(AudioContext(
        iOS: AudioContextIOS(category: AVAudioSessionCategory.playback),
      ));
      if (!_validLoad(version)) return;
      await player.setReleaseMode(ReleaseMode.stop);
      if (!_validLoad(version)) return;
      await player.setSource(UrlSource(url));
      if (!_validLoad(version)) return;
      final duration = await player.getDuration();
      if (!_validLoad(version)) return;
      if (duration != null) _onDuration(duration);
      final position = widget.canSeek ? _bounded(_position) : Duration.zero;
      final seekIntent = _intentVersion;
      if (widget.canSeek && position > Duration.zero) {
        await player.seek(position);
        if (!_validLoad(version)) return;
      }
      _prepared = true;
      if (seekIntent == _intentVersion) _setPosition(position, force: true);
    } finally {
      if (_active) setState(() => _loading = false);
    }
  }

  Future<void> _resumeIfWanted(int intent) async {
    if (!_active ||
        !_prepared ||
        _failed ||
        !_wantsToPlay ||
        intent != _intentVersion) {
      return;
    }
    if (!_allowsPlayback) {
      _wantsToPlay = false;
      _intentVersion++;
      _setPlaying(false, force: true);
      return;
    }
    await _player!.resume();
    if (!_active || intent != _intentVersion || !_wantsToPlay || _failed) {
      return;
    }
    _setPlaying(true);
  }

  Future<void> toggle() {
    if (!_active || !_hasAudio) return Future<void>.value();
    if (_wantsToPlay) return pause();
    _wantsToPlay = true;
    final intent = ++_intentVersion;
    if (_completed) _setPosition(Duration.zero);
    if (!_active) return Future<void>.value();
    setState(() {});
    return _enqueue(() async {
      if (intent != _intentVersion || !_wantsToPlay) return;
      await _prepare();
      await _resumeIfWanted(intent);
    });
  }

  Future<void> pause() {
    if (!_active) return Future<void>.value();
    // 播放意图必须立即撤销，不能等准备操作结束才阻止自动播放。
    _wantsToPlay = false;
    _intentVersion++;
    _setPlaying(false, force: true);
    return _enqueue(() async {
      final player = _player;
      if (player != null) await player.pause();
    });
  }

  Future<void> stop() {
    if (!_active) return Future<void>.value();
    _wantsToPlay = false;
    _intentVersion++;
    _prepared = false;
    _completed = false;
    _dragPosition = null;
    _setPlaying(false, force: true);
    _setPosition(Duration.zero, force: true);
    return _enqueue(() async {
      final player = _player;
      if (player != null) await player.stop();
      if (!_active) return;
      _prepared = false;
      _setPosition(Duration.zero);
    });
  }

  Future<void> _seek(double milliseconds) {
    if (!_active || !widget.canSeek || !_prepared || _failed || _loading) {
      return Future<void>.value();
    }
    final intent = _intentVersion;
    return _enqueue(() async {
      if (!_prepared || _failed || intent != _intentVersion) return;
      final position = _bounded(Duration(milliseconds: milliseconds.round()));
      await _player!.seek(position);
      if (!_active || intent != _intentVersion || _failed) return;
      _setPosition(position);
    });
  }

  Duration _bounded(Duration position) {
    if (position < Duration.zero) return Duration.zero;
    if (_duration > Duration.zero && position > _duration) return _duration;
    return position;
  }

  void _onDuration(Duration duration) {
    if (!_active || _failed || duration < Duration.zero) return;
    setState(() => _duration = duration);
  }

  void _onPosition(Duration position) {
    if (!_active || !_prepared || _failed || _completed) return;
    _setPosition(_bounded(position));
  }

  void _setPosition(Duration position, {bool force = false}) {
    if (!_active || (!force && position == _position)) return;
    setState(() => _position = position);
    if (_active) widget.onPosition(position);
  }

  void _setPlaying(bool playing, {bool force = false}) {
    if (!_active || (!force && playing == _playing)) return;
    setState(() => _playing = playing);
    if (_active) widget.onPlaying(playing);
  }

  void _onPlayerState(PlayerState state) {
    if (!_active || _completed || state == PlayerState.completed) return;
    if (state == PlayerState.playing) {
      if (_wantsToPlay && !_failed) _setPlaying(true);
    } else if (state == PlayerState.paused ||
        state == PlayerState.stopped ||
        state == PlayerState.disposed) {
      _setPlaying(false);
    }
  }

  void _onComplete() {
    if (!_active || !_prepared || _failed || _completed || !_wantsToPlay) {
      return;
    }
    _intentVersion++;
    setState(() {
      _completed = true;
      _prepared = false;
      _playing = false;
      _wantsToPlay = false;
      _dragPosition = null;
    });
    if (_duration > Duration.zero) _setPosition(_duration);
    if (_active) widget.onPlaying(false);
    if (_active) widget.onComplete();
  }

  void _onStreamError(Object error, StackTrace stackTrace) {
    _fail();
  }

  void _fail() {
    if (!_active || _failed) return;
    _intentVersion++;
    _loadVersion++;
    _wantsToPlay = false;
    _prepared = false;
    setState(() {
      _failed = true;
      _loading = false;
      _dragPosition = null;
    });
    _setPlaying(false, force: true);
    unawaited(_enqueue(() async {
      final player = _player;
      if (player != null) await player.stop();
    }));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_active &&
        state == AppLifecycleState.paused &&
        !AppSettings.instance.ttsBackground) {
      unawaited(pause());
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _wantsToPlay = false;
    _intentVersion++;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_disposePlayer());
    super.dispose();
  }

  Future<void> _disposePlayer() async {
    final cancellations = _subscriptions.map((subscription) async {
      try {
        await subscription.cancel();
      } catch (_) {}
    }).toList();
    _subscriptions.clear();
    await Future.wait(cancellations);
    // 等串行操作退出后再销毁，避免与原生 prepare/resume 交错。
    await _operation;
    final player = _player;
    _player = null;
    if (player != null) {
      try {
        await player.dispose();
      } catch (_) {}
    }
  }

  String _formatTime(Duration duration) {
    final seconds = duration.inSeconds;
    final hours = (seconds ~/ 3600).toString().padLeft(2, '0');
    final minutes = (seconds ~/ 60).remainder(60).toString().padLeft(2, '0');
    final remainder = seconds.remainder(60).toString().padLeft(2, '0');
    return '$hours:$minutes:$remainder';
  }

  Widget _roundButton({
    required String tooltip,
    required IconData icon,
    required double size,
    required double iconSize,
    required VoidCallback? onPressed,
    bool filled = false,
  }) {
    return SizedBox.square(
      dimension: size,
      child: Material(
        color: filled ? Colors.white : Colors.transparent,
        shape: CircleBorder(
          side: filled
              ? BorderSide.none
              : const BorderSide(color: Colors.white38),
        ),
        clipBehavior: Clip.antiAlias,
        child: IconButton(
          tooltip: tooltip,
          padding: EdgeInsets.zero,
          color: filled ? const Color(0xFF29232E) : Colors.white,
          disabledColor: filled ? Colors.black38 : Colors.white38,
          iconSize: iconSize,
          icon: Icon(icon),
          onPressed: onPressed,
        ),
      ),
    );
  }

  Widget _action({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
  }) {
    return Expanded(
      child: TextButton(
        style: TextButton.styleFrom(
          foregroundColor: Colors.white70,
          disabledForegroundColor: Colors.white38,
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 8),
          minimumSize: const Size(0, 48),
        ),
        onPressed: onPressed,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 24),
            const SizedBox(height: 6),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(label, maxLines: 1, style: const TextStyle(fontSize: 14)),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF4F4250), Color(0xFF3B3140), Color(0xFF2E2732)],
        ),
      ),
      child: SafeArea(
        child: LayoutBuilder(builder: (context, constraints) {
          final compact = constraints.maxHeight < 600;
          final coverSize = (constraints.maxWidth * 0.56)
              .clamp(88.0, compact ? 170.0 : 260.0)
              .toDouble();
          return SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                        horizontal: 20, vertical: compact ? 8 : 12),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildTopBar(),
                        SizedBox(height: compact ? 8 : 16),
                        _buildCover(coverSize),
                        SizedBox(height: compact ? 8 : 16),
                        _buildTitles(),
                        SizedBox(height: compact ? 8 : 16),
                        if (!_hasAudio)
                          _buildUnavailable()
                        else
                          _buildProgress(),
                        SizedBox(height: compact ? 10 : 20),
                        _buildActions(),
                        SizedBox(height: compact ? 6 : 14),
                        _buildTransport(),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildTopBar() {
    return Row(
      children: [
        _circleIcon('返回', Icons.arrow_back, widget.onBack),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            widget.bookName.isEmpty ? widget.title : widget.bookName,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(width: 12),
        _circleIcon('刷新', Icons.refresh, widget.onRefresh),
      ],
    );
  }

  Widget _circleIcon(String tooltip, IconData icon, VoidCallback? onPressed) {
    return SizedBox.square(
      dimension: 40,
      child: Material(
        color: Colors.white,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: IconButton(
          tooltip: tooltip,
          padding: EdgeInsets.zero,
          iconSize: 22,
          color: const Color(0xFF3B3140),
          icon: Icon(icon),
          onPressed: onPressed,
        ),
      ),
    );
  }

  Widget _buildCover(double size) {
    return Center(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 24,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: BookCover(
          url: widget.coverUrl,
          radius: 18,
          placeholder: const ColoredBox(
            color: Color(0xFF6A5C6C),
            child: Icon(Icons.menu_book, color: Colors.white54, size: 48),
          ),
        ),
      ),
    );
  }

  Widget _buildTitles() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          widget.title,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (widget.bookName.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            widget.bookName,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white54, fontSize: 15),
          ),
        ],
      ],
    );
  }

  Widget _buildUnavailable() {
    final reason = widget.unavailableReason?.trim();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.headphones, size: 40, color: Colors.white54),
        const SizedBox(height: 8),
        Text(
          reason != null && reason.isNotEmpty ? reason : '本章暂无可播放音频',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white70),
        ),
      ],
    );
  }

  Widget _buildProgress() {
    final seekEnabled = widget.canSeek &&
        _prepared &&
        !_loading &&
        !_failed &&
        _duration > Duration.zero;
    final maximum = _duration.inMilliseconds > 0
        ? _duration.inMilliseconds.toDouble()
        : 1.0;
    final progress = (_dragPosition ?? _position.inMilliseconds.toDouble())
        .clamp(0.0, maximum)
        .toDouble();
    final displayPosition = _dragPosition == null
        ? _position
        : Duration(milliseconds: _dragPosition!.round());
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: Colors.white,
            inactiveTrackColor: Colors.white24,
            thumbColor: Colors.white,
            trackHeight: 3,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
          ),
          child: Slider(
            value: progress,
            max: maximum,
            semanticFormatterCallback: (value) =>
                _formatTime(Duration(milliseconds: value.round())),
            onChanged: seekEnabled
                ? (value) {
                    if (_active) setState(() => _dragPosition = value);
                  }
                : null,
            onChangeEnd: seekEnabled
                ? (value) {
                    if (!_active) return;
                    setState(() => _dragPosition = null);
                    unawaited(_seek(value));
                  }
                : null,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_formatTime(displayPosition),
                  style: const TextStyle(color: Colors.white70, fontSize: 13)),
              if (_loading)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white70),
                )
              else if (_failed)
                TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white,
                    minimumSize: const Size(0, 28),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () => unawaited(toggle()),
                  child: const Text('加载失败，重试'),
                )
              else if (!widget.canSeek)
                const Text('不支持拖动进度',
                    style: TextStyle(color: Colors.white38, fontSize: 12)),
              Text(_formatTime(_duration),
                  style: const TextStyle(color: Colors.white70, fontSize: 13)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildActions() {
    return Row(
      children: [
        _action(
          icon: Icons.timer_outlined,
          label: widget.timerLabel,
          onPressed: widget.onTimer,
        ),
        _action(
          icon: Icons.list_alt,
          label: '目录',
          onPressed: widget.onShowChapters,
        ),
        _action(
          icon: widget.inBookshelf
              ? Icons.check_circle_outline
              : Icons.add_circle_outline,
          label: widget.inBookshelf ? '已在书架' : '加入书架',
          onPressed: widget.inBookshelf ? null : widget.onAddToShelf,
        ),
        _action(
          icon: Icons.more_horiz,
          label: '更多',
          onPressed: widget.onMore,
        ),
      ],
    );
  }

  Widget _buildTransport() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _roundButton(
          tooltip: '上一章',
          icon: Icons.skip_previous_rounded,
          size: 52,
          iconSize: 26,
          onPressed: widget.onPrevious,
        ),
        const SizedBox(width: 32),
        _roundButton(
          tooltip: _wantsToPlay ? '暂停' : '播放',
          icon: _wantsToPlay ? Icons.pause_rounded : Icons.play_arrow_rounded,
          size: 72,
          iconSize: 40,
          filled: true,
          onPressed: _hasAudio ? () => unawaited(toggle()) : null,
        ),
        const SizedBox(width: 32),
        _roundButton(
          tooltip: '下一章',
          icon: Icons.skip_next_rounded,
          size: 52,
          iconSize: 26,
          onPressed: widget.onNext,
        ),
      ],
    );
  }
}
