//
//  ContentView.swift
//  MarkitDown
//
//  Created by hani on 9/26/26.
//

import AppKit
import SwiftUI

struct ContentView: View {
    @State private var model = AppModel()
    @State private var isImporting = false
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 18) {
            dropZone

            Picker("Direction", selection: $model.mode) {
                ForEach(ConversionMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(model.mode.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if model.inputURL != nil, !model.inputIsSupported {
                Label("\(model.mode.title) accepts \(model.mode.inputExtensions.sorted().map { ".\($0)" }.joined(separator: ", ")) files.", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                statusView
                Spacer()
                Button {
                    Task { await model.convert() }
                } label: {
                    Text("Convert to .\(model.mode.outputExtension)")
                        .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canConvert)
            }

            Divider()

            EngineStatusView(engine: model.engine, isRelevant: model.mode == .markDown)
        }
        .padding(24)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .fileImporter(isPresented: $isImporting, allowedContentTypes: ConversionMode.allInputTypes) { result in
            if case .success(let url) = result { model.select(url) }
        }
        .task { await model.engine.refresh() }
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: model.inputURL == nil ? "doc.badge.plus" : "doc.text")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tint)

            if let url = model.inputURL {
                Text(url.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(url.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            } else {
                Text("Drop a file here")
                    .font(.headline)
                Text(".docx, .pdf, .txt, or .md")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button(model.inputURL == nil ? "Choose File…" : "Choose Another File…") {
                isImporting = true
            }
        }
        .frame(maxWidth: .infinity, minHeight: 170)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.05))
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: \.isFileURL) else { return false }
            model.select(url)
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    @ViewBuilder
    private var statusView: some View {
        switch model.status {
        case .idle:
            EmptyView()
        case .working:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Converting…").foregroundStyle(.secondary)
            }
        case .succeeded(let output):
            HStack(spacing: 8) {
                Label(output.lastPathComponent, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([output])
                }
                .buttonStyle(.link)
            }
        case .failed(let message):
            Label {
                Text(message)
                    .lineLimit(4)
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: "xmark.octagon.fill")
            }
            .font(.callout)
            .foregroundStyle(.red)
        }
    }
}

/// Shows whether markitdown is installed and offers a one-click install.
private struct EngineStatusView: View {
    let engine: MarkItDownEngine
    let isRelevant: Bool
    @State private var showLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon.name)
                    .foregroundStyle(icon.color)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(isRelevant ? .primary : .secondary)
                    .textSelection(.enabled)
                Spacer()
                actionButton
            }

            if engine.state == .installing || !engine.installLog.isEmpty {
                DisclosureGroup("Install log", isExpanded: $showLog) {
                    ScrollView {
                        Text(engine.installLog)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .defaultScrollAnchor(.bottom)
                    .frame(height: 140)
                }
                .font(.caption)
            }
        }
    }

    private var message: String {
        switch engine.state {
        case .checking: "Checking for Folio…"
        case .notInstalled: "Mark Down needs a one-time download of Python and markitdown (about 300 MB on disk)."
        case .installing: "Installing Folio with \(MarkItDownEngine.extras.joined(separator: ", ")) support…"
        case .ready(let version): "Folio ready (\(version))"
        case .failed(let error): error
        }
    }

    private var icon: (name: String, color: Color) {
        switch engine.state {
        case .ready: ("checkmark.seal.fill", .green)
        case .checking, .installing: ("hourglass", .secondary)
        case .notInstalled: ("arrow.down.circle", .orange)
        case .failed: ("exclamationmark.triangle.fill", .orange)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch engine.state {
        case .notInstalled:
            Button("Install") { Task { await engine.install() } }
        case .failed:
            Button("Retry") { Task { await engine.install() } }
        case .installing, .checking:
            ProgressView().controlSize(.small)
        case .ready:
            EmptyView()
        }
    }
}

#Preview {
    ContentView()
}
