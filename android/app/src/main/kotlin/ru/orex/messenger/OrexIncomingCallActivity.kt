package ru.orex.messenger

import android.app.Activity
import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.content.res.ColorStateList
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.RadialGradient
import android.graphics.Shader
import android.graphics.Typeface
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import java.lang.ref.WeakReference

/**
 * Отдельная task для входящего звонка до запуска Flutter.
 *
 * Структура намеренно повторяет уже существующий Flutter IncomingCallScreen:
 * ambient Orex background -> avatar/name/status по центру -> три действия снизу.
 * После Answer оболочка сразу передаёт действие foreground runtime и закрывается.
 * Единственная поверхность подключения — Flutter CallScreen; если устройство
 * заблокировано, сервис уже подключает медиа, пока MainActivity ждёт unlock.
 */
class OrexIncomingCallActivity : Activity() {
    private val handler = Handler(Looper.getMainLooper())
    private var ringTimeout: Runnable? = null
    private var answerTimeout: Runnable? = null
    private var callId: String = ""
    private var ringEventId: String? = null
    private var displayName: String = "Orex"
    private var avatarCacheKey: String? = null
    private var incomingVideo: Boolean = false
    private var systemManaged: Boolean = false
    private var handoffStarted = false
    private var flutterBootstrapCovered = false
    private var unlockForAnswerInProgress = false
    private var pendingAnswerVideo: Boolean? = null
    private var telecomAnswerAfterUnlock = false
    private var statusText: TextView? = null
    private var avatarSlot: FrameLayout? = null
    private var actionsRow: View? = null
    private var progress: View? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        current = WeakReference(this)
        configureWindow()
        render(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        render(intent)
    }

    override fun onResume() {
        super.onResume()
        if (unlockForAnswerInProgress && !isDeviceLocked()) {
            handler.post { continueAnswerAfterUnlock() }
            return
        }
        if (handoffStarted && flutterBootstrapCovered && !isDeviceLocked()) {
            finishAndRemoveTask()
        }
    }

    override fun onDestroy() {
        ringTimeout?.let(handler::removeCallbacks)
        ringTimeout = null
        answerTimeout?.let(handler::removeCallbacks)
        answerTimeout = null
        if (current?.get() === this) current = null
        super.onDestroy()
    }

    @Deprecated("Back does not dismiss a ringing call")
    override fun onBackPressed() {
        // Входящий вызов закрывается только явным действием.
    }

    private fun configureWindow() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON,
            )
        }
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        window.statusBarColor = Color.TRANSPARENT
        window.navigationBarColor = OREX_DARK_BG
        @Suppress("DEPRECATION")
        window.decorView.systemUiVisibility =
            View.SYSTEM_UI_FLAG_LAYOUT_STABLE or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
    }

    private fun render(source: Intent) {
        val nextCallId = source.getStringExtra(EXTRA_CALL_ID)?.trim().orEmpty()
        val nextRingEventId = normalizeRingEventId(source.getStringExtra(EXTRA_RING_EVENT_ID))
        if (nextCallId.isEmpty() ||
            !OrexCallPresentationState.canPresentCallAttempt(
                applicationContext,
                nextCallId,
                nextRingEventId,
            )
        ) {
            if (callId.isEmpty()) finishAndRemoveTask()
            return
        }
        val changedAttempt = !sameCallAttempt(
            callId,
            ringEventId,
            nextCallId,
            nextRingEventId,
        )
        if (changedAttempt) {
            handoffStarted = false
            flutterBootstrapCovered = false
            unlockForAnswerInProgress = false
            pendingAnswerVideo = null
            telecomAnswerAfterUnlock = false
            ringTimeout?.let(handler::removeCallbacks)
            ringTimeout = null
            answerTimeout?.let(handler::removeCallbacks)
            answerTimeout = null
        }
        callId = nextCallId
        ringEventId = nextRingEventId
        displayName = source.getStringExtra(EXTRA_DISPLAY_NAME)?.trim().orEmpty().ifEmpty { "Orex" }
        avatarCacheKey = source.getStringExtra(EXTRA_AVATAR_CACHE_KEY)?.trim()?.ifEmpty { null }
        incomingVideo = source.getBooleanExtra(EXTRA_VIDEO, false)
        systemManaged = source.getBooleanExtra(EXTRA_SYSTEM_MANAGED, false)
        val timeoutMs = source.getLongExtra(EXTRA_TIMEOUT_MS, DEFAULT_TIMEOUT_MS)
            .coerceIn(1_000L, MAX_TIMEOUT_MS)
        val requestedAction = source.getStringExtra(EXTRA_ACTION)?.trim()
        showIncomingSurface(timeoutMs, rebuild = changedAttempt)
        when (requestedAction) {
            ACTION_ANSWER -> {
                handler.post { beginAnswer(incomingVideo) }
                return
            }
            ACTION_ANSWER_VIDEO -> {
                handler.post { beginAnswer(true) }
                return
            }
            ACTION_TELECOM_ANSWER_AFTER_UNLOCK -> {
                telecomAnswerAfterUnlock = true
                handler.post { beginAnswer(incomingVideo) }
                return
            }
            ACTION_REJECT -> {
                handler.post { declineCall() }
                return
            }
        }
    }

    private fun showIncomingSurface(timeoutMs: Long, rebuild: Boolean) {
        if (handoffStarted) return
        if (rebuild || statusText == null) {
            setContentView(buildContent())
        }
        if (ringTimeout != null) return
        ringTimeout = Runnable {
            OrexNotificationCenter.cancelCall(applicationContext, callId, ringEventId)
            finishAndRemoveTask()
        }.also { handler.postDelayed(it, timeoutMs) }
    }

    private fun buildContent(): View {
        val root = FrameLayout(this).apply {
            background = OrexAmbientBackgroundDrawable()
            isFocusable = true
        }

        val center = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
        }
        val avatar = FrameLayout(this).apply {
            addView(createAvatar(), FrameLayout.LayoutParams(match, match))
        }
        avatarSlot = avatar
        center.addView(avatar, LinearLayout.LayoutParams(dp(120), dp(120)))
        center.addView(
            text(displayName, 23f, Typeface.BOLD, OREX_DARK_TEXT).apply {
                gravity = Gravity.CENTER
                maxLines = 2
                setPadding(dp(24), 0, dp(24), 0)
            },
            LinearLayout.LayoutParams(match, wrap).apply { topMargin = dp(16) },
        )
        statusText = text("Входящий звонок…", 14.5f, Typeface.NORMAL, OREX_DARK_TEXT_SOFT).apply {
            gravity = Gravity.CENTER
        }
        center.addView(
            statusText,
            LinearLayout.LayoutParams(match, wrap).apply { topMargin = dp(4) },
        )
        progress = OrexIndeterminateSpinnerView(this, OREX_COPPER).apply {
            visibility = View.GONE
        }
        center.addView(
            progress,
            LinearLayout.LayoutParams(dp(32), dp(32)).apply { topMargin = dp(16) },
        )
        root.addView(
            center,
            FrameLayout.LayoutParams(match, wrap, Gravity.CENTER).apply { bottomMargin = dp(48) },
        )

        actionsRow = createActionsRow()
        root.addView(
            actionsRow,
            FrameLayout.LayoutParams(match, wrap, Gravity.BOTTOM).apply {
                leftMargin = dp(24)
                rightMargin = dp(24)
                bottomMargin = dp(40)
            },
        )
        return root
    }

    private fun createAvatar(): View {
        val cached = OrexAvatarCache.load(this, avatarCacheKey)
        if (cached != null) {
            return ImageView(this).apply {
                background = circle(OREX_WALNUT_DEEP)
                clipToOutline = true
                elevation = dp(8).toFloat()
                scaleType = ImageView.ScaleType.CENTER_CROP
                setImageBitmap(cached)
                contentDescription = "Аватар $displayName"
            }
        }

        val avatar = FrameLayout(this).apply {
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                colors = intArrayOf(OREX_COPPER_BRIGHT, OREX_WALNUT_DEEP)
                orientation = GradientDrawable.Orientation.TL_BR
            }
            elevation = dp(8).toFloat()
        }
        avatar.addView(
            text(initials(displayName), 38f, Typeface.BOLD, OREX_CREAM).apply {
                gravity = Gravity.CENTER
            },
            FrameLayout.LayoutParams(match, match),
        )
        return avatar
    }

    private fun refreshAvatar(nextKey: String) {
        if (nextKey.isBlank()) return
        avatarCacheKey = nextKey
        val slot = avatarSlot ?: return
        val cached = OrexAvatarCache.load(this, nextKey) ?: return
        slot.removeAllViews()
        slot.addView(
            ImageView(this).apply {
                background = circle(OREX_WALNUT_DEEP)
                clipToOutline = true
                elevation = dp(8).toFloat()
                scaleType = ImageView.ScaleType.CENTER_CROP
                setImageBitmap(cached)
                contentDescription = "Аватар $displayName"
            },
            FrameLayout.LayoutParams(match, match),
        )
    }

    private fun createActionsRow(): View {
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            weightSum = 3f
            addView(
                createAction(
                    icon = R.drawable.ic_call_white,
                    label = "Отклонить",
                    color = OREX_DECLINE,
                    rotation = 135f,
                ) { declineCall() },
                LinearLayout.LayoutParams(0, wrap, 1f),
            )
            addView(
                createAction(
                    icon = android.R.drawable.ic_menu_camera,
                    label = "Видео",
                    color = OREX_COPPER,
                ) { beginAnswer(true) },
                LinearLayout.LayoutParams(0, wrap, 1f),
            )
            addView(
                createAction(
                    icon = R.drawable.ic_call_white,
                    label = "Ответить",
                    color = OREX_ONLINE,
                ) { beginAnswer(false) },
                LinearLayout.LayoutParams(0, wrap, 1f),
            )
        }
    }

    private fun createAction(
        icon: Int,
        label: String,
        color: Int,
        rotation: Float = 0f,
        onClick: () -> Unit,
    ): View {
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
        }
        val button = FrameLayout(this).apply {
            background = circle(color)
            isClickable = true
            isFocusable = true
            elevation = dp(6).toFloat()
            setOnClickListener { onClick() }
        }
        button.addView(
            ImageView(this).apply {
                setImageResource(icon)
                imageTintList = ColorStateList.valueOf(OREX_CREAM)
                this.rotation = rotation
                scaleType = ImageView.ScaleType.CENTER_INSIDE
                setPadding(dp(17), dp(17), dp(17), dp(17))
            },
            FrameLayout.LayoutParams(match, match),
        )
        column.addView(button, LinearLayout.LayoutParams(dp(60), dp(60)))
        column.addView(
            text(label, 12.5f, Typeface.NORMAL, OREX_DARK_TEXT_SOFT).apply {
                gravity = Gravity.CENTER
            },
            LinearLayout.LayoutParams(match, wrap).apply { topMargin = dp(8) },
        )
        return column
    }

    private fun beginAnswer(useVideo: Boolean) {
        if (callId.isEmpty() || handoffStarted) return
        if (isDeviceLocked()) {
            requestUnlockForAnswer(useVideo)
            return
        }

        startAnswerHandoff(useVideo)
    }

    private fun requestUnlockForAnswer(useVideo: Boolean) {
        if (unlockForAnswerInProgress) return
        unlockForAnswerInProgress = true
        pendingAnswerVideo = useVideo
        statusText?.text = "Разблокируйте телефон, чтобы ответить"
        progress?.visibility = View.GONE
        actionsRow?.visibility = View.VISIBLE
        setEnabledRecursively(actionsRow, false)

        // Android 8+ presents the system credential flow over this trusted
        // showWhenLocked surface. Older devices resume here after the user
        // unlocks normally, which onResume handles below.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val keyguard = getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager
        if (keyguard == null) {
            restoreAfterUnlockCancelled()
            return
        }
        keyguard.requestDismissKeyguard(
            this,
            object : KeyguardManager.KeyguardDismissCallback() {
                override fun onDismissSucceeded() {
                    handler.post { continueAnswerAfterUnlock() }
                }

                override fun onDismissCancelled() {
                    handler.post { restoreAfterUnlockCancelled() }
                }

                override fun onDismissError() {
                    handler.post { restoreAfterUnlockCancelled() }
                }
            },
        )
    }

    private fun continueAnswerAfterUnlock() {
        if (!unlockForAnswerInProgress || handoffStarted || isFinishing) return
        if (isDeviceLocked()) return
        val useVideo = pendingAnswerVideo ?: incomingVideo
        unlockForAnswerInProgress = false
        pendingAnswerVideo = null
        beginAnswer(useVideo)
    }

    private fun restoreAfterUnlockCancelled() {
        if (!unlockForAnswerInProgress) return
        unlockForAnswerInProgress = false
        pendingAnswerVideo = null
        if (handoffStarted || isFinishing) return
        statusText?.text = "Входящий звонок…"
        progress?.visibility = View.GONE
        actionsRow?.visibility = View.VISIBLE
        setEnabledRecursively(actionsRow, true)
    }

    private fun startAnswerHandoff(useVideo: Boolean) {
        handoffStarted = true
        ringTimeout?.let(handler::removeCallbacks)
        ringTimeout = null

        statusText?.text = "Подключаем к звонку…"
        progress?.visibility = View.VISIBLE
        actionsRow?.visibility = View.INVISIBLE
        setEnabledRecursively(actionsRow, false)

        val accepted = if (telecomAnswerAfterUnlock) {
            OrexAndroidTelecomManager.continueTelecomAnswerAfterUnlock(
                context = this,
                callId = callId,
                ringEventId = ringEventId,
            )
        } else {
            OrexPushBridge.acceptIncomingCallFromNativeAction(
                context = this,
                callId = callId,
                ringEventId = ringEventId,
                displayName = displayName,
                video = useVideo,
                fromSystem = systemManaged,
                bringUiToFront = true,
            )
        }
        if (!accepted) {
            restoreAfterFailedHandoff("Не удалось запустить звонок")
            handler.postDelayed({
                if (!isFinishing) finishAndRemoveTask()
            }, FAILURE_MESSAGE_VISIBLE_MS)
            return
        }

        // Keep the trusted lock-screen surface until Flutter has actually
        // bootstrapped the call UI. Closing it immediately makes MainActivity
        // race the keyguard and can expose the connecting screen without the
        // expected device-unlock flow.
        scheduleAnswerTimeout()
    }

    private fun scheduleAnswerTimeout() {
        answerTimeout?.let(handler::removeCallbacks)
        answerTimeout = Runnable {
            failAnswerBootstrap("Не удалось подключиться к звонку", stopService = true)
        }.also {
            handler.postDelayed(it, OrexCallForegroundService.ANSWERING_TIMEOUT_MS)
        }
    }

    private fun failAnswerBootstrap(message: String, stopService: Boolean) {
        if (!handoffStarted || isFinishing) return
        answerTimeout?.let(handler::removeCallbacks)
        answerTimeout = null
        if (OrexCallForegroundService.isAnsweredCall(
                applicationContext,
                callId,
                ringEventId,
            )
        ) {
            finishAndRemoveTask()
            return
        }
        OrexPushBridge.cancelPendingCallAction(applicationContext, callId, ringEventId)
        if (stopService) {
            OrexCallForegroundService.stop(applicationContext, callId, ringEventId)
        }
        restoreAfterFailedHandoff(message)
        handler.postDelayed({
            if (!isFinishing) finishAndRemoveTask()
        }, FAILURE_MESSAGE_VISIBLE_MS)
    }

    private fun onFlutterBootstrapCovered() {
        if (!handoffStarted || isFinishing) return
        flutterBootstrapCovered = true
        if (!isDeviceLocked()) {
            finishAndRemoveTask()
            return
        }
        statusText?.text = "Подключаем к звонку… · разблокируйте телефон"
        val keyguard = getSystemService(KeyguardManager::class.java)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        keyguard.requestDismissKeyguard(
            this,
            object : KeyguardManager.KeyguardDismissCallback() {
                override fun onDismissSucceeded() {
                    if (!isFinishing) finishAndRemoveTask()
                }

                override fun onDismissCancelled() = Unit
                override fun onDismissError() = Unit
            },
        )
    }

    private fun isDeviceLocked(): Boolean =
        getSystemService(KeyguardManager::class.java).isKeyguardLocked

    private fun declineCall() {
        if (callId.isEmpty()) return
        if (!OrexCallPresentationState.markEnded(applicationContext, callId, ringEventId)) {
            finishAndRemoveTask()
            return
        }
        OrexNotificationCenter.cancelCallNotification(applicationContext)
        if (systemManaged) {
            OrexAndroidTelecomManager.handleNotificationAction(
                Intent().apply {
                    action = OrexAndroidTelecomManager.ACTION_DECLINE
                    putExtra(OrexAndroidTelecomManager.EXTRA_CALL_ID, callId)
                    ringEventId?.let {
                        putExtra(OrexAndroidTelecomManager.EXTRA_RING_EVENT_ID, it)
                    }
                },
            )
        } else {
            OrexPushBridge.launchIncomingCallAction(
                context = this,
                callId = callId,
                ringEventId = ringEventId,
                displayName = displayName,
                video = incomingVideo,
                action = "reject",
                fromSystem = false,
                bringUiToFront = false,
            )
        }
        finishAndRemoveTask()
    }

    private fun restoreAfterFailedHandoff(message: String) {
        OrexCallPresentationState.markEnded(applicationContext, callId, ringEventId)
        handoffStarted = false
        flutterBootstrapCovered = false
        telecomAnswerAfterUnlock = false
        statusText?.text = message
        progress?.visibility = View.GONE
        actionsRow?.visibility = View.VISIBLE
        setEnabledRecursively(actionsRow, true)
    }

    private fun setEnabledRecursively(view: View?, enabled: Boolean) {
        if (view == null) return
        view.isEnabled = enabled
        view.isClickable = enabled
        if (view is android.view.ViewGroup) {
            for (index in 0 until view.childCount) {
                setEnabledRecursively(view.getChildAt(index), enabled)
            }
        }
    }

    private fun text(value: String, sizeSp: Float, style: Int, color: Int): TextView =
        TextView(this).apply {
            text = value
            textSize = sizeSp
            setTextColor(color)
            typeface = Typeface.create("sans-serif", style)
            includeFontPadding = false
        }

    private fun circle(color: Int) = GradientDrawable().apply {
        shape = GradientDrawable.OVAL
        setColor(color)
    }

    private fun initials(value: String): String {
        val parts = value.trim().split(Regex("\\s+")).filter { it.isNotEmpty() }
        if (parts.isEmpty()) return "O"
        return parts.take(2).mapNotNull { it.firstOrNull()?.uppercase() }.joinToString("")
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    companion object {
        private const val EXTRA_CALL_ID = "orex_call_id"
        private const val EXTRA_RING_EVENT_ID = "orex_ring_event_id"
        private const val EXTRA_DISPLAY_NAME = "orex_display_name"
        private const val EXTRA_AVATAR_CACHE_KEY = "orex_avatar_cache_key"
        private const val EXTRA_VIDEO = "orex_video"
        private const val EXTRA_TIMEOUT_MS = "orex_timeout_ms"
        private const val EXTRA_ACTION = "orex_action"
        private const val EXTRA_SYSTEM_MANAGED = "orex_system_managed"
        private const val ACTION_ANSWER = "answer"
        private const val ACTION_ANSWER_VIDEO = "answer_video"
        private const val ACTION_REJECT = "reject"
        const val ACTION_TELECOM_ANSWER_AFTER_UNLOCK = "telecom_answer_after_unlock"
        private const val DEFAULT_TIMEOUT_MS = OrexCallPresentationState.INCOMING_RING_TIMEOUT_MS
        private const val MAX_TIMEOUT_MS = 90_000L
        private const val FAILURE_MESSAGE_VISIBLE_MS = 1_500L
        private const val match = -1
        private const val wrap = -2

        private val OREX_DARK_BG = Color.rgb(28, 20, 14)
        private val OREX_DARK_TEXT = Color.rgb(243, 230, 213)
        private val OREX_DARK_TEXT_SOFT = Color.rgb(179, 154, 130)
        private val OREX_CREAM = Color.rgb(251, 245, 236)
        private val OREX_COPPER = Color.rgb(200, 118, 60)
        private val OREX_COPPER_BRIGHT = Color.rgb(217, 140, 74)
        private val OREX_WALNUT_DEEP = Color.rgb(94, 58, 26)
        private val OREX_ONLINE = Color.rgb(143, 179, 106)
        private val OREX_DECLINE = Color.rgb(207, 102, 121)

        @Volatile
        private var current: WeakReference<OrexIncomingCallActivity>? = null

        fun createIntent(
            context: Context,
            callId: String,
            ringEventId: String? = null,
            displayName: String,
            video: Boolean,
            timeoutAfterMs: Long,
            action: String? = null,
            systemManaged: Boolean = false,
            avatarCacheKey: String? = null,
        ): Intent = Intent(context, OrexIncomingCallActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(EXTRA_CALL_ID, callId)
            normalizeRingEventId(ringEventId)?.let { putExtra(EXTRA_RING_EVENT_ID, it) }
            putExtra(EXTRA_DISPLAY_NAME, displayName)
            if (!avatarCacheKey.isNullOrBlank()) putExtra(EXTRA_AVATAR_CACHE_KEY, avatarCacheKey)
            putExtra(EXTRA_VIDEO, video)
            putExtra(EXTRA_TIMEOUT_MS, timeoutAfterMs)
            if (!action.isNullOrBlank()) putExtra(EXTRA_ACTION, action)
            putExtra(EXTRA_SYSTEM_MANAGED, systemManaged)
        }

        fun onFlutterBootstrapCovered(callId: String, ringEventId: String?) {
            val activity = current?.get() ?: return
            val sameAttempt = sameCallAttempt(
                activity.callId,
                activity.ringEventId,
                callId,
                ringEventId,
            )
            val canPromoteAttempt = activity.callId == callId &&
                canPromoteRingAttempt(activity.ringEventId, ringEventId)
            if (!sameAttempt && !canPromoteAttempt) return
            if (canPromoteAttempt) activity.ringEventId = normalizeRingEventId(ringEventId)
            activity.runOnUiThread { activity.onFlutterBootstrapCovered() }
        }

        fun onCallUiReady(callId: String, ringEventId: String?) {
            onFlutterBootstrapCovered(callId, ringEventId)
        }

        fun onAnswerBootstrapFailed(callId: String, ringEventId: String?) {
            val activity = current?.get() ?: return
            if (!sameOrPromotableCallAttempt(
                    activity.callId,
                    activity.ringEventId,
                    callId,
                    ringEventId,
                )
            ) return
            activity.runOnUiThread {
                activity.failAnswerBootstrap(
                    "Не удалось подключиться к звонку",
                    stopService = false,
                )
            }
        }

        fun finishActive() {
            val activity = current?.get() ?: return
            activity.runOnUiThread {
                if (!activity.isFinishing) activity.finishAndRemoveTask()
            }
        }

        fun updateAvatarForCall(
            callId: String,
            ringEventId: String?,
            avatarCacheKey: String,
        ) {
            val activity = current?.get() ?: return
            val sameAttempt = sameCallAttempt(
                    activity.callId,
                    activity.ringEventId,
                    callId,
                    ringEventId,
                )
            val canPromoteAttempt = activity.callId == callId &&
                canPromoteRingAttempt(activity.ringEventId, ringEventId)
            if (!sameAttempt && !canPromoteAttempt) return
            if (canPromoteAttempt) activity.ringEventId = normalizeRingEventId(ringEventId)
            activity.runOnUiThread {
                if (!activity.isFinishing) activity.refreshAvatar(avatarCacheKey)
            }
        }

        fun finishForCall(callId: String, ringEventId: String? = null) {
            val activity = current?.get() ?: return
            val sameAttempt = sameCallAttempt(
                    activity.callId,
                    activity.ringEventId,
                    callId,
                    ringEventId,
                )
            val canPromoteAttempt = activity.callId == callId &&
                canPromoteRingAttempt(activity.ringEventId, ringEventId)
            if (!sameAttempt && !canPromoteAttempt) return
            if (canPromoteAttempt) activity.ringEventId = normalizeRingEventId(ringEventId)
            activity.runOnUiThread {
                if (!activity.isFinishing) activity.finishAndRemoveTask()
            }
        }

        fun promoteAttemptForCall(callId: String, ringEventId: String?) {
            val activity = current?.get() ?: return
            if (activity.callId != callId ||
                !canPromoteRingAttempt(activity.ringEventId, ringEventId)
            ) return
            activity.ringEventId = normalizeRingEventId(ringEventId)
        }
    }
}

/** Native approximation of Flutter AmbientBackground from glass.dart. */
internal class OrexAmbientBackgroundDrawable : Drawable() {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)

    override fun draw(canvas: Canvas) {
        val w = bounds.width().toFloat()
        val h = bounds.height().toFloat()
        canvas.drawColor(Color.rgb(28, 20, 14))

        paint.shader = RadialGradient(
            w * 0.20f,
            h * 0.16f,
            maxOf(w, h) * 0.95f,
            intArrayOf(Color.rgb(58, 36, 21), Color.rgb(28, 20, 14)),
            null,
            Shader.TileMode.CLAMP,
        )
        canvas.drawRect(0f, 0f, w, h, paint)

        paint.shader = RadialGradient(
            w * 0.92f,
            h * 0.10f,
            w * 0.48f,
            intArrayOf(Color.argb(56, 200, 118, 60), Color.TRANSPARENT),
            null,
            Shader.TileMode.CLAMP,
        )
        canvas.drawCircle(w * 0.92f, h * 0.10f, w * 0.48f, paint)

        paint.shader = RadialGradient(
            w * 0.08f,
            h * 0.92f,
            w * 0.56f,
            intArrayOf(Color.argb(41, 217, 160, 91), Color.TRANSPARENT),
            null,
            Shader.TileMode.CLAMP,
        )
        canvas.drawCircle(w * 0.08f, h * 0.92f, w * 0.56f, paint)
        paint.shader = null
    }

    override fun setAlpha(alpha: Int) = Unit
    override fun setColorFilter(colorFilter: android.graphics.ColorFilter?) = Unit
    @Deprecated("Deprecated in Android framework")
    override fun getOpacity(): Int = PixelFormat.OPAQUE
}
