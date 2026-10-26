package dev.svoi.app

import android.content.Intent
import android.net.VpnService
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

@RunWith(AndroidJUnit4::class)
class TunnelTest {
    private fun traffic() {
        val connection = URL("http://198.18.0.42:18080/probe").openConnection() as HttpURLConnection
        connection.connectTimeout = 8000; connection.readTimeout = 8000
        connection.setRequestProperty("Connection", "close")
        try { assertEquals("svoi-mobile-tunnel-ok", connection.inputStream.bufferedReader().use { it.readText().trim() }) }
        finally { connection.disconnect() }
    }

    @Test fun isolatedBackendSurvivesUiAndTwentyReconnects() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val watchdog = java.util.Timer(true)
        watchdog.schedule(object : java.util.TimerTask() {
            override fun run() {
                Thread.getAllStackTraces().forEach { (thread, stack) ->
                    android.util.Log.e("SvoiTestWatchdog", "${thread.name} ${thread.state}\n${stack.joinToString("\n")}")
                }
            }
        }, 120000)
        fun launch() = ActivityScenario.launch<MainActivity>(Intent(context, MainActivity::class.java)
            .putExtra("enable-software-rendering", true).putExtra("enable-impeller", false))
        var scenario = launch()
        var client = BackendClient(context)
        fun request(path: String, method: String = "GET", token: String = "", body: JSONObject = JSONObject(), probeId: String = "") =
            client.request(path, method, token, body.toString(), probeId)
        fun sample(phase: String): JSONObject {
            val snapshot = request("android/diagnostics").put("phase", phase)
            android.util.Log.i("SvoiPerf", snapshot.toString())
            return snapshot
        }
        fun promote() { context.startForegroundService(Intent(context, SvoiVpnService::class.java).setAction("foreground")) }
        try {
            request("init")
            assertNull("Grant ACTIVATE_VPN before this test", VpnService.prepare(context))
            val first = sample("initialized")
            assertNotEquals("Backend must be a separate process", android.os.Process.myPid(), first.getInt("pid"))
            assertFalse("UI must not load a second Go runtime", File("/proc/self/maps").readText().contains("libgojni.so"))
            val large = "x".repeat(2 * 1024 * 1024)
            assertEquals(large, request("android/test-echo", "POST", body = JSONObject().put("value", large)).getString("value"))
            val created = request("groups", "POST", body = JSONObject().put("name", "Android smoke").put("deviceName", "Emulator").put("platform", "Android"))
            val token = created.getString("token")
            request("subscription/import", "POST", token, JSONObject().put("content", "vless://90e3da82-374e-46ef-9099-761d39b86b82@10.0.2.2:10880?encryption=none&security=none&type=tcp#Test"))
            val id = request("me", token = token).getJSONArray("servers").getJSONObject(0).getString("id")
            var warm: JSONObject? = null
            for (cycle in 1..20) {
                promote()
                val running = request("connection/start", "POST", token, JSONObject().put("serverId", id))
                assertEquals("running", running.getString("state"))
                if (cycle == 1) {
                    client.cancelProbe("cancel-before-start")
                    try { request("servers/$id/probe", "POST", token, probeId = "cancel-before-start"); fail("Cancelled probe must not start") }
                    catch(e: BackendClient.Failure) { assertTrue(e.message.orEmpty().contains("отменена")) }
                    val pool = java.util.concurrent.Executors.newFixedThreadPool(2)
                    try {
                        val checks = (1..2).map { number -> pool.submit<Boolean> {
                            try { request("servers/$id/probe", "POST", token, probeId = "parallel-$number"); false }
                            catch(e: BackendClient.Failure) { true }
                        } }
                        checks.forEach { assertTrue("HTTP-only fixture must fail HTTPS", it.get(10, java.util.concurrent.TimeUnit.SECONDS)) }
                    } finally { pool.shutdownNow() }
                    request("settings", "PUT", token, request("settings", token = token).put("probe", JSONObject()
                        .put("url", "http://198.18.0.42:18080/probe").put("timeoutSeconds", 1).put("parallel", 2)))
                    val measured = request("servers/$id/probe", "POST", token, probeId = "configured-url")
                    assertTrue("Configured HTTP URL must work through profile", measured.getLong("latency") >= 0)
                    assertEquals("GET", measured.getString("method"))
                    client.cancelProbe("cancel-ip")
                    try { request("connection/ip", "POST", token, probeId = "cancel-ip"); fail("Cancelled IP check must not start") }
                    catch(e: BackendClient.Failure) { assertTrue(e.message.orEmpty().contains("отменена")) }
                    try { request("connection/ip", "POST", token, probeId = "ip-through-fixture"); fail("HTTP-only VPN must not fall back to direct HTTPS IP check") }
                    catch(e: BackendClient.Failure) { assertTrue(e.message.orEmpty().contains("IP")) }
                }
                traffic()
                if (cycle == 3) {
                    val pid = sample("before-ui-close").getInt("pid")
                    scenario.close(); client.close()
                    Thread.sleep(1200)
                    traffic()
                    client = BackendClient(context)
                    assertEquals("running", request("connection").getString("state"))
                    assertEquals(pid, sample("after-ui-rebind").getInt("pid"))
                    scenario = launch()
                    assertEquals(id, request("connection").getString("serverId"))
                    traffic()
                }
                request("connection/stop", "POST", token)
                Thread.sleep(1000)
                val stopped = sample("stopped-$cycle")
                assertEquals("stopped", request("connection").getString("state"))
                assertEquals("TUN descriptor leaked", 0, stopped.getJSONObject("fdKinds").optInt("tun"))
                if (cycle == 5) warm = stopped
                if (cycle == 20) {
                    assertTrue("Descriptors grow after warmup: $warm -> $stopped", stopped.getInt("fds") <= warm!!.getInt("fds") + 4)
                    assertTrue("Goroutines grow after warmup: $warm -> $stopped", stopped.getJSONObject("go").getInt("goroutines") <= warm!!.getJSONObject("go").getInt("goroutines") + 6)
                }
            }
            promote()
            request("connection/start", "POST", token, JSONObject().put("serverId", id))
            val oldPid = sample("before-service-crash").getInt("pid")
            android.os.Process.killProcess(oldPid)
            var recovered: JSONObject? = null
            val until = System.nanoTime() + java.util.concurrent.TimeUnit.SECONDS.toNanos(25)
            while (System.nanoTime() < until) {
                try {
                    val current = request("android/diagnostics")
                    if (current.getInt("pid") != oldPid) { recovered = current; break }
                } catch (_: Exception) { }
                Thread.sleep(200)
            }
            assertNotNull("Client did not rebind after backend death", recovered)
            assertEquals("Dead VPN must not stay connected in UI", "stopped", request("connection").getString("state"))
            assertEquals(id, request("me", token = token).getJSONArray("servers").getJSONObject(0).getString("id"))
            sample("service-recovered")
            assertFalse(File("/proc/self/maps").readText().contains("libgojni.so"))
        } finally {
            runCatching { request("connection/stop", "POST") }
            client.close(); scenario.close()
            watchdog.cancel()
        }
    }
}
