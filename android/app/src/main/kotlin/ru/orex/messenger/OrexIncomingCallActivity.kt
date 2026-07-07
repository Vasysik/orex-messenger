package ru.orex.messenger

import android.animation.Animator
import android.animation.ObjectAnimator
import android.animation.ValueAnimator
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.res.ColorStateList
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
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
 * Native Orex incoming-call surface used by the notification full-screen intent.
 * It appears over the lock screen before Flutter or the Matrix client is running,
 * but deliberately mirrors Orex's dark chocolate / walnut / copper visual system.
 */
class OrexIncomingCallActivity : Activity() {
    private val handler = Handler(Looper.getMainLooper())
    private val runningAnimators = mutableListOf<Animator>()
    private var timeout: Runnable? = null
    private var callId: String = ""
    private var displayName: String = "Orex"
    private var video: Boolean = false

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

    override fun onDestroy() {
        stopAnimations()
        timeout?.let(handler::removeCallbacks)
        timeout = null
        if (current?.get() === this) current = null
        super.onDestroy()
    }

    @Deprecated("Back does not dismiss a ringing call")
    override fun onBackPressed() {
        // A ringing call is explicitly answered or declined.
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
        callId = source.getStringExtra(EXTRA_CALL_ID)?.trim().orEmpty()
        displayName = source.getStringExtra(EXTRA_DISPLAY_NAME)?.trim().orEmpty()
            .ifEmpty { "Orex" }
        video = source.getBooleanExtra(EXTRA_VIDEO, false)
        val timeoutMs = source.getLongExtra(EXTRA_TIMEOUT_MS, DEFAULT_TIMEOUT_MS)
            .coerceIn(1_000L, MAX_TIMEOUT_MS)

        stopAnimations()
        setContentView(buildContent())
        timeout?.let(handler::removeCallbacks)
        timeout = Runnable {
            OrexNotificationCenter.cancelCall(applicationContext)
            finishAndRemoveTask()
        }.also { handler.postDelayed(it, timeoutMs) }
    }

    private fun buildContent(): View {
        val root = FrameLayout(this).apply {
            background = OrexCallBackgroundDrawable()
            isFocusable = true
        }

        root.addView(
            createBrandPill(),
            FrameLayout.LayoutParams(wrap, wrap, Gravity.TOP or Gravity.CENTER_HORIZONTAL).apply {
                topMargin = dp(44)
            },
        )

        val callerBlock = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
        }
        callerBlock.addView(
            text(displayName, 30f, Typeface.BOLD, OREX_DARK_TEXT).apply {
                gravity = Gravity.CENTER
                maxLines = 2
            },
            LinearLayout.LayoutParams(match, wrap).apply {
                marginStart = dp(28)
                marginEnd = dp(28)
            },
        )
        callerBlock.addView(
            text(
                if (video) "Входящий видеозвонок" else "Входящий звонок",
                15.5f,
                Typeface.NORMAL,
                OREX_DARK_TEXT_SOFT,
            ).apply { gravity = Gravity.CENTER },
            LinearLayout.LayoutParams(match, wrap).apply { topMargin = dp(8) },
        )
        root.addView(
            callerBlock,
            FrameLayout.LayoutParams(match, wrap, Gravity.TOP or Gravity.CENTER_HORIZONTAL).apply {
                topMargin = dp(104)
            },
        )

        val avatarHolder = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
        }
        avatarHolder.addView(createAvatar(), LinearLayout.LayoutParams(dp(174), dp(174)))
        avatarHolder.addView(
            createCallTypePill(),
            LinearLayout.LayoutParams(wrap, wrap).apply { topMargin = dp(24) },
        )
        root.addView(
            avatarHolder,
            FrameLayout.LayoutParams(match, wrap, Gravity.CENTER).apply {
                bottomMargin = dp(12)
            },
        )

        root.addView(
            createActionPanel(),
            FrameLayout.LayoutParams(match, wrap, Gravity.BOTTOM).apply {
                leftMargin = dp(20)
                rightMargin = dp(20)
                bottomMargin = dp(28)
            },
        )

        return root
    }

    private fun createBrandPill(): View {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(dp(14), dp(8), dp(14), dp(8))
            background = roundedRect(
                color = Color.argb(224, 42, 29, 20),
                radiusDp = 999,
                strokeColor = Color.argb(92, 200, 118, 60),
                strokeWidthDp = 1,
            )
            elevation = dp(8).toFloat()
        }
        row.addView(
            View(this).apply {
                background = GradientDrawable().apply {
                    shape = GradientDrawable.OVAL
                    colors = intArrayOf(OREX_COPPER_BRIGHT, OREX_WALNUT_DEEP)
                    orientation = GradientDrawable.Orientation.TL_BR
                }
            },
            LinearLayout.LayoutParams(dp(10), dp(10)).apply { marginEnd = dp(8) },
        )
        row.addView(
            text("OREX", 12f, Typeface.BOLD, OREX_OCHRE_LIGHT).apply {
                letterSpacing = 0.18f
            },
            LinearLayout.LayoutParams(wrap, wrap),
        )
        return row
    }

    private fun createAvatar(): View {
        val outer = FrameLayout(this).apply {
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                colors = intArrayOf(OREX_COPPER_BRIGHT, OREX_WALNUT_DEEP)
                orientation = GradientDrawable.Orientation.TL_BR
            }
            elevation = dp(14).toFloat()
        }
        val inner = FrameLayout(this).apply {
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                colors = intArrayOf(OREX_COPPER_BRIGHT, OREX_WALNUT_DEEP)
                orientation = GradientDrawable.Orientation.TL_BR
                setStroke(dp(1), Color.argb(118, 231, 193, 139))
            }
        }
        inner.addView(
            text(initials(displayName), 48f, Typeface.BOLD, OREX_CREAM).apply {
                gravity = Gravity.CENTER
            },
            FrameLayout.LayoutParams(match, match),
        )
        outer.addView(
            inner,
            FrameLayout.LayoutParams(dp(162), dp(162), Gravity.CENTER),
        )
        return outer
    }

    private fun createCallTypePill(): View {
        return text(
            if (video) "OREX • ВИДЕОЗВОНОК" else "OREX • ГОЛОСОВОЙ ЗВОНОК",
            11f,
            Typeface.BOLD,
            OREX_OCHRE_LIGHT,
        ).apply {
            gravity = Gravity.CENTER
            letterSpacing = 0.06f
            setPadding(dp(13), dp(7), dp(13), dp(7))
            background = roundedRect(
                color = Color.argb(112, 94, 58, 26),
                radiusDp = 999,
                strokeColor = Color.argb(72, 200, 118, 60),
                strokeWidthDp = 1,
            )
        }
    }

    private fun createActionPanel(): View {
        val actions = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            weightSum = 2f
            setPadding(dp(12), dp(15), dp(12), dp(12))
            background = roundedRect(
                color = Color.argb(232, 42, 29, 20),
                radiusDp = 30,
                strokeColor = Color.argb(58, 200, 118, 60),
                strokeWidthDp = 1,
            )
            elevation = dp(12).toFloat()
        }
        actions.addView(
            createAction(
                label = "Отклонить",
                color = OREX_DECLINE,
                haloColor = Color.argb(70, 198, 93, 88),
                rotation = 135f,
            ) { declineCall() },
            LinearLayout.LayoutParams(0, wrap, 1f),
        )
        actions.addView(
            createAction(
                label = "Ответить",
                color = OREX_ONLINE,
                haloColor = Color.argb(92, 143, 179, 106),
                rotation = 0f,
                pulse = true,
            ) { answerCall() },
            LinearLayout.LayoutParams(0, wrap, 1f),
        )
        return actions
    }

    private fun createAction(
        label: String,
        color: Int,
        haloColor: Int,
        rotation: Float,
        pulse: Boolean = false,
        onClick: () -> Unit,
    ): View {
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
        }
        val holder = FrameLayout(this)
        if (pulse) {
            val halo = View(this).apply { background = circle(haloColor) }
            holder.addView(halo, FrameLayout.LayoutParams(dp(70), dp(70), Gravity.CENTER))
            startPulse(halo)
        }
        val button = FrameLayout(this).apply {
            background = circle(color)
            isClickable = true
            isFocusable = true
            elevation = dp(8).toFloat()
            setOnClickListener { onClick() }
        }
        val icon = ImageView(this).apply {
            setImageResource(R.drawable.ic_call_white)
            imageTintList = ColorStateList.valueOf(OREX_CREAM)
            this.rotation = rotation
            scaleType = ImageView.ScaleType.CENTER_INSIDE
            setPadding(dp(19), dp(19), dp(19), dp(19))
        }
        button.addView(icon, FrameLayout.LayoutParams(match, match))
        holder.addView(button, FrameLayout.LayoutParams(dp(70), dp(70), Gravity.CENTER))
        column.addView(holder, LinearLayout.LayoutParams(dp(96), dp(96)))
        column.addView(
            text(label, 13.5f, Typeface.BOLD, OREX_DARK_TEXT).apply {
                gravity = Gravity.CENTER
            },
            LinearLayout.LayoutParams(match, wrap),
        )
        return column
    }

    private fun startPulse(view: View) {
        runningAnimators += ObjectAnimator.ofFloat(view, View.SCALE_X, 1f, 1.52f).apply {
            duration = 1450L
            repeatCount = ValueAnimator.INFINITE
            start()
        }
        runningAnimators += ObjectAnimator.ofFloat(view, View.SCALE_Y, 1f, 1.52f).apply {
            duration = 1450L
            repeatCount = ValueAnimator.INFINITE
            start()
        }
        runningAnimators += ObjectAnimator.ofFloat(view, View.ALPHA, 0.64f, 0f).apply {
            duration = 1450L
            repeatCount = ValueAnimator.INFINITE
            start()
        }
    }

    private fun stopAnimations() {
        runningAnimators.forEach(Animator::cancel)
        runningAnimators.clear()
    }

    private fun answerCall() {
        if (callId.isEmpty()) return
        OrexNotificationCenter.cancelCall(applicationContext)
        OrexPushBridge.launchIncomingCallAction(
            context = applicationContext,
            callId = callId,
            displayName = displayName,
            video = video,
            action = "answer",
            fromSystem = false,
        )
        finishAndRemoveTask()
    }

    private fun declineCall() {
        if (callId.isEmpty()) return
        OrexNotificationCenter.cancelCall(applicationContext)
        OrexPushBridge.launchIncomingCallAction(
            context = applicationContext,
            callId = callId,
            displayName = displayName,
            video = video,
            action = "reject",
            fromSystem = false,
        )
        finishAndRemoveTask()
    }

    private fun text(
        value: String,
        sizeSp: Float,
        style: Int,
        color: Int,
    ): TextView = TextView(this).apply {
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

    private fun roundedRect(
        color: Int,
        radiusDp: Int,
        strokeColor: Int,
        strokeWidthDp: Int,
    ) = GradientDrawable().apply {
        shape = GradientDrawable.RECTANGLE
        cornerRadius = dp(radiusDp).toFloat()
        setColor(color)
        if (strokeWidthDp > 0) setStroke(dp(strokeWidthDp), strokeColor)
    }

    private fun initials(value: String): String {
        val parts = value.trim().split(Regex("\\s+")).filter { it.isNotEmpty() }
        if (parts.isEmpty()) return "O"
        return parts.take(2).mapNotNull { it.firstOrNull()?.uppercase() }.joinToString("")
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    companion object {
        private const val EXTRA_CALL_ID = "orex_call_id"
        private const val EXTRA_DISPLAY_NAME = "orex_display_name"
        private const val EXTRA_VIDEO = "orex_video"
        private const val EXTRA_TIMEOUT_MS = "orex_timeout_ms"
        private const val DEFAULT_TIMEOUT_MS = 45_000L
        private const val MAX_TIMEOUT_MS = 90_000L
        private const val match = -1
        private const val wrap = -2

        private val OREX_DARK_BG = Color.rgb(28, 20, 14)
        private val OREX_DARK_TEXT = Color.rgb(243, 230, 213)
        private val OREX_DARK_TEXT_SOFT = Color.rgb(179, 154, 130)
        private val OREX_CREAM = Color.rgb(251, 245, 236)
        private val OREX_COPPER_BRIGHT = Color.rgb(217, 140, 74)
        private val OREX_WALNUT_DEEP = Color.rgb(94, 58, 26)
        private val OREX_OCHRE_LIGHT = Color.rgb(231, 193, 139)
        private val OREX_ONLINE = Color.rgb(143, 179, 106)
        private val OREX_DECLINE = Color.rgb(198, 93, 88)

        @Volatile
        private var current: WeakReference<OrexIncomingCallActivity>? = null

        fun createIntent(
            context: Context,
            callId: String,
            displayName: String,
            video: Boolean,
            timeoutAfterMs: Long,
        ): Intent = Intent(context, OrexIncomingCallActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(EXTRA_CALL_ID, callId)
            putExtra(EXTRA_DISPLAY_NAME, displayName)
            putExtra(EXTRA_VIDEO, video)
            putExtra(EXTRA_TIMEOUT_MS, timeoutAfterMs)
        }

        fun finishActive() {
            val activity = current?.get() ?: return
            activity.runOnUiThread {
                if (!activity.isFinishing) activity.finishAndRemoveTask()
            }
        }
    }
}

private class OrexCallBackgroundDrawable : Drawable() {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)

    override fun draw(canvas: Canvas) {
        val w = bounds.width().toFloat()
        val h = bounds.height().toFloat()

        paint.shader = LinearGradient(
            0f,
            0f,
            w,
            h,
            intArrayOf(
                Color.rgb(58, 36, 21),
                Color.rgb(36, 25, 18),
                Color.rgb(28, 20, 14),
            ),
            floatArrayOf(0f, 0.48f, 1f),
            Shader.TileMode.CLAMP,
        )
        canvas.drawRect(
            bounds.left.toFloat(),
            bounds.top.toFloat(),
            bounds.right.toFloat(),
            bounds.bottom.toFloat(),
            paint,
        )

        paint.shader = RadialGradient(
            w * 0.82f,
            h * 0.18f,
            w * 0.72f,
            intArrayOf(Color.argb(92, 200, 118, 60), Color.TRANSPARENT),
            null,
            Shader.TileMode.CLAMP,
        )
        canvas.drawCircle(w * 0.82f, h * 0.18f, w * 0.72f, paint)

        paint.shader = RadialGradient(
            w * 0.10f,
            h * 0.82f,
            w * 0.62f,
            intArrayOf(Color.argb(64, 217, 160, 91), Color.TRANSPARENT),
            null,
            Shader.TileMode.CLAMP,
        )
        canvas.drawCircle(w * 0.10f, h * 0.82f, w * 0.62f, paint)

        paint.shader = RadialGradient(
            w * 0.50f,
            h * 0.52f,
            w * 0.42f,
            intArrayOf(Color.argb(36, 139, 90, 43), Color.TRANSPARENT),
            null,
            Shader.TileMode.CLAMP,
        )
        canvas.drawCircle(w * 0.50f, h * 0.52f, w * 0.42f, paint)
        paint.shader = null
    }

    override fun setAlpha(alpha: Int) = Unit
    override fun setColorFilter(colorFilter: android.graphics.ColorFilter?) = Unit
    @Deprecated("Deprecated in Android framework")
    override fun getOpacity(): Int = PixelFormat.OPAQUE
}
