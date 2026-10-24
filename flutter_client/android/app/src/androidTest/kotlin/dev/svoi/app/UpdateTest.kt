package dev.svoi.app

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class UpdateTest {
    @Test fun providerExposesOnlyUpdateDirectory() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val file = File(context.filesDir, "updates/provider-test.apk")
        file.parentFile!!.mkdirs()
        try {
            file.writeText("update fixture")
            val uri = androidx.core.content.FileProvider.getUriForFile(context, "${context.packageName}.updates", file)
            assertEquals("content", uri.scheme)
            assertEquals("update fixture", context.contentResolver.openInputStream(uri)!!.bufferedReader().use { it.readText() })
            try {
                androidx.core.content.FileProvider.getUriForFile(context, "${context.packageName}.updates", File(context.filesDir, "groups.json"))
                fail("Private profiles exposed by update provider")
            } catch (_: IllegalArgumentException) { }
        } finally { file.delete() }
    }

    @Test fun updateValidatesVersionHashAndSigningCertificate() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val file = File(context.cacheDir, "update-test.apk")
        try {
            instrumentation.context.assets.open("update.apk").use { input -> file.outputStream().use { input.copyTo(it) } }
            val info = context.packageManager.getPackageArchiveInfo(file.path, AndroidApkVerifier.flags())!!
            val release = AndroidRelease(info.versionName!!, AndroidApkVerifier.code(info), "x86_64", "https://github.com/1atex/svoi/releases/download/test/update.apk", AndroidApkVerifier.hash(file), file.length())
            AndroidApkVerifier.verify(context, file, release)
            fun rejected(candidate: AndroidRelease, expected: String) {
                try { AndroidApkVerifier.verify(context, file, candidate); fail("Unsafe update accepted") }
                catch (e: IllegalArgumentException) { assertTrue(e.message.orEmpty(), e.message.orEmpty().contains(expected)) }
            }
            rejected(release.copy(hash = "0".repeat(64)), "сумма")
            rejected(release.copy(code = 1), "Версия")
            instrumentation.context.assets.open("wrong-key.apk").use { input -> file.outputStream().use { input.copyTo(it) } }
            rejected(release.copy(hash = AndroidApkVerifier.hash(file), size = file.length()), "Подпись")
        } finally { file.delete() }
    }

    @Test fun metadataSelectsArchitectureAndRejectsForeignDownloadUrls() {
        val json = JSONObject("""{"schema":1,"packageName":"dev.svoi.app.preview","versionName":"test","versionCode":100,"minSdk":26,"artifacts":[{"abi":"arm64-v8a","size":100,"sha256":"${"a".repeat(64)}","url":"https://github.com/1atex/svoi/releases/download/test/update.apk"}]}""")
        assertNull(AndroidRelease.parse(json, "dev.svoi.app.preview", listOf("x86_64"), 29))
        assertEquals("arm64-v8a", AndroidRelease.parse(json, "dev.svoi.app.preview", listOf("arm64-v8a"), 29)!!.abi)
        assertNull(AndroidRelease.parse(json, "dev.svoi.app.preview", listOf("arm64-v8a"), 25))
        json.getJSONArray("artifacts").getJSONObject(0).put("url", "https://github.com/attacker/other/releases/download/test/update.apk")
        try { AndroidRelease.parse(json, "dev.svoi.app.preview", listOf("arm64-v8a"), 29); fail("Foreign repository accepted") }
        catch (_: IllegalArgumentException) { }
    }
}
