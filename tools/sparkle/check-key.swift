import CryptoKit
import Foundation

guard CommandLine.arguments.count == 2,
      let encoded = readLine(),
      let seed = Data(base64Encoded: encoded),
      let publicKey = Data(base64Encoded: CommandLine.arguments[1]),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed),
      key.publicKey.rawRepresentation == publicKey else {
    FileHandle.standardError.write(Data("The Sparkle secret does not match the app public key.\n".utf8))
    exit(1)
}
