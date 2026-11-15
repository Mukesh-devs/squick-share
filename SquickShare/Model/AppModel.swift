import AppKit
import Combine
import Network
import QuickShareCore
import UniformTypeIdentifiers

/// The pages of the main window, listed in its sidebar.
enum MainSection: String, CaseIterable, Identifiable {
    case send, receive, history, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .send: "Send"
        case .receive: "Receive"
        case .history: "History"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .send: "paperplane"
        case .receive: "tray.and.arrow.down"
        case .history: "clock.arrow.circlepath"
        case .settings: "gearshape"
        }
    }
}

/// Central app state: owns the receiver, browser and transfers, and drives the UI.
@MainActor
final class AppModel: ObservableObject {
    let settings = AppSettings()
    let log = DiagnosticsLog()
    let diagnostics: Diagnostics
    let windows = WindowCoordinator()
    let notifications = NotificationManager()
    private(set) var statusItem: StatusItemController?

    @Published private(set) var receiverStatus: ReceiverStatus = .stopped
    @Published private(set) var browserStatus: BrowserStatus = .stopped
    @Published private(set) var beaconStatus: BeaconListenerStatus = .off
    @Published private(set) var hasNetwork = true
    @Published private(set) var pendingRequests: [IncomingTransferRequest] = []
    @Published private(set) var transfers: [ActiveTransfer] = []
    @Published private(set) var recents: [RecentTransfer] = []
    @Published private(set) var pendingSendItems: [SendItem] = [] {
        didSet { pendingSendBytes = Self.bytes(of: pendingSendItems) }
    }
    /// Total size of the files in the send list (computed once per change, not on every redraw).
    private(set) var pendingSendBytes: Int64 = 0
    @Published private(set) var nearbyDevices: [DiscoveredDevice] = []
    @Published private(set) var qrSession: QRCodeSession?
    @Published private(set) var isMainWindowOpen = false
    /// The last text or link that arrived, shown as a banner in the window until dismissed.
    @Published private(set) var receivedText: ReceivedTextItem?
    /// Whether macOS lets the app show notifications.
    @Published private(set) var notificationsAllowed = true
    @Published var notice: String?
    /// The main window's page (kept here so it survives closing and reopening the window).
    @Published var section: MainSection = .send
    /// The "Send Text" sheet is open.
    @Published var isComposingText = false
    enum HistoryFilter: String, CaseIterable { case all, received, sent }
    @Published var historyFilter: HistoryFilter = .all
    @Published var historyQuery = ""
    @Published var settingsQuery = ""
    /// The selected Settings tab.
    @Published var settingsTab: SettingsTab = .general
    /// Updated once a second, only while the "Visible for 10 minutes" countdown runs.
    @Published private(set) var now = Date()

    private var receiver: QuickShareReceiver?
    private var browser: NearbyBrowser?
    private var beacon: QuickShareBeaconListener?
    private var outgoing: [UUID: OutgoingTransfer] = [:]
    private var requestDevices: [UUID: RemoteDevice] = [:]
    private var pathMonitor: NWPathMonitor?
    private var pathSignature: String?
    private var networkRestartTask: Task<Void, Never>?
    private var ticker: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var started = false
    /// Recent received texts by notification ID, for the notification's Open Link and Copy buttons.
    private var notifiedTexts: [UUID: ReceivedTextItem] = [:]
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
        diagnostics.info("app", "SQuick Share \(Self.appVersion) starting on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        notifications.onAction = { [weak self] action, id in self?.handleNotificationAction(action, id) }
        notifications.onTextAction = { [weak self] action, id in self?.handleTextAction(action, id) }
        notifications.onAuthorizationChange = { [weak self] allowed in
            if self?.notificationsAllowed != allowed { self?.notificationsAllowed = allowed }
        }
        notifications.setUp()
        windows.onMainWindowChange = { [weak self] event in self?.mainWindowChanged(event) }

        // Created before anything browses, so our own advertisement is never listed as a nearby device.
        receiver = makeReceiver()

        settings.$verboseLogging.dropFirst().sink { [weak self] in self?.diagnostics.verbose = $0 }.store(in: &cancellables)
        // Restart advertising when anything that is advertised changes.
        Publishers.CombineLatest3(settings.$deviceName, settings.$protocolOptions, settings.$interface)
            .dropFirst()
            .debounce(for: .milliseconds(600), scheduler: RunLoop.main)
            .sink { [weak self] _, _, _ in self?.restartNetworking() }
            .store(in: &cancellables)
        // @Published sends before the value is stored, so apply changes on the next main-queue turn.
        settings.$visibility.dropFirst().sink { [weak self] visibility in
            DispatchQueue.main.async { self?.applyVisibility(visibility) }
        }.store(in: &cancellables)
        settings.$useBluetooth.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.applyBluetooth() }
        }.store(in: &cancellables)
        settings.$showInMenuBar.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.applyDockAndMenuBar() }
        }.store(in: &cancellables)
        settings.$showInDock.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.applyDockAndMenuBar() }
        }.store(in: &cancellables)

        let monitor = NWPathMonitor()
        let ref = weakRef
        monitor.pathUpdateHandler = { path in
            let available = path.status == .satisfied
            // What identifies "the network we are on": a new Wi-Fi network changes the gateway.
            let interfaces = path.availableInterfaces.filter { $0.type == .wifi || $0.type == .wiredEthernet }.map(\.name)
            let signature = "\(available)|\(interfaces.sorted())|\(path.gateways.map { "\($0)" }.sorted())"
            DispatchQueue.main.async { MainActor.assumeIsolated { ref.value?.networkPathChanged(available: available, signature: signature) } }
        }
        monitor.start(queue: DispatchQueue(label: "squickshare.path"))
        pathMonitor = monitor

        // Re-register Bonjour after sleep: the network may have changed. Wait a moment, like Google
        // does, because a Mac can wake briefly for network activity and sleep again.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleNetworkRestart(reason: "woke from sleep", delay: 1) }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.notifications.refreshAuthorization() }
        }

        applyVisibility(settings.visibility)
        applyBluetooth()
        let item = StatusItemController(model: self)
        item.install(visible: settings.showInMenuBar)
        statusItem = item
        applyDockAndMenuBar()
    }

    var identity: LocalIdentity {
        LocalIdentity(name: settings.deviceName.trimmingCharacters(in: .whitespacesAndNewlines), options: settings.protocolOptions)
    }

    private func networkPathChanged(available: Bool, signature: String) {
        let first = pathSignature == nil
        let changed = signature != pathSignature
        pathSignature = signature
        if available != hasNetwork {
            hasNetwork = available
            diagnostics.info("app", "network \(available ? "available" : "unavailable")")
        }
        // Any change of network (not just losing it) needs a fresh Bonjour registration.
        guard !first, changed, available else { return }
        scheduleNetworkRestart(reason: "network changed", delay: 1.5)
    }

    /// Restarts discovery after `delay`; changes that arrive in a burst restart it only once.
    private func scheduleNetworkRestart(reason: String, delay: TimeInterval) {
        networkRestartTask?.cancel()
        networkRestartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.diagnostics.info("app", "\(reason); restarting discovery")
            self.restartNetworking(full: true)
        }
    }

    private func tick() {
        now = Date()
        if settings.visibility == .temporary, let until = settings.temporaryVisibilityUntil, until <= now {
            diagnostics.info("app", "temporary visibility expired")
            settings.visibility = .hidden
        }
    }

    /// The one-second timer only runs during the "Visible for 10 minutes" countdown.
    private func updateTicker() {
        if settings.visibility == .temporary {
            guard ticker == nil else { return }
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            timer.tolerance = 0.2
            RunLoop.main.add(timer, forMode: .common)   // keeps counting while a menu is open
            ticker = timer
            now = Date()
        } else {
            ticker?.invalidate()
            ticker = nil
        }
    }

    // MARK: Visibility, receiver and Bluetooth

    func applyVisibility(_ visibility: Visibility) {
        if visibility == .temporary {
            settings.temporaryVisibilityUntil = Date().addingTimeInterval(AppSettings.temporaryVisibilityDuration)
        } else {
            settings.temporaryVisibilityUntil = nil
        }
        if visibility == .hidden { stopReceiver() } else { startReceiver() }
        updateTicker()
    }

    private func makeReceiver() -> QuickShareReceiver {
        var configuration = QuickShareReceiver.Configuration(identity: identity)
        configuration.interface = settings.interface
        let ref = weakRef
        return QuickShareReceiver(
            configuration: configuration, diagnostics: diagnostics,
            eventHandler: { event in
                DispatchQueue.main.async { MainActor.assumeIsolated { ref.value?.handle(event, direction: .incoming) } }
            },
            statusHandler: { status in
                DispatchQueue.main.async { MainActor.assumeIsolated { ref.value?.setReceiverStatus(status) } }
            })
    }

    private func setReceiverStatus(_ status: ReceiverStatus) {
        if receiverStatus != status { receiverStatus = status }
    }

    private func startReceiver() {
        guard let receiver else { return }
        var configuration = QuickShareReceiver.Configuration(identity: identity)
        configuration.interface = settings.interface
        // Updates the advertisement in place when running; starts it when it was stopped.
        receiver.update(configuration)
        if !receiver.isRunning { receiver.start() }
    }

    private func stopReceiver() {
        receiver?.stop()
        setReceiverStatus(.stopped)
    }

    /// - Parameter full: restart the listener (after a network change or wake) instead of updating it in place.
    private func restartNetworking(full: Bool = false) {
        if settings.visibility != .hidden {
            if full, let receiver { receiver.stop() }
            startReceiver()
        }
        if browser != nil {
            stopBrowser()
            updateBrowsing()
        }
    }

    private func applyBluetooth() {
        if settings.useBluetooth {
            guard beacon == nil else { return }
            let ref = weakRef
            let listener = QuickShareBeaconListener(
                diagnostics: diagnostics,
                onBeacon: { DispatchQueue.main.async { MainActor.assumeIsolated { ref.value?.phoneStartedSharing() } } },
                onStatus: { status in DispatchQueue.main.async { MainActor.assumeIsolated { ref.value?.beaconStatus = status } } })
            beacon = listener
            listener.start()
        } else {
            beacon?.stop()
            beacon = nil
            beaconStatus = .off
        }
    }

    /// A phone nearby just opened its Quick Share sheet: announce this Mac now, so the phone lists it
    /// even if its Wi-Fi search started before it could hear our earlier announcements.
    private func phoneStartedSharing() {
        guard settings.visibility != .hidden, case .advertising = receiverStatus else { return }
        receiver?.reannounce(reason: "a nearby phone started Quick Share")
    }

    /// The menu bar icon, and whether the Dock icon stays without a window. Without the menu bar icon
    /// the Dock icon is the only way back in, so it always stays then.
    private func applyDockAndMenuBar() {
        statusItem?.setVisible(settings.showInMenuBar)
        windows.alwaysShowsDockIcon = settings.showInDock || !settings.showInMenuBar
        windows.updateActivationPolicy()
    }

    var statusLine: String {
        switch receiverStatus {
        case .localNetworkDenied: return "Local network permission is off"
        case .failed: return "Can't be discovered right now"
        default: break
        }
        if !hasNetwork { return "Not connected to a network" }
        switch settings.visibility {
        case .everyone: return "Visible as \(identity.name)"
        case .hidden: return "Hidden"
        case .temporary:
            let remaining = (settings.temporaryVisibilityUntil ?? now).timeIntervalSince(now)
            return "Visible for \(Format.countdown(remaining))"
        }
    }

    /// Whether other devices can find this Mac right now.
    var isDiscoverable: Bool {
        if case .advertising = receiverStatus { return settings.visibility != .hidden && hasNetwork }
        return false
    }

    var localNetworkDenied: Bool {
        receiverStatus == .localNetworkDenied || browserStatus == .localNetworkDenied
    }

    /// Transfers still running (not completed or failed).
    var runningTransfers: [ActiveTransfer] { transfers.filter { !$0.isFinished } }

    /// Transfers shown on the Send page (outgoing) and the Receive page (incoming).
    func transfers(_ direction: TransferDirection) -> [ActiveTransfer] {
        transfers.filter { $0.direction == direction }
    }

    /// The number shown next to a page in the sidebar: things waiting or running there.
    func badge(for section: MainSection) -> Int {
        switch section {
        case .send: return runningTransfers.filter { $0.direction == .outgoing }.count
        case .receive: return pendingRequests.count + runningTransfers.filter { $0.direction == .incoming }.count
        case .history, .settings: return 0
        }
    }

    /// Nearby devices that can be listed (hidden devices are only reachable by QR code).
    var visibleDevices: [DiscoveredDevice] { nearbyDevices.filter { $0.name != nil } }

    /// The most recent outgoing transfer to `device`, while it is shown.
    func transfer(to device: DiscoveredDevice) -> ActiveTransfer? {
        transfers.first { $0.direction == .outgoing && $0.targetID == device.id }
    }

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
        var parts = ["SQuick Share"]
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
        switch first.phase {
        case .connecting, .waitingForAcceptance:
            return first.headline
        default:
            var text = "\(first.direction == .incoming ? "Receiving from" : "Sending to") \(first.deviceName) · \(Int(first.fraction * 100))%"
            if first.meter.bytesPerSecond > 0 { text += " · \(Format.speed(first.meter.bytesPerSecond))" }
            return text
        }
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
            presentReceivedText(ReceivedTextItem(id: UUID(), text: text, kind: kind, deviceName: device))
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
        presentRequest(request)
    }

    /// Like AirDrop: a notification with Accept and Decline, or the main window when it is in front.
    /// No window ever pops up over other apps: without notifications, the request waits in the window
    /// (Receive page and sidebar badge) and in the menu bar menu (dot on the icon), with a sound.
    private func presentRequest(_ request: IncomingTransferRequest) {
        let windowInFront = isMainWindowOpen && NSApp.isActive
        if !windowInFront, settings.notificationsEnabled, notifications.canShowAlerts {
            notifications.postIncoming(request)
        } else {
            NSSound(named: "Glass")?.play()
        }
    }

    /// A banner in the window, and a notification with Open Link / Copy when the window isn't in front.
    private func presentReceivedText(_ item: ReceivedTextItem) {
        receivedText = item
        notifiedTexts[item.id] = item
        if notifiedTexts.count > 20, let oldest = notifiedTexts.keys.first(where: { $0 != item.id }) {
            notifiedTexts[oldest] = nil
        }
        let windowInFront = isMainWindowOpen && NSApp.isActive
        if !windowInFront, settings.notificationsEnabled, notifications.canShowAlerts {
            notifications.postText(id: item.id, text: item.text, isLink: item.webURL != nil, from: item.deviceName)
        }
    }

    private func handleTextAction(_ action: NotificationManager.TextAction, _ id: UUID) {
        guard let item = notifiedTexts[id] else {
            showMainWindow(section: .history)
            return
        }
        switch action {
        case .open: openReceivedText(item)
        case .copy: copyText(item.text)
        case .show: showMainWindow(section: .history)
        }
    }

    /// Opens a received link in the browser (only on the user's request).
    func openReceivedText(_ item: ReceivedTextItem) {
        if let url = item.webURL { NSWorkspace.shared.open(url) }
        if receivedText?.id == item.id { receivedText = nil }
    }

    func copyReceivedText(_ item: ReceivedTextItem) {
        copyText(item.text)
        if receivedText?.id == item.id { receivedText = nil }
    }

    func dismissReceivedText() {
        receivedText = nil
    }

    func accept(_ request: IncomingTransferRequest, trust: Bool) {
        guard pendingRequests.contains(where: { $0.id == request.id }) || settings.isTrusted(request.device) else { return }
        if trust { settings.trust(request.device) }
        removeRequest(request.id)
        let names = request.files.map(\.name)
        transfers.insert(ActiveTransfer(id: request.id, direction: .incoming, deviceName: request.device.name,
                                        deviceType: request.device.type, summary: Format.summary(files: names, texts: request.texts.count),
                                        phase: .transferring, totalBytes: request.totalBytes,
                                        kinds: request.files.map { DocKind(fileName: $0.name) }
                                            + request.texts.map { $0.kind == .url ? DocKind.link : DocKind.text }), at: 0)
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
            fileURLs: transfer.savedFiles, text: transfer.texts.first, succeeded: error == nil, message: error?.userMessage,
            kinds: transfer.kinds, totalBytes: transfer.totalBytes > 0 ? transfer.totalBytes : nil, deviceType: transfer.deviceType))
        notifyResult(of: transfer, error: error)

        // Finished rows stay briefly, then move to Recent.
        let delay: TimeInterval = error == nil ? 4 : 12
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.transfers.removeAll { $0.id == id && $0.isFinished }
        }
    }

    private func notifyResult(of transfer: ActiveTransfer, error: TransferError?) {
        // The window already shows the result when it is in front.
        guard settings.notificationsEnabled, !(isMainWindowOpen && NSApp.isActive) else { return }
        if let error {
            guard error != .cancelledByUser, !(error == .declined && transfer.direction == .incoming) else { return }
            notifications.postResult(title: "Transfer failed", body: "\(transfer.deviceName): \(error.userMessage)", reveal: nil)
        } else if transfer.direction == .incoming {
            // Text-only transfers already got their own notification with Open Link / Copy.
            guard !transfer.savedFiles.isEmpty else { return }
            let items = Format.countSummary(files: transfer.savedFiles.count, texts: transfer.texts.count,
                                            bytes: transfer.savedFiles.isEmpty ? 0 : transfer.totalBytes)
            notifications.postResult(title: "Transfer complete", body: "\(items) received from \(transfer.deviceName)",
                                     reveal: transfer.savedFiles.first)
        } else {
            notifications.postResult(title: "Sent to \(transfer.deviceName)", body: transfer.summary, reveal: nil)
        }
    }

    private func handleNotificationAction(_ action: NotificationManager.Action, _ id: UUID) {
        guard let request = pendingRequests.first(where: { $0.id == id }) else {
            if action == .open { showMainWindow(section: .receive) }
            return
        }
        switch action {
        case .accept: accept(request, trust: false)
        case .decline: decline(request)
        case .open: showMainWindow(section: .receive)
        }
    }

    // MARK: Recents

    private func addRecent(_ recent: RecentTransfer) {
        recents.insert(recent, at: 0)
        if recents.count > 30 { recents.removeLast(recents.count - 30) }
        saveRecents()
    }

    private func saveRecents() {
        UserDefaults.standard.set(try? JSONEncoder().encode(recents), forKey: "recents")
    }

    func removeRecent(_ recent: RecentTransfer) {
        recents.removeAll { $0.id == recent.id }
        saveRecents()
    }

    /// History, after the toolbar's filter and search.
    var filteredRecents: [RecentTransfer] {
        let query = historyQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return recents.filter { recent in
            switch historyFilter {
            case .all: break
            case .received: if recent.direction != .incoming { return false }
            case .sent: if recent.direction != .outgoing { return false }
            }
            guard !query.isEmpty else { return true }
            return ([recent.title, recent.deviceName, recent.text ?? ""] + recent.itemNames)
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    /// Puts the cursor in the toolbar's search field (History and Settings).
    func focusSearch() {
        windows.focusSearch()
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

    /// What opening a History entry does: received files in Finder, a link in the browser,
    /// other text to the clipboard.
    func open(_ recent: RecentTransfer) {
        if recent.direction == .incoming, !recent.fileURLs.isEmpty {
            showInFinder(recent)
        } else if let text = recent.text {
            if let url = Format.webURL(text) { NSWorkspace.shared.open(url) } else { copyText(text) }
        } else {
            showMainWindow(section: .history)
        }
    }

    func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func openDownloadFolder() {
        NSWorkspace.shared.open(settings.downloadFolder)
    }

    // MARK: Windows

    /// Opens the main window, on `section` if given (otherwise on the page it last showed).
    func showMainWindow(section: MainSection? = nil) {
        if let section, self.section != section { self.section = section }
        windows.showMain(model: self)
    }

    func showSettings(tab: SettingsTab? = nil) {
        if let tab, settingsTab != tab { settingsTab = tab }
        showMainWindow(section: .settings)
    }

    private func mainWindowChanged(_ event: WindowCoordinator.MainWindowEvent) {
        isMainWindowOpen = event == .opened || event == .restored
        if event == .closed {
            // Nothing can be sent without the window, so forget the send list and stop looking for devices.
            pendingSendItems = []
            qrSession = nil
        }
        updateBrowsing()
    }

    /// Lets the user pick files in a sheet on the main window, then sends them to `device`,
    /// or adds them to the send list when no device is given.
    func chooseFiles(for device: DiscoveredDevice? = nil) {
        showMainWindow(section: .send)
        guard let window = windows.mainWindow else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = device == nil ? "Add" : "Send"
        panel.message = device.map { "Choose files or folders to send to \($0.name ?? "the device")." } ?? "Choose files or folders to send."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self else { return }
            let urls = panel.urls
            if let device {
                self.send(SendItems.expand(urls), to: device)
            } else {
                self.addSendFiles(urls)
            }
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
        updateBrowsing()
    }

    func clearSendItems() {
        pendingSendItems = []
        qrSession = nil
        updateBrowsing()
    }

    var sendSummary: String { Self.summary(of: pendingSendItems) }

    static func summary(of items: [SendItem]) -> String {
        let files = items.compactMap { item -> String? in
            if case .file(let url, _) = item { return url.lastPathComponent }
            return nil
        }
        return Format.summary(files: files, texts: items.count - files.count)
    }

    static func kinds(of items: [SendItem]) -> [DocKind] {
        items.map { item in
            switch item {
            case .file(let url, _): return DocKind(fileName: url.lastPathComponent)
            case .text(let text): return DocKind(text: text)
            }
        }
    }

    static func bytes(of items: [SendItem]) -> Int64 {
        items.reduce(Int64(0)) { total, item in
            guard case .file(let url, _) = item else { return total }
            return total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    /// What clicking a device does: send the chosen items, or pick files to send to it.
    func activate(_ device: DiscoveredDevice) {
        if let current = transfer(to: device), !current.isFinished { return }   // already sending to it
        if pendingSendItems.isEmpty {
            chooseFiles(for: device)
        } else {
            send(to: device)
        }
    }

    /// Sends the pending items to `device`.
    func send(to device: DiscoveredDevice, qr: QRCodeSession? = nil) {
        let items = pendingSendItems
        guard !items.isEmpty else { return }
        startSend(items, to: device, qr: qr)
        clearSendItems()
    }

    /// Sends `items` (for example files dropped on a device) without touching the send list.
    func send(_ items: [SendItem], to device: DiscoveredDevice) {
        guard !items.isEmpty else {
            notice = "Nothing to send: folders were empty or files couldn't be read."
            return
        }
        startSend(items, to: device, qr: nil)
    }

    private func startSend(_ items: [SendItem], to device: DiscoveredDevice, qr: QRCodeSession?) {
        let empty = SendItems.emptyFileCount(items)
        if empty > 0 { notice = "\(empty) empty file\(empty == 1 ? " was" : "s were") skipped (Quick Share can't send empty files)." }

        let sender = QuickShareSender(identity: identity, interface: settings.interface, diagnostics: diagnostics)
        let ref = weakRef
        let transfer = sender.send(items, to: device, qrSession: qr) { event in
            DispatchQueue.main.async { MainActor.assumeIsolated { ref.value?.handle(event, direction: .outgoing) } }
        }
        outgoing[transfer.id] = transfer
        let name = qr.flatMap { device.qrMatch($0) } ?? device.name ?? "Device"
        transfers.insert(ActiveTransfer(id: transfer.id, direction: .outgoing, deviceName: name, deviceType: device.type,
                                        summary: Self.summary(of: items), phase: .connecting, targetID: device.id,
                                        kinds: Self.kinds(of: items)), at: 0)
        diagnostics.info("app", "sending to endpoint \(device.endpointID) type=\(device.type) via \(qr == nil ? "list" : "QR")")
    }

    func showQRCode() {
        qrSession = QRCodeSession()
        diagnostics.info("app", "showing QR code; waiting for a phone to answer it")
        updateBrowsing()
        checkQRMatch()
    }

    func hideQRCode() {
        qrSession = nil
        updateBrowsing()
    }

    private func checkQRMatch() {
        guard let qrSession, !pendingSendItems.isEmpty else { return }
        if let device = nearbyDevices.first(where: { $0.qrMatch(qrSession) != nil }) {
            diagnostics.info("app", "QR code answered by endpoint \(device.endpointID)")
            send(to: device, qr: qrSession)
        }
    }

    /// Looks for nearby devices only while something can be sent: the window is open or items wait.
    private func updateBrowsing() {
        if isMainWindowOpen || !pendingSendItems.isEmpty || qrSession != nil {
            startBrowser()
        } else {
            stopBrowser()
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
                        guard let model = ref.value else { return }
                        if model.nearbyDevices != devices { model.nearbyDevices = devices }
                        model.checkQRMatch()
                    }
                }
            },
            statusHandler: { status in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let model = ref.value, model.browser != nil, model.browserStatus != status else { return }
                        model.browserStatus = status
                    }
                }
            })
        self.browser = browser
        browser.start()
    }

    private func stopBrowser() {
        guard let current = browser else { return }
        current.stop()
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
        if !pendingSendItems.isEmpty { showMainWindow(section: .send) }
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
            "bluetooth": settings.useBluetooth ? "\(beaconStatus)" : "off in settings",
            "menuBarIcon": "\(settings.showInMenuBar)",
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
    /// Fills the UI with sample data for snapshot rendering (the same scene as the design mockups).
    func debugLoadSampleState(request: IncomingTransferRequest) {
        pendingRequests = [request]
        let tablet = DiscoveredDevice.preview(name: "Galaxy Tab S9", type: .tablet)
        let pixel = DiscoveredDevice.preview(name: "Pixel 9", type: .phone)
        let office = DiscoveredDevice.preview(name: "Office PC", type: .laptop)
        let redmi = DiscoveredDevice.preview(name: "Redmi Note 13", type: .phone)
        nearbyDevices = [tablet, pixel, office, redmi]
        let photos = [DocKind(fileName: "a.jpg"), DocKind(fileName: "b.jpg")]
        var receiving = ActiveTransfer(id: UUID(), direction: .incoming, deviceName: "Pixel 9", deviceType: .phone,
                                       summary: "3 files", phase: .transferring, bytes: 61_000_000, totalBytes: 187_000_000,
                                       kinds: photos + [DocKind(fileName: "c.mov")])
        receiving.meter.add(0, at: Date().addingTimeInterval(-2))
        receiving.meter.add(61_000_000)
        var sending = ActiveTransfer(id: UUID(), direction: .outgoing, deviceName: "Galaxy Tab S9", deviceType: .tablet,
                                     summary: "3 files", phase: .transferring, bytes: 24_100_000, totalBytes: 28_400_000,
                                     targetID: tablet.id, kinds: photos + [DocKind(fileName: "c.pdf")])
        sending.meter.add(0, at: Date().addingTimeInterval(-1))
        sending.meter.add(24_100_000)
        transfers = [
            sending,
            receiving,
            ActiveTransfer(id: UUID(), direction: .outgoing, deviceName: "Pixel 9", deviceType: .phone,
                           summary: "holiday.mov", phase: .waitingForAcceptance(pin: "1234"), targetID: pixel.id,
                           kinds: [DocKind(fileName: "holiday.mov")]),
            ActiveTransfer(id: UUID(), direction: .outgoing, deviceName: "Office PC", deviceType: .laptop,
                           summary: "report.pdf", phase: .completed, bytes: 2_100_000, totalBytes: 2_100_000,
                           targetID: office.id, kinds: [DocKind(fileName: "report.pdf")]),
        ]
        let today = Calendar.current.startOfDay(for: Date())
        recents = [
            RecentTransfer(id: UUID(), date: today.addingTimeInterval(9 * 3600 + 15 * 60), direction: .incoming, deviceName: "Redmi Note 13",
                           itemNames: ["VID_20261115_0915.mp4"], fileURLs: [URL(fileURLWithPath: "/tmp/VID_20261115_0915.mp4")],
                           text: nil, succeeded: true, message: nil,
                           kinds: [DocKind(fileName: "v.mp4")], totalBytes: 182_000_000, deviceType: .phone),
            RecentTransfer(id: UUID(), date: today.addingTimeInterval(9 * 3600 + 12 * 60), direction: .incoming, deviceName: "Redmi Note 13",
                           itemNames: ["IMG_20261115_0912.jpg"], fileURLs: [URL(fileURLWithPath: "/tmp/IMG_20261115_0912.jpg")],
                           text: nil, succeeded: true, message: nil,
                           kinds: [DocKind(fileName: "i.jpg")], totalBytes: 4_800_000, deviceType: .phone),
            RecentTransfer(id: UUID(), date: today.addingTimeInterval(8 * 3600 + 40 * 60), direction: .incoming, deviceName: "Pixel 9",
                           itemNames: [], fileURLs: [], text: "https://example.com/article", succeeded: true, message: nil,
                           kinds: [.link], deviceType: .phone),
            RecentTransfer(id: UUID(), date: today.addingTimeInterval(-6 * 3600), direction: .outgoing, deviceName: "Pixel 9",
                           itemNames: ["Project Report.pdf"], fileURLs: [], text: nil, succeeded: true, message: nil,
                           kinds: [DocKind(fileName: "r.pdf")], totalBytes: 2_100_000, deviceType: .phone),
            RecentTransfer(id: UUID(), date: today.addingTimeInterval(-6.3 * 3600), direction: .outgoing, deviceName: "Pixel 9",
                           itemNames: ["Presentation.key"], fileURLs: [], text: nil, succeeded: false,
                           message: "The other device declined the transfer.",
                           kinds: [DocKind(fileName: "p.key")], totalBytes: 48_000_000, deviceType: .phone),
        ]
        pendingSendItems = []
        receivedText = nil
    }

    /// Only nearby devices and recent transfers: what the window looks like most of the time.
    func debugLoadBrowsingState() {
        pendingRequests = []
        transfers = []
        pendingSendItems = []
        notice = nil
        receivedText = nil
    }

    /// Nothing nearby yet: the searching state.
    func debugLoadSearchingState() {
        debugLoadBrowsingState()
        nearbyDevices = []
        browserStatus = .browsing
    }

    /// Snapshots render without networking: show the states a running app would have.
    func debugPrepareSnapshot() {
        isMainWindowOpen = true
        receiverStatus = .advertising(port: 0)
        browserStatus = .browsing
        if settings.useBluetooth { beaconStatus = .listening }
        if !settings.hasSeenWelcome { settings.hasSeenWelcome = true }
    }

    /// Text arriving from a phone, as if it came over the network.
    func debugReceiveText(_ text: String) {
        presentReceivedText(ReceivedTextItem(id: UUID(), text: text, kind: Format.webURL(text) != nil ? .url : .text,
                                             deviceName: "Test Phone"))
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
