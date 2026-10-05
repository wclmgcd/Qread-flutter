# 内置中文字体

阅读器的「字体」一行对应 `lib/pages/reader/widgets/reader_fonts.dart`，
可选项与打包文件如下：

| 面板显示 | id | pubspec family | 源字体 | 授权 |
| --- | --- | --- | --- | --- |
| 默认 | `default` | —（跟随系统） | — | — |
| 谷歌 | `google` | `ReaderSans` | Noto Sans SC（谷歌思源黑体） | SIL OFL-1.1 |
| 宋体 | `song` | `ReaderSerif` | Noto Serif SC（思源宋体） | SIL OFL-1.1 |
| 圆体 | `round` | `ReaderRound` | 悠哉字体 Yozai | SIL OFL-1.1 |

每个 family 都注册了 400 / 700 两个字重文件，所以「粗细」开关改
`FontWeight` 就会命中真粗体，不走 Skia 的合成加粗（合成加粗在中文上会糊）。

## 为什么要内置字体

Android 上不指定 `fontFamily` 时，Flutter 会对每个字符单独走系统回退链。
同一段中文正文里，常用字和生僻字可能落到不同字体上，观感就是
「有的字是黑体、有的字是宋体」—— 也就是用户反馈的「字体不一」。
显式指定一个内置 family 后，正文所有字符都由同一字体渲染。

## 为什么不是直接打包全量字体

四款源字体加起来约 83 MB（Noto Sans SC 17 MB / Noto Serif SC 25 MB /
悠哉字体 15 MB ×2），全量打包会让 APK 膨胀到不可接受。因此做了两步压缩：

1. **子集化** —— 只保留 GB2312 全集（7445 字）+ ASCII + 常用标点/符号/假名，
   约 9800 个字符，覆盖 99.99% 的现代简体中文正文。
2. **实例化** —— Noto 两个字族是可变字体（`wght` 100–900），按 400 / 700
   各实例化一份静态字体。悠哉字体本身就是静态的，Regular 当常规、Medium 当加粗。

结果：6 个文件共约 20.9 MB。GB2312 覆盖率：

| 文件 | 覆盖率 |
| --- | --- |
| ReaderSans-Regular / Bold | 7445 / 7445 |
| ReaderSerif-Regular / Bold | 7445 / 7445 |
| ReaderRound-Regular / Bold | 7444 / 7445（缺 1 个制表符号） |

> 生僻字（GB2312 之外的 CJK 扩展字）仍会回退到系统字体，这是体积与覆盖率的
> 折中。若某本书大量使用生僻字，可把 `tool/subset_fonts.py` 里的字符集换成
> GBK 或 GB18030 后重新生成，代价是体积成倍增长。

## 为什么没有用「霞鹜文楷」等其它字体

选字体的硬门槛是 **GB2312 汉字零缺字**，否则缺的字会回退到系统字体，
又变成「字体不一」。实测过的候选：

| 候选 | GB2312 汉字缺失 | 结论 |
| --- | --- | --- |
| 霞鹜文楷 LXGW WenKai | 0 | 可用（本版未采用） |
| 悠哉字体 Yozai | 0 | **采用为「圆体」** |
| 站酷快乐体 / 庆科黄油体 | 553 | 淘汰 |
| jf open 粉圆 | 2092（简体大量缺失） | 淘汰 |

## 重新生成

```bash
pip install fonttools brotli
python tool/subset_fonts.py
```

源字体（约 74 MB）缓存在 `tool/.fonts-src/`，已 gitignore，不会进仓库。
`--no-download` 可跳过下载步骤。

生成脚本会自动修正字体的 name 表（family / subfamily / usWeightClass），
让内部名与 pubspec 声明一致。

## 授权

三款字体均为 SIL Open Font License 1.1，允许随应用分发、允许修改（子集化
属于修改）。分发时建议在「关于」页保留字体名称与授权说明。
