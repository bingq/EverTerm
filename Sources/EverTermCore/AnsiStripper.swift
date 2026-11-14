import Foundation

/// Streaming escape-code stripper: keeps printable text, newlines and tabs.
/// State carries across chunks, so a sequence split between two reads is handled.
public struct AnsiStripper: Sendable {
    private enum State { case ground, esc, csi, string, stringEsc }
    private var state: State = .ground

    public init() {}

    public mutating func strip(_ input: Data) -> Data {
        var out = Data()
        out.reserveCapacity(input.count)
        for b in input {
            switch state {
            case .ground:
                switch b {
                case 0x1B: state = .esc
                case 0x0A, 0x09: out.append(b)
                case 0x00...0x1F, 0x7F: break          // other controls (CR, BS, BEL...)
                default: out.append(b)                 // printable ASCII and UTF-8 bytes
                }
            case .esc:
                switch b {
                case UInt8(ascii: "["): state = .csi
                case UInt8(ascii: "]"), UInt8(ascii: "P"), UInt8(ascii: "X"),
                     UInt8(ascii: "^"), UInt8(ascii: "_"): state = .string   // OSC / DCS / SOS / PM / APC
                case 0x20...0x2F: break                // intermediate, wait for final byte
                default: state = .ground               // two-byte escape (ESC 7, ESC =, ...)
                }
            case .csi:
                if (0x40...0x7E).contains(b) { state = .ground }
            case .string:
                if b == 0x07 { state = .ground }        // BEL terminator
                else if b == 0x1B { state = .stringEsc }
            case .stringEsc:
                state = (b == UInt8(ascii: "\\")) ? .ground : .string
            }
        }
        return out
    }
}
