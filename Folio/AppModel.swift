//
//  AppModel.swift
//  MarkitDown
//

import Foundation
import Observation
import UniformTypeIdentifiers

enum ConversionMode: String, CaseIterable, Identifiable {
    case markDown
    case markUp

    var id: Self { self }

    var title: String {
        switch self {
        case .markDown: "Mark Down"
        case .markUp: "Mark Up"
        }
    }

    var summary: String {
        switch self {
        case .markDown: "Convert a Word, PDF, or text file to Markdown (.md) with Folio."
        case .markUp: "Render a Markdown or text file into a readable PDF."
        }
    }

    var inputExtensions: Set<String> {
        switch self {
        case .markDown: ["docx", "pdf", "txt"]
        case .markUp: ["md", "markdown", "txt"]
        }
    }

    var outputExtension: String {
        switch self {
        case .markDown: "md"
        case .markUp: "pdf"
        }
    }

    static var allInputTypes: [UTType] {
        let extensions = Set(allCases.flatMap(\.inputExtensions))
        return extensions.sorted().compactMap { UTType(filenameExtension: $0) }
    }
}

@Observable
final class AppModel {
    enum Status: Equatable {
        case idle
        case working
        case succeeded(URL)
        case failed(String)
    }

    var inputURL: URL?
    var mode: ConversionMode = .markDown
    private(set) var status: Status = .idle

    let engine = MarkItDownEngine()

    var inputIsSupported: Bool {
        guard let inputURL else { return false }
        return mode.inputExtensions.contains(inputURL.pathExtension.lowercased())
    }

    var canConvert: Bool {
        guard inputIsSupported, status != .working else { return false }
        return mode == .markUp || engine.isReady
    }

    func select(_ url: URL) {
        inputURL = url
        status = .idle
        // Pick the natural direction for the file; .txt works either way, so keep the current choice.
        let ext = url.pathExtension.lowercased()
        if !mode.inputExtensions.contains(ext),
           let match = ConversionMode.allCases.first(where: { $0.inputExtensions.contains(ext) }) {
            mode = match
        }
    }

    func convert() async {
        guard let inputURL, canConvert else { return }
        status = .working
        do {
            let output = try await Self.convert(inputURL, mode: mode, engine: engine)
            status = .succeeded(output)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Converts `input` and returns the URL of the file written next to it.
    static func convert(_ input: URL, mode: ConversionMode, engine: MarkItDownEngine) async throws -> URL {
        let accessing = input.startAccessingSecurityScopedResource()
        defer { if accessing { input.stopAccessingSecurityScopedResource() } }

        let output = uniqueOutputURL(for: input, extension: mode.outputExtension)
        switch mode {
        case .markDown:
            try await engine.convert(input, to: output)
        case .markUp:
            try await MarkupRenderer().renderPDF(from: input, to: output)
        }
        return output
    }

    /// `report.docx` -> `report.md`, or `report 2.md` if that already exists. Never overwrites.
    static func uniqueOutputURL(for input: URL, extension ext: String) -> URL {
        let folder = input.deletingLastPathComponent()
        let base = input.deletingPathExtension().lastPathComponent
        var candidate = folder.appending(path: "\(base).\(ext)")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appending(path: "\(base) \(counter).\(ext)")
            counter += 1
        }
        return candidate
    }
}
