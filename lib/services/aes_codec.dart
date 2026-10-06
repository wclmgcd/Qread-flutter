import 'dart:convert';
import 'dart:typed_data';

/// 后端 cookie 接口那层 AES 的 Dart 侧复刻。
///
/// 后端 `web/util/hash/aes.kt` 的 `EncryptUtils` 用的是一对**硬编码常量**：
///
///   key = "jhznhuanbznjuyqa"   (16 字节 → AES-128)
///   iv  = "jnzhyavblkjhsquy"   (16 字节)
///   模式 = AES/CBC/PKCS5Padding
///   输出 = **大写 hex**（后端 `bytesToHex` 用的是 `String.format("%02X", ...)`）
///
/// 上游 `/getCookies` 返回的就是这层加密后的 hex；`/saveCookies` 收的入参
/// 也是同一个形状（后端会先 `aesDecrypted` 再落盘）。所以客户端要跟这两个
/// 接口打交道，就必须能自己加解密。
///
/// 【为什么内置实现，而不是依赖 pub 上的 encrypt / pointycastle】
/// 本机没有 Flutter SDK，`flutter pub get` 跑不了 —— 新增依赖能否在 Flutter
/// 工程里解析出来无法验证，而 CI 一轮往返代价不小。这里需要的只是一个固定
/// 密钥的 AES-128-CBC，纯计算、可以用标准测试向量完整对拍，所以内置。
///
/// S 盒也**不写 256 字节的表**，而是按定义现算（GF(2⁸) 求逆 + 仿射变换），
/// 少一处抄错的机会；算一次后缓存。
///
/// 注意：密钥是公开硬编码的，这层加密只有混淆价值，不是安全边界 ——
/// 与后端注释里的判断一致。
class AesCodec {
  AesCodec._();

  static const String _keyStr = 'jhznhuanbznjuyqa';
  static const String _ivStr = 'jnzhyavblkjhsquy';

  static final Uint8List _keyBytes = Uint8List.fromList(utf8.encode(_keyStr));
  static final Uint8List _ivBytes = Uint8List.fromList(utf8.encode(_ivStr));

  static List<int>? _sboxCache;
  static List<int>? _invSboxCache;
  static List<List<int>>? _roundKeysCache;

  // ============================================================
  // 对外
  // ============================================================

  /// 明文 → 大写 hex 密文。对应后端 `EncryptUtils.aesEncode`。
  static String encrypt(String plain) {
    final padded = _padPkcs7(utf8.encode(plain));
    final out = Uint8List(padded.length);
    // CBC：每一块先与上一块密文异或，第一块用 IV
    final prev = Uint8List.fromList(_ivBytes);
    final block = Uint8List(16);
    for (var off = 0; off < padded.length; off += 16) {
      for (var i = 0; i < 16; i++) {
        block[i] = padded[off + i] ^ prev[i];
      }
      final enc = _encryptBlock(block);
      out.setRange(off, off + 16, enc);
      prev.setAll(0, enc);
    }
    return _toHex(out);
  }

  /// hex 密文 → 明文。对应后端 `EncryptUtils.aesDecrypted`。
  ///
  /// 后端返回空 cookie 时也会是一段合法的密文（空串 PKCS5 补成一个整块），
  /// 所以这里解出来就是空串，不会抛。
  static String decrypt(String hex) {
    final data = _fromHex(hex);
    if (data.isEmpty) return '';
    if (data.length % 16 != 0) {
      throw const FormatException('AES 密文长度不是 16 的整数倍');
    }
    final out = Uint8List(data.length);
    final prev = Uint8List.fromList(_ivBytes);
    final block = Uint8List(16);
    for (var off = 0; off < data.length; off += 16) {
      block.setRange(0, 16, data, off);
      final dec = _decryptBlock(block);
      for (var i = 0; i < 16; i++) {
        out[off + i] = dec[i] ^ prev[i];
      }
      prev.setAll(0, block);
    }
    return utf8.decode(_unpadPkcs7(out), allowMalformed: true);
  }

  // ============================================================
  // 分组加解密（状态按列优先：state[row + 4*col]）
  // ============================================================

  static Uint8List _encryptBlock(Uint8List input) {
    final keys = _roundKeys();
    final s = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      s[i] = input[i] ^ keys[0][i];
    }
    for (var round = 1; round <= 10; round++) {
      _subBytes(s);
      _shiftRows(s);
      if (round != 10) _mixColumns(s);
      for (var i = 0; i < 16; i++) {
        s[i] ^= keys[round][i];
      }
    }
    return s;
  }

  static Uint8List _decryptBlock(Uint8List input) {
    final keys = _roundKeys();
    final s = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      s[i] = input[i] ^ keys[10][i];
    }
    for (var round = 9; round >= 0; round--) {
      _invShiftRows(s);
      _invSubBytes(s);
      for (var i = 0; i < 16; i++) {
        s[i] ^= keys[round][i];
      }
      if (round != 0) _invMixColumns(s);
    }
    return s;
  }

  static void _subBytes(Uint8List s) {
    final box = _sbox();
    for (var i = 0; i < 16; i++) {
      s[i] = box[s[i]];
    }
  }

  static void _invSubBytes(Uint8List s) {
    final box = _invSbox();
    for (var i = 0; i < 16; i++) {
      s[i] = box[s[i]];
    }
  }

  /// 行 r 循环左移 r 字节
  static void _shiftRows(Uint8List s) {
    for (var r = 1; r < 4; r++) {
      final row = <int>[s[r], s[r + 4], s[r + 8], s[r + 12]];
      for (var c = 0; c < 4; c++) {
        s[r + 4 * c] = row[(c + r) % 4];
      }
    }
  }

  /// 行 r 循环右移 r 字节
  static void _invShiftRows(Uint8List s) {
    for (var r = 1; r < 4; r++) {
      final row = <int>[s[r], s[r + 4], s[r + 8], s[r + 12]];
      for (var c = 0; c < 4; c++) {
        s[r + 4 * c] = row[(c - r + 4) % 4];
      }
    }
  }

  static void _mixColumns(Uint8List s) {
    for (var c = 0; c < 4; c++) {
      final i = c * 4;
      final a0 = s[i], a1 = s[i + 1], a2 = s[i + 2], a3 = s[i + 3];
      s[i] = _gmul(a0, 2) ^ _gmul(a1, 3) ^ a2 ^ a3;
      s[i + 1] = a0 ^ _gmul(a1, 2) ^ _gmul(a2, 3) ^ a3;
      s[i + 2] = a0 ^ a1 ^ _gmul(a2, 2) ^ _gmul(a3, 3);
      s[i + 3] = _gmul(a0, 3) ^ a1 ^ a2 ^ _gmul(a3, 2);
    }
  }

  static void _invMixColumns(Uint8List s) {
    for (var c = 0; c < 4; c++) {
      final i = c * 4;
      final a0 = s[i], a1 = s[i + 1], a2 = s[i + 2], a3 = s[i + 3];
      s[i] = _gmul(a0, 14) ^ _gmul(a1, 11) ^ _gmul(a2, 13) ^ _gmul(a3, 9);
      s[i + 1] = _gmul(a0, 9) ^ _gmul(a1, 14) ^ _gmul(a2, 11) ^ _gmul(a3, 13);
      s[i + 2] = _gmul(a0, 13) ^ _gmul(a1, 9) ^ _gmul(a2, 14) ^ _gmul(a3, 11);
      s[i + 3] = _gmul(a0, 11) ^ _gmul(a1, 13) ^ _gmul(a2, 9) ^ _gmul(a3, 14);
    }
  }

  // ============================================================
  // 轮密钥（AES-128 → 11 组 × 16 字节）
  // ============================================================

  static List<List<int>> _roundKeys() {
    final cached = _roundKeysCache;
    if (cached != null) return cached;

    final w = List<List<int>>.generate(44, (_) => List<int>.filled(4, 0));
    for (var i = 0; i < 4; i++) {
      for (var j = 0; j < 4; j++) {
        w[i][j] = _keyBytes[i * 4 + j];
      }
    }

    final box = _sbox();
    const rcon = <int>[0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1B, 0x36];
    for (var i = 4; i < 44; i++) {
      var temp = List<int>.from(w[i - 1]);
      if (i % 4 == 0) {
        // RotWord → SubWord → 异或轮常量
        temp = <int>[box[temp[1]], box[temp[2]], box[temp[3]], box[temp[0]]];
        temp[0] ^= rcon[i ~/ 4 - 1];
      }
      for (var j = 0; j < 4; j++) {
        w[i][j] = w[i - 4][j] ^ temp[j];
      }
    }

    final keys = List<List<int>>.generate(11, (r) {
      final k = List<int>.filled(16, 0);
      for (var c = 0; c < 4; c++) {
        for (var j = 0; j < 4; j++) {
          k[c * 4 + j] = w[r * 4 + c][j];
        }
      }
      return k;
    });
    _roundKeysCache = keys;
    return keys;
  }

  // ============================================================
  // GF(2⁸) 与 S 盒（按定义现算）
  // ============================================================

  /// GF(2⁸) 乘法，模 AES 既约多项式 x⁸+x⁴+x³+x+1（0x11B）
  static int _gmul(int a, int b) {
    var p = 0;
    var x = a & 0xFF;
    var y = b & 0xFF;
    for (var i = 0; i < 8; i++) {
      if ((y & 1) != 0) p ^= x;
      final hi = x & 0x80;
      x = (x << 1) & 0xFF;
      if (hi != 0) x ^= 0x1B;
      y >>= 1;
    }
    return p & 0xFF;
  }

  static List<int> _sbox() {
    final cached = _sboxCache;
    if (cached != null) return cached;
    final box = List<int>.filled(256, 0);
    for (var i = 0; i < 256; i++) {
      // 仿射变换：b = x ⊕ rotl(x,1) ⊕ rotl(x,2) ⊕ rotl(x,3) ⊕ rotl(x,4) ⊕ 0x63
      // 其中 x 是 i 在 GF(2⁸) 里的乘法逆元（0 的逆元按 0 处理）
      var r = i == 0 ? 0 : _gpowy(i, 254);
      var s = r;
      for (var k = 0; k < 4; k++) {
        r = ((r << 1) | (r >> 7)) & 0xFF;
        s ^= r;
      }
      box[i] = s ^ 0x63;
    }
    _sboxCache = box;
    return box;
  }

  static List<int> _invSbox() {
    final cached = _invSboxCache;
    if (cached != null) return cached;
    final box = _sbox();
    final inv = List<int>.filled(256, 0);
    for (var i = 0; i < 256; i++) {
      inv[box[i]] = i;
    }
    _invSboxCache = inv;
    return inv;
  }

  /// GF(2⁸) 幂：aⁿ（a = 0 时恒为 0）
  static int _gpowy(int a, int n) {
    var r = 1;
    for (var i = 0; i < n; i++) {
      r = _gmul(r, a);
    }
    return r;
  }

  // ============================================================
  // PKCS#5/7 填充 与 hex
  // ============================================================

  /// 块长 16 时 PKCS#5 与 PKCS#7 等价：补 `16 - len % 16` 个该字节
  static Uint8List _padPkcs7(List<int> data) {
    final pad = 16 - (data.length % 16);
    final out = Uint8List(data.length + pad);
    out.setRange(0, data.length, data);
    for (var i = data.length; i < out.length; i++) {
      out[i] = pad;
    }
    return out;
  }

  static List<int> _unpadPkcs7(List<int> data) {
    if (data.isEmpty) return const <int>[];
    final pad = data.last;
    if (pad < 1 || pad > 16 || pad > data.length) return data;
    // 尾部 pad 个字节必须都等于 pad，否则说明不是我们补的，原样返回
    for (var i = data.length - pad; i < data.length; i++) {
      if (data[i] != pad) return data;
    }
    return data.sublist(0, data.length - pad);
  }

  static String _toHex(List<int> bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write((b & 0xFF).toRadixString(16).padLeft(2, '0').toUpperCase());
    }
    return sb.toString();
  }

  static Uint8List _fromHex(String hex) {
    var s = hex.trim();
    if (s.isEmpty) return Uint8List(0);
    if (s.length.isOdd) s = '0$s';
    final out = Uint8List(s.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      final byte = int.tryParse(s.substring(i * 2, i * 2 + 2), radix: 16);
      if (byte == null) {
        throw FormatException('非法 hex 字符: ${s.substring(i * 2, i * 2 + 2)}');
      }
      out[i] = byte;
    }
    return out;
  }
}
