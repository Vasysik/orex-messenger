package ru.orex.messenger

import android.content.Context
import android.util.Log
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor

/**
 * Process-owned Flutter engine.
 *
 * A call must not be destroyed merely because MainActivity is removed from the
 * recent-apps task. The foreground phone-call service keeps the process alive;
 * this owner keeps the same Dart isolate, Matrix sync and LiveKit session alive
 * while Android detaches and later reattaches the UI Activity.
 */
object OrexFlutterEngineOwner {
    private const val TAG = "OrexFlutterEngine"

    @Volatile
    private var engine: FlutterEngine? = null

    @Synchronized
    fun getOrCreate(context: Context): FlutterEngine {
        engine?.let { return it }
        val appContext = context.applicationContext
        val loader = FlutterInjector.instance().flutterLoader()
        loader.startInitialization(appContext)
        loader.ensureInitializationComplete(appContext, null)
        return FlutterEngine(appContext).also { created ->
            OrexAndroidTelecomManager.attach(
                appContext,
                created.dartExecutor.binaryMessenger,
            )
            OrexPushBridge.attachEngine(
                appContext,
                created.dartExecutor.binaryMessenger,
            )
            created.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint.createDefault(),
            )
            engine = created
            Log.i(TAG, "Created process-owned Flutter engine")
        }
    }

    fun isRunning(): Boolean = engine?.dartExecutor?.isExecutingDart == true
}
