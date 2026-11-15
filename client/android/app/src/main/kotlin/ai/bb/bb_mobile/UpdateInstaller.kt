package ai.bb.bb_mobile

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.zip.ZipFile

/**
 * Android half of the DEA-479 self-update: validates a staged APK and hands it
 * to the system package installer.
 *
 * There is deliberately no silent install. The system installer owns the user
 * confirmation, the "install unknown apps" grant and the final signature
 * enforcement; this class only refuses payloads that are visibly wrong before
 * the intent is launched (wrong package, not newer, foreign signing key,
 * unsupported ABI, path outside the app sandbox). Everything here is
 * project-owned code, so no extra Gradle plugin is pulled in.
 */
internal class UpdateInstaller(
    private val activity: Activity,
    private val channel: MethodChannel,
) {
    companion object {
        const val CHANNEL = "bb/update_install"

        private const val INSTALL_REQUEST = 4791
        private const val PERMISSION_REQUEST = 4792
        private const val EVENT_METHOD = "updateEvent"
        private const val APK_MIME = "application/vnd.android.package-archive"
        private const val AUTHORITY_SUFFIX = ".updates"
    }

    private var lastEvent: Map<String, Any?>? = null

    /** Version code of the APK currently offered to the system installer. */
    private var pendingVersionCode: Long? = null

    fun attach() {
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "availability" -> result.success(availability())
                    "installApk" -> result.success(install(call.argument<String>("path")))
                    "openInstallPermissionSettings" -> result.success(openInstallPermissionSettings())
                    "openExternalUrl" -> result.success(
                        openExternalUrl(call.argument<String>("url")),
                    )
                    "takeLastEvent" -> {
                        val event = lastEvent
                        lastEvent = null
                        result.success(event)
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                result.error(
                    "update_install_error",
                    error.message ?: "update install failed",
                    null,
                )
            }
        }
    }

    /**
     * Called from [MainActivity.onActivityResult]. The package installer has no
     * bindable result API, so its activity result is the only completion signal
     * and is reported as such instead of claiming an independent install check.
     */
    fun onActivityResult(requestCode: Int, resultCode: Int) {
        when (requestCode) {
            INSTALL_REQUEST -> {
                val expected = pendingVersionCode
                pendingVersionCode = null
                publish(installResult(resultCode, expected))
            }
            PERMISSION_REQUEST -> {
                publish(
                    mapOf(
                        "type" to "permissionResult",
                        "granted" to canInstallPackages(),
                    ),
                )
            }
        }
    }

    private fun publish(event: Map<String, Any?>) {
        lastEvent = event
        channel.invokeMethod(EVENT_METHOD, event)
    }

    private fun availability(): Map<String, Any?> {
        val info = installedPackage()
        return mapOf(
            "status" to if (canInstallPackages()) "ready" else "permissionRequired",
            "package_name" to activity.packageName,
            "version_code" to info.longVersionCode,
            "version_name" to info.versionName,
            "supported_abis" to Build.SUPPORTED_ABIS.toList(),
        )
    }

    /** On API < 26 the global toggle is owned by the installer itself. */
    private fun canInstallPackages(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return true
        }
        return activity.packageManager.canRequestPackageInstalls()
    }

    private fun installedPackage(): PackageInfo =
        activity.packageManager.getPackageInfo(activity.packageName, 0)

    /**
     * Opens an https target explicitly confirmed by the user in the update UI.
     * Other schemes are refused here as well, so the Dart side cannot be the
     * only guard.
     */
    private fun openExternalUrl(url: String?): Boolean {
        val uri = url?.let { android.net.Uri.parse(it) } ?: return false
        if (uri.scheme != "https" || uri.host.isNullOrBlank() || uri.userInfo != null) {
            return false
        }
        return try {
            activity.startActivity(Intent(Intent.ACTION_VIEW, uri))
            true
        } catch (_: ActivityNotFoundException) {
            false
        }
    }

    private fun openInstallPermissionSettings(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return false
        }
        val intent = Intent(
            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
            android.net.Uri.parse("package:${activity.packageName}"),
        )
        return try {
            activity.startActivityForResult(intent, PERMISSION_REQUEST)
            true
        } catch (_: ActivityNotFoundException) {
            false
        }
    }

    private fun install(path: String?): Map<String, Any?> {
        if (path.isNullOrBlank()) {
            return rejection("missing_path")
        }
        val file = File(path)
        when (val check = checkApk(file)) {
            is ApkCheck.Rejected -> return rejection(check.reason)
            is ApkCheck.Valid -> {
                if (!canInstallPackages()) {
                    return mapOf(
                        "status" to "permissionRequired",
                        "reason" to "unknown_sources_disabled",
                    )
                }
                val uri = try {
                    FileProvider.getUriForFile(
                        activity,
                        activity.packageName + AUTHORITY_SUFFIX,
                        file,
                    )
                } catch (_: IllegalArgumentException) {
                    // The provider's own path configuration refused the file.
                    return rejection("outside_app_storage")
                }
                val intent = Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, APK_MIME)
                    putExtra(Intent.EXTRA_RETURN_RESULT, true)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
                pendingVersionCode = check.versionCode
                return try {
                    activity.startActivityForResult(intent, INSTALL_REQUEST)
                    mapOf(
                        "status" to "launched",
                        "version_code" to check.versionCode,
                        "version_name" to check.versionName,
                    )
                } catch (_: ActivityNotFoundException) {
                    pendingVersionCode = null
                    mapOf(
                        "status" to "unsupported",
                        "reason" to "no_package_installer",
                    )
                }
            }
        }
    }

    private sealed interface ApkCheck {
        data class Valid(
            val versionCode: Long,
            val versionName: String?,
        ) : ApkCheck

        data class Rejected(val reason: String) : ApkCheck
    }

    private fun checkApk(file: File): ApkCheck {
        if (!file.isFile) {
            return ApkCheck.Rejected("missing_file")
        }
        if (!file.name.endsWith(".apk", ignoreCase = true)) {
            return ApkCheck.Rejected("not_apk")
        }
        if (!isInsideAppStorage(file)) {
            return ApkCheck.Rejected("outside_app_storage")
        }
        if (file.length() <= 0L) {
            return ApkCheck.Rejected("empty_file")
        }
        val archive = try {
            activity.packageManager.getPackageArchiveInfo(file.absolutePath, archiveFlags())
        } catch (_: Exception) {
            null
        } ?: return ApkCheck.Rejected("unreadable_apk")
        if (archive.packageName != activity.packageName) {
            return ApkCheck.Rejected("package_mismatch")
        }
        val installed = installedPackage()
        if (archive.longVersionCode <= installed.longVersionCode) {
            return ApkCheck.Rejected("version_not_newer")
        }
        val archiveSigners = signerDigests(archive)
        val installedSigners = signerDigests(installed)
        if (archiveSigners.isEmpty() || installedSigners.isEmpty()) {
            return ApkCheck.Rejected("signer_unavailable")
        }
        if (archiveSigners != installedSigners) {
            return ApkCheck.Rejected("signer_mismatch")
        }
        return when (checkAbi(file)) {
            null -> ApkCheck.Rejected("unreadable_apk")
            false -> ApkCheck.Rejected("abi_unsupported")
            true -> ApkCheck.Valid(archive.longVersionCode, archive.versionName)
        }
    }

    private fun archiveFlags(): Int {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES or PackageManager.GET_SIGNATURES
        } else {
            @Suppress("DEPRECATION")
            PackageManager.GET_SIGNATURES
        }
    }

    /**
     * True when the APK carries no native libraries (nothing to judge) or at
     * least one ABI this device can run; null when the zip cannot be read.
     *
     * Split-per-ABI release APKs contain exactly one `lib/<abi>/` tree, so a
     * mismatched architecture is refused here instead of failing inside the
     * installer with an opaque error.
     */
    private fun checkAbi(file: File): Boolean? {
        val supported = Build.SUPPORTED_ABIS.toSet()
        return try {
            ZipFile(file).use { zip ->
                val abis = zip.entries().asSequence()
                    .map { it.name }
                    .filter { it.startsWith("lib/") && it.endsWith(".so") }
                    .mapNotNull { it.split('/').getOrNull(1) }
                    .toSet()
                abis.isEmpty() || abis.any { it in supported }
            }
        } catch (_: Exception) {
            null
        }
    }

    /**
     * Only files below this app's own sandbox may be offered to the installer.
     * `canonicalFile` resolves `..` and symlinks, so an escaping link is refused
     * rather than silently served through the content provider.
     */
    private fun isInsideAppStorage(file: File): Boolean {
        val target = try {
            file.canonicalFile
        } catch (_: Exception) {
            return false
        }
        if (target != file.absoluteFile) {
            return false
        }
        val roots = listOfNotNull(
            activity.cacheDir,
            activity.filesDir,
            activity.noBackupFilesDir,
            activity.externalCacheDir,
            activity.getExternalFilesDir(null),
        )
        return roots.any { root ->
            val rootPath = try {
                root.canonicalFile.path
            } catch (_: Exception) {
                return@any false
            }
            target.path.startsWith(rootPath.trimEnd(File.separatorChar) + File.separatorChar)
        }
    }

    private fun signerDigests(info: PackageInfo): Set<String> {
        val certificates = mutableListOf<ByteArray>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.signingInfo?.apkContentsSigners?.forEach {
                certificates.add(it.toByteArray())
            }
        }
        if (certificates.isEmpty()) {
            @Suppress("DEPRECATION")
            info.signatures?.forEach { certificates.add(it.toByteArray()) }
        }
        return certificates
            .map { digest ->
                MessageDigest.getInstance("SHA-256").digest(digest)
                    .joinToString("") { byte -> "%02x".format(byte.toInt() and 0xFF) }
            }
            .toSet()
    }

    private fun rejection(reason: String): Map<String, Any?> =
        mapOf("status" to "rejected", "reason" to reason)

    private fun installResult(
        resultCode: Int,
        expectedVersionCode: Long?,
    ): Map<String, Any?> {
        if (resultCode != Activity.RESULT_OK) {
            return mapOf(
                "type" to "installResult",
                "status" to "cancelled",
            )
        }
        val versionCode = try {
            installedPackage().longVersionCode
        } catch (_: Exception) {
            null
        }
        val confirmed = expectedVersionCode != null &&
            versionCode != null &&
            versionCode >= expectedVersionCode
        return mapOf(
            "type" to "installResult",
            "status" to if (confirmed) "installed" else "unverified",
            "version_code" to versionCode,
            "expected_version_code" to expectedVersionCode,
        )
    }
}
