import Foundation

enum MainBranchUpdates {
    enum Product {
        case sender, receiver

        var filename: String {
            switch self {
            case .sender: return "OpenDisplay.dmg"
            case .receiver: return "OpenDisplayReceiver.dmg"
            }
        }
    }

    struct Available {
        let version: String
        let url: URL
    }

    private struct Manifest: Decodable {
        let version: String
        let senderBuild: Int
        let receiverBuild: Int

        func build(for product: Product) -> Int {
            product == .sender ? senderBuild : receiverBuild
        }
    }

    private struct Version: Comparable {
        let components: [Int]

        init?(_ value: String) {
            let parts = value.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 3 else { return nil }
            let parsed = parts.compactMap { part -> Int? in
                guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
                return Int(part)
            }
            guard parsed.count == parts.count else { return nil }
            components = parsed
        }

        static func < (lhs: Version, rhs: Version) -> Bool {
            lhs.components.lexicographicallyPrecedes(rhs.components)
        }
    }

    enum CheckError: Error {
        case unexpectedResponse, invalidVersion
    }

    private static let directory = URL(string: "https://raw.githubusercontent.com/xiheha3213906313/opendisplay/main/downloads/macos/")!
    static let manifestURL = directory.appendingPathComponent("latest.json")

    static func check(product: Product, version: String, build: Int,
                      session: URLSession = .shared) async throws -> Available? {
        let request = URLRequest(url: manifestURL, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 15)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url == manifestURL else { throw CheckError.unexpectedResponse }
        return try available(in: data, product: product, version: version, build: build)
    }

    static func available(in data: Data, product: Product, version: String, build: Int) throws -> Available? {
        let latest = try JSONDecoder().decode(Manifest.self, from: data)
        let latestBuild = latest.build(for: product)
        guard let installed = Version(version), let offered = Version(latest.version),
              latestBuild > 0 else { throw CheckError.invalidVersion }
        guard offered > installed || (offered == installed && latestBuild > build) else { return nil }

        let url = directory.appendingPathComponent(product.filename)
        var download = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        download.queryItems = [URLQueryItem(name: "version", value: latest.version),
                               URLQueryItem(name: "build", value: String(latestBuild))]
        return Available(version: latest.version, url: download.url!)
    }
}
