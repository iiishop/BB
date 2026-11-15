package androidx.core.content
import android.app.Activity
import android.net.Uri
import java.io.File
object FileProvider {
    fun getUriForFile(activity: Activity, authority: String, file: File) = Uri.parse("content://$authority/test.apk")
}
