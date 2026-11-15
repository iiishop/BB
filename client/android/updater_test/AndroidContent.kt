package android.content
import android.net.Uri
class ActivityNotFoundException : RuntimeException()
class Intent(action: String, uri: Uri? = null) {
    fun setDataAndType(uri: Uri, mime: String) {}
    fun putExtra(key: String, value: Boolean) {}
    fun addFlags(flags: Int) {}
    companion object {
        const val ACTION_VIEW = "VIEW"
        const val EXTRA_RETURN_RESULT = "RETURN"
        const val FLAG_GRANT_READ_URI_PERMISSION = 1
    }
}
