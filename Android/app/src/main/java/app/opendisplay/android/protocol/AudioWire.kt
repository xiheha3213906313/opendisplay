package app.opendisplay.android.protocol

import java.nio.ByteBuffer

/** AUD1 framing adapted from gprot42/android-opendisplay (GPL-3.0). */
object AudioWire {
    const val FORMAT = "AUD1-s16le-48000-stereo"
    const val SAMPLE_RATE = 48_000
    const val BYTES_PER_FRAME = 4
    const val MAX_FRAMES = 960
    private const val MAGIC = 0x41554431
    private const val HEADER_BYTES = 12

    fun isAudio(payload: ByteArray): Boolean =
        payload.size >= 4 && payload[0] == 0x41.toByte() && payload[1] == 0x55.toByte() &&
            payload[2] == 0x44.toByte() && payload[3] == 0x31.toByte()

    fun pcm(payload: ByteArray): ByteBuffer? {
        if (payload.size !in (HEADER_BYTES + BYTES_PER_FRAME)..(HEADER_BYTES + MAX_FRAMES * BYTES_PER_FRAME)) {
            return null
        }
        val buffer = ByteBuffer.wrap(payload)
        if (buffer.int != MAGIC || buffer.get().toInt() != 1 || buffer.get().toInt() != 2 ||
            (buffer.short.toInt() and 0xffff) != SAMPLE_RATE
        ) return null
        val frames = buffer.int
        if (frames !in 1..MAX_FRAMES || buffer.remaining() != frames * BYTES_PER_FRAME) return null
        return buffer.slice()
    }
}
