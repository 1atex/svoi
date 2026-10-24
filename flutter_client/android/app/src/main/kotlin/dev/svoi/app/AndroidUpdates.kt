package dev.svoi.app

import android.app.DownloadManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import androidx.core.content.FileProvider
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.zip.ZipFile

data class AndroidRelease(val version: String, val code: Long, val abi: String, val url: String, val hash: String, val size: Long) {
    fun json() = JSONObject().put("version", version).put("code", code).put("abi", abi).put("url", url).put("hash", hash).put("size", size)
    companion object {
        const val MAX_SIZE = 200L * 1024 * 1024
        fun saved(j: JSONObject) = AndroidRelease(j.getString("version"), j.getLong("code"), j.getString("abi"), j.getString("url"), j.getString("hash"), j.getLong("size"))
        fun parse(j: JSONObject, packageName: String, abis: List<String>, sdk: Int): AndroidRelease? {
            require(j.getInt("schema") == 1 && j.getString("packageName") == packageName) { "Неверный формат обновления" }
            if (j.getInt("minSdk") > sdk) return null
            val files = j.getJSONArray("artifacts")
            for (abi in abis) for (i in 0 until files.length()) {
                val item = files.getJSONObject(i)
                if (item.getString("abi") != abi) continue
                val url = item.getString("url")
                require(isReleaseUrl(url)) { "Недопустимый адрес обновления" }
                val hash = item.getString("sha256").lowercase()
                val size = item.getLong("size")
                require(hash.matches(Regex("[0-9a-f]{64}")) && size in 1..MAX_SIZE && j.getLong("versionCode") > 0) { "Некорректные данные APK" }
                return AndroidRelease(j.getString("versionName"), j.getLong("versionCode"), abi, url, hash, size)
            }
            return null
        }
        fun isReleaseUrl(value: String): Boolean {
            val uri = Uri.parse(value)
            return uri.scheme == "https" && uri.host == "github.com" && uri.port == -1 && uri.userInfo == null && uri.query == null && uri.fragment == null && uri.path.orEmpty().startsWith("/1atex/svoi/releases/download/")
        }
    }
}

object AndroidApkVerifier {
    @Suppress("DEPRECATION")
    fun code(info: PackageInfo): Long = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
    @Suppress("DEPRECATION")
    fun flags() = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES or PackageManager.GET_SIGNATURES else PackageManager.GET_SIGNATURES
    @Suppress("DEPRECATION")
    fun signers(info: PackageInfo): Set<String> {
        val signatures = if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners else info.signatures
        return signatures.orEmpty().map { hex(MessageDigest.getInstance("SHA-256").digest(it.toByteArray())) }.toSet()
    }
    fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it.toInt() and 255) }
    fun hash(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().buffered().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) { val n = input.read(buffer); if (n < 0) break; digest.update(buffer, 0, n) }
        }
        return hex(digest.digest())
    }
    @Suppress("DEPRECATION")
    fun verify(context: Context, file: File, release: AndroidRelease) {
        require(file.length() == release.size && release.size in 1..AndroidRelease.MAX_SIZE) { "Размер APK не совпадает. Скачайте обновление заново." }
        require(hash(file) == release.hash) { "APK повреждён: контрольная сумма не совпадает." }
        val pm = context.packageManager
        val archive = pm.getPackageArchiveInfo(file.absolutePath, flags()) ?: error("Android не распознал APK")
        val installed = pm.getPackageInfo(context.packageName, flags())
        require(archive.packageName == context.packageName) { "APK предназначен для другого приложения" }
        val trusted = signers(installed)
        val candidate = signers(archive)
        if (trusted.isEmpty() || candidate != trusted) {
            android.util.Log.w("SvoiUpdate", "Certificate mismatch: installed=$trusted apk=$candidate")
            throw IllegalArgumentException("Подпись APK не совпадает с установленным SVOI. Автоматическая установка запрещена.")
        }
        require(code(archive) == release.code && release.code > code(installed)) { "Версия APK не подходит для обновления" }
        require((archive.applicationInfo?.minSdkVersion ?: Int.MAX_VALUE) <= Build.VERSION.SDK_INT) { "Нужна более новая версия Android" }
        require(release.abi in Build.SUPPORTED_ABIS) { "APK не подходит для процессора устройства" }
        ZipFile(file).use { zip -> require(zip.entries().asSequence().any { it.name.startsWith("lib/${release.abi}/") }) { "В APK отсутствует нужная архитектура" } }
    }
}

class AndroidUpdates private constructor(private val context: Context) {
    private val prefs = context.getSharedPreferences("android-updates", Context.MODE_PRIVATE)
    private val manager = context.getSystemService(DownloadManager::class.java)
    private val worker = Executors.newSingleThreadExecutor()
    private val directory = File(context.filesDir, "updates").apply { mkdirs() }
    private val apk = File(directory, "update.apk")
    private val downloaded = File(context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS), "svoi-update.apk")
    @Suppress("DEPRECATION") private val installed = context.packageManager.getPackageInfo(context.packageName, 0)
    private var selected = runCatching { prefs.getString("release", null)?.let { AndroidRelease.saved(JSONObject(it)) } }.getOrNull()
    private var downloadId = prefs.getLong("downloadId", -1)
    private var stage = "idle"
    private var error = ""
    private var downloadedBytes = 0L
    private var validating = false
    private var ready = false

    init {
        if ((selected?.code ?: 0) <= AndroidApkVerifier.code(installed)) {
            clearDownload(); selected = null; prefs.edit().remove("release").apply()
        }
    }

    @Synchronized fun status(): JSONObject {
        refreshDownload()
        return JSONObject().put("state", stage).put("error", error).put("currentVersion", installed.versionName)
            .put("version", selected?.version ?: "").put("available", (selected?.code ?: 0) > AndroidApkVerifier.code(installed))
            .put("downloaded", downloadedBytes).put("size", selected?.size ?: 0).put("autoCheck", prefs.getBoolean("autoCheck", true))
            .put("autoDownload", prefs.getBoolean("autoDownload", true)).put("canInstall", context.packageManager.canRequestPackageInstalls())
    }

    @Synchronized fun settings(check: Boolean, download: Boolean): JSONObject {
        prefs.edit().putBoolean("autoCheck", check).putBoolean("autoDownload", download).apply()
        return status()
    }

    @Synchronized fun check(force: Boolean): JSONObject {
        refreshDownload()
        if (stage == "checking" || downloadId >= 0 || validating || ready) return status()
        if (!force && (!prefs.getBoolean("autoCheck", true) || System.currentTimeMillis() - prefs.getLong("checkedAt", 0) < 6 * 60 * 60 * 1000)) return status()
        stage = "checking"; error = ""
        worker.execute {
            try {
                val releases = JSONArray(readUrl("https://api.github.com/repos/1atex/svoi/releases?per_page=100"))
                var best: AndroidRelease? = null
                var inspected = 0
                for (i in 0 until releases.length()) {
                    val release = releases.getJSONObject(i)
                    if (release.optBoolean("draft") || !release.optString("tag_name").startsWith("android-v")) continue
                    val assets = release.getJSONArray("assets")
                    for (a in 0 until assets.length()) {
                        val asset = assets.getJSONObject(a)
                        if (asset.optString("name") != "svoi-android-update.json") continue
                        val url = asset.getString("browser_download_url")
                        require(AndroidRelease.isReleaseUrl(url))
                        val candidate = AndroidRelease.parse(JSONObject(readUrl(url)), context.packageName, Build.SUPPORTED_ABIS.toList(), Build.VERSION.SDK_INT)
                        if (candidate != null && candidate.code > (best?.code ?: 0)) best = candidate
                        inspected++
                    }
                    if (inspected >= 6) break
                }
                synchronized(this) {
                    selected = best?.takeIf { it.code > AndroidApkVerifier.code(installed) }
                    prefs.edit().putLong("checkedAt", System.currentTimeMillis()).putString("release", selected?.json()?.toString()).apply()
                    stage = if (selected == null) "current" else "available"
                    if (selected != null && prefs.getBoolean("autoDownload", true)) download(automatic = true)
                }
            } catch (e: Exception) { synchronized(this) { stage = "error"; error = friendly(e) } }
        }
        return status()
    }

    @Synchronized fun download(automatic: Boolean = false): JSONObject {
        check(stage != "checking" && !validating) { "Дождитесь завершения проверки" }
        if (downloadId >= 0 || ready) return status()
        val release = selected ?: error("Сначала проверьте обновления")
        require(AndroidRelease.isReleaseUrl(release.url))
        downloaded.delete(); apk.delete(); downloaded.parentFile?.mkdirs()
        val request = DownloadManager.Request(Uri.parse(release.url)).setTitle("Обновление SVOI ${release.version}")
            .setDescription("После загрузки откройте SVOI для установки")
            .setAllowedOverMetered(!automatic)
            .setMimeType("application/vnd.android.package-archive")
            .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE)
            .setDestinationUri(Uri.fromFile(downloaded))
        downloadId = manager.enqueue(request)
        prefs.edit().putLong("downloadId", downloadId).apply()
        stage = "downloading"; error = ""
        return status()
    }

    @Synchronized fun cancel(): JSONObject {
        check(!validating) { "Завершается проверка APK" }
        clearDownload(); error = ""; stage = if (selected == null) "idle" else "available"
        return status()
    }

    @Synchronized private fun refreshDownload() {
        if (ready || validating) return
        if (apk.exists() && selected != null) { validate(false); return }
        if (downloadId < 0) return
        manager.query(DownloadManager.Query().setFilterById(downloadId))?.use { cursor ->
            if (!cursor.moveToFirst()) { failDownload("Загрузка удалена. Скачайте обновление заново."); return }
            downloadedBytes = cursor.getLong(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR))
            if (downloadedBytes > (selected?.size ?: 0)) { failDownload("Размер загрузки превышает ожидаемый."); return }
            when (cursor.getInt(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS))) {
                DownloadManager.STATUS_SUCCESSFUL -> validate(true)
                DownloadManager.STATUS_FAILED -> failDownload("Не удалось скачать APK. Проверьте сеть и свободное место, затем повторите.")
                DownloadManager.STATUS_PAUSED -> stage = "waiting"
                else -> stage = "downloading"
            }
        }
    }

    @Synchronized private fun validate(copy: Boolean) {
        val release = selected ?: return
        validating = true; stage = "verifying"
        worker.execute {
            try {
                if (copy) {
                    require(downloaded.length() == release.size) { "Размер загрузки не совпадает" }
                    downloaded.copyTo(apk, overwrite = true)
                }
                AndroidApkVerifier.verify(context, apk, release)
                synchronized(this) {
                    ready = true; stage = "ready"; error = ""
                    if (downloadId >= 0) manager.remove(downloadId)
                    downloadId = -1; prefs.edit().remove("downloadId").apply(); downloaded.delete()
                }
            } catch (e: Exception) { synchronized(this) { failDownload(friendly(e)) } }
            finally { synchronized(this) { validating = false } }
        }
    }

    @Synchronized fun installIntent(): Intent {
        check(ready && apk.exists()) { "Сначала скачайте и проверьте обновление" }
        if (!context.packageManager.canRequestPackageInstalls()) return Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${context.packageName}"))
        AndroidApkVerifier.verify(context, apk, selected!!)
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.updates", apk)
        return Intent(Intent.ACTION_VIEW).setDataAndType(uri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }

    private fun clearDownload() {
        if (downloadId >= 0) manager.remove(downloadId)
        downloadId = -1; prefs.edit().remove("downloadId").apply()
        apk.delete(); downloaded.delete(); ready = false; downloadedBytes = 0
    }
    private fun failDownload(message: String) { clearDownload(); error = message; stage = "error" }
    private fun friendly(e: Exception) = when (e) {
        is java.net.SocketTimeoutException -> "GitHub не ответил вовремя. Повторите проверку позже."
        is java.io.IOException -> "Не удалось получить обновление. Проверьте доступ к GitHub и свободное место."
        else -> e.message ?: "Не удалось проверить обновление"
    }

    private fun readUrl(initial: String): String {
        var url = initial
        repeat(6) {
            val parsed = URL(url)
            require(parsed.protocol == "https" && parsed.host in setOf("api.github.com", "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"))
            val connection = parsed.openConnection() as HttpURLConnection
            connection.connectTimeout = 12000; connection.readTimeout = 15000; connection.instanceFollowRedirects = false
            connection.setRequestProperty("User-Agent", "SVOI-Android/${installed.versionName}")
            try {
                val status = connection.responseCode
                if (status in 300..399) { url = URL(parsed, connection.getHeaderField("Location") ?: error("Нет адреса загрузки")).toString(); return@repeat }
                check(status == 200) { if (status == 403 || status == 429) "GitHub временно ограничил проверки. Повторите позже." else "GitHub вернул HTTP $status" }
                return connection.inputStream.use { input ->
                    val output = java.io.ByteArrayOutputStream()
                    val buffer = ByteArray(8192)
                    while (true) {
                        val n = input.read(buffer)
                        if (n < 0) break
                        require(output.size() + n <= 1024 * 1024) { "Слишком большой ответ обновления" }
                        output.write(buffer, 0, n)
                    }
                    output.toString("UTF-8")
                }
            } finally { connection.disconnect() }
        }
        error("Слишком много перенаправлений")
    }

    companion object {
        @Volatile private var instance: AndroidUpdates? = null
        fun get(context: Context): AndroidUpdates = instance ?: synchronized(this) { instance ?: AndroidUpdates(context.applicationContext).also { instance = it } }
    }
}
