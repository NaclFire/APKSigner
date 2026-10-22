package fire.apk_signer

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "apk_signer/android"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val bridge = SignerBridge(applicationContext)
        MethodChannel(flutterEngine.dartExecutor, channelName).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    // 单参数（路径或 content:// URI）
                    "prepareInput" ->
                        result.success(bridge.prepareInput(call.arguments as? String ?: ""))

                    // Map 参数
                    "sign" -> {
                        val ok = bridge.sign(
                            input = call.argument<String>("input") ?: "",
                            output = call.argument<String>("output") ?: "",
                            ks = call.argument<String>("ks") ?: "",
                            storePass = call.argument<String>("storePass") ?: "",
                            keyPass = call.argument<String>("keyPass") ?: "",
                            alias = call.argument<String>("alias") ?: "",
                            v1 = call.argument<Boolean>("v1") ?: true,
                            v2 = call.argument<Boolean>("v2") ?: true,
                            v3 = call.argument<Boolean>("v3") ?: true
                        )
                        result.success(mapOf("ok" to ok, "message" to "OK"))
                    }

                    "verify" ->
                        result.success(bridge.verify(call.arguments as? String ?: ""))

                    "createKeystore" -> {
                        val ok = bridge.createKeystore(
                            path = call.argument<String>("path") ?: "",
                            alias = call.argument<String>("alias") ?: "",
                            dn = call.argument<String>("dn") ?: "",
                            storePass = call.argument<String>("storePass") ?: "",
                            keyPass = call.argument<String>("keyPass") ?: "",
                            validityDays = call.argument<Int>("validityDays") ?: 3650
                        )
                        result.success(mapOf("ok" to ok, "message" to "OK"))
                    }

                    "listAliases" -> result.success(
                        bridge.listAliases(
                            path = call.argument<String>("path") ?: "",
                            storePass = call.argument<String>("storePass") ?: ""
                        )
                    )

                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("signer-error", e.message ?: e.javaClass.simpleName, null)
            }
        }
    }
}
