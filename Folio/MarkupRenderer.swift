//
//  MarkupRenderer.swift
//  MarkitDown
//
//  Renders Markdown to a paginated PDF using the rendering stack from
//  markdown-live-preview (https://github.com/tanabe/markdown-live-preview):
//  marked + DOMPurify + mermaid + github-markdown-css, in an offscreen WKWebView.
//

import AppKit
import WebKit

final class MarkupRenderer: NSObject, WKNavigationDelegate {
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var printContinuation: CheckedContinuation<Bool, Never>?

    func renderPDF(from markdownFile: URL, to output: URL) async throws {
        let markdown = try Self.readText(markdownFile)

        let printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo
        let margin: CGFloat = 72 // 1 inch
        printInfo.topMargin = margin
        printInfo.bottomMargin = margin
        printInfo.leftMargin = margin
        printInfo.rightMargin = margin
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.isHorizontallyCentered = false
        printInfo.isVerticallyCentered = false
        printInfo.jobDisposition = .save
        printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = output

        let contentWidth = printInfo.paperSize.width - margin * 2
        let frame = NSRect(x: 0, y: 0, width: contentWidth, height: printInfo.paperSize.height)
        let webView = WKWebView(frame: frame, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = self

        // WKWebView only prints reliably when it lives in a window; keep it offscreen.
        let window = NSWindow(
            contentRect: frame.offsetBy(dx: -20_000, dy: -20_000),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.orderBack(nil)
        defer { window.close() }

        // The base URL lets relative image paths in the Markdown resolve next to the source file.
        let html = try Self.makeHTML()
        try await withCheckedThrowingContinuation { continuation in
            loadContinuation = continuation
            webView.loadHTMLString(html, baseURL: markdownFile.deletingLastPathComponent())
        }

        _ = try await webView.callAsyncJavaScript(
            "return await window.renderMarkdown(markdown);",
            arguments: ["markdown": markdown],
            contentWorld: .page
        )

        let operation = webView.printOperation(with: printInfo)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.view?.frame = webView.bounds

        let success = await withCheckedContinuation { continuation in
            printContinuation = continuation
            operation.runModal(
                for: window,
                delegate: self,
                didRun: #selector(printOperationDidRun(_:success:contextInfo:)),
                contextInfo: nil
            )
        }
        guard success, FileManager.default.fileExists(atPath: output.path) else {
            throw ConversionError.failed("Could not write the PDF.")
        }
    }

    @objc private func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        printContinuation?.resume(returning: success)
        printContinuation = nil
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadContinuation?.resume()
        loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: error)
        loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: error)
        loadContinuation = nil
    }

    // MARK: - Helpers

    private static func makeHTML() throws -> String {
        func resource(_ name: String, _ ext: String) throws -> String {
            guard let url = Bundle.main.url(forResource: name, withExtension: ext) else {
                throw ConversionError.failed("Missing bundled resource \(name).\(ext)")
            }
            // Keep inlined scripts from closing the surrounding <script> tag early.
            return try String(contentsOf: url, encoding: .utf8)
                .replacingOccurrences(of: "</script", with: "<\\/script")
        }

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <style>\(try resource("github-markdown-light", "css"))</style>
        <style>\(try resource("print", "css"))</style>
        <style>\(aptosFontFaces())</style>
        <script>\(try resource("marked.umd", "js"))</script>
        <script>\(try resource("purify.min", "js"))</script>
        <script>\(try resource("mermaid.min", "js"))</script>
        <script>\(try resource("render", "js"))</script>
        </head>
        <body>
        <div id="output" class="markdown-body"></div>
        </body>
        </html>
        """
    }

    /// Aptos isn't a standard macOS font; Microsoft Office keeps its own copy inside each app bundle.
    /// When Aptos isn't installed system-wide, embed Office's copy so the PDF still uses it.
    /// Returns an empty string (falling back to the system font) if neither is available.
    private static func aptosFontFaces() -> String {
        if NSFontManager.shared.availableFontFamilies.contains("Aptos") { return "" }

        let officeApps = ["Microsoft Word", "Microsoft PowerPoint", "Microsoft Excel", "Microsoft Outlook"]
        let fontFolders = officeApps.map { URL(filePath: "/Applications/\($0).app/Contents/Resources/DFonts") }
        guard let folder = fontFolders.first(where: {
            FileManager.default.fileExists(atPath: $0.appending(path: "Aptos.ttf").path)
        }) else { return "" }

        let faces: [(file: String, weight: Int, style: String)] = [
            ("Aptos", 400, "normal"),
            ("Aptos-Italic", 400, "italic"),
            ("Aptos-SemiBold", 600, "normal"),
            ("Aptos-SemiBold-Italic", 600, "italic"),
            ("Aptos-Bold", 700, "normal"),
            ("Aptos-Bold-Italic", 700, "italic"),
        ]
        return faces.compactMap { face in
            guard let data = try? Data(contentsOf: folder.appending(path: "\(face.file).ttf")) else { return nil }
            return """
            @font-face { font-family: "Aptos"; font-weight: \(face.weight); font-style: \(face.style); \
            src: url(data:font/ttf;base64,\(data.base64EncodedString())) format("truetype"); }
            """
        }.joined(separator: "\n")
    }

    private static func readText(_ url: URL) throws -> String {
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        var encoding = String.Encoding.utf8
        return try String(contentsOf: url, usedEncoding: &encoding)
    }
}
