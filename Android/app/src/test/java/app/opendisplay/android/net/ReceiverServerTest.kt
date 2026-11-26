package app.opendisplay.android.net

import app.opendisplay.android.protocol.Codec
import app.opendisplay.android.protocol.Framing
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.PipedInputStream
import java.io.PipedOutputStream
import java.net.ConnectException
import java.net.ServerSocket
import java.net.Socket

class ReceiverServerTest {
    @Test
    fun activeAccessoryTakesPriorityOverLoopback() {
        val port = ServerSocket(0).use { it.localPort }
        val server = ReceiverServer(Listener(), { JSONObject().put("type", "hello") }, port = port)
        val accessoryInput = PipedInputStream()
        PipedOutputStream(accessoryInput).use {
            val accessory = object : Link {
                override val input = accessoryInput
                override val output = ByteArrayOutputStream()
                override val transport = "USB"
                override val remote = "test accessory"
                override fun close() = input.close()
            }
            server.start()
            try {
                connect(port).use { socket ->
                    val hello = Framing.readFrame(DataInputStream(socket.getInputStream()))!!
                    assertEquals("hello", JSONObject(hello.decodeToString()).getString("type"))
                }
                assertTrue(server.adoptAccessory(accessory))
                connect(port).use { socket -> assertEquals(-1, socket.getInputStream().read()) }
                assertTrue(server.isOnAccessory)
            } finally {
                server.stop(null)
            }
        }
    }

    private fun connect(port: Int): Socket {
        repeat(100) {
            try {
                return Socket("127.0.0.1", port).apply { soTimeout = 2000 }
            } catch (_: ConnectException) {
                Thread.sleep(10)
            }
        }
        error("Receiver did not start listening")
    }

    private class Listener : ReceiverServer.Listener {
        override fun onSessionStarted(transport: String) = Unit
        override fun onSessionEnded() = Unit
        override fun onVideoFrame(payload: ByteArray) = Unit
        override fun onStreamConfig(codec: Codec?, codecToken: String, width: Int, height: Int, fps: Int) = Unit
        override fun onCursor(x: Double, y: Double, visible: Boolean) = Unit
        override fun onCursorImage(png: ByteArray, nw: Double, nh: Double, ax: Double, ay: Double) = Unit
        override fun onSenderSleeping() = Unit
        override fun onSenderVersion(pv: Int) = Unit
        override fun onUpdateRequired(message: String, store: String?) = Unit
        override fun onSenderHealth(obj: JSONObject) = Unit
        override fun statsSnapshot() = JSONObject()
    }
}
