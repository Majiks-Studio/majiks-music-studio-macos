import Foundation

/// The catalog's `paramsSchema` check, on the Swift side of the FFI.
///
/// # Why this exists
///
/// `engine/timeline-core/src/session.rs` validates every submitted command's
/// params against `command-catalog.v2.json` with `additionalProperties: false`
/// BEFORE apply, and refuses anything that does not fit. That refusal is
/// correct. What was not correct is that the app could not see it: eleven
/// shipping gestures (rename a track, colour it, set a clip's gain, drop a
/// marker) had been sending the MOCK engine's parameter names — `gain` where
/// the contract says `gainDb`, `height` where it says `heightPx`, `index` where
/// it says `newIndex` — and the real engine refused all eleven, silently.
///
/// The reason nobody noticed for so long is the important part, and it is the
/// reason this file is in `Sources` rather than in a test: **the mock read the
/// same wrong keys.** `StudioMockEngine.applyCatalog` accepted `gain`, so every
/// test of every one of those gestures passed. The test seam agreed with the
/// bug. Fixing the eleven call sites would have left that agreement in place,
/// and the twelfth command written against the mock would have arrived with the
/// same defect and the same green suite.
///
/// So the mock validates through here, against the SAME contract the engine
/// validates against, and a wrong parameter name now fails under
/// `MAJIKS_ENGINE=mock` too. That is the difference between fixing eleven bugs
/// and closing the class that produces them.
///
/// # Fidelity
///
/// This is a port of `engine/timeline-core/src/schema.rs` — the same subset of
/// JSON Schema, the same verdicts, the same rule that an **unrecognised
/// keyword is a loud error rather than a skipped check**. A validator that
/// quietly ignores the keyword it does not understand is a validator that
/// passes everything, which is the silent-degradation shape this whole file is
/// here to prevent. `scripts/generate-catalog-names.sh` refuses to emit
/// `CatalogSchemas.swift` if the contract ever uses a keyword this file does
/// not implement, so the two cannot drift apart without something failing.
enum StudioCatalogSchema {

    /// `command-catalog.v2.json`'s paramsSchema fragments, parsed once.
    ///
    /// Keyed by command name. A name absent here is a name the catalog does not
    /// define; see `validate` for what that means.
    ///
    /// `nonisolated(unsafe)` because `[String: Any]` is not `Sendable` and this
    /// is read from the mock engine's actor, the main actor and the test
    /// target. It is a `let` holding parsed JSON that nothing mutates after the
    /// one-time initialisation Swift already serialises, so the unsafety is in
    /// the type system's vocabulary rather than in the program.
    nonisolated(unsafe) static let schemas: [String: Any] = {
        guard let data = CatalogSchemas.json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Generated content that does not parse is a broken build, not a
            // condition to degrade through: an empty table would validate
            // nothing and look green.
            assertionFailure("CatalogSchemas.json is not a JSON object - regenerate it")
            return [:]
        }
        return parsed
    }()

    /// Every schema violation in `params` for the command called `name`, in the
    /// engine's own wording. Empty means the engine would accept it.
    ///
    /// A command name the catalog does not define returns
    /// `["unknown command ..."]` rather than an empty list: an unknown name is
    /// exactly the typo this check is for, and answering "no violations" to a
    /// question about a command that does not exist is the wrong kind of quiet.
    static func violations(name: String, params: [String: AnyHashable]) -> [String] {
        guard let schema = schemas[name] else {
            return ["unknown command \(name)"]
        }
        return violations(against: schema, params: params)
    }

    /// The same check against a schema the CALLER supplies.
    ///
    /// This exists so a test can validate an envelope against
    /// `command-catalog.v2.json` read from disk, through THIS walk — the one
    /// the mock engine runs — rather than against a second validator written
    /// in the test. `catalog_descriptions.rs` shipped a coverage assertion
    /// that counted with its own copy of the traversal it was policing, and
    /// deleting the real walk's array descent left both green. One walk, two
    /// entry points, no copy.
    static func violations(against schema: Any, params: [String: AnyHashable]) -> [String] {
        var errors: [String] = []
        walk(schema, jsonValue(params), "", &errors)
        return errors
    }

    /// The engine's refusal message for these params, or nil if it would accept.
    ///
    /// Shaped like `CommandError::SchemaViolation`'s Display
    /// (`"<name>: <error>; <error>"`) so a mock refusal and a real refusal read
    /// the same in a log — a diagnostic that changes wording depending on which
    /// engine produced it is a diagnostic nobody can search for.
    static func refusal(name: String, params: [String: AnyHashable]) -> String? {
        let errors = violations(name: name, params: params)
        guard !errors.isEmpty else { return nil }
        return "\(name): \(errors.joined(separator: "; "))"
    }

    // MARK: The parameter census

    /// Every parameter NAME the catalog declares, anywhere in any command.
    ///
    /// Includes nested object properties and array-item properties, because
    /// that is where half of them live — `noteId` exists ONLY inside
    /// `note.add`'s `notes[]`, and a walk that stopped at the top level would
    /// report it as a parameter the catalog does not have.
    ///
    /// This is what lets `StudioEngineIDParam`'s classification of id-carrying
    /// params be checked against the contract instead of against somebody's
    /// memory. That list started as two names and was already missing four the
    /// day it was written.
    static func allParameterNames() -> Set<String> {
        var out: Set<String> = []
        for schema in schemas.values { collectNames(schema, into: &out) }
        return out
    }

    private static func collectNames(_ schema: Any, into out: inout Set<String>) {
        guard let object = schema as? [String: Any] else { return }
        if let properties = object["properties"] as? [String: Any] {
            for (name, sub) in properties {
                out.insert(name)
                collectNames(sub, into: &out)
            }
        }
        for key in ["items", "if", "then", "propertyNames", "additionalProperties"] {
            if let sub = object[key] { collectNames(sub, into: &out) }
        }
        if let options = object["oneOf"] as? [Any] {
            for option in options { collectNames(option, into: &out) }
        }
    }

    // MARK: Instance conversion
    //
    // `StudioEngineCommand.catalog` carries `[String: AnyHashable]`, which is
    // what the UI can build and hash. The FFI serialises it to JSON, so the
    // check has to run against the JSON shape rather than the Swift one.

    /// Convert an envelope's params to the JSON the engine would receive.
    private static func jsonValue(_ params: [String: AnyHashable]) -> Any {
        params.mapValues { unboxed($0.base) }
    }

    /// Strip `AnyHashable` boxes recursively, leaving the values a JSON
    /// validator can look at.
    ///
    /// Note what this deliberately does NOT do: test `value as? AnyHashable`.
    /// That cast succeeds for EVERY hashable value — a bare `String` casts to
    /// `AnyHashable`, whose `.base` is the same bare `String` — so unwrapping
    /// on it recurses forever. The first draft did exactly that and the whole
    /// test binary died with SIGBUS on a blown stack. Boxes are unwrapped where
    /// they are statically known to be boxes, at the two `AnyHashable`-typed
    /// containers, and nowhere else.
    ///
    /// `Bool` is tested FIRST and deliberately. `true as? Int` is nil in Swift,
    /// but an `AnyHashable`-boxed `Bool` bridges to `NSNumber`, and an
    /// `NSNumber` carrying a bool answers `intValue == 1` — so a bool checked
    /// after the numeric branch would validate as the integer 1, and a
    /// `"type": "boolean"` schema would silently accept a number. That is the
    /// same class of defect as the wrong parameter name: a check that runs and
    /// does not look.
    private static func unboxed(_ value: Any) -> Any {
        if value is Bool { return value }
        if let dict = value as? [String: AnyHashable] { return dict.mapValues { unboxed($0.base) } }
        if let dict = value as? [String: Any] { return dict.mapValues { unboxed($0) } }
        if let array = value as? [AnyHashable] { return array.map { unboxed($0.base) } }
        if let array = value as? [Any] { return array.map { unboxed($0) } }
        return value
    }

    // MARK: The subset validator (port of engine/timeline-core/src/schema.rs)

    /// Keywords this validator evaluates. Anything else in a schema is an
    /// error, not a shrug.
    private static let knownKeywords: Set<String> = [
        "type", "required", "properties", "additionalProperties", "enum",
        "const", "pattern", "minLength", "minimum", "maximum",
        "exclusiveMinimum", "minItems", "items", "minProperties", "if", "then",
        "default", "description", "oneOf", "uniqueItems", "maxItems",
        "propertyNames",
    ]

    private static func walk(_ schema: Any, _ instance: Any, _ path: String, _ errors: inout [String]) {
        if let allowed = schema as? Bool {
            if !allowed { errors.append("\(path): schema false permits nothing") }
            return
        }
        guard let object = schema as? [String: Any] else {
            errors.append("\(path): unsupported schema form")
            return
        }

        for key in object.keys where !knownKeywords.contains(key) {
            errors.append("\(path): schema keyword \"\(key)\" is outside the supported catalog subset")
            return
        }

        if let options = object["oneOf"] as? [Any] {
            let matches = options.filter { option in
                var scratch: [String] = []
                walk(option, instance, path, &scratch)
                return scratch.isEmpty
            }.count
            if matches != 1 {
                errors.append("\(path): oneOf requires exactly one matching schema, got \(matches)")
            }
            return
        }

        if let type = object["type"] {
            let ok: Bool
            if let single = type as? String {
                ok = matchesType(single, instance)
            } else if let list = type as? [Any] {
                ok = list.compactMap { $0 as? String }.contains { matchesType($0, instance) }
            } else {
                ok = false
            }
            if !ok {
                errors.append("\(path): expected type \(type), got \(typeName(instance))")
                return
            }
        }

        if let expected = object["const"], !jsonEqual(expected, instance) {
            errors.append("\(path): value must equal const \(expected)")
        }

        if let options = object["enum"] as? [Any], !options.contains(where: { jsonEqual($0, instance) }) {
            errors.append("\(path): value \(instance) not in enum")
        }

        if let string = instance as? String {
            if let min = object["minLength"] as? Int, string.count < min {
                errors.append("\(path): string shorter than minLength \(min)")
            }
            if let pattern = object["pattern"] as? String {
                if let regex = try? NSRegularExpression(pattern: pattern) {
                    let range = NSRange(string.startIndex..., in: string)
                    if regex.firstMatch(in: string, range: range) == nil {
                        errors.append("\(path): \"\(string)\" does not match pattern \"\(pattern)\"")
                    }
                } else {
                    errors.append("\(path): unsupported pattern \"\(pattern)\"")
                }
            }
        } else if !(instance is Bool), let number = numeric(instance) {
            if let minimum = object["minimum"].flatMap(numeric), number < minimum {
                errors.append("\(path): \(number) below minimum \(minimum)")
            }
            if let maximum = object["maximum"].flatMap(numeric), number > maximum {
                errors.append("\(path): \(number) above maximum \(maximum)")
            }
            if let exclusive = object["exclusiveMinimum"].flatMap(numeric), number <= exclusive {
                errors.append("\(path): \(number) not above exclusiveMinimum \(exclusive)")
            }
        } else if let items = instance as? [Any] {
            if let minItems = object["minItems"] as? Int, items.count < minItems {
                errors.append("\(path): fewer than minItems \(minItems)")
            }
            if let maxItems = object["maxItems"] as? Int, items.count > maxItems {
                errors.append("\(path): more than maxItems \(maxItems)")
            }
            if object["uniqueItems"] as? Bool == true, items.count > 1 {
                for i in 1..<items.count where items[..<i].contains(where: { jsonEqual($0, items[i]) }) {
                    errors.append("\(path)[\(i)]: duplicate, uniqueItems is true")
                }
            }
            if let itemSchema = object["items"] {
                for (i, item) in items.enumerated() {
                    walk(itemSchema, item, "\(path)[\(i)]", &errors)
                }
            }
        } else if let map = instance as? [String: Any] {
            if let names = object["propertyNames"] {
                for key in map.keys.sorted() {
                    walk(names, key, "\(path)/\(key) (propertyNames)", &errors)
                }
            }
            if let min = object["minProperties"] as? Int, map.count < min {
                errors.append("\(path): fewer than minProperties \(min)")
            }
            if let required = object["required"] as? [Any] {
                for name in required.compactMap({ $0 as? String }) where map[name] == nil {
                    errors.append("\(path): missing required property \"\(name)\"")
                }
            }
            let properties = object["properties"] as? [String: Any]
            if let properties {
                for (key, sub) in properties.sorted(by: { $0.key < $1.key }) {
                    if let value = map[key] {
                        walk(sub, value, "\(path)/\(key)", &errors)
                    }
                }
            }
            switch object["additionalProperties"] {
            case let allowed as Bool where allowed == false:
                for key in map.keys.sorted() where properties?[key] == nil {
                    errors.append("\(path): additional property \"\(key)\" not allowed")
                }
            case let sub as [String: Any]:
                for key in map.keys.sorted() where properties?[key] == nil {
                    walk(sub, map[key] as Any, "\(path)/\(key)", &errors)
                }
            default:
                break
            }
        }

        // if/then: the catalog uses it for conditional requireds (clip.warp.set
        // requires stretchRatio only when mode == "ratio").
        if let condition = object["if"] {
            var conditionErrors: [String] = []
            walk(condition, instance, path, &conditionErrors)
            if conditionErrors.isEmpty, let then = object["then"] {
                walk(then, instance, path, &errors)
            }
        }
    }

    private static func matchesType(_ want: String, _ instance: Any) -> Bool {
        switch want {
        case "object": return instance is [String: Any]
        case "array": return instance is [Any]
        case "string": return instance is String
        case "boolean": return instance is Bool
        case "null": return instance is NSNull
        case "number": return !(instance is Bool) && numeric(instance) != nil
        // JSON Schema: an integer is any number with a zero fractional part.
        case "integer":
            guard !(instance is Bool), let value = numeric(instance) else { return false }
            return value.truncatingRemainder(dividingBy: 1) == 0
        default: return false
        }
    }

    private static func typeName(_ instance: Any) -> String {
        if instance is NSNull { return "null" }
        if instance is Bool { return "boolean" }
        if instance is String { return "string" }
        if instance is [Any] { return "array" }
        if instance is [String: Any] { return "object" }
        if let value = numeric(instance) {
            return value.truncatingRemainder(dividingBy: 1) == 0 ? "integer" : "number"
        }
        return "unsupported"
    }

    /// The numeric value of a JSON number, or nil. `Bool` is excluded by every
    /// caller before this point (see `jsonValue`).
    private static func numeric(_ value: Any) -> Double? {
        switch value {
        case let v as Double: return v
        case let v as Int: return Double(v)
        case let v as Int64: return Double(v)
        case let v as UInt64: return Double(v)
        case let v as CGFloat: return Double(v)
        case let v as Float: return Double(v)
        case let v as NSNumber: return v.doubleValue
        default: return nil
        }
    }

    /// JSON equality where numbers compare by value, matching the engine's
    /// `json_eq` (so `enum: [4]` accepts the double 4.0).
    private static func jsonEqual(_ a: Any, _ b: Any) -> Bool {
        if let x = a as? Bool, let y = b as? Bool { return x == y }
        if !(a is Bool), !(b is Bool), let x = numeric(a), let y = numeric(b) { return x == y }
        if let x = a as? String, let y = b as? String { return x == y }
        if a is NSNull, b is NSNull { return true }
        if let x = a as? [Any], let y = b as? [Any] {
            return x.count == y.count && zip(x, y).allSatisfy { jsonEqual($0, $1) }
        }
        if let x = a as? [String: Any], let y = b as? [String: Any] {
            return x.count == y.count && x.allSatisfy { key, value in
                guard let other = y[key] else { return false }
                return jsonEqual(value, other)
            }
        }
        return false
    }
}
