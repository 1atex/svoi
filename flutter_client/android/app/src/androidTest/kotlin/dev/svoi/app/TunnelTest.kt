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
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

@RunWith(AndroidJUnit4::class)
class TunnelTest {
    private fun resources(phase: String) {
        val memory = android.os.Debug.MemoryInfo()
        android.os.Debug.getMemoryInfo(memory)
        android.util.Log.i("SvoiPerf", JSONObject()
            .put("phase", phase).put("pssKiB", memory.totalPss)
            .put("cpuMs", android.os.Process.getElapsedCpuTime())
            .put("threads", java.io.File("/proc/self/task").list()?.size)
            .put("fds", java.io.File("/proc/self/fd").list()?.size).toString())
    }
    @Test fun importedProfileRoutesTrafficAndReconnects() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        ActivityScenario.launch(MainActivity::class.java).use {
            VpnRuntime.init(context)
            resources("initialized")
            assertNull("Grant ACTIVATE_VPN before this test", VpnService.prepare(context))
            fun request(method: String, path: String, token: String, body: JSONObject): JSONObject {
                val response = JSONObject(VpnRuntime.session!!.request(method, "/api/$path", token, body.toString()))
                assertTrue(response.toString(), response.getInt("status") < 400)
                return response.getJSONObject("body")
            }
            val group = request("POST", "groups", "", JSONObject().put("name","Android smoke").put("deviceName","Emulator").put("platform","Android"))
            val token = group.getString("token")
            request("POST", "subscription/import", token, JSONObject().put("content", "vless://90e3da82-374e-46ef-9099-761d39b86b82@10.0.2.2:10880?encryption=none&security=none&type=tcp#Test"))
            val current = request("GET", "me", token, JSONObject())
            val id = current.getJSONArray("servers").getJSONObject(0).getString("id")
            for (cycle in 1..3) {
                val ready = CountDownLatch(1)
                var error: String? = null
                VpnRuntime.onStarted = { error = it; ready.countDown() }
                context.startForegroundService(Intent(context, SvoiVpnService::class.java).putExtra("token",token).putExtra("serverId",id))
                assertTrue("VPN startup timeout",ready.await(20, TimeUnit.SECONDS))
                assertNull(error)
                assertEquals("running",VpnRuntime.status().getString("state"))
                resources("connected-$cycle")
                if (cycle == 1) {
                    val cancelled = VpnRuntime.session!!.newProbe(token, id)
                    cancelled.cancel()
                    try { cancelled.run(); fail("Cancelled probe must not start") }
                    catch(e: Exception) { assertTrue(e.message.orEmpty().contains("canceled")) }
                    val probes = java.util.concurrent.Executors.newFixedThreadPool(2)
                    try {
                        val checks = (1..2).map { probes.submit<Boolean> {
                            try { VpnRuntime.session!!.probe(token, id); false }
                            catch(e: Exception) { true }
                        } }
                        for (check in checks) assertTrue("HTTP-only fixture must fail HTTPS probe", check.get(8, TimeUnit.SECONDS))
                        assertEquals("probes stopped the active VPN", "running", VpnRuntime.status().getString("state"))
                    } finally { probes.shutdownNow() }
                }
                val connection = URL("http://198.18.0.42:18080/probe").openConnection() as HttpURLConnection
                connection.connectTimeout=8000;connection.readTimeout=8000
                try { assertEquals("svoi-mobile-tunnel-ok",connection.inputStream.bufferedReader().use { reader -> reader.readText().trim() }) }
                finally { connection.disconnect() }
                val stopped = CountDownLatch(1)
                VpnRuntime.stop { stopped.countDown() }
                assertTrue("VPN shutdown timeout",stopped.await(10,TimeUnit.SECONDS))
                assertEquals("stopped",VpnRuntime.status().getString("state"))
                resources("stopped-$cycle")
            }
        }
    }
}
