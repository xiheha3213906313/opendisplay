package app.opendisplay.android.audio

import android.media.AudioManager
import android.os.Build
import app.opendisplay.android.Log
import org.json.JSONObject

/** Controls only the system media stream used by the receiver's AudioTrack. */
internal class MediaVolume(private val manager: AudioManager) {
    data class State(
        val minimum: Int,
        val maximum: Int,
        val index: Int,
        val muted: Boolean,
        val canVolume: Boolean,
        val canMute: Boolean,
    ) {
        fun json() = JSONObject()
            .put("min", minimum).put("max", maximum).put("index", index)
            .put("muted", muted).put("canVolume", canVolume).put("canMute", canMute)
    }

    fun read(): State = try {
        val minimum = if (Build.VERSION.SDK_INT >= 28) manager.getStreamMinVolume(STREAM) else 0
        val maximum = manager.getStreamMaxVolume(STREAM)
        val index = manager.getStreamVolume(STREAM)
        val muteSupported = Build.VERSION.SDK_INT >= 23
        val mutable = !manager.isVolumeFixed && maximum > minimum && index in minimum..maximum
        State(minimum, maximum, index, muteSupported && manager.isStreamMute(STREAM), mutable,
            mutable && muteSupported)
    } catch (_: RuntimeException) {
        State(0, 0, 0, false, false, false)
    }

    fun setIndex(index: Int, current: State) {
        if (!current.canVolume || index !in current.minimum..current.maximum || index == current.index) return
        try {
            manager.setStreamVolume(STREAM, index, 0)
        } catch (e: RuntimeException) {
            // The receiver reports the actual state after allowing it to settle.
            Log.w("OpenDisplay", "media volume change rejected: $e")
        }
    }

    fun setMuted(muted: Boolean, current: State) {
        if (Build.VERSION.SDK_INT < 23 || !current.canMute || muted == current.muted) return
        try {
            manager.adjustStreamVolume(STREAM,
                if (muted) AudioManager.ADJUST_MUTE else AudioManager.ADJUST_UNMUTE, 0)
        } catch (e: RuntimeException) {
            // Respect Do Not Disturb and manufacturer restrictions.
            Log.w("OpenDisplay", "media mute change rejected: $e")
        }
    }

    private companion object {
        const val STREAM = AudioManager.STREAM_MUSIC
    }
}
