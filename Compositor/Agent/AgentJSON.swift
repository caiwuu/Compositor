import Foundation
import CoreGraphics

typealias JSONObject = [String: Any]

/// A tool call that can't go ahead, told to the agent in plain words rather than as an alert on screen.
nonisolated struct AgentError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// A tool call's arguments, read with the checks every tool needs: the agent's JSON is never trusted to have the
/// right types, and a wrong one is reported by name instead of being quietly ignored.
nonisolated struct AgentArguments: @unchecked Sendable {
    let values: JSONObject
    init(_ values: JSONObject) { self.values = values }

    func has(_ key: String) -> Bool { values[key] != nil && !(values[key] is NSNull) }

    func string(_ key: String) throws -> String? {
        guard has(key) else { return nil }
        guard let value = values[key] as? String else { throw AgentError("“\(key)” must be a string.") }
        return value
    }
    func requiredString(_ key: String) throws -> String {
        guard let value = try string(key), !value.isEmpty else { throw AgentError("“\(key)” is required.") }
        return value
    }
    func double(_ key: String) throws -> Double? {
        guard has(key) else { return nil }
        guard let number = values[key] as? NSNumber, !Self.isBool(number), number.doubleValue.isFinite else {
            throw AgentError("“\(key)” must be a number.")
        }
        return number.doubleValue
    }
    func requiredDouble(_ key: String) throws -> Double {
        guard let value = try double(key) else { throw AgentError("“\(key)” is required.") }
        return value
    }
    func int(_ key: String) throws -> Int? {
        guard let value = try double(key) else { return nil }
        guard value.rounded() == value, abs(value) < 1e9 else { throw AgentError("“\(key)” must be a whole number.") }
        return Int(value)
    }
    func requiredInt(_ key: String) throws -> Int {
        guard let value = try int(key) else { throw AgentError("“\(key)” is required.") }
        return value
    }
    func bool(_ key: String) throws -> Bool? {
        guard has(key) else { return nil }
        guard let number = values[key] as? NSNumber, Self.isBool(number) else { throw AgentError("“\(key)” must be true or false.") }
        return number.boolValue
    }
    func object(_ key: String) throws -> JSONObject? {
        guard has(key) else { return nil }
        guard let value = values[key] as? JSONObject else { throw AgentError("“\(key)” must be an object.") }
        return value
    }
    func array(_ key: String) throws -> [Any]? {
        guard has(key) else { return nil }
        guard let value = values[key] as? [Any] else { throw AgentError("“\(key)” must be an array.") }
        return value
    }
    func uuid(_ key: String) throws -> UUID? {
        guard let text = try string(key) else { return nil }
        guard let id = UUID(uuidString: text) else { throw AgentError("“\(key)” isn’t an id Compositor gave out: \(text).") }
        return id
    }
    func requiredUUID(_ key: String) throws -> UUID {
        guard let id = try uuid(key) else { throw AgentError("“\(key)” is required.") }
        return id
    }
    func uuids(_ key: String) throws -> [UUID]? {
        guard let list = try array(key) else { return nil }
        return try list.map { item in
            guard let text = item as? String, let id = UUID(uuidString: text) else { throw AgentError("“\(key)” must list layer ids.") }
            return id
        }
    }
    func color(_ key: String) throws -> PaletteColor? {
        guard let text = try string(key) else { return nil }
        guard let color = AgentColor.parse(text) else { throw AgentError("“\(key)” must be a color such as #FF8800, got “\(text)”.") }
        return color
    }
    func choice<T: RawRepresentable & CaseIterable>(_ key: String, _ type: T.Type) throws -> T? where T.RawValue == String {
        guard let text = try string(key) else { return nil }
        if let exact = T(rawValue: text) { return exact }
        if let loose = T.allCases.first(where: { AgentColor.simplified($0.rawValue) == AgentColor.simplified(text) }) { return loose }
        throw AgentError("“\(key)” must be one of: \(T.allCases.map(\.rawValue).joined(separator: ", ")).")
    }
    /// A rectangle given as x, y, width and height, in document pixels.
    func rect(prefix: String = "") throws -> CGRect? {
        let x = try double(prefix + "x"), y = try double(prefix + "y"), width = try double(prefix + "width"), height = try double(prefix + "height")
        if x == nil && y == nil && width == nil && height == nil { return nil }
        guard let x, let y, let width, let height else { throw AgentError("Give all of x, y, width and height.") }
        guard width > 0, height > 0 else { throw AgentError("width and height must be greater than zero.") }
        return CGRect(x: x, y: y, width: width, height: height)
    }
    /// A list of [x, y] pairs (or {"x", "y"} objects), in document pixels.
    func points(_ key: String) throws -> [CGPoint]? {
        guard let list = try array(key) else { return nil }
        return try list.map { try Self.point($0, key: key) }
    }
    static func point(_ value: Any, key: String) throws -> CGPoint {
        if let pair = value as? [NSNumber], pair.count == 2 { return CGPoint(x: pair[0].doubleValue, y: pair[1].doubleValue) }
        if let object = value as? JSONObject, let x = object["x"] as? NSNumber, let y = object["y"] as? NSNumber {
            return CGPoint(x: x.doubleValue, y: y.doubleValue)
        }
        throw AgentError("“\(key)” must list points as [x, y].")
    }
    static func points(_ value: Any, key: String) throws -> [CGPoint] {
        guard let list = value as? [Any] else { throw AgentError("“\(key)” must be a list of [x, y] points.") }
        return try list.map { try point($0, key: key) }
    }
    static func isBool(_ number: NSNumber) -> Bool { CFGetTypeID(number) == CFBooleanGetTypeID() }
}

nonisolated enum AgentColor {
    private static let names: [String: UInt32] = [
        "black": 0x000000, "white": 0xFFFFFF, "red": 0xFF0000, "green": 0x00FF00, "blue": 0x0000FF,
        "yellow": 0xFFFF00, "cyan": 0x00FFFF, "magenta": 0xFF00FF, "gray": 0x808080, "grey": 0x808080,
        "orange": 0xFF8000, "purple": 0x800080, "pink": 0xFFC0CB, "brown": 0x8B4513,
    ]
    static func parse(_ text: String) -> PaletteColor? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        if let value = names[trimmed] { return color(value) }
        var hex = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return color(value)
    }
    private static func color(_ value: UInt32) -> PaletteColor {
        PaletteColor(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255)
    }
    static func hex(_ color: PaletteColor) -> String {
        func byte(_ value: CGFloat) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(color.red), byte(color.green), byte(color.blue))
    }
    static func hex(red: CGFloat, green: CGFloat, blue: CGFloat) -> String { hex(PaletteColor(red: red, green: green, blue: blue)) }
    /// Compares choice names without case, spaces or punctuation, so "gaussian_blur" finds "Gaussian Blur".
    static func simplified(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
}

/// Settings the agent changes in part: the value as JSON, the agent's keys laid over it, decoded back. Keys it leaves
/// out keep their value, `null` removes an optional one, and a "#RRGGBB" string stands in for any red/green/blue color.
nonisolated enum AgentCoding {
    static func json<T: Encodable>(_ value: T) throws -> Any {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    static func merged<T: Codable>(_ base: T, with patch: JSONObject?, name: String = "settings") throws -> T {
        guard let patch, !patch.isEmpty else { return base }
        let combined = merge(try json(base), patch)
        let data = try JSONSerialization.data(withJSONObject: combined, options: [.fragmentsAllowed])
        let decoded: T
        do { decoded = try JSONDecoder().decode(T.self, from: data) }
        catch { throw AgentError("Invalid \(name): \(describe(error)). Call describe_settings to see the expected shape.") }
        // A key the settings don't have would otherwise be dropped without a word, and the edit look done.
        let unknown = unknownKeys(patch, in: try json(decoded))
        guard unknown.isEmpty else {
            throw AgentError("\(name.prefix(1).uppercased() + name.dropFirst()) have no \(unknown.sorted().map { "“\($0)”" }.joined(separator: ", ")). Call describe_settings to see the keys they take.")
        }
        return decoded
    }

    /// The keys in `patch` (dotted paths into nested objects) that `result` doesn't have.
    static func unknownKeys(_ patch: Any, in result: Any, path: String = "") -> [String] {
        guard let patch = patch as? JSONObject, let result = result as? JSONObject else { return [] }
        return patch.flatMap { key, value -> [String] in
            if value is NSNull || (key == "color" && result["red"] != nil) { return [] }
            guard let found = result[key] else { return [path + key] }
            return unknownKeys(value, in: found, path: path + key + ".")
        }
    }

    static func merge(_ base: Any, _ patch: Any) -> Any {
        guard var result = base as? JSONObject, let changes = patch as? JSONObject else { return patch }
        for (key, value) in changes {
            if value is NSNull { result.removeValue(forKey: key); continue }
            // "color": "#RRGGBB" on an object that keeps its color as red, green and blue.
            if key == "color", let text = value as? String, result["red"] != nil, let color = AgentColor.parse(text) {
                result["red"] = color.red; result["green"] = color.green; result["blue"] = color.blue
                continue
            }
            if let text = value as? String, let existing = result[key] as? JSONObject, existing["red"] != nil,
               let color = AgentColor.parse(text) {
                var replaced = existing
                replaced["red"] = color.red; replaced["green"] = color.green; replaced["blue"] = color.blue
                result[key] = replaced
                continue
            }
            result[key] = result[key].map { merge($0, value) } ?? value
        }
        return result
    }

    static func describe(_ error: Error) -> String {
        guard let error = error as? DecodingError else { return error.localizedDescription }
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }
            return keys.isEmpty ? "the value" : "“\(keys.joined(separator: "."))”"
        }
        switch error {
        case .typeMismatch(_, let context): return "\(path(context)) has the wrong type"
        case .valueNotFound(_, let context): return "\(path(context)) is missing a value"
        case .keyNotFound(let key, let context): return "\(path(context)) needs “\(key.stringValue)”"
        case .dataCorrupted(let context): return "\(path(context)) isn’t valid (\(context.debugDescription))"
        @unknown default: return error.localizedDescription
        }
    }

    /// Pretty JSON text for a tool result.
    static func text(_ value: Any) -> String {
        let value = clean(value)
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "\(value)" }
        return text
    }

    /// Optionals unwrapped (nil as null), and fractions to four places as written, so 0.6 doesn't come out as
    /// 0.59999999999999998.
    static func clean(_ value: Any) -> Any {
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional { return mirror.children.first.map { clean($0.value) } ?? NSNull() }
        switch value {
        case let object as [String: Any]: return object.mapValues(clean)
        case let array as [Any]: return array.map(clean)
        case let number as NSNumber where !AgentArguments.isBool(number) && CFNumberIsFloatType(number as CFNumber):
            let double = number.doubleValue
            guard double.isFinite else { return NSNull() }
            return NSDecimalNumber(string: String((double * 10_000).rounded() / 10_000))
        default: return value
        }
    }
}

/// JSON Schema pieces for the tool list.
nonisolated enum Schema {
    static func object(_ properties: [String: JSONObject], required: [String] = [], description: String? = nil) -> JSONObject {
        var schema: JSONObject = ["type": "object", "properties": properties, "additionalProperties": false]
        if !required.isEmpty { schema["required"] = required }
        if let description { schema["description"] = description }
        return schema
    }
    static func string(_ description: String, choices: [String]? = nil) -> JSONObject {
        var schema: JSONObject = ["type": "string", "description": description]
        if let choices { schema["enum"] = choices }
        return schema
    }
    static func number(_ description: String, minimum: Double? = nil, maximum: Double? = nil) -> JSONObject {
        var schema: JSONObject = ["type": "number", "description": description]
        if let minimum { schema["minimum"] = minimum }
        if let maximum { schema["maximum"] = maximum }
        return schema
    }
    static func integer(_ description: String, minimum: Int? = nil, maximum: Int? = nil) -> JSONObject {
        var schema: JSONObject = ["type": "integer", "description": description]
        if let minimum { schema["minimum"] = minimum }
        if let maximum { schema["maximum"] = maximum }
        return schema
    }
    static func boolean(_ description: String) -> JSONObject { ["type": "boolean", "description": description] }
    static func array(_ description: String, items: JSONObject) -> JSONObject { ["type": "array", "description": description, "items": items] }
    static func anyObject(_ description: String) -> JSONObject { ["type": "object", "description": description] }
    static var points: JSONObject {
        array("Points as [x, y] pairs in document pixels.", items: ["type": "array", "items": ["type": "number"], "minItems": 2, "maxItems": 2])
    }
    static var documentID: JSONObject { string("An open document’s id, from list_documents. Leave it out for the one on screen.") }
    static var layerID: JSONObject { string("A layer id from get_document.") }
    static var selectionMode: JSONObject { string("How the result combines with the current selection.", choices: ["replace", "add", "subtract"]) }
    static func rect(_ what: String) -> [String: JSONObject] {
        ["x": number("Left edge of \(what), in document pixels."), "y": number("Top edge of \(what), in document pixels."),
         "width": number("Width of \(what), in pixels.", minimum: 0), "height": number("Height of \(what), in pixels.", minimum: 0)]
    }
}
