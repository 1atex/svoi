package dev.svoi.app

import android.os.Bundle
import android.os.ParcelFileDescriptor
import java.io.ByteArrayOutputStream
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.ScheduledThreadPoolExecutor

class BackendParcel : AutoCloseable {
    private val writers = Executors.newFixedThreadPool(2)
    private val deadlines = ScheduledThreadPoolExecutor(1).apply { removeOnCancelPolicy = true }
    private val open = ConcurrentHashMap.newKeySet<ParcelFileDescriptor>()

    fun reply(value: String): BackendReply {
        val bundle = Bundle()
        val fd = put(bundle, value)
        return BackendReply(bundle.getString("text"), fd)
    }

    fun put(bundle: Bundle, value: String): ParcelFileDescriptor? {
        val bytes = value.toByteArray(Charsets.UTF_8)
        require(bytes.size <= LIMIT) { "Слишком большой ответ или профиль" }
        if (bytes.size <= 48 * 1024) { bundle.putString("text", value); return null }
        val pipe = ParcelFileDescriptor.createPipe()
        open.add(pipe[1])
        try {
            val deadline = deadlines.schedule({ runCatching { pipe[1].close() } }, 30, TimeUnit.SECONDS)
            writers.execute {
                try { ParcelFileDescriptor.AutoCloseOutputStream(pipe[1]).use { it.write(bytes) } }
                catch (_: Exception) { }
                finally { deadline.cancel(false); open.remove(pipe[1]); runCatching { pipe[1].close() } }
            }
            bundle.putParcelable("stream", pipe[0])
            return pipe[0]
        } catch (e: Exception) {
            pipe.forEach { runCatching { it.close() } }; open.remove(pipe[1]); throw e
        }
    }

    override fun close() {
        open.forEach { runCatching { it.close() } }
        writers.shutdownNow(); deadlines.shutdownNow()
    }

    companion object {
        const val LIMIT = 16 * 1024 * 1024
        @Suppress("DEPRECATION")
        fun read(bundle: Bundle): String {
            val fd = bundle.getParcelable<ParcelFileDescriptor>("stream")
            if (fd == null) return bundle.getString("text") ?: "{}"
            return ParcelFileDescriptor.AutoCloseInputStream(fd).use { input ->
                val output = ByteArrayOutputStream()
                val buffer = ByteArray(8192)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    require(output.size() + count <= LIMIT) { "Слишком большой ответ или профиль" }
                    output.write(buffer, 0, count)
                }
                output.toString("UTF-8")
            }
        }
    }
}
