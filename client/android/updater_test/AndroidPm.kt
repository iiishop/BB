package android.content.pm
import android.os.Build
// Android contract: certificate fields are populated ONLY when requested.
// https://developer.android.com/reference/android/content/pm/PackageInfo#signingInfo
class Signature(private val bytes: ByteArray) { fun toByteArray() = bytes }
class SigningInfo(val apkContentsSigners: Array<Signature>)
class PackageInfo(val packageName: String, private val code: Long, val versionName: String,
                  private val signing: SigningInfo?, val signatures: Array<Signature>?) {
    val versionCode: Int get() = code.toInt()
    val longVersionCode: Long get() {
        if (Build.VERSION.SDK_INT < 28) throw NoSuchMethodError("getLongVersionCode requires API 28")
        return code
    }
    val signingInfo: SigningInfo? get() {
        if (Build.VERSION.SDK_INT < 28) throw NoSuchFieldError("signingInfo requires API 28")
        return signing
    }
}
class PackageManager {
    var installedFlags = -1
    var archiveFlags = -1
    var installedCode = 2002L
    var installedSigner: String? = "same-signing-key"
    var targetName = "ai.bb.bb_mobile"
    var targetCode = 2003L
    var targetSigner: String? = "same-signing-key"
    var permission = true
    fun canRequestPackageInstalls(): Boolean {
        if (Build.VERSION.SDK_INT < 26) throw NoSuchMethodError("requires API 26")
        return permission
    }
    private fun info(name: String, code: Long, flags: Int, signer: String?): PackageInfo {
        val certs = signer?.let { arrayOf(Signature(it.toByteArray())) }
        return PackageInfo(name, code, "1.10.0",
            if (flags and GET_SIGNING_CERTIFICATES != 0 && certs != null) SigningInfo(certs) else null,
            if (flags and GET_SIGNATURES != 0) certs else null)
    }
    fun getPackageInfo(name: String, flags: Int): PackageInfo {
        installedFlags = flags
        return info(name, installedCode, flags, installedSigner)
    }
    fun getPackageArchiveInfo(path: String, flags: Int): PackageInfo {
        archiveFlags = flags
        return info(targetName, targetCode, flags, targetSigner)
    }
    companion object {
        const val GET_SIGNATURES = 64
        const val GET_SIGNING_CERTIFICATES = 134217728
    }
}
