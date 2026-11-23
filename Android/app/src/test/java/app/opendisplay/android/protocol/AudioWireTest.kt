package app.opendisplay.android.protocol

import app.opendisplay.android.audio.writePacket
import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.DataInputStream
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder

class AudioWireTest {
    // Same two signed stereo frames as AudioWireTests.swift.
    private val packet = byteArrayOf(
        0x41, 0x55, 0x44, 0x31, 1, 2, 0xbb.toByte(), 0x80.toByte(), 0, 0, 0, 2,
        0x34, 0x12, 0xfe.toByte(), 0xff.toByte(), 0, 0x80.toByte(), 0xff.toByte(), 0x7f,
    )

    @Test fun stereoPacketMatchesSwiftFixture() {
        val pcm = requireNotNull(AudioWire.pcm(packet)).order(ByteOrder.LITTLE_ENDIAN)
        assertEquals(listOf(0x1234, -2, -32768, 32767), List(4) { pcm.short.toInt() })
    }

    @Test fun invalidHeaderAndLengthAreRejected() {
        assertNull(AudioWire.pcm(packet.copyOf(11)))
        assertNull(AudioWire.pcm(packet.copyOf(packet.size - 1)))
        assertNull(AudioWire.pcm(packet.copyOf(packet.size + 1)))
        for (index in listOf(4, 5, 6, 8, 11)) {
            assertNull(AudioWire.pcm(packet.copyOf().also { it[index] = 0xff.toByte() }))
        }
    }

    @Test fun lengthPrefixedAudioVideoAndControlStaySeparate() {
        val control = """{"type":"ping"}""".toByteArray()
        val video = byteArrayOf(0, 0, 0, 1, 0x65)
        val wire = Framing.encode(packet) + Framing.encode(video) + Framing.encode(control)
        val input = DataInputStream(ByteArrayInputStream(wire))
        assertEquals(Demux.Kind.AUDIO, Demux.kind(requireNotNull(Framing.readFrame(input))))
        assertEquals(Demux.Kind.VIDEO, Demux.kind(requireNotNull(Framing.readFrame(input))))
        assertEquals(Demux.Kind.CONTROL, Demux.kind(requireNotNull(Framing.readFrame(input))))
        assertNull(Framing.readFrame(input))
    }

    @Test fun shortWritesResumeFromTheNextFrame() {
        val pcm = ByteBuffer.allocate(12)
        val positions = mutableListOf<Int>()
        var waits = 0
        val complete = writePacket(pcm, { true }, {
            positions.add(it.position())
            if (positions.size == 2) 0 else {
                it.position(it.position() + 4)
                4
            }
        }, { waits++ })
        assertTrue(complete)
        assertEquals(listOf(0, 4, 4, 8), positions)
        assertEquals(1, waits)
    }

    @Test fun stalePacketIsDroppedWhenPlaybackCannotKeepUp() {
        var fresh = true
        val pcm = ByteBuffer.allocate(4)
        assertFalse(writePacket(pcm, { fresh }, { 0 }, { fresh = false }))
        assertEquals(0, pcm.position())
    }

    @Test(expected = IOException::class)
    fun negativeTrackResultFailsPlayback() {
        writePacket(ByteBuffer.allocate(4), { true }, { -6 }, {})
    }
}
