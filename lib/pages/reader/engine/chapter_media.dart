import 'dart:convert';

import 'package:html/parser.dart' as html;

import '../../../config/constants.dart';
import '../../../services/chapter_markup.dart';
import 'pagination_engine.dart';

class ChapterAudio {
  const ChapterAudio(this.url, {this.headers = const {}, this.error});

  final String url;
  final Map<String, String> headers;
  final String? error;

  bool get canSeek => url.isNotEmpty && error == null;

  String playbackUrl(String token, {String? bookSourceUrl}) {
    if (url.isEmpty || error != null) return '';
    final source = bookSourceUrl?.trim() ?? '';
    final hasSource = source.isNotEmpty && source != 'loc_book';
    if (headers.isEmpty && !hasSource) return url;
    return Uri.parse('${AppConstants.apiBase}/listen').replace(queryParameters: {
      'accessToken': token,
      'url': url,
      'header': jsonEncode(headers),
      if (hasSource) 'bookSourceUrl': source,
    }).toString();
  }
}

class ChapterMedia {
  const ChapterMedia({this.isComic = false, this.images = const [], this.audio});

  final bool isComic;
  final List<String> images;
  final ChapterAudio? audio;

  bool get isAudio => audio != null;
  bool get isMedia => isComic || isAudio;

  static final _imageExtension = RegExp(
    r'\.(?:jpg|jpeg|png|webp|gif|avif|bmp)$', caseSensitive: false);
  static final _audioExtension = RegExp(
    r'\.(?:mp3|m4a|aac|wav|ogg|opus|flac|aiff)$', caseSensitive: false);
  static final _optionsStart = RegExp(r',\s*\{');

  static ChapterMedia parse(String content, {int? bookType}) {
    if (bookType == 3) return const ChapterMedia();
    final cleaned = content.replaceAll(ChapterMarkup.wholeTag, '');
    final document = html.parseFragment(cleaned);
    final audioElement = document.querySelector('audio');
    final audioSrc = audioElement?.attributes['src'] ??
        audioElement?.querySelector('source')?.attributes['src'];
    final raw = (audioSrc ?? document.text ?? '').trim();
    final audio = _parseAudio(raw);
    if (bookType == 1 || audioElement != null ||
        (audio != null && _audioExtension.hasMatch(Uri.parse(audio.url).path))) {
      return ChapterMedia(audio: audio ?? const ChapterAudio('',
        error: '书源未返回可播放的音频直链，请刷新章节或更换书源'));
    }

    final images = <String>[];
    final text = cleaned.replaceAllMapped(ChapterMarkup.anyImgTag, (match) {
      final tag = match.group(0)!;
      final src = PaginationEngine.extractImgSrc(tag) ??
          html.parseFragment(tag).querySelector('img')?.attributes['src'];
      if (src != null) {
        final decoded = (html.parseFragment(src).text ?? '').trim();
        if (_httpUri(_urlPart(decoded)) != null) images.add(decoded);
      }
      return '';
    });
    final remainder = <String>[];
    for (final line in (html.parseFragment(text.replaceAll(
        RegExp(r'<br\s*/?>', caseSensitive: false), '\n')).text ?? '').split('\n')) {
      final value = line.trim();
      final uri = _httpUri(_urlPart(value));
      if (uri != null && (bookType == 2 || _imageExtension.hasMatch(uri.path))) {
        images.add(value);
      } else if (value.isNotEmpty) {
        remainder.add(value);
      }
    }
    final textLength = remainder.join().replaceAll(RegExp(r'\s'), '').length;
    final comic = bookType == 2 || (images.isNotEmpty &&
        (textLength == 0 || (images.length >= 2 && textLength <= 80)));
    return ChapterMedia(isComic: comic, images: List.unmodifiable(images));
  }

  static String _urlPart(String value) {
    final options = _optionsStart.firstMatch(value);
    return (options == null ? value : value.substring(0, options.start)).trim();
  }

  static Uri? _httpUri(String value) {
    value = value.replaceAll('baseurl', AppConstants.apiBase);
    final uri = Uri.tryParse(value);
    if (uri == null || !const ['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty || RegExp(r'\s').hasMatch(value)) return null;
    return uri;
  }

  static ChapterAudio? _parseAudio(String raw) {
    raw = raw.replaceAll('baseurl', AppConstants.apiBase);
    final url = _urlPart(raw);
    if (_httpUri(url) == null) return null;
    final headers = <String, String>{};
    final optionsMatch = _optionsStart.firstMatch(raw);
    if (optionsMatch != null) {
      try {
        final options = jsonDecode(raw.substring(optionsMatch.start + 1));
        if (options is! Map) throw const FormatException();
        final method = (options['method'] ?? 'GET').toString().toUpperCase();
        if (method != 'GET' || options['body'] != null ||
            options['webView'] == true || options['webView'] == 'true') {
          return ChapterAudio(url, error: '此音频需要网页解析或非 GET 请求，暂不支持');
        }
        final values = options['headers'];
        if (values != null) {
          if (values is! Map) throw const FormatException();
          for (final entry in values.entries) {
            headers[entry.key.toString()] = entry.value.toString();
          }
        }
      } catch (_) {
        return ChapterAudio(url, error: '音频地址的请求参数无效，请检查书源');
      }
    }
    return ChapterAudio(url, headers: Map.unmodifiable(headers));
  }
}
