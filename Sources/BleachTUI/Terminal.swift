import Darwin
import Foundation

/// Raw-mode terminal handling.
///
/// Hand-rolled rather than taken as a dependency: the surface needed here is
/// small, and the one thing that absolutely must be right — restoring the
/// terminal on every exit path, including signals — is easier to guarantee
/// when it's explicit.
public final class Terminal {
    private var original = termios()
    private var isRaw = false

    public struct Size: Sendable, Equatable {
        public var rows: Int
        public var cols: Int
    }

    public init() {}

    public var size: Size {
        var w = winsize()
        if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &w) == 0, w.ws_row > 0 {
            return Size(rows: Int(w.ws_row), cols: Int(w.ws_col))
        }
        return Size(rows: 24, cols: 80)
    }

    public func enterRawMode() {
        guard isatty(STDIN_FILENO) == 1, !isRaw else { return }
        tcgetattr(STDIN_FILENO, &original)
        var raw = original
        // Disable canonical mode and echo; keep ISIG so Ctrl-C still works as
        // an escape hatch if the render loop ever wedges.
        raw.c_lflag &= ~(UInt(ECHO) | UInt(ICANON))
        raw.c_iflag &= ~(UInt(IXON) | UInt(ICRNL))
        raw.c_cc.16 = 1   // VMIN
        raw.c_cc.17 = 0   // VTIME
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        isRaw = true
    }

    public func exitRawMode() {
        guard isRaw else { return }
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
        isRaw = false
    }

    public func enterFullScreen() {
        write(ANSI.enterAltScreen + ANSI.hideCursor + ANSI.clearScreen)
    }

    public func exitFullScreen() {
        write(ANSI.showCursor + ANSI.exitAltScreen)
    }

    public func write(_ s: String) {
        FileHandle.standardOutput.write(Data(s.utf8))
    }

    // MARK: - Input

    public enum Key: Equatable {
        case char(Character)
        case up, down, left, right
        case pageUp, pageDown, home, end
        case enter, escape, backspace, tab
        case ctrl(Character)
        case unknown
    }

    /// Blocking single-key read, decoding the CSI sequences we care about.
    public func readKey() -> Key {
        var byte: UInt8 = 0
        guard read(STDIN_FILENO, &byte, 1) == 1 else { return .unknown }

        switch byte {
        case 0x0A, 0x0D: return .enter
        case 0x09: return .tab
        case 0x7F, 0x08: return .backspace
        case 0x01...0x08, 0x0B, 0x0C, 0x0E...0x1A:
            return .ctrl(Character(UnicodeScalar(byte + 96)))
        case 0x1B:
            // Could be a bare Escape or the start of a CSI sequence. Peek
            // without blocking forever: if nothing follows, it was Escape.
            var next: UInt8 = 0
            var fds = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            guard poll(&fds, 1, 25) > 0, read(STDIN_FILENO, &next, 1) == 1 else {
                return .escape
            }
            guard next == 0x5B || next == 0x4F else { return .escape }
            var code: UInt8 = 0
            guard read(STDIN_FILENO, &code, 1) == 1 else { return .escape }
            switch code {
            case 0x41: return .up
            case 0x42: return .down
            case 0x43: return .right
            case 0x44: return .left
            case 0x48: return .home
            case 0x46: return .end
            case 0x35, 0x36:
                var tilde: UInt8 = 0
                _ = read(STDIN_FILENO, &tilde, 1)   // consume the trailing '~'
                return code == 0x35 ? .pageUp : .pageDown
            default: return .unknown
            }
        default:
            // Decode UTF-8 continuation bytes so non-ASCII input doesn't
            // desynchronise the stream.
            var bytes: [UInt8] = [byte]
            let expected = byte >= 0xF0 ? 3 : (byte >= 0xE0 ? 2 : (byte >= 0xC0 ? 1 : 0))
            for _ in 0..<expected {
                var cont: UInt8 = 0
                if read(STDIN_FILENO, &cont, 1) == 1 { bytes.append(cont) }
            }
            let s = String(decoding: bytes, as: UTF8.self)
            return s.first.map { Key.char($0) } ?? .unknown
        }
    }
}
