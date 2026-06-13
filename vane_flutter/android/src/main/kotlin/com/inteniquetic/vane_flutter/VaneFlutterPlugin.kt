package com.inteniquetic.vane_flutter

import com.inteniquetic.vanekotlin.VaneClient
import com.inteniquetic.vanekotlin.VaneClientConfig
import com.inteniquetic.vanekotlin.VaneProtocolMode
import com.inteniquetic.vanekotlin.VaneRequest
import com.inteniquetic.vanekotlin.createDefaultConfig
import com.inteniquetic.vanekotlin.createVaneClient
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

class VaneFlutterPlugin : FlutterPlugin, MethodCallHandler {
    private lateinit var channel: MethodChannel
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val nextHandle = AtomicLong(1)
    private val clients = ConcurrentHashMap<Long, VaneClient>()

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "vane_flutter")
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "createClient" -> createClient(call, result)
            "execute" -> execute(call, result)
            "closeClient" -> closeClient(call, result)
            "setCertificatePins" -> setCertificatePins(call, result)
            else -> result.notImplemented()
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        clients.values.forEach { it.destroy() }
        clients.clear()
        scope.cancel()
        channel.setMethodCallHandler(null)
    }

    private fun createClient(call: MethodCall, result: Result) {
        runCatching {
            val config = configFromMap(call.requiredMap("configuration"))
            val handle = nextHandle.getAndIncrement()
            clients[handle] = createVaneClient(config)
            result.success(handle)
        }.onFailure { error ->
            result.error("VANE_CREATE_CLIENT", error.message, null)
        }
    }

    private fun execute(call: MethodCall, result: Result) {
        val handle = call.requiredLong("handle")
        val requestMap = call.requiredMap("request")
        val client = clients[handle]
        if (client == null) {
            result.error("VANE_INVALID_CLIENT", "No Vane client exists for handle $handle", null)
            return
        }

        scope.launch {
            runCatching {
                client.executeRequest(requestFromMap(requestMap)).toMap()
            }.onSuccess { response ->
                result.success(response)
            }.onFailure { error ->
                result.error("VANE_EXECUTE", error.message, null)
            }
        }
    }

    private fun closeClient(call: MethodCall, result: Result) {
        val handle = call.requiredLong("handle")
        clients.remove(handle)?.destroy()
        result.success(null)
    }

    private fun setCertificatePins(call: MethodCall, result: Result) {
        val handle = call.requiredLong("handle")
        val host = call.requiredString("host")
        val pins = stringList(call.argument<Any?>("pins"))
        val client = clients[handle]
        if (client == null) {
            result.error("VANE_INVALID_CLIENT", "No Vane client exists for handle $handle", null)
            return
        }

        runCatching {
            client.setCertificatePins(host, pins)
            result.success(null)
        }.onFailure { error ->
            result.error("VANE_SET_CERTIFICATE_PINS", error.message, null)
        }
    }

    @Suppress("UNCHECKED_CAST")
    private fun configFromMap(map: Map<String, Any?>): VaneClientConfig {
        return createDefaultConfig().apply {
            baseUrl = map["baseUrl"] as String?
            defaultHeaders = stringMap(map["defaultHeaders"])
            dnsOverrides = stringMap(map["dnsOverrides"])
            certificatePins = stringListMap(map["certificatePins"])
            cookiesEnabled = boolValue(map["cookiesEnabled"], cookiesEnabled)
            cookiePersistencePath = map["cookiePersistencePath"] as String?
            connectionPoolEnabled = boolValue(map["connectionPoolEnabled"], connectionPoolEnabled)
            maxIdleConnections = ulongValue(map["maxIdleConnections"], maxIdleConnections)
            connectionIdleTimeoutSeconds = ulongValue(
                map["connectionIdleTimeoutSeconds"],
                connectionIdleTimeoutSeconds
            )
            retryMaxAttempts = ulongValue(map["retryMaxAttempts"], retryMaxAttempts)
            retryInitialDelayMillis = ulongValue(
                map["retryInitialDelayMillis"],
                retryInitialDelayMillis
            )
            retryMaxDelayMillis = ulongValue(map["retryMaxDelayMillis"], retryMaxDelayMillis)
            retryUnsafeMethods = boolValue(map["retryUnsafeMethods"], retryUnsafeMethods)
            maxRequestBodyBytes = ulongValue(map["maxRequestBodyBytes"], maxRequestBodyBytes)
            maxResponseBodyBytes = ulongValue(map["maxResponseBodyBytes"], maxResponseBodyBytes)
            timeoutSeconds = nullableULongValue(map["timeoutSeconds"])
            followRedirects = boolValue(map["followRedirects"], followRedirects)
            userAgent = map["userAgent"] as String?
            protocolMode = protocolMode(map["protocolMode"] as String?)
            proxyUrl = map["proxyUrl"] as String?
            proxyAuthorization = map["proxyAuthorization"] as String?
        }
    }

    private fun requestFromMap(map: Map<String, Any?>): VaneRequest {
        return VaneRequest(
            url = map["url"] as String,
            method = (map["method"] as String?) ?: "GET",
            headers = stringMap(map["headers"]),
            queryParams = stringMap(map["queryParams"]),
            body = map["body"] as ByteArray?,
            bodyFilePath = map["bodyFilePath"] as String?,
            responseBodyPath = map["responseBodyPath"] as String?,
            cancelTokenId = ulongValue(map["cancelTokenId"], 0uL).takeIf { it != 0uL },
            progressId = ulongValue(map["progressId"], 0uL).takeIf { it != 0uL },
            timeoutSeconds = nullableULongValue(map["timeoutSeconds"]),
            followRedirects = boolValue(map["followRedirects"], true)
        )
    }

    private fun com.inteniquetic.vanekotlin.VaneResponse.toMap(): Map<String, Any?> {
        return mapOf(
            "statusCode" to statusCode.toInt(),
            "headers" to headers,
            "body" to body,
            "bodyFilePath" to bodyFilePath,
            "isSuccess" to isSuccess,
            "url" to url
        )
    }

    private fun protocolMode(value: String?): VaneProtocolMode {
        return when (value) {
            "http3ThenHttp2ThenHttp1" -> VaneProtocolMode.HTTP3_THEN_HTTP2_THEN_HTTP1
            "http2ThenHttp1" -> VaneProtocolMode.HTTP2_THEN_HTTP1
            "http2Only" -> VaneProtocolMode.HTTP2_ONLY
            "http1Only" -> VaneProtocolMode.HTTP1_ONLY
            else -> VaneProtocolMode.HTTP3_ONLY
        }
    }

    @Suppress("UNCHECKED_CAST")
    private fun stringMap(value: Any?): Map<String, String> {
        return (value as? Map<Any?, Any?>)
            ?.mapKeys { it.key.toString() }
            ?.mapValues { it.value.toString() }
            ?: emptyMap()
    }

    @Suppress("UNCHECKED_CAST")
    private fun stringListMap(value: Any?): Map<String, List<String>> {
        return (value as? Map<Any?, Any?>)
            ?.mapKeys { it.key.toString() }
            ?.mapValues { entry ->
                stringList(entry.value)
            }
            ?: emptyMap()
    }

    private fun stringList(value: Any?): List<String> {
        return (value as? List<Any?>)?.map { it.toString() } ?: emptyList()
    }

    private fun boolValue(value: Any?, fallback: Boolean): Boolean {
        return value as? Boolean ?: fallback
    }

    private fun ulongValue(value: Any?, fallback: ULong): ULong {
        return (value as? Number)?.toLong()?.toULong() ?: fallback
    }

    private fun nullableULongValue(value: Any?): ULong? {
        return (value as? Number)?.toLong()?.toULong()
    }

    @Suppress("UNCHECKED_CAST")
    private fun MethodCall.requiredMap(key: String): Map<String, Any?> {
        return argument<Map<String, Any?>>(key)
            ?: throw IllegalArgumentException("Missing $key")
    }

    private fun MethodCall.requiredLong(key: String): Long {
        return when (val value = argument<Any>(key)) {
            is Number -> value.toLong()
            else -> throw IllegalArgumentException("Missing $key")
        }
    }

    private fun MethodCall.requiredString(key: String): String {
        return argument<String>(key) ?: throw IllegalArgumentException("Missing $key")
    }
}
