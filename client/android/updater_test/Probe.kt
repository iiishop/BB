package ai.bb.bb_mobile

import android.app.Activity
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.file.Files
import java.io.File
import java.util.zip.ZipOutputStream
import java.util.zip.ZipEntry

private class Fixture {
    val root = Files.createTempDirectory("bb-updater-contract-").toFile()
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
    fun request(method: String = "installApk"): Map<*, *> {
        var response: Any? = null
        channel.handler(MethodCall(method, mapOf("path" to apk.absolutePath)), object: MethodChannel.Result {
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
    println("RESULT passed=$passed failed=$failed skipped=0")
    check(failed == 0) { "UpdateInstaller contract regression: $failed failed" }
}
