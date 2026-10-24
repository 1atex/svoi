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
    private val main = Handler(Looper.getMainLooper())
    private var vpnResult: MethodChannel.Result? = null
    private var vpnBody: JSONObject? = null
    private var vpnToken = ""
    private var fileResult: MethodChannel.Result? = null
    private var exportResult: MethodChannel.Result? = null
    private var exportContent = ""
    private class BackendError(val status: Int, message: String) : Exception(message)

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        MethodChannel(engine.dartExecutor.binaryMessenger, "dev.svoi/mobile").setMethodCallHandler { call, result ->
            if (call.method == "init") {
                work(result) { VpnRuntime.init(applicationContext); JSONObject().put("directory", filesDir.absolutePath).toString() }
            } else if (call.method == "request") {
                val path = call.argument<String>("path") ?: ""
                val token = call.argument<String>("token") ?: ""
                val body = JSONObject(call.argument<String>("body") ?: "{}")
                val method = call.argument<String>("method") ?: "GET"
                when {
                    path == "connection/start" -> prepareVpn(token, body, result)
                    path == "connection/stop" -> VpnRuntime.stop { reply(result, it) }
                    path == "connection/check" -> VpnRuntime.check { reply(result, it) }
                    path.startsWith("connection") -> result.success(VpnRuntime.status().toString())
                    path == "android/apps" -> work(result) { VpnRuntime.apps(applicationContext).toString() }
                    path == "android/routing" -> work(result) {
                        if (method == "PUT") VpnRuntime.saveRouting(applicationContext, body)
                        VpnRuntime.routing(applicationContext).toString()
                    }
                    path.endsWith("/probe") -> result.error("unsupported", "В Android-версии проверяйте связь после подключения.", null)
                    else -> work(result) {
                        val response = JSONObject(VpnRuntime.session!!.request(method, "/api/$path", token, body.toString()))
                        if (response.getInt("status") >= 400) throw BackendError(response.getInt("status"), response.getJSONObject("body").optString("error", "Ошибка сервиса"))
                        response.getJSONObject("body").toString()
                    }
                }
            } else result.notImplemented()
        }
        MethodChannel(engine.dartExecutor.binaryMessenger, "dev.svoi/window").setMethodCallHandler { call, result ->
            when (call.method) {
                "ready", "show", "updateTray" -> result.success(null)
                "tray" -> { moveTaskToBack(true); result.success(null) }
                "close" -> { finish(); result.success(null) }
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
    private fun work(result: MethodChannel.Result, block: () -> String) {
        workers.execute { try { val value = block(); main.post { result.success(value) } } catch(e: Exception) { main.post { result.error(if (e is BackendError) e.status.toString() else "backend", e.message, null) } } }
    }
    private fun reply(result: MethodChannel.Result, error: String?) {
        main.post { if (error != null) result.error("vpn", error, null) else result.success(VpnRuntime.status().toString()) }
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
        val intent = Intent(this, SvoiVpnService::class.java).putExtra("serverId", vpnBody!!.getString("serverId")).putExtra("token", vpnToken)
        vpnResult = null; vpnBody = null; vpnToken = ""
        VpnRuntime.onStarted = { reply(result, it) }
        try {
            if (Build.VERSION.SDK_INT >= 26) startForegroundService(intent) else startService(intent)
        } catch (e: Exception) { VpnRuntime.onStarted = null; result.error("vpn", e.message, null) }
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
