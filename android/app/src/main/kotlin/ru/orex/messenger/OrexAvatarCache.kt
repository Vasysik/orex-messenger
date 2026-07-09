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
 * v2 separates sender and conversation identities and understands an explicit
 * no-avatar tombstone. This prevents a user/channel without a picture from
 * inheriting an unrelated cached room or participant avatar.
 */
object OrexAvatarCache {
    private const val DIRECTORY_NAME = "orex_avatar_cache_v2"
    private const val BINDING_PREFIX = "binding_"
    private const val NO_AVATAR_MARKER = "-"
    private const val MAX_DECODE_SIZE = 512
    private val KEY_PATTERN = Regex("[0-9a-f]{16}")
    private val memoryCache = object : LruCache<String, Bitmap>(8 * 1024 * 1024) {
        override fun sizeOf(key: String, value: Bitmap): Int = value.byteCount
    }

    private sealed interface BindingLookup {
        object Missing : BindingLookup
        object NoAvatar : BindingLookup
        data class Key(val value: String) : BindingLookup
    }

    fun resolveSenderKey(
        context: Context,
        explicitKey: String?,
        userId: String?,
    ): String? {
        return when (val binding = lookupBinding(context, userId?.let { "user:$it" })) {
            is BindingLookup.Key -> binding.value
            BindingLookup.NoAvatar -> null
            BindingLookup.Missing -> normalizeKey(explicitKey)
        }
    }

    fun resolveConversationKey(
        context: Context,
        explicitKey: String?,
        roomId: String?,
        userId: String? = null,
    ): String? {
        when (val roomBinding = lookupBinding(context, roomId?.let { "room:$it" })) {
            is BindingLookup.Key -> return roomBinding.value
            BindingLookup.NoAvatar -> return null
            BindingLookup.Missing -> Unit
        }
        normalizeKey(explicitKey)?.let { return it }
        return when (val userBinding = lookupBinding(context, userId?.let { "user:$it" })) {
            is BindingLookup.Key -> userBinding.value
            BindingLookup.NoAvatar, BindingLookup.Missing -> null
        }
    }

    fun load(context: Context, key: String?): Bitmap? {
        val resolved = normalizeKey(key) ?: return null
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

    private fun lookupBinding(context: Context, identity: String?): BindingLookup {
        val normalized = identity?.trim().orEmpty()
        if (normalized.isEmpty()) return BindingLookup.Missing
        return try {
            val file = File(
                cacheDirectory(context),
                "$BINDING_PREFIX${stableKey(normalized)}",
            )
            if (!file.isFile) return BindingLookup.Missing
            val value = file.readText().trim().lowercase()
            when {
                value == NO_AVATAR_MARKER -> BindingLookup.NoAvatar
                KEY_PATTERN.matches(value) -> BindingLookup.Key(value)
                else -> BindingLookup.Missing
            }
        } catch (_: Throwable) {
            BindingLookup.Missing
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
