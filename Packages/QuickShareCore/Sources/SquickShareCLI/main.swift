import CoreImage
import CryptoKit
import Foundation
import QuickShareCore

// squick-share-cli: a command-line harness for QuickShareCore.
//
//   squick-share-cli receive [--name NAME] [--dir DIR] [--auto-accept] [--verbose] [--info-version 0|1]
//   squick-share-cli send [--to NAME] [--qr] [--verbose] [--text TEXT] [FILE...]
//   squick-share-cli browse [--verbose]

let usage = """
usage:
  squick-share-cli receive [--name NAME] [--dir DIR] [--auto-accept] [--verbose] [--info-version 0|1]
  squick-share-cli send [--to NAME] [--qr] [--verbose] [--text TEXT] [FILE...]
  squick-share-cli browse [--verbose]
"""

struct Arguments {
    var command = ""
    var name = Host.current().localizedName ?? "Mac"
    var directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
    var autoAccept = false
    var verbose = false
    var infoVersion: UInt8 = 0
    var target: String?
    var qr = false
    var texts: [String] = []
    var files: [URL] = []

    init(_ args: [String]) {
        var iterator = args.dropFirst().makeIterator()
        command = iterator.next() ?? ""
        while let arg = iterator.next() {
            switch arg {
            case "--name": name = iterator.next() ?? name
            case "--dir": directory = URL(fileURLWithPath: iterator.next() ?? ".")
            case "--auto-accept": autoAccept = true
            case "--verbose", "-v": verbose = true
            case "--info-version": infoVersion = UInt8(iterator.next() ?? "0") ?? 0
            case "--to": target = iterator.next()
            case "--qr": qr = true
            case "--text": if let text = iterator.next() { texts.append(text) }
            default: files.append(URL(fileURLWithPath: arg))
            }
        }
    }
}

let arguments = Arguments(CommandLine.arguments)
let diagnostics = Diagnostics(verbose: arguments.verbose) { entry in
    let time = ISO8601DateFormatter.string(from: entry.date, timeZone: .current, formatOptions: [.withTime, .withColonSeparatorInTime])
    FileHandle.standardError.write(Data("\(time) [\(entry.category)] \(entry.message)\n".utf8))
}
var options = ProtocolOptions()
options.endpointInfoVersion = arguments.infoVersion
let identity = LocalIdentity(name: arguments.name, options: options)

func say(_ text: String) { print(text); fflush(stdout) }

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func fileSHA256(_ url: URL) -> String {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return "?" }
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

/// Renders `text` as a QR code using half-block characters.
func printQRCode(_ text: String) {
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return say(text) }
    filter.setValue(Data(text.utf8), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let image = filter.outputImage else { return say(text) }
    let context = CIContext()
    let width = Int(image.extent.width), height = Int(image.extent.height)
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    context.render(image, toBitmap: &pixels, rowBytes: width * 4, bounds: image.extent, format: .RGBA8, colorSpace: nil)
    func dark(_ x: Int, _ y: Int) -> Bool {
        guard x >= 0, y >= 0, x < width, y < height else { return false }
        return pixels[((height - 1 - y) * width + x) * 4] < 128
    }
    var lines: [String] = []
    var y = -2
    while y < height + 2 {
        var line = ""
        for x in -2..<(width + 2) {
            switch (dark(x, y), dark(x, y + 1)) {
            case (true, true): line += " "
            case (true, false): line += "▄"
            case (false, true): line += "▀"
            case (false, false): line += "█"
            }
        }
        lines.append(line)
        y += 2
    }
    say(lines.joined(separator: "\n"))
}

func receive() async {
    let directory = arguments.directory
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    say("squick-share: visible as \"\(arguments.name)\", saving to \(directory.path)")
    say("On the phone: Share → Quick Share, and pick \"\(arguments.name)\". Ctrl-C to quit.")

    let receiverBox = ReceiverBox()
    let receiver = QuickShareReceiver(
        configuration: QuickShareReceiver.Configuration(identity: identity), diagnostics: diagnostics,
        eventHandler: { event in
            switch event {
            case .incomingRequest(let request):
                say("\nIncoming from \"\(request.device.name)\" (\(request.device.type)) — PIN \(request.pin)")
                for file in request.files {
                    say("  file: \(file.parentFolder.map { $0 + "/" } ?? "")\(file.name)  \(formatBytes(file.size))  \(file.mimeType)")
                }
                for text in request.texts { say("  text (\(text.kind)): \(text.title)") }
                if arguments.autoAccept {
                    say("Auto-accepting.")
                    receiverBox.receiver?.respond(to: request.id, accept: true, destination: directory)
                } else {
                    DispatchQueue.global().async {
                        print("Accept? [y/N] ", terminator: "")
                        fflush(stdout)
                        let answer = readLine()?.lowercased() ?? ""
                        receiverBox.receiver?.respond(to: request.id, accept: answer.hasPrefix("y"), destination: directory)
                    }
                }
            case .progress(_, let bytes, let total):
                let percent = total > 0 ? Double(bytes) / Double(total) * 100 : 100
                print(String(format: "\r  %.0f%%  %@ of %@   ", percent, formatBytes(bytes), formatBytes(total)), terminator: "")
                fflush(stdout)
            case .receivedFile(_, let url):
                say("\n  saved \(url.lastPathComponent)  sha256=\(fileSHA256(url))")
            case .receivedText(_, let text, let kind):
                say("\n  text (\(kind)): \(text)")
            case .completed:
                say("Transfer complete.")
            case .failed(_, let error):
                say("\nTransfer failed: \(error.userMessage) [\(error)]")
            case .awaitingAcceptance:
                break
            }
        },
        statusHandler: { status in
            switch status {
            case .advertising(let port): say("Advertising on port \(port).")
            case .localNetworkDenied: say("Local network permission is off. Allow it in System Settings → Privacy & Security → Local Network.")
            case .failed(let message): say("Receiver error: \(message)")
            case .stopped: break
            }
        })
    receiverBox.receiver = receiver
    receiver.start()
    while true { try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
}

final class ReceiverBox: @unchecked Sendable {
    var receiver: QuickShareReceiver?
}

final class DeviceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [DiscoveredDevice] = []
    var devices: [DiscoveredDevice] {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

func browse(seconds: Double) async -> [DiscoveredDevice] {
    let box = DeviceBox()
    let browser = NearbyBrowser(diagnostics: diagnostics, updateHandler: { box.devices = $0 }, statusHandler: { status in
        if status == .localNetworkDenied { say("Local network permission is off.") }
    })
    browser.start()
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    browser.stop()
    return box.devices
}

func send() async {
    var items = SendItems.expand(arguments.files)
    items += arguments.texts.map { SendItem.text($0) }
    guard !items.isEmpty else { return say(usage) }
    let qr = arguments.qr ? QRCodeSession() : nil
    if let qr {
        say("Scan this QR code with the phone's camera (or Quick Share → Receive → scan):")
        printQRCode(qr.url.absoluteString)
        say(qr.url.absoluteString)
    } else {
        say("On the phone, open Files → Quick Share → Receive so it becomes visible.")
    }

    let box = DeviceBox()
    let browser = NearbyBrowser(diagnostics: diagnostics, updateHandler: { box.devices = $0 })
    browser.start()
    var target: DiscoveredDevice?
    for _ in 0..<600 where target == nil {   // up to 2 minutes
        try? await Task.sleep(nanoseconds: 200_000_000)
        let devices = box.devices
        if let qr { target = devices.first { $0.qrMatch(qr) != nil } }
        else if let name = arguments.target { target = devices.first { $0.name?.localizedCaseInsensitiveContains(name) == true } }
        else if devices.count == 1 { target = devices.first }
    }
    browser.stop()
    guard let target else { return say("No matching device found.") }
    say("Sending to \"\(target.qrMatch(qr ?? QRCodeSession()) ?? target.name ?? "device")\"…")

    let done = DispatchSemaphore(value: 0)
    QuickShareSender(identity: identity, diagnostics: diagnostics).send(items, to: target, qrSession: qr) { event in
        switch event {
        case .awaitingAcceptance(_, _, let pin): say("PIN \(pin). Waiting for the phone to accept…")
        case .progress(_, let bytes, let total):
            print(String(format: "\r  %@ of %@   ", formatBytes(bytes), formatBytes(total)), terminator: "")
            fflush(stdout)
        case .completed: say("\nSent."); done.signal()
        case .failed(_, let error): say("\nFailed: \(error.userMessage) [\(error)]"); done.signal()
        default: break
        }
    }
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async { done.wait(); continuation.resume() }
    }
}

switch arguments.command {
case "receive":
    await receive()
case "send":
    await send()
case "browse":
    say("Browsing for 10 seconds…")
    for device in await browse(seconds: 10) {
        say("  \(device.name ?? "(hidden)")  type=\(device.type)  endpoint=\(device.endpointID)")
    }
default:
    say(usage)
}
