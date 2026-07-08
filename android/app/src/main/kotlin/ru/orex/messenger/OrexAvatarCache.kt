package ru.orex.messenger

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Shader
import android.util.LruCache
import java.io.File

/**
 * Native reader for avatar files written by Flutter's OrexAvatarCache.
 *
 * The cache stores authenticated Matrix media in app-private files, so Android
 * notification/call UI can render avatars while Flutter is killed without
 * carrying Matrix access tokens into Kotlin.
 */
object OrexAvatarCache {
    private const val DIRECTORY_NAME = "orex_avatar_cache_v1"
    private const val BINDING_PREFIX = "binding_"
    private const val MAX_DECODE_SIZE = 512
    private val KEY_PATTERN = Regex("[0-9a-f]{16}")
    private val memoryCache = object : LruCache<String, Bitmap>(8 * 1024 * 1024) {
        override fun sizeOf(key: String, value: Bitmap): Int = value.byteCount
    }

    fun resolveKey(
        context: Context,
        explicitKey: String?,
        roomId: String? = null,
        userId: String? = null,
    ): String? {
        normalizeKey(explicitKey)?.let { return it }
        lookupBinding(context, userId?.let { "user:$it" })?.let { return it }
        return lookupBinding(context, roomId?.let { "room:$it" })
    }

    fun load(
        context: Context,
        key: String?,
        roomId: String? = null,
        userId: String? = null,
    ): Bitmap? {
        val resolved = resolveKey(context, key, roomId = roomId, userId = userId)
            ?: return null
        val cached = synchronized(memoryCache) { memoryCache.get(resolved) }
        if (cached != null) return cached
        val file = File(cacheDirectory(context), resolved)
        if (!file.isFile) return null
        val decoded = decodeScaled(file) ?: return null
        synchronized(memoryCache) { memoryCache.put(resolved, decoded) }
        return decoded
    }

    fun circle(bitmap: Bitmap, size: Int = 192): Bitmap {
        val targetSize = size.coerceAtLeast(32)
        val sourceSize = minOf(bitmap.width, bitmap.height)
        val left = ((bitmap.width - sourceSize) / 2).coerceAtLeast(0)
        val top = ((bitmap.height - sourceSize) / 2).coerceAtLeast(0)
        val square = Bitmap.createBitmap(bitmap, left, top, sourceSize, sourceSize)
        val output = Bitmap.createBitmap(targetSize, targetSize, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(output)
        val shader = BitmapShader(square, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP)
        val scale = targetSize.toFloat() / sourceSize.toFloat()
        shader.setLocalMatrix(android.graphics.Matrix().apply { setScale(scale, scale) })
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.shader = shader }
        val radius = targetSize / 2f
        canvas.drawCircle(radius, radius, radius, paint)
        if (square !== bitmap) square.recycle()
        return output
    }

    private fun lookupBinding(context: Context, identity: String?): String? {
        val normalized = identity?.trim().orEmpty()
        if (normalized.isEmpty()) return null
        return try {
            val file = File(
                cacheDirectory(context),
                "$BINDING_PREFIX${stableKey(normalized)}",
            )
            if (!file.isFile) return null
            normalizeKey(file.readText().trim())
        } catch (_: Throwable) {
            null
        }
    }

    private fun cacheDirectory(context: Context): File =
        File(context.filesDir, DIRECTORY_NAME)

    private fun normalizeKey(value: String?): String? {
        val normalized = value?.trim()?.lowercase().orEmpty()
        return normalized.takeIf(KEY_PATTERN::matches)
    }

    /** Must stay byte-for-byte compatible with Dart orexStableCacheKey(). */
    private fun stableKey(value: String): String {
        var hash = -3750763034362895579L // unsigned FNV-1a offset basis
        for (byte in value.toByteArray(Charsets.UTF_8)) {
            hash = hash xor (byte.toLong() and 0xffL)
            hash *= 1099511628211L
        }
        return java.lang.Long.toUnsignedString(hash, 16).padStart(16, '0')
    }

    private fun decodeScaled(file: File): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.absolutePath, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null

        var sampleSize = 1
        while (bounds.outWidth / sampleSize > MAX_DECODE_SIZE * 2 ||
            bounds.outHeight / sampleSize > MAX_DECODE_SIZE * 2
        ) {
            sampleSize *= 2
        }
        return BitmapFactory.decodeFile(
            file.absolutePath,
            BitmapFactory.Options().apply {
                inSampleSize = sampleSize
                inPreferredConfig = Bitmap.Config.ARGB_8888
            },
        )
    }
}
