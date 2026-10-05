//
//  MarkItDownEngine.swift
//  MarkitDown
//
//  Manages a private Python virtual environment with Microsoft's markitdown
//  (https://github.com/microsoft/markitdown) and runs it to convert files.
//  The Python interpreter itself is a standalone build downloaded on first
//  install, so users never need Homebrew or Terminal.
//

import CryptoKit
import Foundation
import Observation

@Observable
final class MarkItDownEngine {
    enum State: Equatable {
        case checking
        /// markitdown (and its private Python) has not been installed yet.
        case notInstalled
        case installing
        case ready(version: String)
        case failed(String)
    }

    /// markitdown's optional dependency groups needed for the formats this app accepts.
    /// Plain text needs no extras. Add e.g. "pptx" or "xlsx" here to support more formats.
    static let extras = ["docx", "pdf"]

    private(set) var state: State = .checking
    private(set) var installLog = ""

    /// A pinned python-build-standalone release (https://github.com/astral-sh/python-build-standalone).
    /// markitdown requires Python >=3.10,<3.15. To update, change the version/tag and both checksums
    /// (from the release's SHA256SUMS file).
    private enum Runtime {
        static let version = "3.13.16"
        static let tag = "20261003"
        #if arch(arm64)
        static let triple = "aarch64-apple-darwin"
        static let sha256 = "9e01f63bbb08576cd9c8bc2d0564d098cb30c8453a0cd4bcf6aef458f6d2a147"
        #else
        static let triple = "x86_64-apple-darwin"
        static let sha256 = "b4dad38ba6a344555ccb71a1b08caad0a6c0dda88c5803658bc95bd7f04e9f5c"
        #endif
        static var downloadURL: URL {
            URL(string: "https://github.com/astral-sh/python-build-standalone/releases/download/\(tag)/cpython-\(version)%2B\(tag)-\(triple)-install_only_stripped.tar.gz")!
        }
    }

    private let supportURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appending(path: "Folio", directoryHint: .isDirectory)
    }()

    /// The archive extracts to a top-level `python/` directory.
    private var runtimeURL: URL { supportURL.appending(path: "python", directoryHint: .isDirectory) }
    private var runtimePython: URL { runtimeURL.appending(path: "bin/python3") }
    private var venvURL: URL { supportURL.appending(path: "venv", directoryHint: .isDirectory) }
    private var venvPython: URL { venvURL.appending(path: "bin/python") }
    private var markitdownExecutable: URL { venvURL.appending(path: "bin/markitdown") }

    var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    func refresh() async {
        state = .checking
        if FileManager.default.isExecutableFile(atPath: markitdownExecutable.path),
           let result = try? await ProcessRunner.run(markitdownExecutable, ["--version"]),
           result.succeeded {
            state = .ready(version: result.output.trimmingCharacters(in: .whitespacesAndNewlines))
            return
        }
        state = .notInstalled
    }

    func install() async {
        state = .installing
        installLog = ""
        let log: @Sendable (String) -> Void = { text in
            Task { @MainActor in self.installLog += text }
        }

        do {
            try FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
            if !(await isRuntimeUsable()) {
                try await installRuntime(log: log)
            }
            let package = "markitdown[\(Self.extras.joined(separator: ","))]"
            let steps: [(URL, [String])] = [
                (runtimePython, ["-m", "venv", "--clear", venvURL.path]),
                (venvPython, ["-m", "pip", "install", "--upgrade", "pip"]),
                (venvPython, ["-m", "pip", "install", "--upgrade", package]),
            ]
            for (executable, arguments) in steps {
                log("$ \(executable.lastPathComponent) \(arguments.joined(separator: " "))\n")
                let result = try await ProcessRunner.run(executable, arguments, onOutput: log)
                guard result.succeeded else {
                    state = .failed("Installation failed:\n\(result.tail)")
                    return
                }
            }
            await refresh()
        } catch {
            state = .failed("Installation failed: \(error.localizedDescription)")
        }
    }

    /// Converts `input` to Markdown, writing the result to `output`.
    func convert(_ input: URL, to output: URL) async throws {
        let result = try await ProcessRunner.run(markitdownExecutable, [input.path, "-o", output.path])
        guard result.succeeded else {
            throw ConversionError.failed(result.tail.isEmpty ? "markitdown exited with status \(result.status)" : result.tail)
        }
    }

    private func isRuntimeUsable() async -> Bool {
        guard FileManager.default.isExecutableFile(atPath: runtimePython.path),
              let result = try? await ProcessRunner.run(runtimePython, ["--version"]) else { return false }
        return result.succeeded
    }

    /// Downloads the standalone Python build, verifies its checksum and extracts it into Application Support.
    private func installRuntime(log: @escaping @Sendable (String) -> Void) async throws {
        log("Downloading Python \(Runtime.version)…\n")
        let (downloaded, response) = try await URLSession.shared.download(from: Runtime.downloadURL)
        let archive = supportURL.appending(path: "python.tar.gz")
        try? FileManager.default.removeItem(at: archive)
        try FileManager.default.moveItem(at: downloaded, to: archive)
        defer { try? FileManager.default.removeItem(at: archive) }

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw InstallError.download("server returned HTTP \(http.statusCode)")
        }
        guard try await Self.sha256(of: archive) == Runtime.sha256 else {
            throw InstallError.download("the downloaded file failed its integrity check")
        }

        log("Extracting Python…\n")
        try? FileManager.default.removeItem(at: runtimeURL)
        let result = try await ProcessRunner.run(URL(filePath: "/usr/bin/tar"), ["-xzf", archive.path, "-C", supportURL.path])
        guard result.succeeded, await isRuntimeUsable() else {
            throw InstallError.extract(result.tail)
        }
    }

    nonisolated private static func sha256(of file: URL) async throws -> String {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private enum InstallError: LocalizedError {
        case download(String)
        case extract(String)

        var errorDescription: String? {
            switch self {
            case .download(let reason): "Couldn't download Python: \(reason)."
            case .extract(let output): "Couldn't extract Python.\n\(output)"
            }
        }
    }
}

enum ConversionError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): message
        }
    }
}
