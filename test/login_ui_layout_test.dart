// 登录页排版算法的单测。
//
// 覆盖的是 `layoutLoginUiLines`（lib/models/login_ui_layout.dart）——
// 它按 legado-E-main 里 `FlexboxLayout` 的语义分行并分配宽度：
//   - `layout_flexBasisPercent` 决定换行点（0.4 → 一行 2 个、0.27 → 3 个、1 → 整行）
//   - `layout_flexGrow` 决定把该行剩余空间按比例分掉
//   - 输入框（`layout_width="match_parent"`）必然独占一行
//
// 这些规则不是猜的，来自：
//   app/src/main/res/layout/dialog_login.xml          （容器是 FlexboxLayout + flexWrap=wrap）
//   app/src/main/res/layout/item_fillet_text.xml      （按钮 wrap_content）
//   app/src/main/res/layout/item_source_edit.xml      （输入框 match_parent）
//   .../data/entities/rule/FlexChildStyle.kt          （apply() 把 style 写进 LayoutParams）
//   flexbox 的 FlexboxHelper.calculateFlexLines / isWrapRequired（分行判定）
import 'package:flutter_test/flutter_test.dart';
import 'package:qread/models/login_ui_layout.dart';
import 'package:qread/models/row_ui.dart';

/// 内容宽度固定 100，方便断言 —— 只在书源没写 basis 时才用得上。
double _natural(RowUi row) => 100;

RowUi _btn(String name, {double? basis, double grow = 1, bool wrapBefore = false}) {
  final style = <String, dynamic>{
    'layout_flexGrow': grow,
    if (basis != null) 'layout_flexBasisPercent': basis,
    if (wrapBefore) 'layout_wrapBefore': true,
  };
  return RowUi.fromJson({
    'name': name,
    'type': 'button',
    'style': style,
  });
}

RowUi _text(String name) => RowUi.fromJson({'name': name, 'type': 'text'});

/// 完全没有 `style` 的按钮 —— 对应书源里既没写 basis 也没写 grow 的情况。
RowUi _plainBtn(String name) =>
    RowUi.fromJson({'name': name, 'type': 'button'});

List<List<int>> _shape(List<LoginUiLine> lines) =>
    lines.map((l) => l.indices).toList();

void main() {
  const w = 360.0;
  const gap = 6.0;

  List<LoginUiLine> lay(List<RowUi> rows) => layoutLoginUiLines(
        rows: rows,
        maxWidth: w,
        spacing: gap,
        naturalWidth: _natural,
      );

  test('RowUi 从 style 里解析出 grow / basis / wrapBefore', () {
    final a = _btn('a', basis: 0.4);
    expect(a.flexGrow, 1);
    expect(a.flexBasisPercent, 0.4);
    expect(a.wrapBefore, isFalse);

    // 没写 style → 保持 legado 的默认值
    final b = RowUi.fromJson({'name': 'b', 'type': 'button'});
    expect(b.flexGrow, 0);
    expect(b.flexBasisPercent, -1);
    expect(b.isFullWidth, isFalse);

    // 输入框 = match_parent
    expect(_text('c').isFullWidth, isTrue);
  });

  test('basis=1 的按钮独占整行', () {
    final lines = lay([_btn('标题', basis: 1), _btn('a', basis: 0.4), _btn('b', basis: 0.4)]);
    expect(_shape(lines), [
      [0],
      [1, 2],
    ]);
  });

  test('basis=0.4 → 一行 2 个；奇数时最后一个单独一行', () {
    final lines = lay([
      _btn('a', basis: 0.4),
      _btn('b', basis: 0.4),
      _btn('c', basis: 0.4),
    ]);
    expect(_shape(lines), [
      [0, 1],
      [2],
    ]);
  });

  test('basis=0.27/0.33 → 一行 3 个（0.27+0.33+0.27 = 0.87 ≤ 1）', () {
    final lines = lay([
      _btn('a', basis: 0.27),
      _btn('b', basis: 0.33),
      _btn('c', basis: 0.27),
    ]);
    expect(_shape(lines), [
      [0, 1, 2],
    ]);
  });

  test('basis=0.87 与 0.27 放不下同一行（0.87+0.27 > 1）', () {
    final lines = lay([
      _btn('长按钮', basis: 0.87),
      _btn('短按钮', basis: 0.27),
    ]);
    expect(_shape(lines), [
      [0],
      [1],
    ]);
  });

  test('输入框独占一行，且把按钮行断开', () {
    final lines = lay([
      _btn('a', basis: 0.4),
      _btn('b', basis: 0.4),
      _text('输入框'),
      _btn('c', basis: 0.4),
      _btn('d', basis: 0.4),
    ]);
    expect(_shape(lines), [
      [0, 1],
      [2],
      [3, 4],
    ]);
  });

  test('flexGrow 把该行撑满', () {
    final lines = lay([
      _btn('a', basis: 0.4),
      _btn('b', basis: 0.4),
    ]);
    expect(lines.single.widths[0]! + lines.single.widths[1]! + gap, closeTo(w, 0.01));
    // 两个 flexGrow 相同 → 各分到一半剩余空间 → 最终等宽
    expect(lines.single.widths[0], closeTo(lines.single.widths[1]!, 0.01));
  });

  test('flexGrow 不同 → 剩余空间按比例分', () {
    final lines = lay([
      _btn('a', basis: 0.4, grow: 1),
      _btn('b', basis: 0.4, grow: 3),
    ]);
    final w0 = lines.single.widths[0]!;
    final w1 = lines.single.widths[1]!;
    // free = 360 - 144 - 144 - 6 = 66；按 1:3 分 → +16.5 / +49.5
    expect(w0, closeTo(144 + 16.5, 0.01));
    expect(w1, closeTo(144 + 49.5, 0.01));
  });

  test('没写 basis 也没写 grow 的条目保持内容宽度（不约束）', () {
    final lines = lay([_plainBtn('a'), _plainBtn('b')]);
    expect(_shape(lines), [
      [0, 1],
    ]);
    expect(lines.single.widths, [null, null]);
  });

  test('layout_wrapBefore 强制换行', () {
    final lines = lay([
      _btn('a', basis: 0.4),
      _btn('b', basis: 0.4, wrapBefore: true),
    ]);
    expect(_shape(lines), [
      [0],
      [1],
    ]);
  });

  test('顺序与数量原样保留', () {
    final rows = [
      _btn('a', basis: 0.4),
      _text('t1'),
      _btn('b', basis: 1),
      _btn('c', basis: 0.27),
      _text('t2'),
    ];
    final lines = lay(rows);
    expect(lines.expand((l) => l.indices).toList(), [0, 1, 2, 3, 4]);
  });

  test('空输入 / 非法宽度不炸', () {
    expect(lay([]), isEmpty);
    expect(
      layoutLoginUiLines(
          rows: [_btn('a', basis: 0.4)],
          maxWidth: 0,
          spacing: gap,
          naturalWidth: _natural),
      isEmpty,
    );
  });
}
