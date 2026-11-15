package android.net
class Uri(private val value: String) {
    private val parsed get() = java.net.URI(value)
    val scheme get() = parsed.scheme
    val host get() = parsed.host
    val userInfo get() = parsed.userInfo
    companion object { fun parse(value: String) = Uri(value) }
}
