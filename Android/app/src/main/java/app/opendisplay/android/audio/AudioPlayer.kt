package app.opendisplay.android.audio

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Build
import android.os.SystemClock
import app.opendisplay.android.Log
import app.opendisplay.android.protocol.AudioWire
import java.io.IOException
import java.nio.ByteBuffer
import java.util.concurrent.LinkedBlockingDeque

/** AudioTrack playback adapted from gprot42/android-opendisplay (GPL-3.0). */
internal class AudioPlayer(private val onStatus: (String) -> Unit) {
    private data class Packet(val pcm: ByteBuffer, val expiresAt: Long)

    // The worker owns the track. Keep at most 80 ms waiting outside the device.
    private val packets = LinkedBlockingDeque<Packet>(4)
    @Volatile private var closed = false
    private val worker = Thread(::play, "od-audio").apply { isDaemon = true }

    fun start() = worker.start()

    fun feed(payload: ByteArray) {
        if (closed) return
        val pcm = AudioWire.pcm(payload) ?: return
        val packet = Packet(pcm, SystemClock.elapsedRealtime() + 80)
        if (!packets.offerLast(packet)) {
            packets.pollFirst()
            packets.offerLast(packet)
        }
    }

    fun close() {
        closed = true
        packets.clear()
        worker.interrupt()
    }

    private fun play() {
        var track: AudioTrack? = null
        try {
            if (closed) return
            val output = createTrack()
            track = output
            check(output.state == AudioTrack.STATE_INITIALIZED) { "AudioTrack initialization failed" }
            output.play()
            check(output.playState == AudioTrack.PLAYSTATE_PLAYING) { "AudioTrack did not start" }
            if (closed) return
            onStatus("ready")
            var stalledSince: Long? = null
            while (!closed) {
                val packet = packets.takeFirst()
                if (SystemClock.elapsedRealtime() >= packet.expiresAt) continue
                val written = writePacket(
                    packet.pcm,
                    stillFresh = { !closed && SystemClock.elapsedRealtime() < packet.expiresAt },
                    write = { output.write(it, it.remaining(), AudioTrack.WRITE_NON_BLOCKING) },
                    waitForSpace = { Thread.sleep(4) },
                )
                if (written || packet.pcm.position() > 0) {
                    stalledSince = null
                } else {
                    val now = SystemClock.elapsedRealtime()
                    val since = stalledSince ?: now
                    stalledSince = since
                    if (now - since >= 500) throw IOException("AudioTrack stopped accepting audio")
                }
            }
        } catch (e: Exception) {
            if (!closed) {
                Log.w("OpenDisplay", "audio playback failed: $e")
                onStatus("failed")
            }
        } finally {
            closed = true
            packets.clear()
            track?.let { output ->
                try {
                    if (output.playState == AudioTrack.PLAYSTATE_PLAYING) output.pause()
                    output.flush()
                } catch (e: IllegalStateException) {
                    Log.w("OpenDisplay", "audio stopped: $e")
                } finally {
                    output.release()
                }
            }
        }
    }

    @Suppress("DEPRECATION") // AudioTrack.Builder was introduced in API 23.
    private fun createTrack(): AudioTrack {
        val rate = AudioWire.SAMPLE_RATE
        val channelMask = AudioFormat.CHANNEL_OUT_STEREO
        val encoding = AudioFormat.ENCODING_PCM_16BIT
        val minimum = AudioTrack.getMinBufferSize(rate, channelMask, encoding)
        check(minimum > 0) { "48 kHz stereo output is unavailable ($minimum)" }
        val bytes = maxOf(minimum, AudioWire.MAX_FRAMES * AudioWire.BYTES_PER_FRAME * 2)
        val attributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
            .build()
        val format = AudioFormat.Builder()
            .setSampleRate(rate)
            .setEncoding(encoding)
            .setChannelMask(channelMask)
            .build()
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            AudioTrack.Builder()
                .setAudioAttributes(attributes)
                .setAudioFormat(format)
                .setBufferSizeInBytes(bytes)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()
        } else {
            AudioTrack(attributes, format, bytes, AudioTrack.MODE_STREAM, AudioManager.AUDIO_SESSION_ID_GENERATE)
        }
    }
}

/** AudioTrack advances the buffer position on every successful write. */
internal fun writePacket(
    pcm: ByteBuffer,
    stillFresh: () -> Boolean,
    write: (ByteBuffer) -> Int,
    waitForSpace: () -> Unit,
): Boolean {
    while (pcm.hasRemaining() && stillFresh()) {
        val bytes = write(pcm)
        if (bytes < 0) throw IOException("AudioTrack.write failed ($bytes)")
        if (bytes == 0) waitForSpace()
    }
    return !pcm.hasRemaining()
}
