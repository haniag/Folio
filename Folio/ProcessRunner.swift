//
//  ProcessRunner.swift
//  MarkitDown
//

import Foundation

nonisolated struct ProcessResult: Sendable {
    let status: Int32
    let output: String

    var succeeded: Bool { status == 0 }

    /// The last few lines of output, handy for error messages.
    var tail: String {
        output.split(separator: "\n").suffix(8).joined(separator: "\n")
    }
}

nonisolated enum ProcessRunner {
    /// Runs an executable, streaming combined stdout/stderr to `onOutput` as it arrives.
    static func run(
        _ executable: URL,
        _ arguments: [String],
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONIOENCODING"] = "utf-8"
        environment["PIP_DISABLE_PIP_VERSION_CHECK"] = "1"
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let buffer = OutputBuffer()
        let reader = pipe.fileHandleForReading

        reader.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            buffer.append(text)
            onOutput?(text)
        }

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                reader.readabilityHandler = nil
                let remaining = reader.readDataToEndOfFile()
                if !remaining.isEmpty {
                    let text = String(decoding: remaining, as: UTF8.self)
                    buffer.append(text)
                    onOutput?(text)
                }
                continuation.resume(returning: ProcessResult(status: process.terminationStatus, output: buffer.value))
            }
            do {
                try process.run()
            } catch {
                reader.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
}

private nonisolated final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""

    func append(_ text: String) {
        lock.withLock { storage += text }
    }

    var value: String {
        lock.withLock { storage }
    }
}
