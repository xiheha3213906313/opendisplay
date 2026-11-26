package app.opendisplay.android.net

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.InetAddress

class LocalLanAddressTest {
    @Test
    fun recognizesBothLoopbackFamilies() {
        for (address in listOf("127.0.0.2", "::1", "::ffff:127.0.0.1")) {
            assertTrue(address, isLocalLanAddress(InetAddress.getByName(address)))
        }
    }

    @Test
    fun unrelatedAddressesAreEligible() {
        for (address in listOf("192.0.2.17", "2001:db8::17")) {
            assertFalse(address, isLocalLanAddress(InetAddress.getByName(address)))
        }
    }
}
