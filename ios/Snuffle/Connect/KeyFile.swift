import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// The `.p8` private key App Store Connect downloads. Declared in Info.plist so Files and AirDrop offer
    /// "用 Snuffle 打开".
    static let appStoreConnectKey = UTType(importedAs: "ai.snuffle.p8")
}

/// An App Store Connect key file: its PEM text and, from Apple's `AuthKey_<KEYID>.p8` name, the key ID.
nonisolated struct KeyFile: Equatable, Sendable {
    var pem: String
    var keyId: String?

    /// Reads a file chosen in the picker or handed over by "Open in"; nil when it is not a private key.
    init?(url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8), text.contains("PRIVATE KEY") else { return nil }
        pem = text
        let name = url.deletingPathExtension().lastPathComponent
        keyId = name.hasPrefix("AuthKey_") ? String(name.dropFirst("AuthKey_".count)) : nil
    }
}
