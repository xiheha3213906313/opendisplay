import Foundation
import Network
import ODPairing
import Security
import SwiftUI

struct LANPeer: Identifiable, Equatable {
    let id: String
    let name: String
    let endpoint: NWEndpoint

    static func from(_ result: NWBrowser.Result) -> LANPeer? {
        guard case let .service(name, _, _, _) = result.endpoint,
              case let .bonjour(txt) = result.metadata,
              txt["auth"] == "1",
              let id = txt["id"]?.lowercased(), UUID(uuidString: id) != nil else { return nil }
        return LANPeer(id: id, name: name, endpoint: result.endpoint)
    }

    static func == (lhs: LANPeer, rhs: LANPeer) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.endpoint == rhs.endpoint
    }
}

enum LANRole: String {
    case sender, receiver

    var serviceType: String { self == .sender ? "_od-sender._tcp" : "_od-receiver._tcp" }
    var peer: LANRole { self == .sender ? .receiver : .sender }
}

enum LANRequest: Int32 {
    case incoming = 0, manual = 1, resume = 2
}

enum LANPairingKeys {
    private static func query(_ role: LANRole, _ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "OpenDisplay LAN \(role.rawValue)",
         kSecAttrAccount as String: id]
    }

    static func read(_ role: LANRole, _ id: String) -> Data? {
        var parameters = query(role, id)
        parameters[kSecReturnData as String] = true
        parameters[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(parameters as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, data.count == 32 else { return nil }
        return data
    }

    static func write(_ key: Data, _ role: LANRole, _ id: String) -> Bool {
        let parameters = query(role, id)
        let attributes = [kSecValueData as String: key]
        let status = SecItemUpdate(parameters as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        return SecItemAdd(parameters.merging(attributes) { _, value in value } as CFDictionary,
                          nil) == errSecSuccess
    }

    static func forget(_ role: LANRole, _ id: String) {
        SecItemDelete(query(role, id) as CFDictionary)
    }
}

/// A TLS socket before the media pipeline owns it. Blocking C callbacks run
/// on a worker; Network.framework's callbacks stay on the socket's queue.
private final class LANHandshake {
    let connection: NWConnection
    let exporter: Data
    let deadline = DispatchTime.now() + 120.0
    let inspect: (String, String, LANRequest) -> Bool
    let load: (String) -> Data?
    let prompt: (String, String?) -> String?

    init(connection: NWConnection, exporter: Data,
         inspect: @escaping (String, String, LANRequest) -> Bool, load: @escaping (String) -> Data?,
         prompt: @escaping (String, String?) -> String?) {
        self.connection = connection
        self.exporter = exporter
        self.inspect = inspect
        self.load = load
        self.prompt = prompt
    }

    func read(_ count: Int) -> Data? {
        let result = LANWait<Data>()
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
            result.finish(error == nil && data?.count == count ? data : nil)
        }
        return result.get(until: deadline)
    }

    func write(_ data: Data) -> Bool {
        let result = LANWait<Bool>()
        connection.send(content: data, completion: .contentProcessed { result.finish($0 == nil) })
        return result.get(until: deadline) == true
    }

    func run(role: LANRole, request: LANRequest, id: String, name: String) -> (Int32, od_lan_result) {
        var callbacks = od_lan_io(
            read: { context, output, count in
                guard let context, let output else { return 0 }
                let state = Unmanaged<LANHandshake>.fromOpaque(context).takeUnretainedValue()
                guard let data = state.read(count) else { return 0 }
                _ = data.copyBytes(to: UnsafeMutableBufferPointer(start: output, count: count))
                return 1
            },
            write: { context, input, count in
                guard let context, let input else { return 0 }
                let state = Unmanaged<LANHandshake>.fromOpaque(context).takeUnretainedValue()
                return state.write(Data(bytes: input, count: count)) ? 1 : 0
            },
            inspect: { context, id, name, request in
                guard let context, let id, let name, let request = LANRequest(rawValue: request) else { return 0 }
                let state = Unmanaged<LANHandshake>.fromOpaque(context).takeUnretainedValue()
                return state.inspect(String(cString: id), String(cString: name), request) ? 1 : 0
            },
            load: { context, id, output in
                guard let context, let id, let output else { return 0 }
                let state = Unmanaged<LANHandshake>.fromOpaque(context).takeUnretainedValue()
                guard let secret = state.load(String(cString: id)), secret.count == 32 else { return 0 }
                _ = secret.copyBytes(to: UnsafeMutableBufferPointer(start: output, count: 32))
                return 1
            },
            code: { context, name, buffer, displayed in
                guard let context, let name, let buffer else { return 0 }
                let state = Unmanaged<LANHandshake>.fromOpaque(context).takeUnretainedValue()
                guard let code = state.prompt(String(cString: name), displayed != 0 ? String(cString: buffer) : nil),
                      code.utf8.count == 6, code.utf8.allSatisfy({ (48...57).contains($0) }) else { return 0 }
                for (index, value) in code.utf8.enumerated() { buffer[index] = CChar(value) }
                return 1
            })
        var result = od_lan_result()
        let bytes = Data(name.utf8.prefix(120))
        let safeName = String(data: bytes, encoding: .utf8) ?? "OpenDisplay"
        let status = exporter.withUnsafeBytes { buffer in
            od_lan_handshake(&callbacks, Unmanaged.passUnretained(self).toOpaque(),
                             role == .sender ? 1 : 0, request.rawValue, id, safeName,
                             buffer.bindMemory(to: UInt8.self).baseAddress, &result)
        }
        return (status, result)
    }
}

/// A single result transferred from a Network/UI callback to a worker.
private final class LANWait<Value>: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var value: Value?

    func finish(_ value: Value?) {
        lock.lock()
        self.value = value
        lock.unlock()
        semaphore.signal()
    }

    func get(until deadline: DispatchTime) -> Value? {
        guard semaphore.wait(timeout: deadline) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

enum LANTLS {
    static let alpn = "opendisplay/1"

    private static let identity: sec_identity_t? = {
        var certificate = [UInt8](repeating: 0, count: 1024)
        var pkcs8 = [UInt8](repeating: 0, count: 256)
        var raw = [UInt8](repeating: 0, count: 97)
        var certSize = certificate.count
        var keySize = pkcs8.count
        guard od_pair_identity(&certificate, &certSize, &pkcs8, &keySize, &raw) == 1,
              let cert = SecCertificateCreateWithData(nil, Data(certificate.prefix(certSize)) as CFData),
              let key = SecKeyCreateWithData(Data(raw) as CFData,
                   [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
                    kSecAttrKeyClass: kSecAttrKeyClassPrivate] as CFDictionary, nil),
              let identity = SecIdentityCreate(nil, cert, key) else { return nil }
        return sec_identity_create(identity)
    }()

    static func parameters(server: Bool, queue: DispatchQueue) -> NWParameters? {
        let tls = NWProtocolTLS.Options()
        let security = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv13)
        sec_protocol_options_set_tls_resumption_enabled(security, false)
        sec_protocol_options_add_tls_application_protocol(security, alpn)
        if server {
            guard let identity else { return nil }
            sec_protocol_options_set_local_identity(security, identity)
        } else {
            // This connection stays quarantined until the exporter-bound
            // pairing protocol authenticates both sides.
            sec_protocol_options_set_verify_block(security, { _, _, reply in reply(true) }, queue)
        }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.preferNoProxies = true
        parameters.serviceClass = .interactiveVideo
        return parameters
    }

    static func exporter(for connection: NWConnection) -> Data? {
        guard let tls = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata,
              let protocolName = sec_protocol_metadata_get_negotiated_protocol(tls.securityProtocolMetadata),
              String(cString: protocolName) == alpn else { return nil }
        var exported = [UInt8](repeating: 0, count: 32)
        guard od_pair_export_apple(tls.securityProtocolMetadata, &exported) == 1 else { return nil }
        return Data(exported)
    }
}

@MainActor
final class LANService: ObservableObject {
    struct Prompt: Identifiable {
        let id: UUID
        let name: String
        let code: String?
    }

    struct Authenticated {
        let id: String
        let name: String
        let request: LANRequest
        let connection: NWConnection
        let queue: DispatchQueue
    }

    @Published private(set) var peers: [LANPeer] = []
    @Published private var connectionMessage: String?
    var status: String? {
        listenerFailed
            ? String(localized: "Wi-Fi listener failed. Check local network permissions.")
            : connectionMessage
    }
    @Published private(set) var prompt: Prompt?
    @Published private(set) var paired: [String: String]
    @Published private var listenerDenied = false
    @Published private var browserDenied = false
    var localNetworkDenied: Bool { listenerDenied || browserDenied }
    var allow: ((String, LANRequest) -> Bool)?
    var onConnected: ((Authenticated) -> Bool)?
    var onPeersChanged: (() -> Void)?
    var onCodeRequested: (() -> Void)?
    var onForgot: ((String) -> Void)?

    let id: String
    private let role: LANRole
    private var name: String
    private var listener: NWListener?
    private var browser: NWBrowser?
    private let localBonjour = LocalBonjour()
    private var browseResults: Set<NWBrowser.Result> = []
    @Published private var listenerFailed = false
    private var browserFailed = false
    private let queue: DispatchQueue
    private struct Candidate {
        let connection: NWConnection
        let outgoing: Bool
        var id: String?
        var pairing = false
        var codeAttempts = 0
        var answer: LANWait<String>?
    }
    private var candidates: [UUID: Candidate] = [:]

    init(role: LANRole, id: String, name: String, queue: DispatchQueue) {
        self.role = role
        self.id = id.lowercased()
        self.name = name
        self.queue = queue
        paired = UserDefaults.standard.dictionary(forKey: "lan.\(role.rawValue).pairs") as? [String: String] ?? [:]
    }

    func start() {
        if listener == nil { startListener() }
        if browser == nil { startBrowser() }
    }

    private func startListener() {
        guard let parameters = LANTLS.parameters(server: true, queue: queue),
              let listener = try? NWListener(using: parameters) else {
            connectionMessage = String(localized: "Could not start secure Wi-Fi")
            return
        }
        self.listener = listener
        listenerFailed = false
        advertise()
        listener.newConnectionHandler = { [weak self, weak listener] connection in
            Task { @MainActor in
                guard let self, let listener, self.listener === listener else { connection.cancel(); return }
                self.start(connection, request: .incoming, expected: nil)
            }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { @MainActor in
                guard let self, let listener, self.listener === listener else { return }
                switch state {
                case .ready:
                    self.listenerDenied = false
                case .waiting(let error):
                    self.listenerDenied = Self.isPolicyDenied(error)
                case .failed(let error):
                    self.listenerDenied = Self.isPolicyDenied(error)
                    self.listenerFailed = true
                default: break
                }
            }
        }
        listener.start(queue: queue)
    }

    private func startBrowser() {
        localBonjour.changed = { [weak self] in self?.publishPeers() }
        localBonjour.start(type: role.peer.serviceType)
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: role.peer.serviceType, domain: nil), using: .tcp)
        self.browser = browser
        browserFailed = false
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            Task { @MainActor in
                guard let self, let browser, self.browser === browser else { return }
                switch state {
                case .ready: self.browserDenied = false
                case .waiting(let error): self.browserDenied = Self.isPolicyDenied(error)
                case .failed(let error):
                    self.browserDenied = Self.isPolicyDenied(error)
                    self.browserFailed = true
                default: break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            Task { @MainActor in
                guard let self, let browser, self.browser === browser else { return }
                self.browseResults = results
                self.publishPeers()
            }
        }
        browser.start(queue: queue)
    }

    private func publishPeers() {
        var seen = Set<String>()
        let visible = browseResults.compactMap(LANPeer.from)
            .filter { $0.id != id && !localBonjour.contains($0.endpoint, id: $0.id) }
            .sorted { ($0.name, $0.id) < ($1.name, $1.id) }
            .filter { seen.insert($0.id).inserted }
        guard visible != peers else { return }
        peers = visible
        onPeersChanged?()
    }

    private static func isPolicyDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error { return code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) }
        return false
    }

    func retryLocalNetworkDiscovery() {
        if listenerDenied && listenerFailed {
            listener?.cancel()
            listener = nil
            startListener()
        }
        if browserDenied && browserFailed {
            browser?.cancel()
            browser = nil
            startBrowser()
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
        localBonjour.stop()
        browseResults = []
        listenerDenied = false
        browserDenied = false
        listenerFailed = false
        for token in Array(candidates.keys) { cancel(token) }
        peers = []
    }

    func updateName(_ name: String) {
        guard self.name != name else { return }
        self.name = name
        advertise()
    }

    private func advertise() {
        var txt = NWTXTRecord()
        txt["id"] = id
        txt["auth"] = "1"
        listener?.service = NWListener.Service(name: name, type: role.serviceType, txtRecord: txt)
    }

    func connect(to peer: LANPeer, request: LANRequest) {
        guard peer.id != id, !localBonjour.contains(peer.endpoint, id: peer.id) else {
            if request == .manual { connectionMessage = String(localized: "Cannot connect to this device") }
            return
        }
        guard !candidates.values.contains(where: { $0.id == peer.id }),
              let parameters = LANTLS.parameters(server: false, queue: queue) else { return }
        start(NWConnection(to: peer.endpoint, using: parameters), request: request, expected: peer.id)
    }

    func forget(_ id: String) {
        LANPairingKeys.forget(role, id)
        paired.removeValue(forKey: id)
        savePairNames()
        onForgot?(id)
        for token in candidates.compactMap({ $0.value.id == id ? $0.key : nil }) { cancel(token) }
    }

    func answer(_ value: String?, token: UUID) {
        candidates[token]?.answer?.finish(value)
        candidates[token]?.answer = nil
        if value == nil { cancel(token) }
        if prompt?.id == token { prompt = nil }
    }

    func hasCandidate(for id: String) -> Bool {
        candidates.values.contains { $0.id == id }
    }

    private func savePairNames() {
        UserDefaults.standard.set(paired, forKey: "lan.\(role.rawValue).pairs")
    }

    private func start(_ connection: NWConnection, request: LANRequest, expected: String?) {
        guard listener != nil, candidates.count < 8 else { connection.cancel(); return }
        let token = UUID()
        candidates[token] = Candidate(connection: connection, outgoing: expected != nil, id: expected)
        if request == .manual { connectionMessage = String(localized: "Connecting over Wi-Fi…") }
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.candidates[token] != nil else { return }
                switch state {
                case .ready:
                    if LocalNetworkDevice.contains(connection) {
                        if request == .manual { self.connectionMessage = String(localized: "Cannot connect to this device") }
                        self.cancel(token)
                        return
                    }
                    self.authenticate(token, request: request)
                case .waiting(let error):
                    Log.info("LAN TLS waiting: \(error)")
                case .failed(let error):
                    Log.info("LAN TLS failed: \(error)")
                    if request == .manual { self.connectionMessage = String(localized: "Could not reach the device over Wi-Fi") }
                    self.cancel(token)
                case .cancelled:
                    self.cancel(token)
                default: break
                }
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            Task { @MainActor in
                guard let self, let candidate = self.candidates[token], !candidate.pairing else { return }
                if request == .manual { self.connectionMessage = String(localized: "Wi-Fi connection timed out") }
                self.cancel(token)
            }
        }
    }

    private func authenticate(_ token: UUID, request: LANRequest) {
        guard let candidate = candidates[token], !candidate.pairing,
              let exporter = LANTLS.exporter(for: candidate.connection) else {
            cancel(token)
            return
        }
        candidates[token]?.pairing = true
        let handshake = LANHandshake(connection: candidate.connection, exporter: exporter,
            inspect: { [weak self] id, _, request in
                let result = LANWait<Bool>()
                Task { @MainActor in result.finish(self?.inspect(token, id: id, request: request)) }
                return result.get(until: .now() + 5) == true
            }, load: { [role] in LANPairingKeys.read(role, $0) },
            prompt: { [weak self] name, code in
                let result = LANWait<String>()
                Task { @MainActor in
                    guard let self, self.candidates[token] != nil,
                          self.prompt == nil || self.prompt?.id == token else { result.finish(nil); return }
                    self.prompt = Prompt(id: token, name: name, code: code)
                    if let code { result.finish(code) }
                    else {
                        if self.candidates[token]?.codeAttempts ?? 0 > 0 {
                            self.connectionMessage = String(localized: "The code did not match. Try again.")
                        }
                        self.candidates[token]?.codeAttempts += 1
                        self.candidates[token]?.answer = result
                        self.onCodeRequested?()
                    }
                }
                return result.get(until: .now() + 120)
            })
        let (role, id, name) = (self.role, self.id, self.name)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (status, result) = handshake.run(role: role, request: request, id: id, name: name)
            Task { @MainActor in self?.completed(token, status: status, result: result) }
        }
        queue.asyncAfter(deadline: handshake.deadline) { [weak self] in
            Task { @MainActor in
                guard let self, self.candidates[token] != nil else { return }
                if self.prompt?.id == token { self.connectionMessage = String(localized: "The pairing code expired. Try connecting again.") }
                self.cancel(token)
            }
        }
    }

    private func inspect(_ token: UUID, id: String, request: LANRequest) -> Bool {
        guard let candidate = candidates[token], candidate.id == nil || candidate.id == id,
              allow?(id, request) != false else { return false }
        if let twin = candidates.first(where: { $0.key != token && $0.value.id == id }) {
            // Both endpoints prefer the connection opened by the sender.
            guard candidate.outgoing != twin.value.outgoing,
                  candidate.outgoing == (role == .sender) else { return false }
            cancel(twin.key)
        }
        candidates[token]?.id = id
        return true
    }

    private func completed(_ token: UUID, status: Int32, result: od_lan_result) {
        guard let candidate = candidates.removeValue(forKey: token) else { return }
        if prompt?.id == token { prompt = nil }
        guard status == 1, let id = candidate.id,
              let request = LANRequest(rawValue: result.request) else {
            candidate.connection.cancel()
            Log.info("LAN authentication ended with status \(status)")
            switch status {
            case -2: self.connectionMessage = String(localized: "Pair again to resume Wi-Fi")
            case -3: self.connectionMessage = String(localized: "Wi-Fi verification failed")
            default:
                if candidate.outgoing { self.connectionMessage = String(localized: "The Wi-Fi connection was closed before verification") }
            }
            return
        }
        let name = withUnsafeBytes(of: result.peer_name) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        if result.fresh != 0 {
            let key = withUnsafeBytes(of: result.secret) { Data($0) }
            guard LANPairingKeys.write(key, role, id) else {
                self.connectionMessage = String(localized: "The pairing key could not be saved")
                candidate.connection.cancel()
                return
            }
        }
        candidate.connection.stateUpdateHandler = nil
        guard onConnected?(Authenticated(id: id, name: name, request: request,
                                         connection: candidate.connection, queue: queue)) == true else {
            candidate.connection.cancel()
            return
        }
        if paired[id] != name {
            paired[id] = name
            savePairNames()
        }
        self.connectionMessage = nil
    }

    private func cancel(_ token: UUID) {
        guard let candidate = candidates.removeValue(forKey: token) else { return }
        candidate.answer?.finish(nil)
        candidate.connection.cancel()
        if prompt?.id == token { prompt = nil }
    }
}

struct LANReceiverControls: View {
    @ObservedObject var lan: LANService
    let connected: Bool
    let disconnect: () -> Void

    var body: some View {
        if let prompt = lan.prompt, let code = prompt.code {
            VStack(alignment: .leading, spacing: 8) {
                Text("Enter this code on \(prompt.name)")
                Text(code).font(.title.monospacedDigit())
                Button("Cancel") { lan.answer(nil, token: prompt.id) }
            }
        } else if !connected {
            ForEach(lan.peers) { peer in
                Button {
                    lan.connect(to: peer, request: .manual)
                } label: {
                    Label(peer.name, systemImage: "desktopcomputer")
                }
            }
        }
        if let status = lan.status { Text(status).font(.caption) }
        if connected { Button("Disconnect", action: disconnect) }
        if !lan.paired.isEmpty {
            Menu("Forget paired computer") {
                ForEach(lan.paired.keys.sorted(), id: \.self) { id in
                    Button(lan.paired[id] ?? id) { lan.forget(id) }
                }
            }
        }
    }
}

extension LANService {
    static let senderInstallationID: String = {
        let key = "lan.sender.installationID"
        if let existing = UserDefaults.standard.string(forKey: key), UUID(uuidString: existing) != nil {
            return existing
        }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()
}

struct LANCodeForm: View {
    @ObservedObject var lan: LANService
    var forget: (String) -> Void
    @State private var code = ""
    @FocusState private var codeFocused: Bool

    var body: some View {
        if let prompt = lan.prompt, prompt.code == nil {
            Text("Enter the code shown on \(prompt.name)")
            HStack {
                TextField("Six-digit code", text: $code, prompt: Text("Six-digit code"))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .focused($codeFocused)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 32)
                    .frame(width: 144)
                    .background {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.background)
                            .onTapGesture { codeFocused = true }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(codeFocused ? Color.accentColor : Color.secondary,
                                          lineWidth: codeFocused ? 2 : 1)
                            .allowsHitTesting(false)
                    }
                    .onSubmit { submit(prompt.id) }
                    .task(id: prompt.id) { codeFocused = true }
                Button("Verify") { submit(prompt.id) }
                    .disabled(!valid)
                Button("Cancel") {
                    lan.answer(nil, token: prompt.id)
                    code = ""
                }
            }
        }
        if let status = lan.status { Text(status).font(.caption) }
        if !lan.paired.isEmpty {
            Menu("Forget paired receiver") {
                ForEach(lan.paired.keys.sorted(), id: \.self) { id in
                    Button(lan.paired[id] ?? id) { forget(id) }
                }
            }
        }
    }

    private var valid: Bool {
        code.utf8.count == 6 && code.utf8.allSatisfy { (48...57).contains($0) }
    }

    private func submit(_ token: UUID) {
        guard valid else { return }
        lan.answer(code, token: token)
        code = ""
    }
}
