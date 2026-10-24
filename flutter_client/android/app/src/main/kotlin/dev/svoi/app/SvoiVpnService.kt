package dev.svoi.app

import android.app.*
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import mobile.Mobile
import mobile.Protector
import mobile.Session
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors

object VpnRuntime {
    private val queue = Executors.newSingleThreadExecutor()
    @Volatile var session: Session? = null
    @Volatile var service: SvoiVpnService? = null
    private var snapshot = JSONObject().put("available", true).put("state", "stopped").put("mode", "tun").put("logs", JSONArray())
    @Synchronized fun init(context: Context) {
        if (session != null) return
        val assets = File(context.filesDir, "core").apply { mkdirs() }
        for (name in arrayOf("geoip.dat", "geosite.dat")) {
            val file = File(assets, name)
            if (!file.exists()) context.assets.open("core/$name").use { input -> file.outputStream().use { input.copyTo(it) } }
        }
        session = Mobile.newSession(context.filesDir.absolutePath)
        snapshot.put("version", "Xray ${Mobile.version()}")
    }
    @Synchronized fun status(): JSONObject = JSONObject(snapshot.toString())
    @Synchronized fun update(state: String, error: String = "", serverId: String? = null) {
        snapshot.put("state", state).put("error", error).put("checked", false).put("latency", 0)
        if (serverId != null) snapshot.put("serverId", serverId)
        if (state == "running") snapshot.put("startedAt", java.time.Instant.now().toString())
        if (state == "stopped") snapshot.remove("startedAt")
    }
    fun start(context: Context, svc: SvoiVpnService, token: String, id: String, callback: (String?) -> Unit) = queue.execute {
        var error: String? = null
        try {
            init(context)
            service?.closeTunnel(false)
            service = svc
            update("starting", serverId = id)
            val config = session!!.config(token, id)
            svc.openTunnel(config, routing(context))
            update("running", serverId = id)
            svc.showNotification(true)
        } catch(e: Exception) {
            error = e.message ?: "Не удалось подключиться"
            svc.closeTunnel(); service = null
            update("stopped", error)
            svc.stopSelf()
        }
        callback(error)
    }
    fun stop(callback: (String?) -> Unit = {}) = queue.execute {
        update("stopping")
        val svc = service
        try { svc?.closeTunnel(); service = null; update("stopped"); svc?.stopSelf(); callback(null) }
        catch(e: Exception) { update("stopped", e.message ?: "Ошибка отключения"); callback(e.message) }
    }
    fun check(callback: (String?) -> Unit) = queue.execute {
        try {
            if (status().optString("state") != "running") throw IllegalStateException("Сначала подключитесь")
            val latency = Mobile.check()
            synchronized(this) { snapshot.put("checked", true).put("latency", latency).put("error", "").put("checkedAt", java.time.Instant.now().toString()) }
            callback(null)
        } catch(e: Exception) {
            synchronized(this) { snapshot.put("checked", false).put("error", e.message ?: "Нет ответа") }
            callback(null)
        }
    }
    fun routing(context: Context): JSONObject = JSONObject(context.getSharedPreferences("vpn",0).getString("routing", "{\"mode\":\"all\",\"packages\":[]}")!!)
    fun saveRouting(context: Context, value: JSONObject) {
        require(value.optString("mode") in listOf("all", "include", "exclude"))
        context.getSharedPreferences("vpn",0).edit().putString("routing",value.toString()).apply()
    }
    fun apps(context: Context): JSONObject {
        val pm = context.packageManager
        val items = pm.queryIntentActivities(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER), 0)
            .filter { it.activityInfo.packageName != context.packageName }.distinctBy { it.activityInfo.packageName }
            .sortedBy { it.loadLabel(pm).toString().lowercase() }
        return JSONObject().put("apps", JSONArray(items.map { JSONObject().put("package",it.activityInfo.packageName).put("name",it.loadLabel(pm).toString()) }))
    }
}

class SvoiVpnService : VpnService(), Protector {
    private var tunnel: ParcelFileDescriptor? = null
    private lateinit var endpoint: BackendEndpoint
    private val main = android.os.Handler(android.os.Looper.getMainLooper())
    private val promotionTimeout = Runnable {
        if (VpnRuntime.status().optString("state") !in listOf("running", "starting")) {
            stopForeground(STOP_FOREGROUND_REMOVE); stopSelf()
        }
    }
    override fun onCreate() { super.onCreate(); endpoint = BackendEndpoint(this) }
    override fun onBind(intent: Intent?): android.os.IBinder? =
        if (intent?.action == BackendClient.ACTION) endpoint else super.onBind(intent)
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "stop") { VpnRuntime.stop(); return START_NOT_STICKY }
        if (intent?.action == "foreground") {
            showNotification(VpnRuntime.status().optString("state") == "running")
            main.removeCallbacks(promotionTimeout); main.postDelayed(promotionTimeout, 20000)
        }
        return START_NOT_STICKY
    }
    fun showNotification(connected: Boolean) {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel("vpn", "VPN-подключение", NotificationManager.IMPORTANCE_LOW))
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val stop = PendingIntent.getService(this, 1, Intent(this, SvoiVpnService::class.java).setAction("stop"), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notification = Notification.Builder(this,"vpn").setContentTitle("SVOI · VPN")
            .setContentText(if (connected) "VPN включён. Нажмите, чтобы открыть приложение." else "Подключаемся…")
            .setSmallIcon(R.drawable.ic_vpn).setContentIntent(open).setOngoing(true)
            .addAction(Notification.Action.Builder(null, "Отключить",stop).build()).build()
        startForeground(1, notification)
    }
    fun openTunnel(config: String, route: JSONObject) {
        val builder = Builder().setSession("SVOI").setMtu(1500)
            .addAddress("172.31.255.1",30).addAddress("fd42:7376:6f69::1",126)
            .addRoute("0.0.0.0",0).addRoute("::",0).addDnsServer("1.1.1.1")
        val packages = route.optJSONArray("packages") ?: JSONArray()
        when(route.optString("mode")) {
            "include" -> {
                require(packages.length() > 0) { "Выберите приложения для VPN" }
                builder.addAllowedApplication(packageName)
                for(i in 0 until packages.length()) builder.addAllowedApplication(packages.getString(i))
            }
            "exclude" -> for(i in 0 until packages.length()) if(packages.getString(i) != packageName) builder.addDisallowedApplication(packages.getString(i))
        }
        if (Build.VERSION.SDK_INT >= 29) builder.setMetered(false)
        tunnel = builder.establish() ?: throw IllegalStateException("Разрешение VPN отозвано")
        try { Mobile.start(config, tunnel!!.fd, File(filesDir,"core").absolutePath, this) }
        catch(e: Exception) { tunnel?.close(); tunnel = null; throw e }
    }
    fun closeTunnel(removeNotification: Boolean = true) {
        try { Mobile.stop() } finally { tunnel?.close(); tunnel = null; if (removeNotification) stopForeground(STOP_FOREGROUND_REMOVE) }
    }
    override fun onRevoke() { VpnRuntime.stop(); super.onRevoke() }
    override fun onDestroy() {
        main.removeCallbacks(promotionTimeout)
        endpoint.close()
        if (VpnRuntime.service === this) VpnRuntime.stop()
        super.onDestroy()
    }
}
