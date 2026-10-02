import AppKit
import Combine
import Network
import QuickShareCore
import UniformTypeIdentifiers

/// Central app state: owns the receiver, browser and transfers, and drives the UI.
@MainActor
final class AppModel: ObservableObject {
    let settings = AppSettings()
    let log = DiagnosticsLog()
    let diagnostics: Diagnostics
    let windows = WindowCoordinator()
    let notifications = NotificationManager()

    @Published private(set) var receiverStatus: ReceiverStatus = .stopped
    @Published private(set) var browserStatus: BrowserStatus = .stopped
    @Published private(set) var hasNetwork = true
    @Published private(set) var pendingRequests: [IncomingTransferRequest] = []
    @Published private(set) var transfers: [ActiveTransfer] = []
    @Published private(set) var recents: [RecentTransfer] = []
    @Published private(set) var pendingSendItems: [SendItem] = []
    @Published private(set) var nearbyDevices: [DiscoveredDevice] = []
    @Published private(set) var qrSession: QRCodeSession?
    @Published var notice: String?
    @Published private(set) var now = Date()

    private var receiver: QuickShareReceiver?
    private var browser: NearbyBrowser?
    private var outgoing: [UUID: OutgoingTransfer] = [:]
    private var requestDevices: [UUID: RemoteDevice] = [:]
    private var pathMonitor: NWPathMonitor?
    private var ticker: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var started = false
    /// A Sendable weak handle for callbacks that arrive on background queues.
    private lazy var weakRef = WeakRef(self)

    init() {
        let log = self.log
        diagnostics = Diagnostics(verbose: false) { log.append($0) }
        diagnostics.verbose = settings.verboseLogging
        recents = Self.loadRecents()
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        diagnostics.info("app", "squick-share \(Self.appVersion) starting on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        notifications.onAction = { [weak self] action, id in self?.handleNotificationAction(action, id) }
        notifications.setUp()

        settings.$verboseLogging.dropFirst().sink { [weak self] in self?.diagnostics.verbose = $0 }.store(in: &cancellables)
        // Restart advertising when anything that is advertised changes.
        Publishers.CombineLatest3(settings.$deviceName, settings.$protocolOptions, settings.$interface)
            .dropFirst()
            .debounce(for: .milliseconds(600), scheduler: RunLoop.main)
            .sink { [weak self] _, _, _ in self?.restartNetworking() }
            .store(in: &cancellables)
        settings.$visibility.dropFirst().sink { [weak self] visibility in
            DispatchQueue.main.async { self?.applyVisibility(visibility) }
        }.store(in: &cancellables)

        let monitor = NWPathMonitor()
        let ref = weakRef
        monitor.pathUpdateHandler = { path in
            let available = path.status == .satisfied
            DispatchQueue.main.async { MainActor.assumeIsolated { ref.value?.setNetworkAvailable(available) } }
        }
        monitor.start(queue: DispatchQueue(label: "squickshare.path"))
        pathMonitor = monitor

        // Re-register Bonjour after sleep: the network may have changed.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.diagnostics.info("app", "woke from sleep; restarting discovery")
                self?.restartNetworking(full: true)
            }
        }

        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        applyVisibility(settings.visibility)
    }

    var identity: LocalIdentity {
        LocalIdentity(name: settings.deviceName.trimmingCharacters(in: .whitespacesAndNewlines), options: settings.protocolOptions)
    }

    private func setNetworkAvailable(_ available: Bool) {
        guard available != hasNetwork else { return }
        hasNetwork = available
        diagnostics.info("app", "network \(available ? "available" : "unavailable")")
        // Re-register Bonjour on a new network.
        if available { restartNetworking(full: true) }
    }

    private func tick() {
        now = Date()
        if settings.visibility == .temporary, let until = settings.temporaryVisibilityUntil, until <= now {
            diagnostics.info("app", "temporary visibility expired")
            settings.visibility = .hidden
        }
    }

    // MARK: Visibility and receiver

    func applyVisibility(_ visibility: Visibility) {
        if visibility == .temporary {
            settings.temporaryVisibilityUntil = Date().addingTimeInterval(AppSettings.temporaryVisibilityDuration)
        } else {
            settings.temporaryVisibilityUntil = nil
        }
        if visibility == .hidden { stopReceiver() } else { startReceiver() }
    }

    private func startReceiver() {
        var configuration = QuickShareReceiver.Configuration(identity: identity)
        configuration.interface = settings.interface
        if let receiver {
            // Updates the advertisement in place when running; starts it when it was stopped.
            receiver.update(configuration)
            if !receiver.isRunning { receiver.start() }
            return
        }
        let ref = weakRef
        let receiver = QuickShareReceiver(
            configuration: configuration, diagnostics: diagnostics,
            eventHandler: { event in
                DispatchQueue.main.async { MainActor.assumeIsolated { ref.value?.handle(event, direction: .incoming) } }
            },
            statusHandler: { status in
                DispatchQueue.main.async { MainActor.assumeIsolated { ref.value?.receiverStatus = status } }
            })
        self.receiver = receiver
        receiver.start()
    }

    private func stopReceiver() {
        receiver?.stop()
        receiverStatus = .stopped
    }

    /// - Parameter full: restart the listener (after a network change or wake) instead of updating it in place.
    private func restartNetworking(full: Bool = false) {
        if settings.visibility != .hidden {
            if full, let receiver { receiver.stop() }
            startReceiver()
        }
        if browser != nil {
            stopBrowser()
            startBrowser()
        }
    }

    var statusLine: String {
        switch receiverStatus {
        case .localNetworkDenied: return "Local network permission is off"
        case .failed: return "Can't be discovered right now"
        default: break
        }
        switch settings.visibility {
        case .everyone: return "Visible as \(identity.name)"
        case .hidden: return "Hidden"
        case .temporary:
            let remaining = (settings.temporaryVisibilityUntil ?? now).timeIntervalSince(now)
            return "Visible for \(Format.countdown(remaining))"
        }
    }

    var localNetworkDenied: Bool {
        receiverStatus == .localNetworkDenied || browserStatus == .localNetworkDenied
    }

    /// Transfers still running (not completed or failed).
    var runningTransfers: [ActiveTransfer] { transfers.filter { !$0.isFinished } }

    var menuBarState: MenuBarState {
        let running = runningTransfers
        let attention = !pendingRequests.isEmpty
        guard !running.isEmpty else {
            return MenuBarState(activity: .idle(hidden: settings.visibility == .hidden), needsAttention: attention)
        }
        let total = running.reduce(Int64(0)) { $0 + $1.totalBytes }
        let done = running.reduce(Int64(0)) { $0 + $1.bytes }
        let fraction = total > 0 ? (Double(done) / Double(total) * 50).rounded() / 50 : 0
        return MenuBarState(activity: .transferring(progress: fraction,
                                                    incoming: running.contains { $0.direction == .incoming },
                                                    outgoing: running.contains { $0.direction == .outgoing }),
                            needsAttention: attention)
    }

    var menuBarAccessibilityLabel: String {
        var parts = ["squick-share"]
        if let activity = activitySummary { parts.append(activity) }
        if !pendingRequests.isEmpty { parts.append("request waiting") }
        return parts.joined(separator: ", ")
    }

    /// One line describing what is happening right now, or nil when idle.
    var activitySummary: String? {
        if let request = pendingRequests.first {
            return "\(request.device.name) wants to share"
        }
        let running = runningTransfers
        guard let first = running.first else { return nil }
        if running.count > 1 {
            let total = running.reduce(Int64(0)) { $0 + $1.totalBytes }
            let done = running.reduce(Int64(0)) { $0 + $1.bytes }
            let percent = total > 0 ? Int(Double(done) / Double(total) * 100) : 0
            return "\(running.count) transfers · \(percent)%"
        }
        let verb = first.direction == .incoming ? "Receiving from" : "Sending to"
        switch first.phase {
        case .connecting:
            return "Connecting to \(first.deviceName)…"
        case .waitingForAcceptance:
            return "Waiting for \(first.deviceName) to accept"
        default:
            var text = "\(verb) \(first.deviceName) · \(Int(first.fraction * 100))%"
            if first.meter.bytesPerSecond > 0 { text += " · \(Format.speed(first.meter.bytesPerSecond))" }
            return text
        }
    }

    var menuBarSymbol: String {
        if transfers.contains(where: { !$0.isFinished }) { return "arrow.up.arrow.down.circle.fill" }
        return settings.visibility == .hidden ? "antenna.radiowaves.left.and.right.slash" : "antenna.radiowaves.left.and.right"
    }

    // MARK: Events

    private func handle(_ event: TransferEvent, direction: TransferDirection) {
        switch event {
        case .incomingRequest(let request):
            handleIncoming(request)
        case .awaitingAcceptance(let id, let device, let pin):
            update(id) {
                $0.phase = .waitingForAcceptance(pin: pin)
                $0.deviceName = device.name
            }
        case .progress(let id, let bytes, let total):
            update(id) {
                if case .waitingForAcceptance = $0.phase { $0.phase = .transferring }
                if $0.phase == .connecting { $0.phase = .transferring }
                $0.bytes = bytes
                $0.totalBytes = total
                $0.meter.add(bytes)
            }
        case .receivedFile(let id, let url):
            update(id) { $0.savedFiles.append(url) }
        case .receivedText(let id, let text, let kind):
            update(id) { $0.texts.append(text) }
            let device = transfers.first { $0.id == id }?.deviceName ?? "a device"
            windows.showReceivedText(text: text, kind: kind, from: device)
        case .completed(let id):
            finish(id, error: nil)
        case .failed(let id, let error):
            if pendingRequests.contains(where: { $0.id == id }) {
                removeRequest(id)
                if error != .declined {
                    notice = "The request from \(requestDevices[id]?.name ?? "a device") ended: \(error.userMessage)"
                }
            }
            finish(id, error: error)
        }
    }

    private func handleIncoming(_ request: IncomingTransferRequest) {
        requestDevices[request.id] = request.device
        diagnostics.info("app", "incoming request: \(request.files.count) files, \(request.texts.count) texts")
        if settings.autoAcceptTrusted, settings.isTrusted(request.device) {
            diagnostics.info("app", "auto-accepting from trusted device")
            accept(request, trust: false)
            return
        }
        pendingRequests.append(request)
        windows.showIncomingRequest(request, model: self)
        if settings.notificationsEnabled { notifications.postIncoming(request) }
        NSSound(named: "Glass")?.play()
    }

    func accept(_ request: IncomingTransferRequest, trust: Bool) {
        if trust { settings.trust(request.device) }
        removeRequest(request.id)
        let names = request.files.map(\.name)
        transfers.insert(ActiveTransfer(id: request.id, direction: .incoming, deviceName: request.device.name,
                                        deviceType: request.device.type, summary: Format.summary(files: names, texts: request.texts.count),
                                        phase: .transferring, totalBytes: request.totalBytes), at: 0)
        receiver?.respond(to: request.id, accept: true, destination: settings.downloadFolder)
    }

    func decline(_ request: IncomingTransferRequest) {
        removeRequest(request.id)
        receiver?.respond(to: request.id, accept: false, destination: nil)
    }

    /// The user saw a different PIN on the other device: decline and explain.
    func declineForPinMismatch(_ request: IncomingTransferRequest) {
        diagnostics.info("app", "user declined: PIN mismatch")
        decline(request)
        notice = "Declined because the PINs didn't match. Another device may have tried to connect. Try again from the phone."
    }

    /// Outgoing: the phone shows a different PIN.
    func cancelForPinMismatch(_ transfer: ActiveTransfer) {
        diagnostics.info("app", "user cancelled: PIN mismatch")
        cancel(transfer)
        notice = "Cancelled because the PINs didn't match. Make sure you picked the right device and try again."
    }

    private func removeRequest(_ id: UUID) {
        pendingRequests.removeAll { $0.id == id }
        windows.close(id: "request-\(id)")
        notifications.remove(id)
    }

    func cancel(_ transfer: ActiveTransfer) {
        guard let index = transfers.firstIndex(where: { $0.id == transfer.id }), !transfers[index].cancelling else { return }
        transfers[index].cancelling = true
        diagnostics.info("app", "user cancelled \(transfer.direction) transfer")
        if transfer.direction == .incoming { receiver?.cancel(transfer.id) } else { outgoing[transfer.id]?.cancel() }
    }

    func dismiss(_ transfer: ActiveTransfer) {
        transfers.removeAll { $0.id == transfer.id }
    }

    private func update(_ id: UUID, _ change: (inout ActiveTransfer) -> Void) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        change(&transfers[index])
    }

    private func finish(_ id: UUID, error: TransferError?) {
        outgoing[id] = nil
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        var transfer = transfers[index]
        if let error {
            transfer.phase = .failed(error == .declined && transfer.direction == .incoming ? "Declined" : error.userMessage)
        } else {
            transfer.phase = .completed
            transfer.bytes = transfer.totalBytes
        }
        transfers[index] = transfer

        let names = transfer.savedFiles.map(\.lastPathComponent)
        addRecent(RecentTransfer(
            id: id, date: Date(), direction: transfer.direction, deviceName: transfer.deviceName,
            itemNames: transfer.direction == .incoming ? names : [transfer.summary],
            fileURLs: transfer.savedFiles, text: transfer.texts.first, succeeded: error == nil, message: error?.userMessage))

        if settings.notificationsEnabled {
            if let error, error != .cancelledByUser, !(error == .declined && transfer.direction == .incoming) {
                notifications.postResult(title: "Transfer failed", body: "\(transfer.deviceName): \(error.userMessage)", reveal: nil)
            } else if error == nil, transfer.direction == .incoming, !transfer.savedFiles.isEmpty {
                notifications.postResult(title: "Received from \(transfer.deviceName)",
                                         body: Format.summary(files: names, texts: transfer.texts.count),
                                         reveal: transfer.savedFiles.first)
            } else if error == nil, transfer.direction == .outgoing {
                notifications.postResult(title: "Sent to \(transfer.deviceName)", body: transfer.summary, reveal: nil)
            }
        }
        // Finished rows stay briefly, then move to Recent.
        let delay: TimeInterval = error == nil ? 4 : 12
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.transfers.removeAll { $0.id == id && $0.isFinished }
        }
    }

    private func handleNotificationAction(_ action: NotificationManager.Action, _ id: UUID) {
        guard let request = pendingRequests.first(where: { $0.id == id }) else { return }
        switch action {
        case .accept: accept(request, trust: false)
        case .decline: decline(request)
        case .open: windows.showIncomingRequest(request, model: self)
        }
    }

    // MARK: Recents

    private func addRecent(_ recent: RecentTransfer) {
        recents.insert(recent, at: 0)
        if recents.count > 30 { recents.removeLast(recents.count - 30) }
        UserDefaults.standard.set(try? JSONEncoder().encode(recents), forKey: "recents")
    }

    func clearRecents() {
        recents = []
        UserDefaults.standard.removeObject(forKey: "recents")
    }

    private static func loadRecents() -> [RecentTransfer] {
        guard let data = UserDefaults.standard.data(forKey: "recents") else { return [] }
        return (try? JSONDecoder().decode([RecentTransfer].self, from: data)) ?? []
    }

    func showInFinder(_ recent: RecentTransfer) {
        let existing = recent.fileURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
        if existing.isEmpty {
            NSWorkspace.shared.open(settings.downloadFolder)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(existing)
        }
    }

    // MARK: Sending

    func addSendFiles(_ urls: [URL]) {
        let items = SendItems.expand(urls)
        guard !items.isEmpty else {
            notice = "Nothing to send: folders were empty or files couldn't be read."
            return
        }
        addSendItems(items)
    }

    func addSendText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        addSendItems([.text(trimmed)])
    }

    private func addSendItems(_ items: [SendItem]) {
        pendingSendItems.append(contentsOf: items)
        diagnostics.info("app", "send list has \(pendingSendItems.count) items")
        startBrowser()
    }

    func clearSendItems() {
        pendingSendItems = []
        qrSession = nil
        stopBrowser()
    }

    var sendSummary: String {
        let files = pendingSendItems.compactMap { item -> String? in
            if case .file(let url, _) = item { return url.lastPathComponent }
            return nil
        }
        let texts = pendingSendItems.count - files.count
        return Format.summary(files: files, texts: texts)
    }

    func send(to device: DiscoveredDevice, qr: QRCodeSession? = nil) {
        let items = pendingSendItems
        guard !items.isEmpty else { return }
        let empty = SendItems.emptyFileCount(items)
        if empty > 0 { notice = "\(empty) empty file\(empty == 1 ? " was" : "s were") skipped (Quick Share can't send empty files)." }

        let sender = QuickShareSender(identity: identity, interface: settings.interface, diagnostics: diagnostics)
        let summary = sendSummary
        let ref = weakRef
        let transfer = sender.send(items, to: device, qrSession: qr) { event in
            DispatchQueue.main.async { MainActor.assumeIsolated { ref.value?.handle(event, direction: .outgoing) } }
        }
        outgoing[transfer.id] = transfer
        let name = qr.flatMap { device.qrMatch($0) } ?? device.name ?? "Device"
        transfers.insert(ActiveTransfer(id: transfer.id, direction: .outgoing, deviceName: name, deviceType: device.type,
                                        summary: summary, phase: .connecting), at: 0)
        diagnostics.info("app", "sending to endpoint \(device.endpointID) type=\(device.type) via \(qr == nil ? "list" : "QR")")
        clearSendItems()
        windows.close(id: "send")
    }

    func showQRCode() {
        qrSession = QRCodeSession()
        diagnostics.info("app", "showing QR code; waiting for a phone to answer it")
        startBrowser()
        checkQRMatch()
    }

    func hideQRCode() {
        qrSession = nil
    }

    private func checkQRMatch() {
        guard let qrSession, !pendingSendItems.isEmpty else { return }
        if let device = nearbyDevices.first(where: { $0.qrMatch(qrSession) != nil }) {
            diagnostics.info("app", "QR code answered by endpoint \(device.endpointID)")
            send(to: device, qr: qrSession)
        }
    }

    private func startBrowser() {
        guard browser == nil else { return }
        let ownIDs = receiver.map { Set([$0.endpointID]) } ?? []
        let ref = weakRef
        let browser = NearbyBrowser(
            diagnostics: diagnostics, interface: settings.interface, excluding: { ownIDs },
            updateHandler: { devices in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        ref.value?.nearbyDevices = devices
                        ref.value?.checkQRMatch()
                    }
                }
            },
            statusHandler: { status in
                DispatchQueue.main.async { MainActor.assumeIsolated { ref.value?.browserStatus = status } }
            })
        self.browser = browser
        browser.start()
    }

    private func stopBrowser() {
        browser?.stop()
        browser = nil
        nearbyDevices = []
        browserStatus = .stopped
    }

    // MARK: Open files from Finder / share extension

    func handleOpen(_ urls: [URL]) {
        var files: [URL] = []
        for url in urls {
            #if DEBUG
            if handleDebugURL(url) { continue }
            #endif
            if url.scheme == "squickshare" {
                let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                if let text = components?.queryItems?.first(where: { $0.name == "text" })?.value { addSendText(text) }
            } else if url.isFileURL {
                files.append(url)
            }
        }
        if !files.isEmpty { addSendFiles(files) }
        if !pendingSendItems.isEmpty { windows.showSend(model: self) }
    }

    // MARK: Diagnostics

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    func copyDiagnosticLog() {
        var arch = "unknown"
        #if arch(arm64)
        arch = "arm64"
        #elseif arch(x86_64)
        arch = "x86_64"
        #endif
        let options = (try? JSONEncoder().encode(settings.protocolOptions)).map { String(decoding: $0, as: UTF8.self) } ?? "?"
        let text = log.export(header: [
            "app": Self.appVersion,
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "arch": arch,
            "visibility": settings.visibility.rawValue,
            "receiver": "\(receiverStatus)",
            "browser": "\(browserStatus)",
            "network": hasNetwork ? "available" : "unavailable",
            "interface": settings.interface.rawValue,
            "verbose": "\(settings.verboseLogging)",
            "protocolOptions": options,
            "endpointID": receiver?.endpointID ?? "-",
        ])
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        diagnostics.info("app", "diagnostic log copied (\(log.count) entries)")
    }

    #if DEBUG
    /// Fills the UI with sample data for snapshot rendering.
    func debugLoadSampleState(request: IncomingTransferRequest) {
        pendingRequests = [request]
        var receiving = ActiveTransfer(id: UUID(), direction: .incoming, deviceName: "Redmi Note 13", deviceType: .phone,
                                       summary: "3 files", phase: .transferring, bytes: 61_000_000, totalBytes: 187_000_000)
        receiving.meter.add(0, at: Date().addingTimeInterval(-2))
        receiving.meter.add(61_000_000)
        transfers = [
            receiving,
            ActiveTransfer(id: UUID(), direction: .outgoing, deviceName: "Pixel 9", deviceType: .phone,
                           summary: "holiday.mov", phase: .waitingForAcceptance(pin: "1234")),
            ActiveTransfer(id: UUID(), direction: .outgoing, deviceName: "Pixel 9", deviceType: .phone,
                           summary: "report.pdf", phase: .failed("The other device declined the transfer.")),
        ]
        recents = [
            RecentTransfer(id: UUID(), date: Date().addingTimeInterval(-300), direction: .incoming, deviceName: "Redmi Note 13",
                           itemNames: ["IMG_0001.jpg", "IMG_0002.jpg"], fileURLs: [URL(fileURLWithPath: "/tmp/IMG_0001.jpg")],
                           text: nil, succeeded: true, message: nil),
            RecentTransfer(id: UUID(), date: Date().addingTimeInterval(-4000), direction: .incoming, deviceName: "Redmi Note 13",
                           itemNames: [], fileURLs: [], text: "https://example.com", succeeded: true, message: nil),
        ]
        notice = "1 empty file was skipped (Quick Share can't send empty files)."
        pendingSendItems = [.text("Hello from the Mac")]
    }
    #endif

    /// Sends a fresh Bonjour announcement so phones that just joined the network see this Mac.
    func announceAgain() {
        diagnostics.info("app", "user asked to announce again")
        receiver?.reannounce(reason: "user")
    }

    func openLocalNetworkSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Weak reference that can cross concurrency domains; only dereferenced on the main actor.
final class WeakRef<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
}
