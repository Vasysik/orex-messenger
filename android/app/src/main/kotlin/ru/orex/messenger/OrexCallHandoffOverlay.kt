package ru.orex.messenger

import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView

/**
 * Native cover shown above Flutter while a cold/background incoming answer is
 * being converted into the expanded Flutter call route.
 *
 * MainActivity is allowed to boot and build its navigator underneath this view,
 * but the user never sees a half-initialized messenger screen. The overlay is
 * removed only after Flutter reports that CallScreen has been pushed.
 */
internal class OrexCallHandoffOverlay(
    context: Context,
    displayName: String,
    avatarCacheKey: String?,
) : FrameLayout(context) {
    init {
        background = OrexAmbientBackgroundDrawable()
        isClickable = true
        isFocusable = true
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES

        val center = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
        }
        center.addView(createAvatar(context, displayName, avatarCacheKey), LayoutParams(dp(120), dp(120)))
        center.addView(
            text(context, displayName, 23f, Typeface.BOLD, OREX_DARK_TEXT).apply {
                gravity = Gravity.CENTER
                maxLines = 2
                setPadding(dp(24), 0, dp(24), 0)
            },
            LinearLayout.LayoutParams(match, wrap).apply { topMargin = dp(16) },
        )
        center.addView(
            text(
                context,
                "Подключаем к звонку…",
                14.5f,
                Typeface.NORMAL,
                OREX_DARK_TEXT_SOFT,
            ).apply { gravity = Gravity.CENTER },
            LinearLayout.LayoutParams(match, wrap).apply { topMargin = dp(4) },
        )
        center.addView(
            OrexIndeterminateSpinnerView(context, OREX_COPPER),
            LinearLayout.LayoutParams(dp(32), dp(32)).apply { topMargin = dp(16) },
        )
        addView(center, LayoutParams(match, wrap, Gravity.CENTER).apply { bottomMargin = dp(48) })
    }

    private fun createAvatar(
        context: Context,
        displayName: String,
        avatarCacheKey: String?,
    ): View {
        val cached = OrexAvatarCache.load(context, avatarCacheKey)
        if (cached != null) {
            return ImageView(context).apply {
                background = circle(OREX_WALNUT_DEEP)
                clipToOutline = true
                elevation = dp(8).toFloat()
                scaleType = ImageView.ScaleType.CENTER_CROP
                setImageBitmap(cached)
                contentDescription = "Аватар $displayName"
            }
        }

        return FrameLayout(context).apply {
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                colors = intArrayOf(OREX_COPPER_BRIGHT, OREX_WALNUT_DEEP)
                orientation = GradientDrawable.Orientation.TL_BR
            }
            elevation = dp(8).toFloat()
            addView(
                text(context, initials(displayName), 38f, Typeface.BOLD, OREX_CREAM).apply {
                    gravity = Gravity.CENTER
                },
                LayoutParams(match, match),
            )
        }
    }

    private fun text(
        context: Context,
        value: String,
        sizeSp: Float,
        style: Int,
        color: Int,
    ): TextView = TextView(context).apply {
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
        private const val match = -1
        private const val wrap = -2
        private val OREX_DARK_TEXT = Color.rgb(243, 230, 213)
        private val OREX_DARK_TEXT_SOFT = Color.rgb(179, 154, 130)
        private val OREX_CREAM = Color.rgb(251, 245, 236)
        private val OREX_COPPER = Color.rgb(200, 118, 60)
        private val OREX_COPPER_BRIGHT = Color.rgb(217, 140, 74)
        private val OREX_WALNUT_DEEP = Color.rgb(94, 58, 26)
    }
}
