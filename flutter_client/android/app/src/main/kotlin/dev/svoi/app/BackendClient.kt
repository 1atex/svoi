package dev.svoi.app

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Binder
import android.os.Bundle
import android.os.IBinder
import android.os.RemoteException
import org.json.JSONObject
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class BackendClient(private val context: Context) : AutoCloseable {
    class Failure(val status: Int, message: String) : Exception(message)
    private val lock = Any()
    private val owner = Binder()
    private val parcels = BackendParcel()
    private var remote: IBackendService? = null
    private var ready = CountDownLatch(1)
    private var bound = false
    private var closed = false
    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, binder: IBinder) = synchronized(lock) {
            remote = IBackendService.Stub.asInterface(binder); ready.countDown()
        }
        override fun onServiceDisconnected(name: ComponentName) = synchronized(lock) {
            remote = null; ready.countDown(); ready = CountDownLatch(1)
        }
        override fun onBindingDied(name: ComponentName) { reset() }
        override fun onNullBinding(name: ComponentName) { reset() }
    }

    private fun reset() = synchronized(lock) {
        remote = null; ready.countDown()
        if (bound) runCatching { context.unbindService(connection) }
        bound = false; ready = CountDownLatch(1)
    }

    private fun service(): IBackendService {
        val waiting = synchronized(lock) {
            check(!closed) { "Клиент закрыт" }
            remote?.let { return it }
            if (!bound) {
                bound = context.bindService(Intent(context, SvoiVpnService::class.java).setAction(ACTION), connection, Context.BIND_AUTO_CREATE)
                check(bound) { "Не удалось запустить службу VPN" }
            }
            ready
        }
        check(waiting.await(15, TimeUnit.SECONDS)) { "Служба VPN не ответила. Повторите попытку." }
        return synchronized(lock) { remote ?: throw IllegalStateException("Связь со службой VPN прервана") }
    }

    fun request(path: String, method: String = "GET", token: String = "", body: String = "{}", probeId: String = ""): JSONObject {
        val service = service()
        val request = Bundle().apply {
            putString("path", path); putString("method", method); putString("token", token)
            putString("probeId", probeId); putBinder("owner", owner)
        }
        val fd = parcels.put(request, body)
        try {
            val response = JSONObject(service.call(request).read())
            val status = response.getInt("status")
            val result = response.getJSONObject("body")
            if (status >= 400) throw Failure(status, result.optString("error", "Ошибка службы VPN"))
            return result
        } catch (e: RemoteException) {
            reset()
            throw Failure(503, "Служба VPN перезапустилась. Повторите действие.")
        } finally { fd?.close() }
    }

    fun cancelProbe(id: String) { request("android/cancel-probe", probeId = id) }

    override fun close() {
        val old = synchronized(lock) { if (closed) return; closed = true; remote }
        try {
            old?.call(Bundle().apply { putString("path", "android/detach"); putBinder("owner", owner) })
        } catch (_: Exception) { }
        finally { reset(); parcels.close() }
    }

    companion object { const val ACTION = "dev.svoi.BACKEND" }
}
