package app.opendisplay.android.net

import java.io.InputStream
import java.io.OutputStream
import java.security.SecureRandom

/** AOA v2 record encoding. Each new receiver lifetime picks a fresh epoch. */
internal class AccessoryRecords(
    private val source: InputStream,
    private val sink: OutputStream,
    private val epoch: ByteArray = ByteArray(16).also(SecureRandom()::nextBytes),
) {
    private var greeted = false

    val output: OutputStream = object : OutputStream() {
        override fun write(byte: Int) = write(byteArrayOf(byte.toByte()), 0, 1)

        override fun write(bytes: ByteArray, offset: Int, length: Int) {
            if (!greeted) {
                sink.write("ODU2".toByteArray())
                sink.write(encode(1, epoch, byteArrayOf(), 0, 0))
                greeted = true
            }
            var start = offset
            while (start < offset + length) {
                val count = minOf(15 * 1024, offset + length - start)
                sink.write(encode(2, epoch, bytes, start, count))
                start += count
            }
        }

        override fun flush() = sink.flush()
    }

    val input: InputStream = object : InputStream() {
        private var current = byteArrayOf()
        private var position = 0
        private val encoded = ByteArray(16 * 1024)

        override fun read(): Int {
            if (!fill()) return -1
            return current[position++].toInt() and 255
        }

        override fun read(bytes: ByteArray, offset: Int, length: Int): Int {
            if (length == 0) return 0
            if (!fill()) return -1
            val count = minOf(length, current.size - position)
            current.copyInto(bytes, offset, position, position + count)
            position += count
            return count
        }

        private fun fill(): Boolean {
            if (position < current.size) return true
            var count = 0
            var oversized = false
            while (true) {
                val byte = source.read()
                if (byte < 0) return false
                if (byte != 0) {
                    if (count == encoded.size) oversized = true
                    else if (!oversized) encoded[count++] = byte.toByte()
                    continue
                }
                val decoded = if (!oversized && count > 0) decode(encoded, count) else null
                count = 0
                oversized = false
                if (decoded != null && decoded.size > 17 && decoded[0] == 2.toByte() &&
                    epoch.indices.all { epoch[it] == decoded[it + 1] }) {
                    current = decoded
                    position = 17
                    return true
                }
            }
        }
    }

    companion object {
        fun encode(kind: Int, epoch: ByteArray, bytes: ByteArray, offset: Int, length: Int): ByteArray {
            val input = byteArrayOf(kind.toByte()) + epoch + bytes.copyOfRange(offset, offset + length)
            val encoded = ByteArray(input.size + input.size / 254 + 4)
            var index = 2
            var codeIndex = 1
            var run = 1
            for (byte in input) {
                if (byte != 0.toByte()) {
                    encoded[index++] = byte
                    run++
                }
                if (byte == 0.toByte() || run == 255) {
                    encoded[codeIndex] = run.toByte()
                    codeIndex = index++
                    run = 1
                }
            }
            encoded[codeIndex] = run.toByte()
            return encoded.copyOf(index + 1)
        }

        private fun decode(encoded: ByteArray, size: Int): ByteArray? {
            val decoded = ByteArray(size)
            var offset = 0
            var index = 0
            while (offset < size) {
                val run = encoded[offset++].toInt() and 255
                val end = offset + run - 1
                if (run == 0 || end > size) return null
                encoded.copyInto(decoded, index, offset, end)
                index += end - offset
                offset = end
                if (run != 255 && offset < size) decoded[index++] = 0
            }
            return decoded.copyOf(index)
        }
    }
}
