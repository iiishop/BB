package io.flutter.plugin.common
class MethodCall(val method: String, val arguments: Map<String, Any?>) {
    @Suppress("UNCHECKED_CAST") fun <T> argument(key: String): T? = arguments[key] as T?
}
class MethodChannel {
    interface Result { fun success(value: Any?); fun error(code: String, message: String?, details: Any?); fun notImplemented() }
    lateinit var handler: (MethodCall, Result) -> Unit
    fun setMethodCallHandler(callback: (MethodCall, Result) -> Unit) { handler = callback }
    val events = mutableListOf<Any?>()
    fun invokeMethod(method: String, value: Any?) { events.add(value) }
}
