import Foundation

public enum Shell {
    public struct Result: Sendable {
        public var stdout: String
        public var stderr: String
        public var exitCode: Int32
        public var timedOut: Bool
        public var ok: Bool { exitCode == 0 && !timedOut }

        public init(stdout: String, stderr: String, exitCode: Int32, timedOut: Bool) {
            self.stdout = stdout
            self.stderr = stderr
            self.exitCode = exitCode
            self.timedOut = timedOut
        }
    }

    /// Run an executable and capture output. Never throws on a non-zero exit —
    /// inventory sources are best-effort and a missing tool must degrade
    /// gracefully rather than abort the scan.
    @discardableResult
    public static func run(
        _ launchPath: String,
        _ args: [String],
        timeout: TimeInterval = 60
    ) -> Result {
        guard FileManager.default.isExecutableFile(atPath: launchPath) else {
            return Result(stdout: "", stderr: "not executable: \(launchPath)", exitCode: 127, timedOut: false)
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        proc.standardInput = FileHandle.nullDevice

        do { try proc.run() } catch {
            return Result(stdout: "", stderr: "\(error)", exitCode: 126, timedOut: false)
        }

        // Drain concurrently: lsregister -dump emits megabytes and will
        // deadlock against a full pipe buffer if we wait() first.
        let lock = NSLock()
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        for (pipe, isOut) in [(out, true), (err, false)] {
            group.enter()
            DispatchQueue.global().async {
                let d = pipe.fileHandleForReading.readDataToEndOfFile()
                lock.lock()
                if isOut { outData = d } else { errData = d }
                lock.unlock()
                group.leave()
            }
        }

        var timedOut = false
        let deadline = DispatchWorkItem {
            if proc.isRunning { timedOut = true; proc.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        proc.waitUntilExit()
        deadline.cancel()
        group.wait()

        return Result(
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self),
            exitCode: proc.terminationStatus,
            timedOut: timedOut
        )
    }
}

/// Variant of `Shell` that writes a payload to the child's stdin. Split out
/// because feeding stdin needs its own drain thread to avoid deadlocking
/// against a child that writes a large response before reading its input.
public enum ShellIO {
    public static func run(
        _ launchPath: String,
        _ args: [String],
        stdin payload: Data,
        timeout: TimeInterval = 30
    ) -> Shell.Result {
        guard FileManager.default.isExecutableFile(atPath: launchPath) else {
            return Shell.Result(stdout: "", stderr: "not executable: \(launchPath)",
                                exitCode: 127, timedOut: false)
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do { try proc.run() } catch {
            return Shell.Result(stdout: "", stderr: "\(error)", exitCode: 126, timedOut: false)
        }

        let lock = NSLock()
        var outData = Data(), errData = Data()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global().async {
            // Ignore write failures: a plugin is allowed to exit without
            // reading its input, which surfaces as EPIPE.
            try? inPipe.fileHandleForWriting.write(contentsOf: payload)
            try? inPipe.fileHandleForWriting.close()
            group.leave()
        }
        for (pipe, isOut) in [(outPipe, true), (errPipe, false)] {
            group.enter()
            DispatchQueue.global().async {
                let d = pipe.fileHandleForReading.readDataToEndOfFile()
                lock.lock()
                if isOut { outData = d } else { errData = d }
                lock.unlock()
                group.leave()
            }
        }

        var timedOut = false
        let deadline = DispatchWorkItem {
            if proc.isRunning { timedOut = true; proc.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        proc.waitUntilExit()
        deadline.cancel()
        group.wait()

        return Shell.Result(
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self),
            exitCode: proc.terminationStatus,
            timedOut: timedOut
        )
    }
}
