package androidx.core.content
import android.app.Activity
import android.net.Uri
import java.io.File
object FileProvider {
    /** Simulates the provider XML refusing a directory. */
    var rejectNext = false
    fun getUriForFile(activity: Activity, authority: String, file: File): Uri {
        if (rejectNext) throw IllegalArgumentException("outside configured paths")
        return Uri.parse("content://$authority/test.apk")
    }
}
