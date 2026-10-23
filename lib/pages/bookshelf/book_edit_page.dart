import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../models/book.dart';
import '../../models/search_result.dart';
import '../../services/api_service.dart';
import '../../services/error_text.dart';
import '../../widgets/book_cover.dart';
import '../../widgets/book_detail_style.dart';

/// 编辑书籍信息页（对齐轻阅时光）：封面 + 书名 / 作者 / 简介。
///
/// 保存走 `/saveBookInfo` —— 它写的 `custom_cover_url` / `custom_intro`
/// 对书架里已有的书也生效（`/saveBook` 会返回 BOOKIS）。
class BookEditPage extends StatefulWidget {
  const BookEditPage({
    Key? key,
    required this.book,
    required this.token,
  }) : super(key: key);

  final Book book;
  final String token;

  @override
  State<BookEditPage> createState() => _BookEditPageState();
}

class _BookEditPageState extends State<BookEditPage> {
  late final TextEditingController _nameCtl;
  late final TextEditingController _authorCtl;
  late final TextEditingController _introCtl;
  late String _coverUrl;

  /// 刚上传成功的本地字节 —— 预览时优先用它，避免服务端静态目录
  /// 跟上传目录对不上导致「传成功了但封面转圈」。
  Uint8List? _localCoverBytes;
  bool _saving = false;
  bool _loadingSource = false;

  @override
  void initState() {
    super.initState();
    _nameCtl = TextEditingController(text: widget.book.name ?? '');
    _authorCtl = TextEditingController(text: widget.book.author ?? '');
    _introCtl = TextEditingController(text: _initialIntro);
    _coverUrl = _initialCover;
  }

  @override
  void dispose() {
    _nameCtl.dispose();
    _authorCtl.dispose();
    _introCtl.dispose();
    super.dispose();
  }

  String get _initialIntro {
    final custom = widget.book.customIntro?.trim() ?? '';
    if (custom.isNotEmpty) return custom;
    return widget.book.intro ?? '';
  }

  String get _initialCover {
    final custom = widget.book.customCoverUrl?.trim() ?? '';
    if (custom.isNotEmpty) return custom;
    return widget.book.coverUrl ?? '';
  }

  // ---------------------------------------------------------------- 结构

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BookDetailStyle.sheet(context),
      body: Stack(
        children: [
          SafeArea(
            child: Column(
              children: [
                _buildTopBar(),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(18, 6, 18, 32),
                    children: [
                      const SizedBox(height: 8),
                      Center(child: _buildCover()),
                      const SizedBox(height: 28),
                      _buildField(
                        controller: _nameCtl,
                        label: '书名',
                      ),
                      const SizedBox(height: 18),
                      _buildField(
                        controller: _authorCtl,
                        label: '作者',
                      ),
                      const SizedBox(height: 18),
                      _buildField(
                        controller: _introCtl,
                        label: '简介',
                        minLines: 8,
                        maxLines: null,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (_loadingSource)
            Positioned.fill(
              child: Container(
                color: Colors.black26,
                alignment: Alignment.center,
                child: Container(
                  padding: const EdgeInsets.all(22),
                  decoration: BoxDecoration(
                    color: BookDetailStyle.card(context),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const SizedBox(
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(strokeWidth: 2.4),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Text(
            '编辑书籍信息',
            style: TextStyle(
              fontSize: 21,
              fontWeight: FontWeight.w700,
              color: BookDetailStyle.text(context),
            ),
          ),
          Row(
            children: [
              GestureDetector(
                onTap: _saving ? null : () => Navigator.pop(context, false),
                child: _circle(Icons.arrow_back),
              ),
              const Spacer(),
              GestureDetector(
                onTap: _saving ? null : _save,
                child: _saving
                    ? Container(
                        width: 42,
                        height: 42,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: BookDetailStyle.circleButton(context),
                          shape: BoxShape.circle,
                        ),
                        child: const SizedBox(
                          width: 18,
                          height: 18,
                          child:
                              CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : _circle(Icons.save_outlined),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _circle(IconData icon) {
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: BookDetailStyle.circleButton(context),
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Icon(icon, size: 22, color: BookDetailStyle.text(context)),
    );
  }

  Widget _buildCover() {
    return SizedBox(
      width: 132,
      height: 180,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.12),
                    blurRadius: 14,
                    offset: const Offset(0, 5),
                  ),
                ],
              ),
              // 刚上传的字节直接画，绕开「服务端静态目录 ≠ 上传目录」时
              // 网络图一时 404 的问题；保存后其它端走 URL 拉同一张图。
              child: _localCoverBytes != null
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Image.memory(
                        _localCoverBytes!,
                        width: 128,
                        height: 176,
                        fit: BoxFit.cover,
                      ),
                    )
                  : BookCover(
                      url: _coverUrl,
                      sourceUrl: widget.book.origin,
                      width: 128,
                      height: 176,
                      radius: 6,
                    ),
            ),
          ),
          Positioned(
            right: -2,
            bottom: -2,
            child: GestureDetector(
              onTap: _pickCover,
              child: Container(
                width: 38,
                height: 38,
                decoration: const BoxDecoration(
                  color: Color(0xCC3A3A3C),
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(10),
                    bottomRight: Radius.circular(8),
                  ),
                ),
                child: const Icon(
                  Icons.edit,
                  size: 20,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildField({
    required TextEditingController controller,
    required String label,
    int minLines = 1,
    int? maxLines = 1,
  }) {
    OutlineInputBorder border(Color color, [double width = 1]) =>
        OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: color, width: width),
        );
    return TextField(
      controller: controller,
      minLines: minLines,
      maxLines: maxLines,
      style: TextStyle(
        fontSize: 18,
        height: 1.5,
        color: BookDetailStyle.text(context),
      ),
      decoration: InputDecoration(
        labelText: label,
        floatingLabelBehavior: FloatingLabelBehavior.always,
        labelStyle: TextStyle(
          fontSize: 14,
          color: BookDetailStyle.sub(context),
        ),
        fillColor: Colors.transparent,
        contentPadding: const EdgeInsets.fromLTRB(14, 16, 14, 16),
        enabledBorder: border(BookDetailStyle.outline),
        focusedBorder: border(BookDetailStyle.accent, 1.4),
        border: border(BookDetailStyle.outline),
      ),
    );
  }

  // ---------------------------------------------------------------- 封面

  Future<void> _pickCover() async {
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => _CoverSourceDialog(dark: BookDetailStyle.isDark(ctx)),
    );
    if (!mounted || picked == null) return;
    switch (picked) {
      case 'search':
        await _pickFromSource();
        break;
      case 'upload':
        await _uploadImage();
        break;
      case 'link':
        await _inputLink();
        break;
    }
  }

  /// 用当前书源按书名搜一次，列出候选封面
  Future<void> _pickFromSource() async {
    final origin = widget.book.origin?.trim() ?? '';
    final keyword = _nameCtl.text.trim();
    if (origin.isEmpty) {
      _toast('这本书没有书源信息，无法搜索');
      return;
    }
    if (keyword.isEmpty) {
      _toast('先填书名再搜索');
      return;
    }
    setState(() => _loadingSource = true);
    List<SearchResult> results = [];
    var failed = false;
    try {
      results = await ApiService.instance
          .searchBook(widget.token, keyword, bookSourceUrl: origin);
    } catch (e) {
      failed = true;
      _toast('搜索失败：${friendlyError(e)}');
    } finally {
      if (mounted) setState(() => _loadingSource = false);
    }
    if (!mounted || failed) return;
    final covers = results
        .where((r) => (r.coverUrl ?? '').trim().isNotEmpty)
        .toList(growable: false);
    if (covers.isEmpty) {
      _toast('书源里没有搜到带封面的结果');
      return;
    }
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: BookDetailStyle.card(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
              child: Row(
                children: [
                  Text(
                    '选择封面',
                    style: TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w700,
                      color: BookDetailStyle.text(ctx),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '共 ${covers.length} 个',
                    style: TextStyle(
                      fontSize: 13,
                      color: BookDetailStyle.sub(ctx),
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: GridView.builder(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                shrinkWrap: true,
                gridDelegate:
                    const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: 14,
                  crossAxisSpacing: 14,
                  childAspectRatio: 0.62,
                ),
                itemCount: covers.length,
                itemBuilder: (_, i) {
                  final result = covers[i];
                  return GestureDetector(
                    onTap: () =>
                        Navigator.pop(ctx, result.coverUrl!.trim()),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: BookCover(
                            url: result.coverUrl,
                            sourceUrl: result.origin ?? origin,
                            width: double.infinity,
                            radius: 8,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          result.name ?? keyword,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            color: BookDetailStyle.text(ctx),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
    if (picked != null && picked.isNotEmpty && mounted) {
      setState(() {
        _coverUrl = picked;
        _localCoverBytes = null;
      });
    }
  }

  /// 本地图片 → 480 宽 PNG 字节 → 传服务端 `/uploadimage`，拿回可访问的 URL。
  ///
  /// 上传成功后把 URL 写进 `_coverUrl`，保存时随 `/saveBookInfo` 一起入库。
  /// 预览用 `_localCoverBytes` 直接画内存字节 —— 不等网络回显，也避免
  /// 服务端静态目录跟上传目录对不上时，「明明传成功了但封面转圈」。
  Future<void> _uploadImage() async {
    const group = XTypeGroup(
      label: '图片',
      extensions: ['jpg', 'jpeg', 'png', 'webp'],
    );
    try {
      final file = await openFile(acceptedTypeGroups: [group]);
      if (file == null) return;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) {
        _toast('图片是空的');
        return;
      }
      final png = await _encodeCover(bytes);
      if (png == null || png.isEmpty) {
        _toast('图片读取失败');
        return;
      }
      if (!mounted) return;
      setState(() => _loadingSource = true);
      String url;
      try {
        url = await ApiService.instance.uploadImage(widget.token, png);
      } catch (e) {
        _toast('上传失败：${friendlyError(e)}');
        return;
      } finally {
        if (mounted) setState(() => _loadingSource = false);
      }
      if (!mounted) return;
      setState(() {
        _coverUrl = url;
        _localCoverBytes = png;
      });
    } catch (e) {
      _toast('上传失败：${friendlyError(e)}');
    }
  }

  /// 把任意格式图片解码后统一转成 480 宽的 PNG 字节。
  ///
  /// 服务端按 md5 存文件，统一格式能让同一张图无论来源是 jpg 还是 webp
  /// 都得到同一个文件名，避免重复占用 `assets/images`。
  Future<Uint8List?> _encodeCover(Uint8List bytes) async {
    ui.Codec? codec;
    ui.Image? image;
    try {
      codec = await ui.instantiateImageCodec(bytes, targetWidth: 480);
      final frame = await codec.getNextFrame();
      image = frame.image;
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return null;
      return data.buffer
          .asUint8List(data.offsetInBytes, data.lengthInBytes);
    } finally {
      image?.dispose();
      codec?.dispose();
    }
  }

  Future<void> _inputLink() async {
    final ctl = TextEditingController(
      text: _coverUrl.startsWith('http') ? _coverUrl : '',
    );
    final link = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('输入图片链接'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: 'https://...',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final text = ctl.text.trim();
              if (text.isEmpty) return;
              Navigator.pop(ctx, text);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (link != null && mounted) {
      setState(() {
        _coverUrl = link;
        _localCoverBytes = null;
      });
    }
  }

  // ---------------------------------------------------------------- 保存

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    final name = _nameCtl.text.trim();
    if (name.isEmpty) {
      _toast('书名不能为空');
      return;
    }
    final author = _authorCtl.text.trim();
    final intro = _introCtl.text.trim();
    setState(() => _saving = true);
    final book = widget.book;
    final oldName = book.name;
    final oldAuthor = book.author;
    final oldCover = book.coverUrl;
    final oldCustomCover = book.customCoverUrl;
    final oldIntro = book.intro;
    final oldCustomIntro = book.customIntro;
    void restore() {
      book.name = oldName;
      book.author = oldAuthor;
      book.coverUrl = oldCover;
      book.customCoverUrl = oldCustomCover;
      book.intro = oldIntro;
      book.customIntro = oldCustomIntro;
    }

    try {
      // /saveBookInfo 把 coverUrl / intro 写进 custom_cover_url / custom_intro，
      // 所以这里要先把展示值放回 coverUrl / intro 再提交。
      book.name = name;
      book.author = author;
      book.coverUrl = _coverUrl;
      book.customCoverUrl = _coverUrl;
      book.intro = intro;
      book.customIntro = intro;
      final resp = await ApiService.instance.saveBookInfo(widget.token, book);
      if (resp['isSuccess'] == false) {
        restore();
        if (mounted) setState(() => _saving = false);
        _toast(
            '保存失败：${friendlyServerMessage(resp['errorMsg']?.toString())}');
        return;
      }
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      restore();
      if (mounted) setState(() => _saving = false);
      _toast('保存失败：${friendlyError(e)}');
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }
}

/// 「请选择图片获取方式」弹窗
class _CoverSourceDialog extends StatelessWidget {
  const _CoverSourceDialog({required this.dark});

  final bool dark;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: dark ? const Color(0xFF23262B) : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 28),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 24, 22, 22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '请选择图片获取方式',
              style: TextStyle(
                fontSize: 21,
                fontWeight: FontWeight.w600,
                color: dark ? Colors.white : BookDetailStyle.title,
              ),
            ),
            const SizedBox(height: 24),
            _option(
              label: '书源搜索',
              icon: Icons.search,
              background: const Color(0xFF0AA0F5),
              foreground: Colors.white,
              onTap: () => Navigator.pop(context, 'search'),
            ),
            const SizedBox(height: 14),
            _option(
              label: '上传图片',
              icon: Icons.cloud_upload,
              background: const Color(0xFF00A88E),
              foreground: Colors.white,
              onTap: () => Navigator.pop(context, 'upload'),
            ),
            const SizedBox(height: 14),
            _option(
              label: '输入链接',
              icon: Icons.link,
              background: const Color(0xFFD5E9FF),
              foreground: const Color(0xFF1E6FD9),
              onTap: () => Navigator.pop(context, 'link'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _option({
    required String label,
    required IconData icon,
    required Color background,
    required Color foreground,
    required VoidCallback onTap,
  }) {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: Material(
        color: background,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 21, color: foreground),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: foreground,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
