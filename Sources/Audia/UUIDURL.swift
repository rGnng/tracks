import AppKit
import Foundation
import SwiftUI

enum UUIDURLStyle: String, CaseIterable, Identifiable {
    case uuid
    case base64URL

    var id: String { rawValue }

    var title: String {
        switch self {
        case .uuid: return "UUID"
        case .base64URL: return "URL safe BASE64"
        }
    }
}

enum UUIDURLDefaults {
    static let enabledKey = "copyUUIDURL.enabled"
    static let prefixKey = "copyUUIDURL.prefix"
    static let styleKey = "copyUUIDURL.type"
}

enum UUIDURL {
    static func string(for uuid: UUID, style: UUIDURLStyle) -> String {
        switch style {
        case .uuid:
            return uuid.uuidString
        case .base64URL:
            return base64URL(for: uuid)
        }
    }

    static func base64URL(for uuid: UUID) -> String {
        let data = withUnsafeBytes(of: uuid.uuid) { Data($0) }
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func uuid(fromBase64URL value: String) -> UUID? {
        var base64 = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: base64), data.count == 16 else { return nil }
        let bytes = [UInt8](data)
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    static func copyValue(prefix: String, uuid: UUID, style: UUIDURLStyle) -> String {
        let trimmedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedPrefix + string(for: uuid, style: style)
    }

    static func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

struct CopyUUIDURLMenuItem: View {
    let uuid: UUID

    @AppStorage(UUIDURLDefaults.enabledKey) private var enabled = false
    @AppStorage(UUIDURLDefaults.prefixKey) private var prefix = ""
    @AppStorage(UUIDURLDefaults.styleKey) private var styleRaw = UUIDURLStyle.uuid.rawValue

    var body: some View {
        Group {
            Divider()
            if enabled {
                Button("Copy UUID URL") {
                    let style = UUIDURLStyle(rawValue: styleRaw) ?? .uuid
                    let value = UUIDURL.copyValue(prefix: prefix, uuid: uuid, style: style)
                    UUIDURL.copyToPasteboard(value)
                }
            }
        }
    }
}
