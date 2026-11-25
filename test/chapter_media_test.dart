import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:qread/pages/reader/engine/chapter_media.dart';

void main() {
  group('漫画识别', () {
    test('纯图片正文自动识别，保留图片顺序和附加参数', () {
      const first = 'https://images.test/1.webp,{"style":"FULL","type":"qd"}';
      final media = ChapterMedia.parse('<img src="$first"><img src="https://images.test/2.jpg">');
      expect(media.isComic, isTrue);
      expect(media.images, [first, 'https://images.test/2.jpg']);
      expect(media.isAudio, isFalse);
    });

    test('裸图片地址按行识别，保留查询参数', () {
      final media = ChapterMedia.parse('https://images.test/1.PNG?sign=a\nhttps://images.test/2.jpg');
      expect(media.isComic, isTrue);
      expect(media.images.length, 2);
    });

    test('HTML实体与无引号图片地址', () {
      final media = ChapterMedia.parse('<img src="https://images.test/1.jpg?a=1&amp;b=2"><img src=https://images.test/2.jpg>');
      expect(media.images.first, 'https://images.test/1.jpg?a=1&b=2');
      expect(media.images.last, 'https://images.test/2.jpg');
    });

    test('有正文的小说插图不自动切换为漫画', () {
      final text = List.filled(100, '这里是小说正文。').join();
      final media = ChapterMedia.parse('$text<img src="https://images.test/1.jpg">');
      expect(media.isComic, isFalse);
      expect(media.isAudio, isFalse);
    });

    test('单张插图加短段落也仍是小说', () {
      expect(ChapterMedia.parse('这是一个短小的小说段落<img src="https://images.test/1.jpg">').isComic, isFalse);
    });

    test('段评SVG和神评图片不能成为漫画页', () {
      const bubble = '<img src="data:image/svg+xml;base64,PHN2Zz4=,{"click":"showCmt(1)"}">';
      final media = ChapterMedia.parse('正文$bubble$bubble<img src="data:image/svg+xml;base64,PHN2Zz4=">');
      expect(media.isComic, isFalse);
      expect(media.images, isEmpty);
    });

    test('明确的漫画类型允许单张图片和空章', () {
      expect(ChapterMedia.parse('标题<img src="https://images.test/1.jpg">', bookType: 2).isComic, isTrue);
      final empty = ChapterMedia.parse('本章暂未更新', bookType: 2);
      expect(empty.isComic, isTrue);
      expect(empty.images, isEmpty);
      expect(ChapterMedia.parse('https://images.test/page?id=1', bookType: 2).images,
          ['https://images.test/page?id=1']);
    });

    test('不接受本地文件与脚本图片地址', () {
      final media = ChapterMedia.parse('<img src="file:///tmp/page.jpg"><img src="javascript:alert(1)">');
      expect(media.images, isEmpty);
      expect(media.isComic, isFalse);
    });
  });

  group('有声书地址', () {
    test('识别带签名的音频直链，不经过代理', () {
      final media = ChapterMedia.parse('https://audio.test/chapter.MP3?sign=test');
      expect(media.isAudio, isTrue);
      expect(media.audio!.canSeek, isTrue);
      expect(media.audio!.playbackUrl('test-token'), 'https://audio.test/chapter.MP3?sign=test');
    });

    test('已声明音频的书允许无扩展名直链', () {
      expect(ChapterMedia.parse('https://audio.test/stream?id=12', bookType: 1).audio!.url,
          'https://audio.test/stream?id=12');
      expect(ChapterMedia.parse('https://books.test/chapter/12').isAudio, isFalse);
    });

    test('无扩展名音频按查询串 MIME 自动识别，覆盖书籍默认文本类型', () {
      for (final mime in ['audio_mpeg', 'audio%2Fmpeg', 'audio%2Fmp4']) {
        final url = 'https://audio.test/video/chapter/?mime_type=$mime&sign=test';
        final media = ChapterMedia.parse(url, bookType: 0);
        expect(media.isAudio, isTrue);
        expect(media.audio!.url, url);
      }
      expect(ChapterMedia.parse('https://audio.test/play?content-type=audio%2Faac').isAudio, isTrue);
      expect(ChapterMedia.parse('https://video.test/play?mime_type=video_mp4').isAudio, isFalse);
      expect(ChapterMedia.parse('https://books.test/page?title=audio_mpeg').isAudio, isFalse);
      expect(ChapterMedia.parse('正文 https://audio.test/play?mime_type=audio_mpeg').isAudio, isFalse);
    });

    test('音频标签支持source及转义查询串', () {
      final media = ChapterMedia.parse('<audio controls><source src="https://audio.test/play?a=1&amp;b=2"></audio>');
      expect(media.audio!.url, 'https://audio.test/play?a=1&b=2');
    });

    test('请求头通过listen转发，支持Range代理的进度恢复', () {
      final media = ChapterMedia.parse(
        'https://audio.test/chapter.mp3,{"headers":{"Referer":"https://books.test/","X-Test":"value"}}',
        bookType: 1);
      final audio = media.audio!;
      expect(audio.error, isNull);
      expect(audio.canSeek, isTrue);
      final proxy = Uri.parse(audio.playbackUrl('test-token'));
      expect(proxy.path, endsWith('/api/5/listen'));
      expect(proxy.queryParameters['accessToken'], 'test-token');
      expect(proxy.queryParameters['url'], audio.url);
      expect(jsonDecode(proxy.queryParameters['header']!), audio.headers);
    });

    test('有书源时交给后端合并书源请求头，匿名直链不强制代理', () {
      const audio = ChapterAudio('https://audio.test/chapter.mp3');
      final proxy = Uri.parse(audio.playbackUrl('test-token',
          bookSourceUrl: 'https://books.test/'));
      expect(proxy.path, endsWith('/api/5/listen'));
      expect(proxy.queryParameters['bookSourceUrl'], 'https://books.test/');
      expect(jsonDecode(proxy.queryParameters['header']!), isEmpty);
      expect(audio.playbackUrl('test-token'), audio.url);
      expect(audio.playbackUrl('test-token', bookSourceUrl: 'loc_book'), audio.url);
    });

    test('不可播放的音频不允许恢复进度', () {
      expect(const ChapterAudio('').canSeek, isFalse);
      expect(const ChapterAudio('https://audio.test/chapter.mp3', error: '无效').canSeek,
          isFalse);
    });

    test('POST、网页解析和损坏参数不能直接播放', () {
      for (final options in ['{"method":"POST","body":"x=1"}', '{"webView":true}', '{invalid}']) {
        final audio = ChapterMedia.parse('https://audio.test/chapter.mp3,$options', bookType: 1).audio!;
        expect(audio.error, isNotNull);
        expect(audio.playbackUrl('test-token'), isEmpty);
      }
    });

    test('音频类型的网页正文显示不可播放而不是TTS朗读', () {
      for (final text in ['', '<p>请登录后收听</p>', 'javascript:alert(1)', 'file:///tmp/book.mp3']) {
        final audio = ChapterMedia.parse(text, bookType: 1).audio!;
        expect(audio.error, isNotNull);
        expect(audio.playbackUrl('test-token'), isEmpty);
      }
    });

    test('视频与下载类型不新增播放器', () {
      expect(ChapterMedia.parse('<video src="https://video.test/1.mp4"></video>').isAudio, isFalse);
      expect(ChapterMedia.parse('https://video.test/1.mp4').isAudio, isFalse);
      expect(ChapterMedia.parse('https://audio.test/1.mp3', bookType: 3).isMedia, isFalse);
    });
  });
}
