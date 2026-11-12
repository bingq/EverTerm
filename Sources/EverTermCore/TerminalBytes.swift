/// Byte-level filters applied to host output before it reaches the screen.
public enum TerminalBytes {
    /// ESC[3J, "erase scrollback".
    public static let eraseScrollback: [UInt8] = Array("\u{1b}[3J".utf8)

    /// #14: removes every ESC[3J; everything else passes through unchanged.
    /// ESC[2J (clear the visible screen) still works.
    public static func removingEraseScrollback(_ bytes: [UInt8]) -> [UInt8] {
        let seq = eraseScrollback
        guard bytes.count >= seq.count, bytes.contains(0x1B) else { return bytes }
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x1B, bytes.count - i >= seq.count, bytes[i ..< i + seq.count].elementsEqual(seq) {
                i += seq.count
                continue
            }
            out.append(bytes[i])
            i += 1
        }
        return out
    }
}
