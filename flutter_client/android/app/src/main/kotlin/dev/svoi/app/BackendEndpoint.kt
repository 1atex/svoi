package dev.svoi.app

import android.app.ActivityManager
import android.content.pm.ApplicationInfo
import android.os.Binder
import android.os.Bundle
import android.os.IBinder
import android.os.Process
import mobile.Mobile
import mobile.DNSRequest
import mobile.ProbeRequest
import mobile.PublicIPRequest
import org.json.JSONObject
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class BackendEndpoint(private val service: SvoiVpnService) : IBackendService.Stub(), AutoCloseable {
    private val parcels = BackendParcel()
    private val clients = HashMap<IBinder, Client>()
    private class Client(val binder: IBinder, val death: IBinder.DeathRecipient) {
        val probes = HashMap<String, ProbeRequest>()
        val ips = HashMap<String, PublicIPRequest>()
        val dns = HashMap<String, DNSRequest>()
        val cancelled = LinkedHashSet<String>()
        var dead = false
    }

    private fun client(binder: IBinder): Client = synchronized(clients) {
        clients[binder] ?: run {
            val death = IBinder.DeathRecipient { detach(binder) }
            binder.linkToDeath(death, 0)
            Client(binder, death).also { clients[binder] = it }
        }
    }

    private fun detach(binder: IBinder) {
        val client = synchronized(clients) { clients.remove(binder) } ?: return
        synchronized(client) {
            Mobile.cancelSpeed()
            client.dead = true; client.probes.values.forEach { it.cancel() }; client.ips.values.forEach { it.cancel() }; client.dns.values.forEach { it.cancel() }; client.cancelled.clear()
        }
        runCatching { binder.unlinkToDeath(client.death, 0) }
    }

    override fun call(request: Bundle): BackendReply {
        check(Binder.getCallingUid() == Process.myUid()) { "Недоступная служба" }
        return try {
            val body = BackendParcel.read(request)
            val path = request.getString("path") ?: ""
            val owner = requireNotNull(request.getBinder("owner"))
            val client = client(owner)
            val id = request.getString("probeId") ?: ""
            when (path) {
                "android/detach" -> { detach(owner); response(JSONObject()) }
                "android/cancel-probe" -> {
                    synchronized(client) {
                        client.probes[id]?.cancel(); client.ips[id]?.cancel(); client.dns[id]?.cancel()
                        client.cancelled.add(id)
                        if (client.cancelled.size > 128) client.cancelled.remove(client.cancelled.first())
                    }
                    response(JSONObject())
                }
                else -> {
                    VpnRuntime.init(service.applicationContext)
                    val method = request.getString("method") ?: "GET"
                    val token = request.getString("token") ?: ""
                    when {
                        path == "init" -> response(JSONObject().put("directory", service.filesDir.absolutePath)
                            .put("probeConcurrency", probeLimit()))
                        path == "tools/speed/start" -> {
                            val cm = service.getSystemService(android.net.ConnectivityManager::class.java)
                            check(cm.getNetworkCapabilities(cm.activeNetwork)?.hasTransport(android.net.NetworkCapabilities.TRANSPORT_VPN) != true) { "Отключите VPN перед сравнением скорости" }
                            check(VpnRuntime.status().optString("state") !in listOf("starting", "running", "stopping")) { "Отключите VPN перед сравнением скорости" }
                            parcels.reply(VpnRuntime.session!!.request(method, "/api/$path", token, body))
                        }
                        path == "dns/benchmark" && method == "POST" -> {
                            val cm = service.getSystemService(android.net.ConnectivityManager::class.java)
                            check(cm.getNetworkCapabilities(cm.activeNetwork)?.hasTransport(android.net.NetworkCapabilities.TRANSPORT_VPN) != true) { "Отключите VPN перед сравнением DNS" }
                            check(VpnRuntime.status().optString("state") !in listOf("starting", "running", "stopping")) { "Отключите VPN перед сравнением DNS" }
                            val dns = synchronized(client) {
                                check(!client.dead && !client.cancelled.remove(id)) { "Проверка отменена" }
                                check(client.dns.size < 3 && !client.dns.containsKey(id)) { "Завершается предыдущая проверка DNS" }
                                VpnRuntime.session!!.newDNSRequest(token, body).also { client.dns[id] = it }
                            }
                            try { parcels.reply(dns.run()) }
                            finally { dns.cancel(); synchronized(client) { client.dns.remove(id); client.cancelled.remove(id) } }
                        }
                        path == "connection/start" -> {
                            val input = JSONObject(body)
                            await { callback -> VpnRuntime.start(service.applicationContext, service, token, input.getString("serverId"), callback) }
                            response(VpnRuntime.status())
                        }
                        path == "connection/stop" -> { await { VpnRuntime.stop(it) }; response(VpnRuntime.status()) }
                        path == "connection/check" -> { await { VpnRuntime.check(it) }; response(VpnRuntime.status()) }
                        path == "connection/ip" -> {
                            val before = VpnRuntime.status()
                            check(before.optString("state") !in listOf("starting", "stopping")) { "Дождитесь переключения VPN" }
                            val ip = synchronized(client) {
                                check(!client.dead && !client.cancelled.remove(id)) { "Проверка отменена" }
                                Mobile.newPublicIPRequest().also { client.ips[id] = it }
                            }
                            try {
                                val result = JSONObject(ip.run())
                                val after = VpnRuntime.status()
                                check(listOf("state", "serverId", "startedAt").all { before.optString(it) == after.optString(it) }) { "Подключение изменилось. Проверка IP отменена." }
                                response(result)
                            }
                            finally { ip.cancel(); synchronized(client) { client.ips.remove(id); client.cancelled.remove(id) } }
                        }
                        path.startsWith("connection") -> response(VpnRuntime.status())
                        path == "android/apps" -> response(VpnRuntime.apps(service))
                        path == "android/routing" -> {
                            if (method == "PUT") VpnRuntime.saveRouting(service, JSONObject(body))
                            response(VpnRuntime.routing(service))
                        }
                        path == "android/goroutines" && service.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0 -> response(JSONObject().put("stack", Mobile.goroutineDump()))
                        path == "android/diagnostics" && service.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0 -> response(diagnostics())
                        path == "android/test-echo" && service.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0 -> response(JSONObject(body))
                        path.endsWith("/probe") && path.startsWith("servers/") && method == "POST" -> {
                            val serverID = android.net.Uri.decode(path.removePrefix("servers/").removeSuffix("/probe"))
                            val probe = synchronized(client) {
                                check(!client.dead && !client.cancelled.remove(id)) { "Проверка отменена" }
                                check(client.probes.size < probeLimit()) { "Завершается предыдущая проверка" }
                                check(!client.probes.containsKey(id)) { "Проверка уже запущена" }
                                VpnRuntime.session!!.newProbe(token, serverID).also { client.probes[id] = it }
                            }
                            try { response(JSONObject().put("latency", probe.run()).put("method", "GET").put("checkedAt", java.time.Instant.now().toString())) }
                            finally { probe.cancel(); synchronized(client) { client.probes.remove(id); client.cancelled.remove(id) } }
                        }
                        else -> parcels.reply(VpnRuntime.session!!.request(method, "/api/$path", token, body))
                    }
                }
            }
        } catch (e: Exception) {
            parcels.reply(JSONObject().put("status", if (e.message?.startsWith("Подготовка ядра:") == true) 503 else 400).put("body", JSONObject().put("error", e.message ?: "Ошибка службы VPN")).toString())
        }
    }

    private fun response(body: JSONObject) = parcels.reply(JSONObject().put("status", 200).put("body", body).toString())
    private fun probeLimit() = if (service.getSystemService(ActivityManager::class.java).isLowRamDevice) 1 else 2

    private fun await(operation: ((String?) -> Unit) -> Unit) {
        val done = CountDownLatch(1)
        var error: String? = null
        operation { error = it; done.countDown() }
        check(done.await(35, TimeUnit.SECONDS)) { "Служба не завершила действие. Проверьте состояние VPN." }
        error?.let { throw IllegalStateException(it) }
    }

    private fun diagnostics(): JSONObject {
        val memory = android.os.Debug.MemoryInfo()
        android.os.Debug.getMemoryInfo(memory)
        val kinds = HashMap<String, Int>()
        File("/proc/self/fd").listFiles()?.forEach {
            val target = runCatching { android.system.Os.readlink(it.path) }.getOrDefault("closed")
            val kind = when {
                target.startsWith("socket:") -> "socket"
                target.startsWith("pipe:") -> "pipe"
                target.startsWith("anon_inode:") -> target
                target == "/dev/net/tun" || target == "/dev/tun" -> "tun"
                else -> "file"
            }
            kinds[kind] = (kinds[kind] ?: 0) + 1
        }
        return JSONObject().put("pid", Process.myPid()).put("pssKiB", memory.totalPss)
            .put("cpuMs", Process.getElapsedCpuTime()).put("threads", File("/proc/self/task").list()?.size)
            .put("fds", kinds.values.sum()).put("fdKinds", JSONObject(kinds as Map<*, *>))
            .put("go", JSONObject(Mobile.diagnostics()))
    }

    override fun close() {
        synchronized(clients) { clients.keys.toList() }.forEach { detach(it) }
        parcels.close()
    }
}
