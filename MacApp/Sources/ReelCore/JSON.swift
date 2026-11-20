// A plain JSON value, for the MCP messages, the tool schemas and tool results.
import Foundation

public enum JSON: Codable, Equatable, Sendable {
  case null, bool(Bool), number(Double), string(String), array([JSON]), object([String: JSON])

  public init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() { self = .null }
    else if let b = try? c.decode(Bool.self) { self = .bool(b) }
    else if let n = try? c.decode(Double.self) { self = .number(n) }
    else if let s = try? c.decode(String.self) { self = .string(s) }
    else if let a = try? c.decode([JSON].self) { self = .array(a) }
    else { self = .object(try c.decode([String: JSON].self)) }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .null: try c.encodeNil()
    case .bool(let b): try c.encode(b)
    case .number(let n): if n.rounded() == n && abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
    case .string(let s): try c.encode(s)
    case .array(let a): try c.encode(a)
    case .object(let o): try c.encode(o)
    }
  }

  public subscript(key: String) -> JSON? { if case .object(let o) = self { return o[key] }; return nil }
  public var string: String? { if case .string(let s) = self { return s }; return nil }
  public var double: Double? { if case .number(let n) = self { return n }; return nil }
  public var int: Int? { if case .number(let n) = self, n.rounded() == n { return Int(n) }; return nil }
  public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
  public var array: [JSON]? { if case .array(let a) = self { return a }; return nil }
  public var object: [String: JSON]? { if case .object(let o) = self { return o }; return nil }
  public var isNull: Bool { if case .null = self { return true }; return false }

  // Any Codable value as JSON.
  public static func from<T: Encodable>(_ value: T) -> JSON {
    let data = (try? JSONEncoder().encode(value)) ?? Data("null".utf8)
    return (try? JSONDecoder().decode(JSON.self, from: data)) ?? .null
  }
  public func decode<T: Decodable>(_ type: T.Type) throws -> T { try JSONDecoder().decode(type, from: JSONEncoder().encode(self)) }

  public func text(pretty: Bool = false) -> String {
    let enc = JSONEncoder()
    enc.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
    return String(data: (try? enc.encode(self)) ?? Data(), encoding: .utf8) ?? "null"
  }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
  public init(stringLiteral v: String) { self = .string(v) }
  public init(booleanLiteral v: Bool) { self = .bool(v) }
  public init(floatLiteral v: Double) { self = .number(v) }
  public init(integerLiteral v: Int) { self = .number(Double(v)) }
  public init(arrayLiteral elements: JSON...) { self = .array(elements) }
  public init(dictionaryLiteral elements: (String, JSON)...) { self = .object(Dictionary(elements, uniquingKeysWith: { $1 })) }
}
