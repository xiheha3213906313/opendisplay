package app.opendisplay.android.net

import org.junit.Assert.assertArrayEquals
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream

class AccessoryRecordsTest {
    @Test
    fun recoversAtDelimiterAndDropsRetiredEpoch() {
        val epoch = ByteArray(16) { 1 }
        val payload = byteArrayOf(0, 1, 0, 2)
        val record = AccessoryRecords.encode(2, epoch, payload, 0, payload.size)
        assertArrayEquals(byteArrayOf(0, 18, 2) + epoch + byteArrayOf(2, 1, 2, 2, 0), record)
        val retired = AccessoryRecords.encode(2, ByteArray(16) { 9 }, byteArrayOf(88), 0, 1)
        val input = ByteArrayInputStream(byteArrayOf(4, 7) + retired + record)
        val records = AccessoryRecords(input, ByteArrayOutputStream(), epoch)
        assertArrayEquals(payload, records.input.readBytes())
    }
}
