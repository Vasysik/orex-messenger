package ru.orex.messenger

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.view.View
import android.view.animation.LinearInterpolator

/** Small deterministic spinner that does not depend on an OEM ProgressBar skin. */
internal class OrexIndeterminateSpinnerView(
    context: Context,
    color: Int,
) : View(context) {
    private val arcBounds = RectF()
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        strokeWidth = 2.8f * resources.displayMetrics.density
        this.color = color
    }
    private var rotationDegrees = 0f
    private val animator: ValueAnimator by lazy(LazyThreadSafetyMode.NONE) {
        ValueAnimator.ofFloat(0f, 360f).apply {
            duration = 850L
            repeatCount = ValueAnimator.INFINITE
            interpolator = LinearInterpolator()
            addUpdateListener {
                rotationDegrees = it.animatedValue as Float
                invalidate()
            }
        }
    }

    init {
        contentDescription = "Подключение"
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        if (visibility == VISIBLE && !animator.isStarted) animator.start()
    }

    override fun onDetachedFromWindow() {
        animator.cancel()
        super.onDetachedFromWindow()
    }

    override fun onVisibilityChanged(changedView: View, visibility: Int) {
        super.onVisibilityChanged(changedView, visibility)
        if (!isAttachedToWindow) return
        if (visibility == VISIBLE) {
            if (!animator.isStarted) animator.start()
        } else {
            animator.cancel()
        }
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val inset = paint.strokeWidth / 2f
        arcBounds.set(inset, inset, width - inset, height - inset)
        canvas.save()
        canvas.rotate(rotationDegrees, width / 2f, height / 2f)
        canvas.drawArc(arcBounds, -90f, 250f, false, paint)
        canvas.restore()
    }
}
