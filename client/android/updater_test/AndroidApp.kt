package android.app
import android.content.Intent
import android.content.pm.PackageManager
import java.io.File
open class Activity(val packageManager: PackageManager, val cacheDir: File) {
    val packageName = "ai.bb.bb_mobile"
    val filesDir = cacheDir
    val noBackupFilesDir = cacheDir
    val externalCacheDir = cacheDir
    fun getExternalFilesDir(type: String?): File = cacheDir
    var launches = 0
    fun startActivity(intent: Intent) { launches++ }
    fun startActivityForResult(intent: Intent, request: Int) { launches++ }
    companion object { const val RESULT_OK = -1 }
}
