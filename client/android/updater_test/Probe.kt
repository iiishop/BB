package ai.bb.bb_mobile

import android.app.Activity
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.file.Files
import java.io.File
import java.util.zip.ZipOutputStream
import java.util.zip.ZipEntry

private class Fixture(rootDir: File? = null) {
    val root = rootDir ?: Files.createTempDirectory("bb-updater-contract-").toFile()
    val apk = File(root, "fixture.apk")
    val pm = PackageManager()
    val activity = Activity(pm, root)
    val channel = MethodChannel()
    val installer = UpdateInstaller(activity, channel)
    init {
        ZipOutputStream(apk.outputStream()).use { zip ->
            zip.putNextEntry(ZipEntry("lib/arm64-v8a/libflutter.so"))
            zip.write(byteArrayOf(1)); zip.closeEntry()
        }
        installer.attach()
    }
    fun request(method: String = "installApk"): Map<*, *> =
        requestPath(apk.absolutePath, method)

    fun requestPath(path: String, method: String = "installApk"): Map<*, *> {
        var response: Any? = null
        channel.handler(MethodCall(method, mapOf("path" to path)), object: MethodChannel.Result {
            override fun success(value: Any?) { response = value }
            override fun error(code: String, message: String?, details: Any?) { error("$code: $message") }
            override fun notImplemented() { error("Unexpected method") }
        })
        return response as Map<*, *>
    }
    fun rejected(reason: String) {
        val value = request()
        check(value["status"] == "rejected" && value["reason"] == reason) { "$value; expected $reason" }
        check(activity.launches == 0)
    }
}

fun main() {
    var passed = 0
    var failed = 0
    fun case(sdk: Int, name: String, test: Fixture.() -> Unit) {
        Build.VERSION.SDK_INT = sdk
        val fixture = Fixture()
        try {
            fixture.test()
            passed++
            println("PASS API$sdk $name")
        } catch (error: Throwable) {
            failed++
            println("FAIL API$sdk $name: $error")
        } finally { fixture.root.deleteRecursively() }
    }
    fun caseAt(sdk: Int, name: String, root: File, test: Fixture.() -> Unit) {
        Build.VERSION.SDK_INT = sdk
        val fixture = Fixture(root)
        try {
            fixture.test()
            passed++
            println("PASS API$sdk $name")
        } catch (error: Throwable) {
            failed++
            println("FAIL API$sdk $name: $error")
        } finally { fixture.root.deleteRecursively() }
    }
    for (sdk in listOf(24, 27, 28, 35)) {
        case(sdk, "availability reports real version") {
            check(request("availability")["version_code"] == 2002L)
        }
        case(sdk, "same signer newer split code launches and confirms result") {
            val result = request()
            check(result["status"] == "launched" && activity.launches == 1) { "$result; installedFlags=${pm.installedFlags}" }
            check(result["version_code"] == 2003L)
            pm.installedCode = 2003L
            installer.onActivityResult(4791, Activity.RESULT_OK)
            check((channel.events.last() as Map<*, *>)["status"] == "installed")
        }
        case(sdk, "different signer never launches") {
            pm.targetSigner = "foreign-key"
            rejected("signer_mismatch")
        }
        case(sdk, "missing installed signer fails closed") {
            pm.installedSigner = null
            rejected("signer_unavailable")
        }
        case(sdk, "missing archive signer fails closed") {
            pm.targetSigner = null
            rejected("signer_unavailable")
        }
        case(sdk, "equal version never launches") {
            pm.targetCode = pm.installedCode
            rejected("version_not_newer")
        }
        case(sdk, "downgrade never launches") {
            pm.targetCode = pm.installedCode - 1
            rejected("version_not_newer")
        }
        case(sdk, "wrong package never launches") {
            pm.targetName = "another.package"
            rejected("package_mismatch")
        }
        if (sdk >= 26) case(sdk, "unknown-source grant is required before launch") {
            pm.permission = false
            check(request()["status"] == "permissionRequired")
            check(activity.launches == 0)
        }
    }
    case(35, "modern long version retains high bits on all paths") {
        pm.installedCode = (1L shl 32) + 2002
        pm.targetCode = pm.installedCode + 1
        check(request("availability")["version_code"] == pm.installedCode)
        check(request()["status"] == "launched")
        pm.installedCode = pm.targetCode
        installer.onActivityResult(4791, Activity.RESULT_OK)
        check((channel.events.last() as Map<*, *>)["status"] == "installed")
    }
    // Android 的应用私有目录可能经符号链接别名访问（老设备上 /data/data 指向
    // /data/user/0）。路径是合法的，只是 canonical 与字面路径不同，不能因此拒绝。
    run {
        val real = Files.createTempDirectory("bb-real-storage-").toFile()
        val alias = File(real.parentFile, real.name + "-alias")
        Files.createSymbolicLink(alias.toPath(), real.toPath())
        val root = File(alias, "cache").also { it.mkdirs() }
        caseAt(35, "app storage reached through a symlinked path still installs", root) {
            val value = request()
            check(value["status"] == "launched") { "$value; expected launched" }
        }
        alias.delete()
        real.deleteRecursively()
    }
    // 反方向：指向应用私有目录之外的符号链接必须继续被拒。
    case(35, "symlink escaping app storage is refused") {
        val outside = File(Files.createTempDirectory("bb-outside-").toFile(), "escape.apk")
        Files.copy(apk.toPath(), outside.toPath())
        val link = File(root, "escape.apk")
        Files.createSymbolicLink(link.toPath(), outside.toPath())
        val value = requestPath(link.absolutePath)
        check(value["status"] == "rejected" && value["reason"] == "outside_app_storage") { "$value" }
        outside.parentFile.deleteRecursively()
    }
    // 路径检查通过、但 FileProvider 的 XML 没有暴露该目录时，原因必须与
    // outside_app_storage 区分，否则现场只能看到同一句话。
    case(35, "provider path rejection is reported separately") {
        FileProvider.rejectNext = true
        try {
            val value = request()
            check(value["status"] == "rejected" && value["reason"] == "provider_rejected") { "$value" }
            check(activity.launches == 0)
        } finally { FileProvider.rejectNext = false }
    }
    println("RESULT passed=$passed failed=$failed skipped=0")
    check(failed == 0) { "UpdateInstaller contract regression: $failed failed" }
}
