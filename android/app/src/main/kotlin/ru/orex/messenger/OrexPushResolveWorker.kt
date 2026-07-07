package ru.orex.messenger

import android.content.Context
import android.util.Log
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume

/**
 * Resolves one Matrix push outside FirebaseMessagingService.
 *
 * The worker may open the encrypted Matrix cache, fetch the exact event and
 * wait for missing Megolm keys. None of that work is allowed to block FCM.
 */
class OrexPushResolveWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {

    override suspend fun doWork(): Result {
        val payload = decodePayload(inputData.getString(KEY_PAYLOAD_JSON))
        if (payload.isEmpty()) return Result.success()

        val resolved = withTimeoutOrNull(WORK_TIMEOUT_MS) {
            suspendCancellableCoroutine<Map<String, String>?> { continuation ->
                OrexPushBridge.resolvePushPayload(applicationContext, payload) { value ->
                    if (continuation.isActive) continuation.resume(value)
                }
            }
        }

        if (resolved == null) {
            Log.w(TAG, "Matrix push resolution unavailable attempt=$runAttemptCount")
            return if (runAttemptCount < MAX_RETRIES) Result.retry() else Result.success()
        }

        OrexPushBridge.handleResolvedPush(applicationContext, resolved)
        return Result.success()
    }

    companion object {
        private const val TAG = "OrexPushWorker"
        private const val KEY_PAYLOAD_JSON = "payload_json"
        private const val WORK_TIMEOUT_MS = 85_000L
        private const val MAX_RETRIES = 2

        fun enqueue(context: Context, payload: Map<String, String>) {
            if (payload.isEmpty()) return
            val encoded = JSONObject(payload).toString()
            val input = try {
                Data.Builder().putString(KEY_PAYLOAD_JSON, encoded).build()
            } catch (error: IllegalStateException) {
                Log.e(TAG, "Push payload exceeds WorkManager Data limit", error)
                return
            }

            val constraints = Constraints.Builder()
                .setRequiredNetworkType(NetworkType.CONNECTED)
                .build()
            val request = OneTimeWorkRequestBuilder<OrexPushResolveWorker>()
                .setInputData(input)
                .setConstraints(constraints)
                .setBackoffCriteria(BackoffPolicy.LINEAR, 10L, TimeUnit.SECONDS)
                .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
                .build()

            val identity = payload["event_id"]
                ?: payload["message_id"]
                ?: "${payload["room_id"].orEmpty()}|${payload.hashCode()}"
            val workName = "orex_push_resolve_${identity.hashCode()}"
            WorkManager.getInstance(context.applicationContext).enqueueUniqueWork(
                workName,
                ExistingWorkPolicy.KEEP,
                request,
            )
            Log.i(TAG, "Queued Matrix push resolution work=$workName")
        }

        private fun decodePayload(encoded: String?): Map<String, String> {
            if (encoded.isNullOrBlank()) return emptyMap()
            return try {
                val json = JSONObject(encoded)
                val result = linkedMapOf<String, String>()
                val keys = json.keys()
                while (keys.hasNext()) {
                    val key = keys.next()
                    result[key] = json.optString(key, "")
                }
                result
            } catch (error: Throwable) {
                Log.w(TAG, "Failed to decode queued Matrix push", error)
                emptyMap()
            }
        }
    }
}
