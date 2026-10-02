import AppKit
import UniformTypeIdentifiers

/// Finder / Safari share extension. It hands the shared items to the main app, which shows the
/// device picker: files are opened with the app (this also grants the sandboxed app access to them),
/// links and text travel in a squickshare:// URL.
final class ShareViewController: NSViewController {
    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        let label = NSTextField(labelWithString: "Opening squick-share…")
        label.alignment = .center
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 60))
        label.frame = view.bounds.insetBy(dx: 10, dy: 18)
        label.autoresizingMask = [.width, .height]
        view.addSubview(label)
        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        Task { await forward() }
    }

    private var appURL: URL {
        // .../squick-share.app/Contents/PlugIns/ShareExtension.appex
        Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func forward() async {
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        var files: [URL] = []
        var texts: [String] = []
        for provider in items.flatMap({ $0.attachments ?? [] }) {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
               let url = await loadURL(provider, UTType.fileURL) {
                files.append(url)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                      let url = await loadURL(provider, UTType.url) {
                if url.isFileURL { files.append(url) } else { texts.append(url.absoluteString) }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
                      let url = await saveImage(provider) {
                files.append(url)
            } else if provider.canLoadObject(ofClass: NSString.self), let text = await loadText(provider) {
                texts.append(text)
            }
        }

        if !files.isEmpty {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try? await NSWorkspace.shared.open(files, withApplicationAt: appURL, configuration: configuration)
        }
        for text in texts {
            var components = URLComponents()
            components.scheme = "squickshare"
            components.host = "send"
            components.queryItems = [URLQueryItem(name: "text", value: text)]
            if let url = components.url {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                _ = try? await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration)
            }
        }
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func loadURL(_ provider: NSItemProvider, _ type: UTType) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type.identifier) { item, _ in
                if let url = item as? URL { continuation.resume(returning: url) }
                else if let data = item as? Data { continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil)) }
                else { continuation.resume(returning: nil) }
            }
        }
    }

    private func loadText(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSString.self) { item, _ in
                continuation.resume(returning: item as? String)
            }
        }
    }

    /// Images shared as data (not files) are written to a temporary file first.
    private func saveImage(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
                guard let url else { return continuation.resume(returning: nil) }
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: copy)
                let saved = (try? FileManager.default.copyItem(at: url, to: copy)) != nil
                continuation.resume(returning: saved ? copy : nil)
            }
        }
    }
}
