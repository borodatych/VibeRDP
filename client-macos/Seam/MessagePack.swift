import Foundation

/// A value of the MessagePack subset the Seam protocol uses: protocol/seam-protocol.md, section 3
/// The helper writes the same subset, helper-win/src/protocol.rs
enum MessagePackValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case float(Double)
    case string(String)
    case binary(Data)
    case array([MessagePackValue])
    /// Keys in their order: the protocol writes string keys only
    case map([(String, MessagePackValue)])

    static func == (lhs: MessagePackValue, rhs: MessagePackValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): true
        case (.bool(let a), .bool(let b)): a == b
        case (.float(let a), .float(let b)): a == b
        case (.string(let a), .string(let b)): a == b
        case (.binary(let a), .binary(let b)): a == b
        case (.array(let a), .array(let b)): a == b
        case (.map(let a), .map(let b)): a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        // MessagePack does not tell a non-negative signed integer from an unsigned one
        case (.int, _), (.uint, _): lhs.int64 == rhs.int64 && lhs.uint64 == rhs.uint64
        default: false
        }
    }

    /// The value under a key of a map; nil for another value or a missing key
    subscript(key: String) -> MessagePackValue? {
        guard case .map(let entries) = self else { return nil }
        return entries.first { $0.0 == key }?.1
    }

    var string: String? {
        if case .string(let value) = self { value } else { nil }
    }

    /// An integer that fits in UInt64, whichever way MessagePack wrote it
    var uint64: UInt64? {
        switch self {
        case .uint(let value): value
        case .int(let value): UInt64(exactly: value)
        default: nil
        }
    }

    /// An integer that fits in Int64, whichever way MessagePack wrote it
    var int64: Int64? {
        switch self {
        case .int(let value): value
        case .uint(let value): Int64(exactly: value)
        default: nil
        }
    }

    var array: [MessagePackValue]? {
        if case .array(let value) = self { value } else { nil }
    }

    var binary: Data? {
        if case .binary(let value) = self { value } else { nil }
    }
}

/// What is wrong with bytes that should hold one value
enum MessagePackError: Error, Equatable {
    /// The bytes end before the value does
    case truncated
    /// A type outside the subset, or a map key that is not a string
    case unsupported(UInt8)
    /// A string that is not UTF-8
    case badString
    /// Bytes left after the value
    case trailingBytes
}

enum MessagePack {
    /// The shortest MessagePack form of the value
    static func encode(_ value: MessagePackValue) -> Data {
        var out = Data()
        encode(value, into: &out)
        return out
    }

    /// The one value the bytes hold, all of them
    static func decode(_ bytes: Data) throws -> MessagePackValue {
        var reader = Reader(bytes: [UInt8](bytes))
        let value = try reader.value()
        guard reader.at == reader.bytes.count else { throw MessagePackError.trailingBytes }
        return value
    }

    private static func encode(_ value: MessagePackValue, into out: inout Data) {
        switch value {
        case .null:
            out.append(0xc0)
        case .bool(let flag):
            out.append(flag ? 0xc3 : 0xc2)
        case .uint(let number):
            encodeUnsigned(number, into: &out)
        case .int(let number) where number >= 0:
            encodeUnsigned(UInt64(number), into: &out)
        case .int(let number):
            encodeNegative(number, into: &out)
        case .float(let number):
            out.append(0xcb)
            append(number.bitPattern, into: &out)
        case .string(let text):
            let bytes = Data(text.utf8)
            if bytes.count < 32 {
                out.append(0xa0 | UInt8(bytes.count))
            } else {
                encodeLength(bytes.count, markers: (0xd9, 0xda, 0xdb), into: &out)
            }
            out.append(bytes)
        case .binary(let bytes):
            encodeLength(bytes.count, markers: (0xc4, 0xc5, 0xc6), into: &out)
            out.append(bytes)
        case .array(let items):
            encodeCount(items.count, fix: 0x90, wide: 0xdc, into: &out)
            items.forEach { encode($0, into: &out) }
        case .map(let entries):
            encodeCount(entries.count, fix: 0x80, wide: 0xde, into: &out)
            for (key, item) in entries {
                encode(.string(key), into: &out)
                encode(item, into: &out)
            }
        }
    }

    private static func encodeUnsigned(_ number: UInt64, into out: inout Data) {
        switch number {
        case 0..<128: out.append(UInt8(number))
        case ...UInt64(UInt8.max): out.append(contentsOf: [0xcc, UInt8(number)])
        case ...UInt64(UInt16.max): out.append(0xcd); append(UInt16(number), into: &out)
        case ...UInt64(UInt32.max): out.append(0xce); append(UInt32(number), into: &out)
        default: out.append(0xcf); append(number, into: &out)
        }
    }

    private static func encodeNegative(_ number: Int64, into out: inout Data) {
        switch number {
        case -32 ..< 0: out.append(UInt8(bitPattern: Int8(number)))
        case Int64(Int8.min)...: out.append(contentsOf: [0xd0, UInt8(bitPattern: Int8(number))])
        case Int64(Int16.min)...: out.append(0xd1); append(UInt16(bitPattern: Int16(number)), into: &out)
        case Int64(Int32.min)...: out.append(0xd2); append(UInt32(bitPattern: Int32(number)), into: &out)
        default: out.append(0xd3); append(UInt64(bitPattern: number), into: &out)
        }
    }

    /// Strings and binaries: 8, 16 and 32 bits of length
    private static func encodeLength(_ length: Int, markers: (UInt8, UInt8, UInt8), into out: inout Data) {
        if length <= Int(UInt8.max) {
            out.append(contentsOf: [markers.0, UInt8(length)])
        } else if length <= Int(UInt16.max) {
            out.append(markers.1)
            append(UInt16(length), into: &out)
        } else {
            out.append(markers.2)
            append(UInt32(length), into: &out)
        }
    }

    /// Arrays and maps: up to 15 entries in the first byte, then 16 and 32 bits of count
    private static func encodeCount(_ count: Int, fix: UInt8, wide: UInt8, into out: inout Data) {
        if count < 16 {
            out.append(fix | UInt8(count))
        } else if count <= Int(UInt16.max) {
            out.append(wide)
            append(UInt16(count), into: &out)
        } else {
            out.append(wide + 1)
            append(UInt32(count), into: &out)
        }
    }

    private static func append<T: FixedWidthInteger>(_ number: T, into out: inout Data) {
        withUnsafeBytes(of: number.bigEndian) { out.append(contentsOf: $0) }
    }

    private struct Reader {
        let bytes: [UInt8]
        var at = 0

        mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
            guard count <= bytes.count - at else { throw MessagePackError.truncated }
            defer { at += count }
            return bytes[at ..< at + count]
        }

        mutating func byte() throws -> UInt8 {
            try take(1).first!
        }

        mutating func integer<T: FixedWidthInteger>(_: T.Type) throws -> T {
            try take(MemoryLayout<T>.size).reduce(T.zero) { $0 << 8 | T(truncatingIfNeeded: $1) }
        }

        mutating func length(_ width: Int) throws -> Int {
            switch width {
            case 1: Int(try byte())
            case 2: Int(try integer(UInt16.self))
            default: Int(try integer(UInt32.self))
            }
        }

        mutating func string(_ length: Int) throws -> MessagePackValue {
            guard let text = String(data: Data(try take(length)), encoding: .utf8) else { throw MessagePackError.badString }
            return .string(text)
        }

        mutating func array(_ count: Int) throws -> MessagePackValue {
            // Each entry takes a byte at least: a count beyond the bytes left is a lie, not an allocation
            guard count <= bytes.count - at else { throw MessagePackError.truncated }
            var items: [MessagePackValue] = []
            items.reserveCapacity(count)
            for _ in 0 ..< count {
                items.append(try value())
            }
            return .array(items)
        }

        mutating func map(_ count: Int) throws -> MessagePackValue {
            guard count <= bytes.count - at else { throw MessagePackError.truncated }
            var entries: [(String, MessagePackValue)] = []
            entries.reserveCapacity(count)
            for _ in 0 ..< count {
                guard at < bytes.count else { throw MessagePackError.truncated }
                let marker = bytes[at]
                guard case .string(let key) = try value() else { throw MessagePackError.unsupported(marker) }
                entries.append((key, try value()))
            }
            return .map(entries)
        }

        mutating func value() throws -> MessagePackValue {
            let marker = try byte()
            switch marker {
            case 0x00 ... 0x7f: return .uint(UInt64(marker))
            case 0x80 ... 0x8f: return try map(Int(marker & 0x0f))
            case 0x90 ... 0x9f: return try array(Int(marker & 0x0f))
            case 0xa0 ... 0xbf: return try string(Int(marker & 0x1f))
            case 0xc0: return .null
            case 0xc2: return .bool(false)
            case 0xc3: return .bool(true)
            case 0xc4 ... 0xc6: return .binary(Data(try take(try length(1 << Int(marker - 0xc4)))))
            case 0xcb: return .float(Double(bitPattern: try integer(UInt64.self)))
            case 0xcc: return .uint(UInt64(try byte()))
            case 0xcd: return .uint(UInt64(try integer(UInt16.self)))
            case 0xce: return .uint(UInt64(try integer(UInt32.self)))
            case 0xcf: return .uint(try integer(UInt64.self))
            case 0xd0: return .int(Int64(Int8(bitPattern: try byte())))
            case 0xd1: return .int(Int64(try integer(Int16.self)))
            case 0xd2: return .int(Int64(try integer(Int32.self)))
            case 0xd3: return .int(try integer(Int64.self))
            case 0xd9 ... 0xdb: return try string(try length(1 << Int(marker - 0xd9)))
            case 0xdc, 0xdd: return try array(try length(2 << Int(marker - 0xdc)))
            case 0xde, 0xdf: return try map(try length(2 << Int(marker - 0xde)))
            case 0xe0 ... 0xff: return .int(Int64(Int8(bitPattern: marker)))
            default: throw MessagePackError.unsupported(marker)
            }
        }
    }
}
