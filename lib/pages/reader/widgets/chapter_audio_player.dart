import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../../../services/app_settings.dart';

class ChapterAudioPlayer extends StatefulWidget {
  const ChapterAudioPlayer({
    super.key,
    required this.url,
    required this.title,
    required this.textColor,
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
  });

  final String url;
  final String title;
  final Color textColor;
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
    final minutes = (seconds ~/ 60).remainder(60).toString().padLeft(2, '0');
    final remainder = seconds.remainder(60).toString().padLeft(2, '0');
    if (seconds >= 3600) return '${seconds ~/ 3600}:$minutes:$remainder';
    return '${seconds ~/ 60}:$remainder';
  }

  @override
  Widget build(BuildContext context) {
    final hasAudio = _hasAudio;
    final seekEnabled = hasAudio &&
        widget.canSeek &&
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
    final reason = widget.unavailableReason?.trim();
    final textStyle = TextStyle(color: widget.textColor);

    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: constraints.hasBoundedHeight ? constraints.maxHeight : 0,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
                child: DefaultTextStyle.merge(
                  style: textStyle,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Icon(Icons.headphones, size: 48, color: widget.textColor),
                      const SizedBox(height: 16),
                      Text(
                        widget.title,
                        textAlign: TextAlign.center,
                        style: textStyle.copyWith(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 16),
                      if (!hasAudio)
                        Text(
                          reason != null && reason.isNotEmpty
                              ? reason
                              : '本章暂无可播放音频',
                          textAlign: TextAlign.center,
                        )
                      else ...[
                        if (_loading) ...[
                          Center(
                            child: SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: widget.textColor,
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Text('正在加载音频', textAlign: TextAlign.center),
                        ],
                        if (_failed) ...[
                          const Text(
                            '音频加载失败，请重试或换源',
                            textAlign: TextAlign.center,
                          ),
                          TextButton(
                            style: TextButton.styleFrom(
                              foregroundColor: widget.textColor,
                            ),
                            onPressed: () => unawaited(toggle()),
                            child: const Text('重试'),
                          ),
                        ],
                        Slider(
                          value: progress,
                          max: maximum,
                          activeColor: widget.textColor,
                          semanticFormatterCallback: (value) =>
                              _formatTime(Duration(milliseconds: value.round())),
                          onChanged: seekEnabled
                              ? (value) {
                                  if (_active) {
                                    setState(() => _dragPosition = value);
                                  }
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
                        Text(
                          '${_formatTime(displayPosition)} / ${_formatTime(_duration)}',
                          textAlign: TextAlign.center,
                        ),
                        if (!widget.canSeek) ...[
                          const SizedBox(height: 8),
                          const Text(
                            '当前音频不支持拖动进度',
                            textAlign: TextAlign.center,
                          ),
                        ],
                        const SizedBox(height: 12),
                        Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 16,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            IconButton(
                              tooltip: _wantsToPlay ? '暂停' : '播放',
                              color: widget.textColor,
                              iconSize: 40,
                              icon: Icon(_wantsToPlay
                                  ? Icons.pause_circle_outline
                                  : Icons.play_circle_outline),
                              onPressed: () => unawaited(toggle()),
                            ),
                            IconButton(
                              tooltip: '停止',
                              color: widget.textColor,
                              icon: const Icon(Icons.stop_rounded),
                              onPressed: () => unawaited(stop()),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 12),
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          TextButton(
                            style: TextButton.styleFrom(
                              foregroundColor: widget.textColor,
                            ),
                            onPressed: widget.onPrevious,
                            child: const Text('上一章'),
                          ),
                          TextButton(
                            style: TextButton.styleFrom(
                              foregroundColor: widget.textColor,
                            ),
                            onPressed: widget.onShowChapters,
                            child: const Text('目录'),
                          ),
                          TextButton(
                            style: TextButton.styleFrom(
                              foregroundColor: widget.textColor,
                            ),
                            onPressed: widget.onNext,
                            child: const Text('下一章'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
