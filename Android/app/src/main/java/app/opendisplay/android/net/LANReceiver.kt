package app.opendisplay.android.net

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import android.util.Base64
import androidx.annotation.Keep
import app.opendisplay.android.Log
import app.opendisplay.android.R
import androidx.annotation.StringRes
import org.conscrypt.Conscrypt
import java.io.ByteArrayInputStream
import java.io.DataInputStream
import java.io.IOException
import java.net.InetSocketAddress
import java.security.KeyFactory
import java.security.KeyStore
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.security.spec.PKCS8EncodedKeySpec
import java.util.Locale
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLServerSocket
import javax.net.ssl.SSLSocket
import javax.net.ssl.X509TrustManager

internal object LANPairing {
    init { System.loadLibrary("odpair_jni") }
    external fun identity(): Array<ByteArray>?
    external fun authenticate(channel: LANReceiver.Candidate, request: Int, id: String,
                              name: ByteArray, exporter: ByteArray, secret: ByteArray): Int
}

internal class LANReceiver(
    private val context: Context,
    id: String,
    private val server: ReceiverServer,
    private val showCode: (String, String, () -> Unit) -> Unit,
    private val hideCode: () -> Unit,
    private val changed: () -> Unit,
) {
    data class Peer(val id: String, val name: String, val address: InetSocketAddress)
    private val id = id.lowercase(Locale.ROOT)
    private val prefs = context.getSharedPreferences("lan", Context.MODE_PRIVATE)
    private val nsd = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val handler = Handler(Looper.getMainLooper())
    private val scheduler = Executors.newSingleThreadScheduledExecutor()
    private val candidates = java.util.Collections.newSetFromMap(ConcurrentHashMap<Candidate, Boolean>())
    private val choices = linkedMapOf<String, Peer>()
    private val resolving = ArrayDeque<NsdServiceInfo>()
    private val foundNames = mutableSetOf<String>()
    private var resolutionInFlight = false
    private var registration: NsdManager.RegistrationListener? = null
    private var discovery: NsdManager.DiscoveryListener? = null
    private var multicast: WifiManager.MulticastLock? = null
    @Volatile private var listener: SSLServerSocket? = null
    @Volatile private var activeSessionPeer: String? = null
    @Volatile private var name = "Android"
    @Volatile private var generation = 0
    private var codeOwner: Candidate? = null
    private var lastResume = 0L
    @get:StringRes
    var status: Int? = null
        private set

    val peers: List<Peer> get() = choices.values.distinctBy { it.id }.sortedBy { it.name }
    val paired: Map<String, String>
        get() = prefs.all.keys.filter { it.startsWith("name.") }
            .associate { it.removePrefix("name.") to (prefs.getString(it, null) ?: context.getString(R.string.device_computer)) }

    private val tls by lazy {
        val (certificate, privateKey) = LANPairing.identity() ?: throw IOException("TLS identity unavailable")
        val cert = CertificateFactory.getInstance("X.509")
            .generateCertificate(ByteArrayInputStream(certificate))
        val key = KeyFactory.getInstance("EC").generatePrivate(PKCS8EncodedKeySpec(privateKey))
        privateKey.fill(0)
        val keys = KeyStore.getInstance(KeyStore.getDefaultType()).apply {
            load(null)
            setKeyEntry("opendisplay", key, charArrayOf(), arrayOf(cert))
        }
        val managers = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm()).apply {
            init(keys, charArrayOf())
        }
        SSLContext.getInstance("TLS", Conscrypt.newProvider()).apply {
            // The candidate is quarantined until its TLS exporter is bound
            // to both sides' proof of the pairing key.
            init(managers.keyManagers, arrayOf(object : X509TrustManager {
                override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) = Unit
                override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) = Unit
                override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
            }), null)
        }
    }

    fun start(name: String) {
        if (discovery != null) return
        this.name = name
        val epoch = ++generation
        val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        multicast = wifi.createMulticastLock("OpenDisplay discovery").apply { acquire() }
        browse()
        Thread({
            try {
                val socket = tls.serverSocketFactory.createServerSocket(0) as SSLServerSocket
                handler.post {
                    if (generation == epoch && discovery != null) {
                        listener = socket
                        advertise()
                        accept(socket, epoch)
                        tryResume()
                    } else socket.close()
                }
            } catch (e: Exception) {
                handler.post { if (generation == epoch) updateStatus(R.string.lan_secure_unavailable) }
            } catch (e: LinkageError) {
                handler.post { if (generation == epoch) updateStatus(R.string.lan_secure_unavailable) }
            }
        }, "od-lan-listen").apply { isDaemon = true }.start()
    }

    private fun accept(socket: SSLServerSocket, epoch: Int) {
        Thread({
            try {
                while (generation == epoch) {
                    val client = socket.accept() as SSLSocket
                    handler.post {
                        if (listener === socket) startCandidate(client, null, 0) else client.close()
                    }
                }
            } catch (_: IOException) {
                // The foreground lifecycle owns the listener.
            }
        }, "od-lan-accept").apply { isDaemon = true }.start()
    }

    fun rename(name: String) {
        this.name = name
        advertise()
    }

    private fun advertise() {
        val socket = listener ?: return
        registration?.let { runCatching { nsd.unregisterService(it) } }
        val info = NsdServiceInfo().apply {
            serviceName = name
            serviceType = "_od-receiver._tcp"
            port = socket.localPort
            setAttribute("id", id)
            setAttribute("auth", "1")
        }
        val handle = object : NsdManager.RegistrationListener {
            override fun onRegistrationFailed(info: NsdServiceInfo, error: Int) {
                handler.post { if (registration === this) updateStatus(R.string.lan_advertise_failed) }
            }
            override fun onServiceRegistered(info: NsdServiceInfo) = Unit
            override fun onServiceUnregistered(info: NsdServiceInfo) = Unit
            override fun onUnregistrationFailed(info: NsdServiceInfo, error: Int) = Unit
        }
        registration = handle
        runCatching { nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, handle) }
            .onFailure { updateStatus(R.string.lan_advertise_failed) }
    }

    private fun browse() {
        val handle = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(type: String) = Unit
            override fun onDiscoveryStopped(type: String) = Unit
            override fun onStopDiscoveryFailed(type: String, error: Int) = Unit
            override fun onStartDiscoveryFailed(type: String, error: Int) {
                handler.post { if (discovery === this) updateStatus(R.string.lan_discovery_failed) }
            }
            override fun onServiceFound(info: NsdServiceInfo) {
                handler.post {
                    if (discovery !== this) return@post
                    foundNames.add(info.serviceName)
                    resolving.addLast(info)
                    resolveNext()
                }
            }
            override fun onServiceLost(info: NsdServiceInfo) {
                handler.post {
                    if (discovery !== this) return@post
                    foundNames.remove(info.serviceName)
                    choices.remove(info.serviceName)
                    changed()
                }
            }
        }
        discovery = handle
        runCatching { nsd.discoverServices("_od-sender._tcp", NsdManager.PROTOCOL_DNS_SD, handle) }
            .onFailure { updateStatus(R.string.lan_discovery_failed) }
    }

    @Suppress("DEPRECATION")
    private fun resolveNext() {
        if (resolutionInFlight || resolving.isEmpty()) return
        val info = resolving.removeFirst()
        val epoch = generation
        val handle = object : NsdManager.ResolveListener {
            override fun onResolveFailed(info: NsdServiceInfo, error: Int) = completed(null)
            override fun onServiceResolved(info: NsdServiceInfo) = completed(info)
            private fun completed(resolved: NsdServiceInfo?) {
                handler.post {
                    if (generation != epoch) return@post
                    resolutionInFlight = false
                    val peerID = resolved?.attributes?.get("id")?.decodeToString()?.lowercase(Locale.ROOT)
                    val version = resolved?.attributes?.get("auth")?.decodeToString()
                    val host = resolved?.host
                    if (resolved != null && host != null && version == "1" && peerID != null &&
                        runCatching { UUID.fromString(peerID).toString() == peerID }.getOrDefault(false) &&
                        resolved.serviceName in foundNames) {
                        choices[resolved.serviceName] = Peer(peerID, resolved.serviceName,
                            InetSocketAddress(host, resolved.port))
                        changed()
                        tryResume()
                    }
                    resolveNext()
                }
            }
        }
        resolutionInFlight = true
        runCatching { nsd.resolveService(info, handle) }
            .onFailure { handle.onResolveFailed(info, -1) }
    }

    fun connect(peer: Peer) = dial(peer, 1)

    private fun dial(peer: Peer, request: Int) {
        if (listener == null || server.isConnected || candidates.any { it.peerId == peer.id }) return
        val client = runCatching { tls.socketFactory.createSocket() as SSLSocket }.getOrNull() ?: return
        startCandidate(client, peer, request)
    }

    private fun startCandidate(socket: SSLSocket, peer: Peer?, request: Int) {
        if (listener == null || candidates.size >= 8 || server.isConnected) {
            socket.close()
            return
        }
        val candidate = Candidate(socket, peer, request, generation)
        candidates.add(candidate)
        if (request == 1) updateStatus(R.string.lan_connecting)
        Thread(candidate::run, "od-lan-pairing").apply { isDaemon = true }.start()
    }

    fun stop() {
        generation++
        handler.removeCallbacksAndMessages(null)
        listener?.close()
        listener = null
        registration?.let { runCatching { nsd.unregisterService(it) } }
        registration = null
        discovery?.let { runCatching { nsd.stopServiceDiscovery(it) } }
        discovery = null
        multicast?.release()
        multicast = null
        candidates.forEach(Candidate::cancel)
        candidates.clear()
        choices.clear()
        foundNames.clear()
        resolving.clear()
        resolutionInFlight = false
        codeOwner = null
        hideCode()
    }

    fun destroy() { scheduler.shutdownNow() }

    fun sessionChanged(transport: String?) {
        when (transport) {
            "WiFi" -> Unit
            null -> {
                activeSessionPeer = null
                tryResume()
            }
            else -> {
                activeSessionPeer = null
                prefs.edit().remove("resume").apply()
            }
        }
    }

    private fun tryResume() {
        val wanted = prefs.getString("resume", null) ?: return
        val peer = peers.firstOrNull { it.id == wanted } ?: return
        if (listener == null || server.isConnected) return
        val now = android.os.SystemClock.elapsedRealtime()
        if (now - lastResume < 5000) {
            handler.removeCallbacks(resume)
            handler.postDelayed(resume, 5000 - (now - lastResume))
            return
        }
        lastResume = now
        dial(peer, 2)
    }

    private val resume = Runnable { tryResume() }

    fun pause() {
        prefs.edit().remove("resume").apply()
        handler.removeCallbacks(resume)
    }

    fun disconnect() {
        pause()
        server.disconnect()
    }

    fun forget(id: String) {
        if (activeSessionPeer == id) disconnect()
        if (prefs.getString("resume", null) == id) pause()
        prefs.edit().remove("name.$id").remove("key.$id").apply()
        candidates.filter { it.peerId == id }.forEach(Candidate::cancel)
        changed()
    }

    private fun updateStatus(@StringRes message: Int?) {
        status = message
        changed()
    }

    @Keep
    inner class Candidate(private val socket: SSLSocket, private val peer: Peer?,
                          private val request: Int, private val epoch: Int) {
        @Volatile var peerId: String? = peer?.id
            private set
        private var label = "Computer"
        private lateinit var input: DataInputStream
        @Volatile private var cancelled = false
        @Volatile private var adopted = false

        fun run() {
            val timeout = scheduler.schedule({ cancel() }, 120, TimeUnit.SECONDS)
            var result = 0
            val secret = ByteArray(32)
            try {
                if (peer != null) socket.connect(peer.address, 5000)
                socket.useClientMode = peer != null
                socket.enabledProtocols = arrayOf("TLSv1.3")
                socket.soTimeout = 5000
                socket.tcpNoDelay = true
                Conscrypt.setApplicationProtocols(socket, arrayOf("opendisplay/1"))
                socket.startHandshake()
                if (Conscrypt.getApplicationProtocol(socket) != "opendisplay/1") return
                socket.soTimeout = 120000
                val exporter = Conscrypt.exportKeyingMaterial(socket, "EXPORTER-OpenDisplay-LAN-v1", null, 32)
                    ?: return
                input = DataInputStream(socket.inputStream)
                result = LANPairing.authenticate(this, request, id, name.toByteArray().let {
                    if (it.size <= 120) it else "Android".toByteArray()
                }, exporter, secret)
                exporter.fill(0)
                val sender = peerId
                if (result > 0 && sender != null && !cancelled && generation == epoch) {
                    if (result == 2 && !prefs.edit()
                            .putString("key.$sender", Base64.encodeToString(secret, Base64.NO_WRAP)).commit()) return
                    socket.soTimeout = 0
                    adopted = server.adoptSecure(socket) {
                        if (generation != epoch || cancelled) return@adoptSecure false
                        activeSessionPeer = sender
                        prefs.edit().putString("name.$sender", label).putString("resume", sender).apply()
                        true
                    }
                }
            } catch (error: IOException) {
                if (!cancelled) Log.i("OpenDisplay", "LAN TLS ended: ${error.message}")
            } catch (error: IllegalStateException) {
                if (!cancelled) Log.i("OpenDisplay", "LAN socket unavailable: ${error.message}")
            } finally {
                secret.fill(0)
                timeout.cancel(false)
                if (!adopted) cancel()
                candidates.remove(this)
                handler.post {
                    if (generation != epoch) return@post
                    if (codeOwner === this) {
                        codeOwner = null
                        hideCode()
                    }
                    if (adopted) updateStatus(null)
                    else if (result == -2) { pause(); updateStatus(R.string.lan_pair_again) }
                    else if (result == -3) { pause(); updateStatus(R.string.lan_verification_failed) }
                    else if (request == 2) tryResume()
                    else if (request == 1) updateStatus(R.string.lan_connection_ended)
                }
            }
        }

        fun cancel() {
            cancelled = true
            if (!adopted) runCatching { socket.close() }
        }

        @Keep fun readPairing(count: Int): ByteArray? = runCatching {
            ByteArray(count).also(input::readFully)
        }.getOrNull()

        @Keep fun writePairing(data: ByteArray): Boolean = runCatching {
            socket.outputStream.write(data)
            socket.outputStream.flush()
        }.isSuccess

        @Keep fun inspectPairing(id: String, name: ByteArray, request: Int): Boolean {
            synchronized(candidates) {
                if (cancelled || generation != epoch || server.isConnected ||
                    (peerId != null && peerId != id) ||
                    (request == 2 && prefs.getString("resume", null) != id)) return false
                val twin = candidates.firstOrNull { it !== this && it.peerId == id && !it.cancelled }
                if (twin != null) {
                    if (peer != null || twin.peer == null) return false
                    twin.cancel() // sender-opened connection wins on both peers
                }
                peerId = id
                label = name.decodeToString()
                return true
            }
        }

        @Keep fun loadPairingKey(id: String): ByteArray? =
            prefs.getString("key.$id", null)?.let { Base64.decode(it, Base64.NO_WRAP) }

        @Keep fun showPairingCode(digits: String): Boolean {
            synchronized(candidates) {
                if (cancelled || generation != epoch || candidates.any { it !== this && it.showing }) return false
                showing = true
            }
            handler.post {
                if (!cancelled && generation == epoch) {
                    codeOwner = this
                    showCode(label, digits, ::cancel)
                }
            }
            return true
        }

        private var showing = false
    }
}
