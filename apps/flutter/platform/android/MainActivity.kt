package vn.erpdistribution.erp_distribution

import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val worker = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "erp/android_update")
            .setMethodCallHandler { call, result ->
                if (call.method !in setOf("installed", "inspect", "install")) {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                worker.execute {
                    try {
                        if (call.method == "installed") {
                            val own = ownInfo()
                            val info = mapOf(
                                "packageName" to own.packageName, "versionName" to own.versionName,
                                "versionCode" to version(own), "signerSha256" to signer(own),
                                "cacheDir" to cacheDir.canonicalPath
                            )
                            runOnUiThread { result.success(info) }
                        } else {
                            val apk = verifiedApk(call)
                            runOnUiThread {
                                try {
                                    if (isFinishing || isDestroyed) throw IllegalStateException()
                                    if (call.method == "inspect") result.success(null)
                                    else result.success(openInstaller(apk))
                                } catch (_: Exception) { result.error("INSTALL_DENIED", "Không thể mở trình cài đặt.", null) }
                            }
                        }
                    } catch (_: Exception) {
                        runOnUiThread { result.error("VERIFY_FAILED", "Không xác minh được bản cập nhật.", null) }
                    }
                }
            }
    }

    @Suppress("DEPRECATION")
    private fun flags(): Int = if (Build.VERSION.SDK_INT >= 28)
        PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES

    @Suppress("DEPRECATION")
    private fun ownInfo(): PackageInfo = packageManager.getPackageInfo(packageName, flags())

    @Suppress("DEPRECATION")
    private fun version(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()

    @Suppress("DEPRECATION")
    private fun signer(info: PackageInfo): String {
        val signatures = if (Build.VERSION.SDK_INT >= 28)
            info.signingInfo?.apkContentsSigners else info.signatures
        require(signatures != null && signatures.size == 1)
        return hex(MessageDigest.getInstance("SHA-256").digest(signatures[0].toByteArray()))
    }

    private fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it.toInt() and 255) }

    private fun fileHash(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(65536)
            while (true) {
                val n = input.read(buffer)
                if (n < 0) break
                digest.update(buffer, 0, n)
            }
        }
        return hex(digest.digest())
    }

    @Suppress("DEPRECATION")
    private fun verifiedApk(call: MethodCall): File {
        val path = call.argument<String>("path") ?: throw IllegalArgumentException()
        val expectedVersion = call.argument<Number>("versionCode")?.toLong() ?: throw IllegalArgumentException()
        val expectedSize = call.argument<Number>("size")?.toLong() ?: throw IllegalArgumentException()
        val expectedHash = call.argument<String>("sha256") ?: throw IllegalArgumentException()
        val expectedSigner = call.argument<String>("signerSha256") ?: throw IllegalArgumentException()
        val root = File(cacheDir, "erp-updates").canonicalFile
        val apk = File(path).canonicalFile
        require(apk.parentFile == root && apk.name.matches(Regex("[a-f0-9]{64}-[a-f0-9]{64}\\.apk")))
        require(apk.isFile && expectedSize in 1..314572800L && apk.length() == expectedSize)
        require(expectedHash.matches(Regex("[a-f0-9]{64}")) && fileHash(apk) == expectedHash)
        val own = ownInfo()
        val candidate = packageManager.getPackageArchiveInfo(apk.path, flags()) ?: throw IllegalArgumentException()
        require(packageName == "vn.erpdistribution.erp_distribution" && candidate.packageName == packageName)
        require(version(candidate) == expectedVersion && expectedVersion > version(own))
        require(signer(own) == expectedSigner && signer(candidate) == expectedSigner)
        return apk
    }

    private fun openInstaller(apk: File): Boolean {
        if (Build.VERSION.SDK_INT >= 26 && !packageManager.canRequestPackageInstalls()) {
            startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:" + packageName)))
            return false
        }
        val uri = FileProvider.getUriForFile(this, packageName + ".updates", apk)
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        startActivity(intent)
        return true
    }

    override fun onDestroy() {
        worker.shutdownNow()
        super.onDestroy()
    }
}
