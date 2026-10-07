import 'dart:async';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../models/tts_engine.dart';
import 'api_service.dart';
import 'storage_service.dart';

enum TtsState { stopped, playing, paused }

class TtsService extends ChangeNotifier {
  static final TtsService _instance = TtsService._();
  factory TtsService() => _instance;
  TtsService._();

  final FlutterTts _tts = FlutterTts();

  /// HTTP 朗读引擎（「我的 → 朗读引擎」里配的那套）用的播放器。
  ///
  /// 【为什么需要两条播放链路】
  /// 后端 `/tts?id=…&speakText=…` 返回的是**音频流**（书源自己拼的 TTS 接口），
  /// 系统 TTS 播不了。所以：
  ///   - 选了「我的 → 朗读引擎」里的引擎 → 走 [_player] 播 `/tts` 的音频；
  ///   - 没选（或引擎被删了）→ 退回系统语音（[FlutterTts]）。
  final AudioPlayer _player = AudioPlayer();

  /// 当前选中的 HTTP 引擎；null = 用系统语音
  TtsEngine? _httpEngine;
  TtsEngine? get httpEngine => _httpEngine;

  /// 「我的 → 朗读引擎」页里写的就是这个 key，两处必须一致，
  /// 否则在阅读页选完、回「我的」看还是旧的。
  static const String selectedEngineKey = 'tts_selected_engine_id';

  String? _accessToken;

  TtsState _state = TtsState.stopped;
  TtsState get state => _state;
  bool get isPlaying => _state == TtsState.playing;
  bool get isStopped => _state == TtsState.stopped;

  double _rate = 0.5;
  double get rate => _rate;

  /// 后端 `/tts` 的 `speechRate` 量纲是 1~10（legado 的 speakSpeed），
  /// 而 flutter_tts 是 0.0~1.0，0.5 是默认 —— 乘 10 正好对上。
  double get httpSpeechRate => (_rate * 10).clamp(1.0, 10.0);

  List<Map<String, dynamic>> _voices = [];
  List<Map<String, dynamic>> get voices => _voices;

  String? _selectedVoiceId;
  String? get selectedVoiceId => _selectedVoiceId;

  // Callback when current chunk finishes — caller can feed next text
  VoidCallback? onChunkComplete;

  // Progress: text position (char offset in current chunk)
  int _currentCharOffset = 0;
  int get currentCharOffset => _currentCharOffset;

  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    await _tts.setSpeechRate(_rate);

    _tts.setStartHandler(() {
      _state = TtsState.playing;
      notifyListeners();
    });

    _tts.setCompletionHandler(() {
      _state = TtsState.stopped;
      _currentCharOffset = 0;
      notifyListeners();
      onChunkComplete?.call();
    });

    _tts.setErrorHandler((msg) {
      _state = TtsState.stopped;
      notifyListeners();
    });

    _tts.setCancelHandler(() {
      _state = TtsState.stopped;
      notifyListeners();
    });

    _tts.setPauseHandler(() {
      _state = TtsState.paused;
      notifyListeners();
    });

    _tts.setContinueHandler(() {
      _state = TtsState.playing;
      notifyListeners();
    });

    _tts.setProgressHandler((text, start, end, word) {
      _currentCharOffset = start;
      notifyListeners();
    });

    // HTTP 引擎的播放器：一段音频播完 == 系统 TTS 的一段读完，
    // 都往 onChunkComplete 上报，阅读页那边就不用区分两条链路了。
    _player.onPlayerComplete.listen((_) {
      _state = TtsState.stopped;
      _currentCharOffset = 0;
      notifyListeners();
      onChunkComplete?.call();
    });
    _player.onPlayerStateChanged.listen((s) {
      switch (s) {
        case PlayerState.playing:
          _state = TtsState.playing;
          break;
        case PlayerState.paused:
          _state = TtsState.paused;
          break;
        case PlayerState.stopped:
        case PlayerState.completed:
        case PlayerState.disposed:
          _state = TtsState.stopped;
          break;
        default:
          // PlayerState 来自 audioplayers 依赖包：它新增状态时，全列举的
          // switch 会因「不再穷尽」编译失败。未知状态一律当「已停止」。
          _state = TtsState.stopped;
          break;
      }
      notifyListeners();
    });

    try {
      _voices = List<Map<String, dynamic>>.from(
        (await _tts.getVoices).cast<Map>(),
      );
    } catch (_) {}

    // Default to Chinese if available
    await _setDefaultChinese();
  }

  /// 拉取「我的 → 朗读引擎」里的引擎，并把上次选中的那个恢复出来。
  ///
  /// 阅读页进入朗读前调用一次即可；引擎在「我的」里被删掉时会自动退回系统语音。
  Future<void> loadSelectedHttpEngine(String? token) async {
    _accessToken = token;
    if (token == null || token.isEmpty) return;
    final storage = await StorageService.instance;
    final id = storage.readString(selectedEngineKey);
    if (id == null || id.isEmpty) {
      if (_httpEngine != null) {
        _httpEngine = null;
        notifyListeners();
      }
      return;
    }
    try {
      final list = await ApiService.instance.getAllTts(token);
      TtsEngine? found;
      for (final e in list) {
        if (e.id == id) {
          found = e;
          break;
        }
      }
      _httpEngine = found;
    } catch (_) {
      // 后端不可达时保持原状，别把用户的选中项清掉
    }
    notifyListeners();
  }

  /// 选择/取消一个 HTTP 朗读引擎（null = 用系统语音）
  Future<void> setHttpEngine(TtsEngine? engine) async {
    final storage = await StorageService.instance;
    final id = engine?.id ?? '';
    if (id.isEmpty) {
      await storage.remove(selectedEngineKey);
      _httpEngine = null;
    } else {
      await storage.setString(selectedEngineKey, id);
      _httpEngine = engine;
    }
    notifyListeners();
  }

  Future<void> _setDefaultChinese() async {
    if (_voices.isEmpty) return;
    // Prefer zh-CN voice
    for (final v in _voices) {
      final locale = v['locale']?.toString() ?? v['name']?.toString() ?? '';
      if (locale.startsWith('zh') || locale.contains('Chinese')) {
        _selectedVoiceId = v['name']?.toString() ?? v['identifier']?.toString();
        try {
          await _tts.setVoice(v as Map<String, String>);
        } catch (_) {}
        return;
      }
    }
  }

  Future<void> setLanguage(String language) async {
    await _tts.setLanguage(language);
  }

  Future<void> setVoiceById(String voiceId) async {
    _selectedVoiceId = voiceId;
    final voice = _voices.firstWhere(
      (v) => (v['name'] ?? v['identifier']) == voiceId,
      orElse: () => <String, dynamic>{},
    );
    if (voice.isNotEmpty) {
      try {
        await _tts.setVoice(voice as Map<String, String>);
      } catch (e) {
        // Fallback: try setting via language
        final locale = voice['locale']?.toString() ?? 'zh-CN';
        await _tts.setLanguage(locale);
      }
    }
  }

  Future<void> setRate(double rate) async {
    // flutter_tts uses 0.0-1.0, where 0.5 is default
    _rate = rate.clamp(0.1, 1.0);
    await _tts.setSpeechRate(_rate);
    notifyListeners();
  }

  Future<void> speak(String text) async {
    _currentCharOffset = 0;

    // 选了「我的 → 朗读引擎」里的 HTTP 引擎 → 让后端合成音频来播。
    // 后端 `/tts` 会按 id 取出引擎、把 {{speakText}} / {{speakSpeed}} 替换好，
    // 直接返回音频流，所以客户端只要给播放器一个 URL。
    final engine = _httpEngine;
    final token = _accessToken;
    final engineId = engine?.id ?? '';
    if (engine != null && engineId.isNotEmpty && token != null && token.isNotEmpty) {
      try {
        await _player.stop();
        final url = ApiService.instance.ttsAudioUrl(
          token,
          engineId,
          text,
          rate: httpSpeechRate,
        );
        _state = TtsState.playing;
        notifyListeners();
        await _player.play(UrlSource(url));
        return;
      } catch (e) {
        // 引擎挂了就退回系统语音，别让用户点了朗读一点声音都没有
        debugPrint('HTTP TTS 失败，回退系统语音: $e');
      }
    }

    // Split long text into paragraphs for better progress tracking
    // Use max 2000 chars per chunk
    if (text.length > 2000) {
      final paragraphs = text.split(RegExp(r'\n+'));
      var buffer = '';
      for (final para in paragraphs) {
        if (buffer.length + para.length > 2000) {
          await _tts.speak(buffer);
          buffer = para;
        } else {
          if (buffer.isNotEmpty) buffer += '\n';
          buffer += para;
        }
      }
      if (buffer.isNotEmpty) {
        await _tts.speak(buffer);
      }
    } else {
      await _tts.speak(text);
    }
  }

  Future<void> speakText(String text) async {
    await speak(text);
  }

  Future<void> stop() async {
    // 两条链路都停 —— 不知道上一次是哪个在发声，多停一次没副作用
    await _player.stop();
    await _tts.stop();
    _state = TtsState.stopped;
    _currentCharOffset = 0;
    notifyListeners();
  }

  Future<void> pause() async {
    if (_player.state == PlayerState.playing) {
      await _player.pause();
      return;
    }
    await _tts.pause();
  }

  void togglePlayPause() {
    if (_state == TtsState.playing) {
      pause();
    } else if (_state == TtsState.paused) {
      // Flutter_tts doesn't have resume; we use stop + speak again
      stop();
    }
  }

  Future<void> setVolume(double volume) async {
    await _tts.setVolume(volume.clamp(0.0, 1.0));
  }

  @override
  void dispose() {
    _player.dispose();
    _tts.stop();
    super.dispose();
  }
}
