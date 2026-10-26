package dev.svoi.app

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val workers = Executors.newFixedThreadPool(4)
    private val probes = Executors.newFixedThreadPool(2)
    private val control = Executors.newSingleThreadExecutor()
    private val backend by lazy { BackendClient(applicationContext) }
    private val main = Handler(Looper.getMainLooper())
    private var vpnResult: MethodChannel.Result? = null
    private var vpnBody: JSONObject? = null
    private var vpnToken = ""
    private var fileResult: MethodChannel.Result? = null
    private var exportResult: MethodChannel.Result? = null
    private var exportContent = ""

    override fun onDestroy() {
        control.execute { backend.close() }
        control.shutdown()
        workers.shutdown()
        probes.shutdown()
        super.onDestroy()
    }

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        MethodChannel(engine.dartExecutor.binaryMessenger, "dev.svoi/updates").setMethodCallHandler { call, result ->
            if (call.method == "install") {
                workers.execute {
                    try {
                        val intent = AndroidUpdates.get(applicationContext).installIntent()
                        main.post {
                            try { startActivity(intent); result.success(null) }
                            catch (e: Exception) { result.error("update", e.message, null) }
                        }
                    } catch (e: Exception) { main.post { result.error("update", e.message, null) } }
                }
            } else work(result) {
                val updates = AndroidUpdates.get(applicationContext)
                when (call.method) {
                    "status" -> updates.status()
                    "check" -> updates.check(call.argument<Boolean>("force") == true)
                    "download" -> updates.download()
                    "cancel" -> updates.cancel()
                    "settings" -> updates.settings(call.argument<Boolean>("autoCheck") != false, call.argument<Boolean>("autoDownload") == true)
                    else -> throw IllegalArgumentException("Неизвестная команда обновления")
                }.toString()
            }
        }
        MethodChannel(engine.dartExecutor.binaryMessenger, "dev.svoi/mobile").setMethodCallHandler { call, result ->
            if (call.method == "init") {
                work(result) { backend.request("init").toString() }
            } else if (call.method == "cancelProbe") {
                control.execute {
                    runCatching { backend.cancelProbe(call.argument<String>("id") ?: "") }
                    main.post { result.success(null) }
                }
            } else if (call.method == "request") {
                val path = call.argument<String>("path") ?: ""
                val token = call.argument<String>("token") ?: ""
                val body = call.argument<String>("body") ?: "{}"
                val method = call.argument<String>("method") ?: "GET"
                if (path == "connection/start") prepareVpn(token, JSONObject(body), result)
                else work(result, if (path.endsWith("/probe")) probes else workers) {
                    backend.request(path, method, token, body, call.argument<String>("probeID") ?: "").toString()
                }
            } else result.notImplemented()
        }
        MethodChannel(engine.dartExecutor.binaryMessenger, "dev.svoi/window").setMethodCallHandler { call, result ->
            when (call.method) {
                "ready", "show", "updateTray" -> result.success(null)
                "tray" -> { moveTaskToBack(true); result.success(null) }
                "close" -> { finish(); result.success(null) }
                "openExternal" -> {
                    val uri = android.net.Uri.parse(call.arguments as? String ?: "")
                    if (uri.scheme != "https" || uri.host.isNullOrBlank() || uri.userInfo != null) result.error("url", "Некорректная ссылка", null)
                    else try { startActivity(Intent(Intent.ACTION_VIEW, uri)); result.success(null) }
                    catch (e: Exception) { result.error("url", "Не удалось открыть ссылку", null) }
                }
                "openFile" -> {
                    if (fileResult != null) result.error("busy", "Выбор файла уже открыт", null)
                    else { fileResult = result; startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*"), 42) }
                }
                "exportText" -> {
                    if (exportResult != null) result.error("busy", "Сохранение файла уже открыто", null)
                    else {
                        exportResult = result
                        exportContent = call.argument<String>("content") ?: ""
                        startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE)
                            .setType("application/octet-stream").putExtra(Intent.EXTRA_TITLE, call.argument<String>("name") ?: "profile.json"), 43)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
    private fun work(result: MethodChannel.Result, executor: java.util.concurrent.Executor = workers, block: () -> String) {
        executor.execute {
            try { val value = block(); main.post { result.success(value) } }
            catch(e: Exception) { main.post { result.error(if (e is BackendClient.Failure) e.status.toString() else "backend", e.message, null) } }
        }
    }
    private fun prepareVpn(token: String, body: JSONObject, result: MethodChannel.Result) {
        if (vpnResult != null) { result.error("busy", "Ожидается разрешение VPN", null); return }
        vpnResult = result; vpnBody = body; vpnToken = token
        val permission = VpnService.prepare(this)
        if (permission != null) startActivityForResult(permission, 41) else launchVpn()
    }
    private fun launchVpn() {
        val result = vpnResult ?: return
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 44)
        }
        val body = vpnBody!!.toString()
        val token = vpnToken
        vpnResult = null; vpnBody = null; vpnToken = ""
        val intent = Intent(this, SvoiVpnService::class.java).setAction("foreground")
        try {
            if (Build.VERSION.SDK_INT >= 26) startForegroundService(intent) else startService(intent)
            work(result) { backend.request("connection/start", "POST", token, body).toString() }
        } catch (e: Exception) { result.error("vpn", e.message, null) }
    }
    @Deprecated("Activity result bridge")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == 41) {
            if (resultCode == Activity.RESULT_OK) launchVpn()
            else { vpnResult?.error("permission", "Для подключения разрешите создание VPN", null); vpnResult = null; vpnBody = null; vpnToken = "" }
        }
        if (requestCode == 42) {
            val result = fileResult ?: return
            fileResult = null
            val uri = data?.data
            if (resultCode != Activity.RESULT_OK || uri == null) { result.success(null); return }
            workers.execute {
                try {
                    val target = java.io.File(cacheDir, "import-profile.txt")
                    val bytes = contentResolver.openInputStream(uri)!!.use { input ->
                        val output = java.io.ByteArrayOutputStream()
                        val buffer = ByteArray(8192)
                        while (output.size() <= 8 * 1024 * 1024) {
                            val count = input.read(buffer)
                            if (count < 0) break
                            output.write(buffer, 0, count)
                        }
                        output.toByteArray()
                    }
                    if (bytes.size > 8 * 1024 * 1024) throw IllegalStateException("Файл слишком большой")
                    target.writeBytes(bytes)
                    main.post { result.success(target.absolutePath) }
                } catch(e: Exception) { main.post { result.error("file", e.message, null) } }
            }
        }
        if (requestCode == 43) {
            val result = exportResult ?: return
            val content = exportContent
            exportResult = null; exportContent = ""
            val uri = data?.data
            if (resultCode != Activity.RESULT_OK || uri == null) { result.success(null); return }
            workers.execute {
                try {
                    contentResolver.openOutputStream(uri, "wt")!!.use { it.write(content.toByteArray(Charsets.UTF_8)) }
                    main.post { result.success(null) }
                } catch(e: Exception) { main.post { result.error("file", e.message, null) } }
            }
        }
    }
}
