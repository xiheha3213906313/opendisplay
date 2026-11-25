import AppKit

enum MacPrivacySettings {
    @discardableResult
    static func open(_ anchor: String) -> Bool {
        let modern = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
        let legacy = "x-apple.systempreferences:com.apple.preference.security"
        let routes = if #available(macOS 13, *) {
            [modern + "?" + anchor, legacy + "?" + anchor, modern, legacy]
        } else {
            [legacy + "?" + anchor, legacy]
        }
        return routes.compactMap(URL.init(string:)).contains { NSWorkspace.shared.open($0) }
    }
}
