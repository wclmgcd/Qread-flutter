import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qread/pages/reader/widgets/chapter_audio_player.dart';
import 'package:qread/pages/reader/widgets/comic_reader.dart';

void main() {
  testWidgets('漫画图片全宽保比例，缓慢越界拖动累计后只切章一次', (tester) async {
    const url = 'https://images.test/page.png';
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawRect(const Rect.fromLTWH(0, 0, 100, 200), ui.Paint());
    final picture = recorder.endRecording();
    final image = picture.toImageSync(100, 200);
    picture.dispose();
    PaintingBinding.instance.imageCache.putIfAbsent(
      const NetworkImage(url),
      () => OneFrameImageStreamCompleter(Future.value(ImageInfo(image: image))),
    );
    final controller = ScrollController();
    var next = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ComicReader(
      images: const [url], controller: controller,
      imageUrlBuilder: (src) => src, onImageLongPress: (_) {},
      onShowChapters: () {}, title: '第一章', onNext: () => next++,
    ))));
    await tester.pumpAndSettle();
    final rendered = tester.widget<Image>(find.byType(Image));
    expect(rendered.width, double.infinity);
    expect(rendered.fit, BoxFit.fitWidth);
    expect(tester.getSize(find.byType(Image)).width,
        tester.getSize(find.byType(ListView)).width);
    final listContext = tester.element(find.byType(ListView));
    ScrollStartNotification(metrics: controller.position, context: listContext,
        dragDetails: DragStartDetails()).dispatch(listContext);
    for (var i = 0; i < 10; i++) {
      OverscrollNotification(metrics: controller.position, context: listContext,
          overscroll: 5).dispatch(listContext);
    }
    expect(next, 1);
    ScrollEndNotification(metrics: controller.position, context: listContext)
        .dispatch(listContext);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  testWidgets('没有音频直链时不创建播放器，目录仍可操作', (tester) async {
    var opened = false;
    await tester.binding.setSurfaceSize(const Size(240, 240));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ChapterAudioPlayer(
      url: '', title: '未返回音频的章节',
      unavailableReason: '书源未返回音频直链',
      onPosition: (_) => fail('不应播放'),
      onPlaying: (_) => fail('不应播放'),
      onComplete: () => fail('不应播放'),
      onShowChapters: () => opened = true,
    ))));
    expect(find.text('书源未返回音频直链'), findsOneWidget);
    expect(find.byType(Slider), findsNothing);
    await tester.ensureVisible(find.text('目录'));
    await tester.tap(find.text('目录'));
    expect(opened, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('有声书整页布局包含封面区、四个动作和播放控制', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final tapped = <String>[];
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ChapterAudioPlayer(
      // 有地址但解析失败：进度区仍在，顶栏/封面/标题/动作全都画得出来
      url: 'https://audio.test/a.mp3', title: '第001集 出门即是江湖',
      bookName: '我做老千的那些年', unavailableReason: '音频加载失败',
      onBack: () => tapped.add('back'),
      onRefresh: () => tapped.add('refresh'),
      onTimer: () => tapped.add('timer'),
      onAddToShelf: () => tapped.add('shelf'),
      onMore: () => tapped.add('more'),
      onPosition: (_) {}, onPlaying: (_) {}, onComplete: () {},
      onShowChapters: () => tapped.add('chapters'),
    ))));
    expect(find.text('我做老千的那些年'), findsNWidgets(2));
    expect(find.text('第001集 出门即是江湖'), findsOneWidget);
    expect(find.text('定时'), findsOneWidget);
    expect(find.text('加入书架'), findsOneWidget);
    expect(find.text('更多'), findsOneWidget);
    expect(find.byType(Slider), findsOneWidget);
    // 测试里没有原生播放器，prepare 会失败，播放键停在「重试」态
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    for (final entry in {
      Icons.arrow_back: 'back',
      Icons.refresh: 'refresh',
      Icons.timer_outlined: 'timer',
      Icons.more_horiz: 'more',
    }.entries) {
      await tester.tap(find.byIcon(entry.key));
      expect(tapped, contains(entry.value));
    }
    await tester.ensureVisible(find.text('目录'));
    await tester.tap(find.text('目录'));
    expect(tapped, contains('chapters'));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    // 播放器销毁里有一串 await（取消订阅、等串行队列），等它跑完再结束用例
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('小屏有声书布局不溢出', (tester) async {
    await tester.binding.setSurfaceSize(const Size(240, 240));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ChapterAudioPlayer(
      url: '', title: '章节', unavailableReason: '无音频',
      onPosition: (_) {}, onPlaying: (_) {}, onComplete: () {},
      onShowChapters: () {},
    ))));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('空漫画章显示提示和章节按钮，列表不留边距', (tester) async {
    final controller = ScrollController();
    var next = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ComicReader(
      images: const [], controller: controller,
      imageUrlBuilder: (src) => src,
      onImageLongPress: (_) {}, onShowChapters: () {},
      title: '第一章', onNext: () => next++,
    ))));
    expect(find.text('本章没有可显示的漫画图片'), findsOneWidget);
    final list = tester.widget<ListView>(find.byType(ListView));
    expect(list.padding, EdgeInsets.zero);
    expect(list.scrollDirection, Axis.vertical);
    await tester.drag(find.byType(ListView), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(next, 0);
    await tester.tap(find.text('下一章'));
    expect(next, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
