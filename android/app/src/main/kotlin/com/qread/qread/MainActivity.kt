package com.qread.qread

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import android.view.View
import androidx.core.content.FileProvider
import androidx.core.content.IntentCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 阅读页的「全屏沉浸」：隐藏系统导航栏（底部手势条 / 三大金刚键）。
 *
 * 【为什么必须在原生侧做】
 * Flutter 的 `SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky)`
 * 底层是 `View.setSystemUiVisibility(SYSTEM_UI_FLAG_* | IMMERSIVE_STICKY)`。
 * 而从 Android 15（API 35）起系统强制 edge-to-edge，并**忽略**这些 flag ——
 * Flutter 引擎源码里也明确写着：
 *   "If the Flutter Android app targets Android SDK 15 (API 35) or later then
 *    the Android system will ignore this value unless the app also follows the
 *    opt out instructions."
 * 而那条 opt-out（`windowOptOutEdgeToEdgeEnforcement`）在 Android 16 上会崩。
 * 所以纯 Flutter 写法在现在的手机上是**完全无效**的 —— 这正是用户反馈
 * 「屏幕底部的小横条还是自动无法隐藏」的原因。
 *
 * 正确姿势是 `WindowInsetsControllerCompat.hide(navigationBars())` 配合
 * `BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE`：从 API 30 一直有效到 Android 16，
 * 且「滑一下临时出现、松手又自己收回去」，就是用户要的「自动隐藏」。
 * 状态栏保持不动（3.41 阅读时状态栏也是显示的）。
 *
 * ---------------------------------------------------------------------------
 *
 * 「打开方式」：把外部传来的 .json 文件交给 Dart 侧。
 *
 * 【为什么需要】
 * Manifest 里加了 VIEW / SEND 的 intent-filter 之后，系统「打开方式」里会出现
 * Qread。但**光有 intent-filter 不够** —— 还得有人真的把那个文件读出来、
 * 交给 Dart。这里就是这个「人」。
 *
 * 【两条路径，别搞混】
 *   - 冷启动（App 没在跑）：`configureFlutterEngine` 时 intent 里就有文件，
 *     但此刻 Dart 还没起来、方法通道还没人接。所以先**攒进 pendingFile**，
 *     等 Dart 主动调 `getInitialFile` 来取。
 *   - 热启动（App 已在后台）：走 `onNewIntent`，Dart 已经活着，
 *     直接 `invokeMethod("onFileOpened", …)` 推过去。
 *     万一推送失败（Dart 侧 handler 还没挂上），退回 pendingFile 兜底。
 *
 * 【为什么不引第三方插件】
 * `receive_sharing_intent` 之类要改 pubspec 并依赖其原生实现；
 * 本仓库本机没有 Flutter SDK、无法验证 pub 解析，一旦解析失败就是 CI 红。
 * 这里的逻辑只有几十行，自己开一个 MethodChannel 更可控。
 *
 * ---------------------------------------------------------------------------
 *
 * 「添加本地」：书架里主动选一个电子书文件。
 *
 * 【为什么要把文件复制一份出来】
 * 系统选择器（ACTION_OPEN_DOCUMENT）给回来的是 `content://` URI，
 * 而 Dart 侧上传用的是 dio 的 `MultipartFile.fromFile(path)`，它要的是**真实路径**。
 * `content://` 没法直接当路径用，所以这里先把内容拷进 App 私有缓存目录，
 * 再把路径交给 Dart。选完的文件会一直留在 `cacheDir/import_books/`，
 * 系统在空间紧张时会自行清理，不需要我们操心。
 *
 * ---------------------------------------------------------------------------
 *
 * 「导出文件」：把 Dart 拼好的 txt / json 交给系统分享面板。
 *
 * 【为什么移动端必须走分享面板，不能弹「另存为」】
 * Flutter 侧的 `file_selector` 只提供 `getSaveLocation()`，它底层调
 * `getSavePath()`，而**这个接口在 Android 上根本没实现** —— 直接调会抛
 * `UnimplementedError: getSavePath() has not been implemented.`
 * （官方支持表里 Android / iOS / Web 三端都是 ❌，只有桌面三端是 ✔）。
 * Android 的标准做法就是 `ACTION_SEND` + `FileProvider`，用户在面板里
 * 选「保存到文件」（文件 App）即可落盘，且**不需要任何存储权限**。
 *
 * 【为什么由原生写文件，而不是 Dart 写完再传路径】
 * Dart 侧要写文件就得引 `dart:io` + `path_provider`，而网页版编不过
 * （本仓库为此专门做了 `cache_store.dart` 那套条件导入）。让原生直接收
 * `byte[]` 落进 `cacheDir` 最省事，Dart 那边一行平台判断都不用写。
 */
class MainActivity : FlutterActivity() {

    private val systemUiChannelName = "qread/system_ui"
    private val fileOpenChannelName = "qread/file_open"
    private val filePickChannelName = "qread/file_pick"
    private val dictionaryChannelName = "qread/dictionary"
    private val shareFileChannelName = "qread/share_file"

    private val requestPickBook = 10021

    /** 导出文件落在这里；FileProvider 的 file_paths.xml 只放行这一个子目录。 */
    private val exportDirName = "export"

    /**
     * 选择器要展示的文件类型。
     *
     * 只写后缀是没用的 —— 文件选择器认 MIME。
     * `application/octet-stream` 是兜底：不少文件管理器（尤其国产 ROM）
     * 对 .azw3 / .prc 报的就是这个，不给它就会变成灰色不可选。
     */
    private val bookMimeTypes = arrayOf(
        "text/plain",                     // .txt
        "application/epub+zip",           // .epub
        "application/x-mobipocket-ebook", // .mobi / .prc
        "application/vnd.amazon.ebook",   // .azw
        "application/octet-stream"        // .azw3 等
    )

    /** 已收到但还没交给 Dart 的文件；Dart 取走后置空。 */
    private var pendingFile: Map<String, String>? = null

    private var fileOpenChannel: MethodChannel? = null

    /** 正在等待结果的文件选择框。同一时刻只允许一个。 */
    private var pendingPickResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, systemUiChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hideNavigationBar" -> {
                        hideNavigationBar()
                        result.success(true)
                    }
                    "showSystemBars" -> {
                        showSystemBars()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        fileOpenChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, fileOpenChannelName)
        fileOpenChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                // Dart 侧就绪后主动来取「冷启动带进来的那个文件」。
                // 取走即清空 —— 否则用户下次从后台切回来会重复弹一次导入框。
                "getInitialFile" -> {
                    val file = pendingFile
                    pendingFile = null
                    result.success(file)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, filePickChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickBookFile" -> openBookPicker(result)
                    else -> result.notImplemented()
                }
            }

        // 阅读页长按选中文字后的「字典」。
        // 用 ACTION_PROCESS_TEXT 把选中的词交给系统里带词典 / 翻译能力的 App
        // （和 3.41 一样）。系统里一个都没有时返回 false，Dart 侧降级到网页词典。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, dictionaryChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "lookup" -> {
                        val text = call.argument<String>("text")?.trim().orEmpty()
                        result.success(
                            if (text.isEmpty()) false else openSystemDictionary(text)
                        )
                    }
                    else -> result.notImplemented()
                }
            }

        // 「导出文件」：Dart 把字节交过来，这里落盘 + 弹分享面板。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, shareFileChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "shareFile" -> {
                        val bytes = call.argument<ByteArray>("bytes")
                        val name = call.argument<String>("name")
                        if (bytes == null || name.isNullOrBlank()) {
                            result.error("BAD_ARGS", "缺少 bytes 或 name", null)
                        } else {
                            result.success(
                                shareBytes(
                                    bytes = bytes,
                                    name = name,
                                    mimeType = call.argument<String>("mimeType")
                                        ?: "application/octet-stream",
                                    title = call.argument<String>("title"),
                                )
                            )
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // 冷启动：此刻 Dart 还没起来，先攒着
        collectFromIntent(intent, deliverNow = false)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // 必须 setIntent，否则 getIntent() 还是旧的（框架不会自动更新）
        setIntent(intent)
        // 热启动：Dart 已经活着，直接推
        collectFromIntent(intent, deliverNow = true)
    }

    /**
     * 把选中的文字交给系统词典。
     *
     * `ACTION_PROCESS_TEXT` 是 Android 6.0+ 标准的「处理这段文本」入口，
     * 装了词典 / 翻译类 App 的设备会弹出选择器。
     *
     * 返回 false 表示系统里没有任何 App 能处理它 —— Dart 侧据此降级到网页词典，
     * 而不是弹一个「无应用可执行」的空选择器。
     */
    @Suppress("DEPRECATION")
    private fun openSystemDictionary(text: String): Boolean {
        return try {
            val intent = Intent(Intent.ACTION_PROCESS_TEXT).apply {
                type = "text/plain"
                putExtra(Intent.EXTRA_PROCESS_TEXT, text)
                putExtra(Intent.EXTRA_PROCESS_TEXT_READONLY, true)
            }
            if (packageManager.queryIntentActivities(intent, 0).isEmpty()) {
                return false
            }
            startActivity(Intent.createChooser(intent, "词典"))
            true
        } catch (e: Exception) {
            false
        }
    }

    // ==================================================================
    // 「打开方式」/「分享」的文件读取
    // ==================================================================

    private fun collectFromIntent(intent: Intent?, deliverNow: Boolean) {
        val payload = readFileFromIntent(intent) ?: return
        val channel = fileOpenChannel
        if (deliverNow && channel != null) {
            channel.invokeMethod("onFileOpened", payload, object : MethodChannel.Result {
                override fun success(result: Any?) {}

                override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                    pendingFile = payload
                }

                override fun notImplemented() {
                    pendingFile = payload
                }
            })
        } else {
            pendingFile = payload
        }
    }

    /**
     * 从 intent 里取出文件内容。
     *
     * 支持两种入口：
     *   - `ACTION_VIEW`：点「用其他应用打开」，文件在 `intent.data`（content:// 或 file://）
     *   - `ACTION_SEND`：点「分享」，正文在 `EXTRA_TEXT`（纯文本分享），
     *     或者附件在 `EXTRA_STREAM`（文件分享）
     */
    private fun readFileFromIntent(intent: Intent?): Map<String, String>? {
        if (intent == null) return null
        return when (intent.action) {
            Intent.ACTION_VIEW -> intent.data?.let { readUri(it) }

            Intent.ACTION_SEND -> {
                // 纯文本分享优先：微信/浏览器「分享」过来的往往就是正文
                val text = intent.getStringExtra(Intent.EXTRA_TEXT)
                if (!text.isNullOrBlank()) {
                    return mapOf("name" to "分享内容.json", "content" to text)
                }
                // IntentCompat 而不是 getParcelableExtra：后者在 API 33+ 已废弃，
                // 直接用会在 targetSdk 35 下报 deprecation 警告
                val stream: Uri? = IntentCompat.getParcelableExtra(
                    intent, Intent.EXTRA_STREAM, Uri::class.java
                )
                stream?.let { readUri(it) }
            }

            else -> null
        }
    }

    /**
     * 读一个 content:// 或 file:// 的文件。失败一律返回 null（不要崩）。
     *
     * 【返回形态】
     *   - 二进制书籍（epub / mobi）：`{name, path}` —— 内容不读，读出来也是坏的；
     *   - 纯文本（书源 json / txt）：`{name, content, path}` —— 内容给书源导入用，
     *     路径留着，万一是 txt 小说就转去上传。
     *
     * 【为什么都要复制一份】
     * `ACTION_VIEW` 给回来的是 `content://` URI，这个 URI 的读取权限只在本次
     * 回调期间有效，而且 dio 上传要的是真实路径。复制进缓存目录两件事一起解决。
     */
    private fun readUri(uri: Uri): Map<String, String>? {
        val name = displayName(uri) ?: "导入文件"
        val copied = copyUriToCache(uri) ?: return null
        val path = copied["path"] ?: return null

        val result = mutableMapOf("name" to name, "path" to path)
        if (isTextLike(name)) {
            val content = try {
                File(path).readText(Charsets.UTF_8)
            } catch (_: Exception) {
                null
            }
            if (!content.isNullOrBlank()) result["content"] = content
        }
        return result
    }

    private fun isTextLike(name: String): Boolean {
        val lower = name.lowercase()
        return lower.endsWith(".json") || lower.endsWith(".txt")
    }

    /** 取文件名。`content://` 要走 OpenableColumns，`file://` 直接取末段。 */
    private fun displayName(uri: Uri): String? {
        if (uri.scheme != "content") return uri.lastPathSegment
        return try {
            contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index >= 0 && cursor.moveToFirst()) cursor.getString(index) else null
            }
        } catch (_: Exception) {
            null
        }
    }

    // ==================================================================
    // 「导出文件」的分享
    // ==================================================================

    /**
     * 把字节写成文件再交给系统分享面板。
     *
     * 【为什么必须先落盘】`ACTION_SEND` 传的是 URI，不是字节流。
     * 而我们自己私有目录里的文件不能直接把 `file://` 路径给对方 ——
     * Android 7(N) 起 `FileUriExposedException` 会直接崩，必须经
     * `FileProvider` 换成 `content://`。
     *
     * 【为什么要 FLAG_GRANT_READ_URI_PERMISSION】`content://` 默认不对
     * 接收方开放；不授权的话对方打开就是「文件不存在 / 无权限」。
     * chooser 上也加一份，因为部分 ROM 是拿 chooser 的 flag 去授权的。
     *
     * @return false 表示没有任何 App 能接收（Dart 侧据此提示用户），
     *         异常一律吞掉返回 false —— 导出失败不该让 App 崩。
     */
    private fun shareBytes(
        bytes: ByteArray,
        name: String,
        mimeType: String,
        title: String?,
    ): Boolean {
        return try {
            // 文件名可能带 `/`（书名里出现斜杠），不处理会写到别的目录去。
            val safeName = name.replace('/', '_').replace('\\', '_')

            val dir = File(cacheDir, exportDirName)
            if (!dir.exists()) dir.mkdirs()
            // 同名直接覆盖：`writeBytes` 是截断写，不会残留旧内容；
            // 但先删一次能顺带清掉「上一次写了一半」的坏文件。
            val target = File(dir, safeName)
            if (target.exists()) target.delete()
            target.writeBytes(bytes)

            val uri: Uri = FileProvider.getUriForFile(
                this, "$packageName.fileprovider", target
            )
            val send = Intent(Intent.ACTION_SEND).apply {
                type = mimeType
                putExtra(Intent.EXTRA_STREAM, uri)
                putExtra(Intent.EXTRA_TITLE, title ?: safeName)
                if (!title.isNullOrBlank()) putExtra(Intent.EXTRA_SUBJECT, title)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            val chooser = Intent.createChooser(send, title ?: safeName).apply {
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(chooser)
            true
        } catch (_: Exception) {
            false
        }
    }

    // ==================================================================
    // 「添加本地」的文件选择
    // ==================================================================

    private fun openBookPicker(result: MethodChannel.Result) {
        if (pendingPickResult != null) {
            result.error("BUSY", "已经有一个文件选择框打开了", null)
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_MIME_TYPES, bookMimeTypes)
        }
        try {
            pendingPickResult = result
            startActivityForResult(intent, requestPickBook)
        } catch (e: Exception) {
            // 极少数精简系统上没有任何文件选择器
            pendingPickResult = null
            result.error("NO_PICKER", "系统里没有可用的文件选择器", e.message)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != requestPickBook) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val result = pendingPickResult
        pendingPickResult = null
        if (result == null) return

        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) {
            // 用户点了返回 / 取消：不是错误，回 null 让 Dart 静默处理
            result.success(null)
            return
        }
        val copied = copyUriToCache(uri)
        if (copied == null) {
            result.error("READ_FAILED", "读取所选文件失败", null)
        } else {
            result.success(copied)
        }
    }

    /** 把 content:// 的内容拷进 App 缓存目录，返回 {path, name}。 */
    private fun copyUriToCache(uri: Uri): Map<String, String>? {
        return try {
            val name = displayName(uri) ?: "book_${System.currentTimeMillis()}"
            val dir = File(cacheDir, "import_books")
            if (!dir.exists()) dir.mkdirs()
            val target = File(dir, name)
            val stream = contentResolver.openInputStream(uri) ?: return null
            stream.use { input ->
                target.outputStream().use { output -> input.copyTo(output) }
            }
            mapOf("path" to target.absolutePath, "name" to name)
        } catch (_: Exception) {
            null
        }
    }

    // ==================================================================
    // 全屏沉浸
    // ==================================================================

    private fun hideNavigationBar() {
        val window = window ?: return
        val controller = WindowInsetsControllerCompat(window, window.decorView)
        // 划一下临时出现，松手后自己收回去
        controller.systemBarsBehavior =
            WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            controller.hide(WindowInsetsCompat.Type.navigationBars())
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility =
                window.decorView.systemUiVisibility or
                    View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
                    View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or
                    View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or
                    View.SYSTEM_UI_FLAG_LAYOUT_STABLE
        }
    }

    private fun showSystemBars() {
        val window = window ?: return
        val controller = WindowInsetsControllerCompat(window, window.decorView)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            controller.show(WindowInsetsCompat.Type.systemBars())
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_LAYOUT_STABLE
        }
    }
}
