import Foundation

/// A validated haptic request from the web app. The only accepted wire shapes are
///   { v: 1, kind: "selection" }
///   { v: 1, kind: "impact", style: "light" | "medium" | "heavy" | "soft" | "rigid" }
/// Anything else (unknown keys, wrong types, other versions) is rejected.
public enum HapticRequest: Equatable {
    public enum ImpactStyle: String, CaseIterable {
        case light, medium, heavy, soft, rigid
    }

    case selection
    case impact(ImpactStyle)
}

public enum HapticRequestError: Error, Equatable {
    case notAnObject
    case unsupportedVersion
    case unknownKey(String)
    case unknownKind
    case invalidStyle
}

public enum HapticRequestParser {
    public static let currentVersion = 1

    public static func parse(_ body: Any) -> Result<HapticRequest, HapticRequestError> {
        guard let object = body as? [String: Any] else { return .failure(.notAnObject) }
        // JSON numbers arrive as NSNumber; reject booleans, which bridge to NSNumber too.
        guard let version = object["v"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(),
              version.intValue == currentVersion, version.doubleValue == Double(currentVersion)
        else { return .failure(.unsupportedVersion) }
        guard let kind = object["kind"] as? String else { return .failure(.unknownKind) }

        switch kind {
        case "selection":
            if let extra = object.keys.first(where: { !["v", "kind"].contains($0) }) { return .failure(.unknownKey(extra)) }
            return .success(.selection)
        case "impact":
            if let extra = object.keys.first(where: { !["v", "kind", "style"].contains($0) }) { return .failure(.unknownKey(extra)) }
            guard let raw = object["style"] as? String, let style = HapticRequest.ImpactStyle(rawValue: raw) else {
                return .failure(.invalidStyle)
            }
            return .success(.impact(style))
        default:
            return .failure(.unknownKind)
        }
    }
}
