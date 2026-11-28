package uk.drache.spicychatqol

import android.content.Context
import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import android.webkit.JavascriptInterface
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.util.ArrayDeque
import java.util.UUID

/** DS_ANDROID_033_PRIVATE_ENGINE_V1: a lazy, local-only origin for the reviewed
 * upstream IndexedDB engines. No remote content or generic script evaluation.
 * This worker is never attached to the Flutter view hierarchy. */
internal class QolPrivateStorage(private val context: Context) {
    private companion object {
        const val ORIGIN = "https://qol-android-storage.invalid/"
        const val MAX_CHARS = 16 * 1024 * 1024
        const val IDLE_MS = 150_000L // exceeds upstream Settings clear review window
    }
    private data class Work(val id: String, val message: String, val url: String,
                            val settings: Boolean, val reply: MethodChannel.Result)
    private val handler = Handler(Looper.getMainLooper())
    private val queue = ArrayDeque<Work>()
    private var queuedChars = 0
    private var active: Work? = null
    private var web: WebView? = null
    private var nonce = ""
    private var ready = false
    private var installed = false
    private var timeout: Runnable? = null
    private val idle = Runnable { if (active == null && queue.isEmpty()) dropWebView() }
    private val quotaActions = setOf("record", "summary", "bind", "scopeInfo", "gap", "clear", "resetEstimate", "export", "historyTime", "nativeNotice")
    private val exportActions = setOf("get", "page", "commit", "append", "clear", "release", "download-status")
    private fun failure(reply: MethodChannel.Result, reason: String) {
        reply.success(JSONObject().put("ok", false).put("error", reason).toString())
    }
    fun request(message: String, url: String, settings: Boolean, reply: MethodChannel.Result) {
        if (message.isEmpty() || message.length > MAX_CHARS || queue.size >= 16 || queuedChars + message.length > MAX_CHARS) {
            failure(reply, "Private storage busy or request exceeds bounded size; retry"); return
        }
        try {
            val obj = JSONObject(message)
            val action = obj.optString("action")
            val type = obj.optString("type")
            val allowed = if (settings) type == "DS_CHAT_EXPORT_CHECKPOINT" && action in setOf("settings-overview", "settings-clear")
                else (type == "DS_GENERATION_QUOTA_RESEARCH" && action in quotaActions) ||
                     (type == "DS_CHAT_EXPORT_CHECKPOINT" && action in exportActions)
            val uri = android.net.Uri.parse(url)
            if (!allowed || (!settings && (uri.scheme != "https" || uri.host !in setOf("spicychat.ai", "www.spicychat.ai")))) {
                failure(reply, "Invalid private storage scope"); return
            }
        } catch (_: Exception) { failure(reply, "Invalid private storage request"); return }
        handler.removeCallbacks(idle)
        queue.addLast(Work(UUID.randomUUID().toString(), message, url, settings, reply))
        queuedChars += message.length
        if (web == null) start() else pump()
    }
    @Suppress("SetJavaScriptEnabled", "DEPRECATION")
    private fun start() {
        try {
            val engine = context.assets.open("flutter_assets/assets/native/qol-private-engine-033.js").bufferedReader(Charsets.UTF_8).use { it.readText() }
            val view = WebView(context)
            web = view; nonce = UUID.randomUUID().toString(); ready = false; installed = false
            val key = nonce
            view.settings.apply {
                javaScriptEnabled = true
                domStorageEnabled = true
                blockNetworkLoads = true
                allowFileAccess = false
                allowContentAccess = false
                allowFileAccessFromFileURLs = false
                allowUniversalAccessFromFileURLs = false
                javaScriptCanOpenWindowsAutomatically = false
                setSupportMultipleWindows(false)
                mixedContentMode = android.webkit.WebSettings.MIXED_CONTENT_NEVER_ALLOW
            }
            view.addJavascriptInterface(Receipt(), "QolPrivateReceipt")
            view.webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest) = true
                override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse =
                    WebResourceResponse("text/plain", "UTF-8", 403, "Forbidden", emptyMap(), ByteArrayInputStream(byteArrayOf()))
                override fun onPageStarted(view: WebView, url: String, favicon: Bitmap?) {
                    if (web === view && url != ORIGIN && url != "about:blank") failAll("Private storage origin changed")
                }
                override fun onPageFinished(view: WebView, url: String) {
                    if (web !== view || key != nonce || installed || url != ORIGIN) return
                    installed = true
                    view.evaluateJavascript(engine + "\n;QolPrivateReceipt.ready(${JSONObject.quote(key)}, Boolean(globalThis.__qolPrivateDispatch && indexedDB && isSecureContext && crypto.randomUUID));", null)
                }
                @android.annotation.TargetApi(26)
                override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
                    if (web === view) failAll("Private storage renderer exited; committed data retained")
                    return true
                }
            }
            armTimeout(10_000L, "Private storage startup timed out")
            view.loadDataWithBaseURL(ORIGIN,
                "<!doctype html><meta charset=utf-8><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'unsafe-inline'; connect-src 'none'; frame-src 'none'; object-src 'none'\"><title>QoL local storage</title>",
                "text/html", "UTF-8", ORIGIN)
        } catch (_: Exception) { failAll("Private storage initialization failed") }
    }
    private inner class Receipt {
        @JavascriptInterface fun ready(key: String, available: Boolean) {
            handler.post {
                if (key != nonce || web == null || ready) return@post
                if (!available) { failAll("Private IndexedDB unavailable"); return@post }
                clearTimeout(); ready = true; pump()
            }
        }
        @JavascriptInterface fun complete(key: String, id: String, value: String) {
            handler.post {
                val work = active ?: return@post
                if (key != nonce || id != work.id) return@post
                active = null; clearTimeout()
                if (value.length > MAX_CHARS) failure(work.reply, "Private storage response too large; data retained")
                else work.reply.success(value)
                pump()
            }
        }
    }
    private fun pump() {
        val view = web ?: return
        if (!ready || active != null) return
        handler.removeCallbacks(idle)
        val work = queue.pollFirst()
        if (work == null) { handler.postDelayed(idle, IDLE_MS); return }
        queuedChars -= work.message.length; active = work
        armTimeout(if (work.message.contains("\"DS_GENERATION_QUOTA_RESEARCH\"")) 13_000L else 27_000L,
            "Private storage reply unconfirmed; reopen to verify committed state")
        try {
            view.evaluateJavascript("globalThis.__qolPrivateDispatch(${JSONObject.quote(nonce)},${JSONObject.quote(work.id)},${JSONObject.quote(work.message)},${JSONObject.quote(work.url)},${work.settings});", null)
        } catch (_: Exception) { failAll("Private storage dispatch failed") }
    }
    private fun armTimeout(delay: Long, reason: String) {
        clearTimeout(); val task = Runnable { failAll(reason) }; timeout = task; handler.postDelayed(task, delay)
    }
    private fun clearTimeout() { timeout?.let { handler.removeCallbacks(it) }; timeout = null }
    private fun dropWebView() {
        handler.removeCallbacks(idle); clearTimeout()
        val old = web; web = null; nonce = ""; ready = false; installed = false
        if (old != null) {
            try { old.removeJavascriptInterface("QolPrivateReceipt"); old.stopLoading(); old.destroy() } catch (_: Exception) {}
        }
    }
    private fun failAll(reason: String) {
        val previous = active; active = null
        val waiting = queue.toList(); queue.clear(); queuedChars = 0
        dropWebView()
        previous?.let { failure(it.reply, reason) }
        waiting.forEach { failure(it.reply, reason) }
    }
    fun shutdown() = failAll("Private storage context closed; reopen to resume")
    fun trimIfIdle() { if (active == null && queue.isEmpty() && ready) dropWebView() }
}
