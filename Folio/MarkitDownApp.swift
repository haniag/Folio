//
//  MarkitDownApp.swift
//  MarkitDown
//
//  Created by hani on 9/26/26.
//

import SwiftUI

@main
struct MarkitDownApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        Window("Folio", id: "main") {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    #if DEBUG
    /// Debug-only headless mode for testing:
    /// `MarkitDown.app/Contents/MacOS/MarkitDown --convert <file> --mode down|up`
    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        guard let fileIndex = arguments.firstIndex(of: "--convert"), fileIndex + 1 < arguments.count else { return }
        let input = URL(filePath: arguments[fileIndex + 1])
        var mode = ConversionMode.markDown
        if let modeIndex = arguments.firstIndex(of: "--mode"), modeIndex + 1 < arguments.count, arguments[modeIndex + 1] == "up" {
            mode = .markUp
        }
        Task {
            let engine = MarkItDownEngine()
            do {
                if mode == .markDown {
                    await engine.refresh()
                    if !engine.isReady { await engine.install() }
                }
                let output = try await AppModel.convert(input, mode: mode, engine: engine)
                print("OK \(output.path)")
                exit(0)
            } catch {
                print("ERROR \(error.localizedDescription)")
                exit(1)
            }
        }
    }
    #endif
}
