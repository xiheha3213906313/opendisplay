import Foundation
import Network

enum LocalNetworkDevice {
    struct Address: Equatable {
        let bytes: Data
        let scope: String?

        init?(_ literal: String, interface: String? = nil) {
            let parts = literal.split(separator: "%", maxSplits: 1)
            guard let address = parts.first else { return nil }
            if let ipv4 = IPv4Address(String(address)) {
                bytes = ipv4.rawValue
                scope = nil
            } else if let ipv6 = IPv6Address(String(address)) {
                bytes = ipv6.isIPv4Mapped ? Data(ipv6.rawValue.suffix(4)) : ipv6.rawValue
                let zone = parts.count == 2 ? String(parts[1]) : interface
                if ipv6.isLinkLocal, let zone, let index = UInt32(zone) {
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    scope = if_indextoname(index, &name) == nil ? zone : String(cString: name)
                } else {
                    scope = ipv6.isLinkLocal ? zone : nil
                }
            } else {
                return nil
            }
        }

        var isLoopback: Bool {
            bytes.count == 4 ? bytes.first == 127 : IPv6Address(bytes)?.isLoopback == true
        }

        func isLocal(in addresses: [Address]) -> Bool {
            isLoopback || addresses.contains { $0.bytes == bytes && (scope == nil || $0.scope == scope) }
        }
    }

    static func isLoopback(_ endpoint: NWEndpoint?) -> Bool {
        guard case .hostPort(let host, _)? = endpoint else { return false }
        if case .name(let name, _) = host, name.lowercased().trimmingCharacters(in: .init(charactersIn: ".")) == "localhost" {
            return true
        }
        return Address("\(host)")?.isLoopback == true
    }

    static func contains(_ endpoint: NWEndpoint?) -> Bool {
        contains(endpoint, interface: nil)
    }

    private static func contains(_ endpoint: NWEndpoint?, interface: String?) -> Bool {
        guard case .hostPort(let host, _)? = endpoint else { return false }
        return isLoopback(endpoint) || Address("\(host)", interface: interface)?.isLocal(in: interfaceAddresses()) == true
    }

    static func contains(_ connection: NWConnection) -> Bool {
        let path = connection.currentPath
        return path?.usesInterfaceType(.loopback) == true
            || contains(path?.remoteEndpoint ?? connection.endpoint, interface: path?.availableInterfaces.first?.name)
    }

    private static func interfaceAddresses() -> [Address] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        return sequence(first: first, next: { $0.pointee.ifa_next }).compactMap { entry in
            let interface = entry.pointee
            guard let address = interface.ifa_addr,
                  address.pointee.sa_family == AF_INET || address.pointee.sa_family == AF_INET6 else { return nil }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { return nil }
            return Address(String(cString: host), interface: String(cString: interface.ifa_name))
        }
    }
}

/// Watches advertisements registered by this host, including other app bundles.
/// Manage DNS-SD references on the main queue. Sender sockets can read the snapshot.
final class LocalBonjour {
    struct Service: Hashable {
        let name: String
        let type: String
        let domain: String

        init(name: String, type: String, domain: String) {
            self.name = name.lowercased()
            self.type = type.lowercased().trimmingCharacters(in: .init(charactersIn: "."))
            self.domain = domain.lowercased().trimmingCharacters(in: .init(charactersIn: "."))
        }
    }

    struct Record {
        var id: String?
        var port: UInt16?
    }

    private let lock = NSLock()
    private var records: [Service: Record] = [:]
    private var browser: DNSServiceRef?
    private var resolutions: [DNSServiceRef: Service] = [:]
    var changed: (() -> Void)?

    func start(type: String) {
        guard browser == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard DNSServiceBrowse(&browser, 0, kDNSServiceInterfaceIndexLocalOnly, type, "local.", {
            _, flags, index, error, name, type, domain, context in
            guard let context else { return }
            let watcher = Unmanaged<LocalBonjour>.fromOpaque(context).takeUnretainedValue()
            guard error == kDNSServiceErr_NoError, let name, let type, let domain else {
                watcher.stop()
                watcher.changed?()
                return
            }
            watcher.update(flags: flags, index: index, name: String(cString: name),
                           type: String(cString: type), domain: String(cString: domain))
        }, context) == kDNSServiceErr_NoError, let browser else { return }
        if DNSServiceSetDispatchQueue(browser, .main) != kDNSServiceErr_NoError { stop() }
    }

    func stop() {
        if let browser { DNSServiceRefDeallocate(browser) }
        browser = nil
        for resolution in resolutions.keys { DNSServiceRefDeallocate(resolution) }
        resolutions.removeAll()
        lock.withLock { records.removeAll() }
    }

    deinit { stop() }

    func contains(_ endpoint: NWEndpoint, id: String?) -> Bool {
        guard case .service(let name, let type, let domain, _) = endpoint else {
            return LocalNetworkDevice.contains(endpoint)
        }
        let service = Service(name: name, type: type, domain: domain)
        return lock.withLock { Self.matches(service, id: id, in: records) }
    }

    static func matches(_ service: Service, id: String?, in records: [Service: Record]) -> Bool {
        guard let record = records[service] else { return false }
        guard let localID = record.id, let id else { return true }
        return localID == id.lowercased()
    }

    func containsReceiver(id: String?, port: UInt16?) -> Bool {
        lock.withLock {
            records.values.contains { record in
                if let id, let localID = record.id { return localID == id.lowercased() }
                return port != nil && record.port == port
            }
        }
    }

    private func update(flags: DNSServiceFlags, index: UInt32, name: String, type: String, domain: String) {
        let service = Service(name: name, type: type, domain: domain)
        if flags & kDNSServiceFlagsAdd == 0 {
            lock.withLock { _ = records.removeValue(forKey: service) }
            for ref in resolutions.compactMap({ $0.value == service ? $0.key : nil }) {
                resolutions.removeValue(forKey: ref)
                DNSServiceRefDeallocate(ref)
            }
        } else if lock.withLock({ records[service] == nil }) {
            lock.withLock { records[service] = Record() }
            resolve(service, index: index, name: name, type: type, domain: domain)
        }
        if flags & kDNSServiceFlagsMoreComing == 0 { changed?() }
    }

    private func resolve(_ service: Service, index: UInt32, name: String, type: String, domain: String) {
        var ref: DNSServiceRef?
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard DNSServiceResolve(&ref, 0, index, name, type, domain, {
            ref, _, _, error, _, _, port, length, txt, context in
            guard let context, let ref else { return }
            let watcher = Unmanaged<LocalBonjour>.fromOpaque(context).takeUnretainedValue()
            watcher.resolved(ref, error: error, port: port, length: length, txt: txt)
        }, context) == kDNSServiceErr_NoError, let ref else { return }
        resolutions[ref] = service
        if DNSServiceSetDispatchQueue(ref, .main) != kDNSServiceErr_NoError {
            resolutions.removeValue(forKey: ref)
            DNSServiceRefDeallocate(ref)
        }
    }

    private func resolved(_ ref: DNSServiceRef, error: DNSServiceErrorType, port: UInt16,
                          length: UInt16, txt: UnsafePointer<UInt8>?) {
        guard let service = resolutions.removeValue(forKey: ref) else { return }
        defer { DNSServiceRefDeallocate(ref) }
        guard error == kDNSServiceErr_NoError else { return }
        var count: UInt8 = 0
        let id = TXTRecordGetValuePtr(length, txt, "id", &count).flatMap { value in
            String(data: Data(bytes: value, count: Int(count)), encoding: .utf8)?.lowercased()
        }
        lock.withLock { records[service] = Record(id: id, port: UInt16(bigEndian: port)) }
        changed?()
    }
}
