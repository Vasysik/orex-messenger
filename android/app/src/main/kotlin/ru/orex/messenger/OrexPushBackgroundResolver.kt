package ru.orex.messenger

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant
import java.util.ArrayDeque
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Serialized headless Matrix/E2EE runtime for Android background work.
 *
 * It resolves encrypted push events and can deliver an exact call Reject while
 * the UI engine is absent. Requests share one Flutter isolate so background
 * work never races the encrypted Matrix database with itself.
 */
object OrexPushBackgroundResolver {
    private const val TAG = "OrexPushResolver"
    private const val CHANNEL_NAME = "orex/push_background"
    private const val ENTRYPOINT_NAME = "orexPushBackgroundMain"
    private const val STARTUP_TIMEOUT_MS = 20_000L
    private const val RESOLVE_TIMEOUT_MS = 30_000L
    private const val IDLE_SHUTDOWN_MS = 15_000L

    private data class Request(
        val id: String = UUID.randomUUID().toString(),
        val method: String,
        val payload: Map<String, String>,
        val callback: (Any?) -> Unit,
    )

    private val mainHandler = Handler(Looper.getMainLooper())
    private val queue = ArrayDeque<Request>()

    private var engine: FlutterEngine? = null
    private var channel: MethodChannel? = null
    private var ready = false
    private var creatingEngine = false
    private var active: Request? = null
    private var activeTimeout: Runnable? = null
    private var startupTimeout: Runnable? = null
    private var idleShutdown: Runnable? = null

    /**
     * Gives exclusive Flutter/Matrix ownership to the process call runtime.
     * Active background requests fail cleanly and WorkManager retries them on
     * the process engine instead of opening two encrypted databases/isolate sets.
     */
    fun yieldToProcessRuntime() {
        fun stopNow() {
            if (engine == null && !creatingEngine && active == null && queue.isEmpty()) return
            Log.i(TAG, "Yielding headless resolver to process-owned Flutter runtime")
            failAll()
            destroyEngine()
        }

        if (Looper.myLooper() == Looper.getMainLooper()) {
            stopNow()
            return
        }
        val latch = CountDownLatch(1)
        mainHandler.post {
            try {
                stopNow()
            } finally {
                latch.countDown()
            }
        }
        try {
            latch.await(2, TimeUnit.SECONDS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }

    fun resolve(
        context: Context,
        payload: Map<String, String>,
        callback: (Map<String, String>?) -> Unit,
    ) = enqueue(
        context = context,
        method = "resolvePush",
        payload = payload,
    ) { raw -> callback(stringMap(raw)) }

    fun handleCallAction(
        context: Context,
        payload: Map<String, String>,
        callback: (Boolean) -> Unit,
    ) = enqueue(
        context = context,
        method = "handleCallAction",
        payload = payload,
    ) { raw -> callback(raw == true) }

    private fun enqueue(
        context: Context,
        method: String,
        payload: Map<String, String>,
        callback: (Any?) -> Unit,
    ) {
        val appContext = context.applicationContext
        mainHandler.post {
            queue.addLast(
                Request(
                    method = method,
                    payload = LinkedHashMap(payload),
                    callback = callback,
                ),
            )
            cancelIdleShutdown()
            ensureEngine(appContext)
            pump()
        }
    }

    private fun ensureEngine(context: Context) {
        if (engine != null || creatingEngine) return
        creatingEngine = true
        try {
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(context)
            loader.ensureInitializationCompleteAsync(
                context,
                null,
                mainHandler,
            ) {
                try {
                    if (!creatingEngine || engine != null) {
                        return@ensureInitializationCompleteAsync
                    }
                    val newEngine = FlutterEngine(context)
                    GeneratedPluginRegistrant.registerWith(newEngine)
                    val newChannel = MethodChannel(
                        newEngine.dartExecutor.binaryMessenger,
                        CHANNEL_NAME,
                    )
                    newChannel.setMethodCallHandler(::handleDartCall)
                    engine = newEngine
                    channel = newChannel
                    ready = false
                    creatingEngine = false

                    val entrypoint = DartExecutor.DartEntrypoint(
                        loader.findAppBundlePath(),
                        ENTRYPOINT_NAME,
                    )
                    newEngine.dartExecutor.executeDartEntrypoint(entrypoint)
                    scheduleStartupTimeout()
                    Log.i(TAG, "Headless Matrix runtime started")
                } catch (error: Throwable) {
                    Log.e(TAG, "Failed to start headless Flutter resolver", error)
                    creatingEngine = false
                    failAll()
                    destroyEngine()
                }
            }
        } catch (error: Throwable) {
            Log.e(TAG, "Flutter initialization failed", error)
            creatingEngine = false
            failAll()
            destroyEngine()
        }
    }

    private fun handleDartCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "backgroundReady" -> {
                ready = true
                startupTimeout?.let(mainHandler::removeCallbacks)
                startupTimeout = null
                result.success(true)
                Log.i(TAG, "Headless Matrix runtime is ready")
                pump()
            }
            else -> result.notImplemented()
        }
    }

    private fun pump() {
        if (!ready || active != null) return
        val methodChannel = channel ?: return
        if (queue.isEmpty()) {
            scheduleIdleShutdown()
            return
        }
        val request = queue.removeFirst()
        active = request

        val timeout = Runnable {
            if (active?.id != request.id) return@Runnable
            Log.w(TAG, "Push resolution timed out id=${request.id}")
            finishActive(request, null)
        }
        activeTimeout = timeout
        mainHandler.postDelayed(timeout, RESOLVE_TIMEOUT_MS)

        methodChannel.invokeMethod(
            request.method,
            request.payload,
            object : MethodChannel.Result {
                override fun success(result: Any?) {
                    finishActive(request, result)
                }

                override fun error(
                    errorCode: String,
                    errorMessage: String?,
                    errorDetails: Any?,
                ) {
                    Log.e(TAG, "Push resolution failed code=$errorCode message=$errorMessage")
                    finishActive(request, null)
                }

                override fun notImplemented() {
                    Log.e(TAG, "Dart background method is not implemented")
                    finishActive(request, null)
                }
            },
        )
    }

    private fun finishActive(request: Request, result: Any?) {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            mainHandler.post { finishActive(request, result) }
            return
        }
        if (active?.id != request.id) return
        activeTimeout?.let(mainHandler::removeCallbacks)
        activeTimeout = null
        active = null
        try {
            request.callback(result)
        } catch (error: Throwable) {
            Log.e(TAG, "Push resolution callback failed", error)
        }
        pump()
    }

    private fun scheduleStartupTimeout() {
        startupTimeout?.let(mainHandler::removeCallbacks)
        val timeout = Runnable {
            if (ready) return@Runnable
            Log.e(TAG, "Headless Flutter resolver startup timed out")
            failAll()
            destroyEngine()
        }
        startupTimeout = timeout
        mainHandler.postDelayed(timeout, STARTUP_TIMEOUT_MS)
    }

    private fun scheduleIdleShutdown() {
        cancelIdleShutdown()
        val shutdown = Runnable {
            if (active == null && queue.isEmpty()) destroyEngine()
        }
        idleShutdown = shutdown
        mainHandler.postDelayed(shutdown, IDLE_SHUTDOWN_MS)
    }

    private fun cancelIdleShutdown() {
        idleShutdown?.let(mainHandler::removeCallbacks)
        idleShutdown = null
    }

    private fun failAll() {
        active?.let { request ->
            activeTimeout?.let(mainHandler::removeCallbacks)
            activeTimeout = null
            active = null
            try {
                request.callback(null)
            } catch (_: Throwable) {
                // Best effort only.
            }
        }
        while (queue.isNotEmpty()) {
            val request = queue.removeFirst()
            try {
                request.callback(null)
            } catch (_: Throwable) {
                // Best effort only.
            }
        }
    }

    private fun destroyEngine() {
        startupTimeout?.let(mainHandler::removeCallbacks)
        startupTimeout = null
        activeTimeout?.let(mainHandler::removeCallbacks)
        activeTimeout = null
        cancelIdleShutdown()
        ready = false
        creatingEngine = false
        channel?.setMethodCallHandler(null)
        channel = null
        engine?.destroy()
        engine = null
        Log.i(TAG, "Headless Matrix runtime stopped")
    }

    private fun stringMap(raw: Any?): Map<String, String>? {
        if (raw !is Map<*, *>) return null
        val result = linkedMapOf<String, String>()
        for ((keyRaw, valueRaw) in raw) {
            val key = keyRaw?.toString()?.trim().orEmpty()
            if (key.isEmpty()) continue
            result[key] = valueRaw?.toString().orEmpty()
        }
        return result.takeIf { it.isNotEmpty() }
    }
}
