import AppKit
import QuickLookThumbnailing
import QuickShareCore
import UserNotifications

/// System notifications: incoming requests (with Accept and Decline) and transfer results.
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    enum Action { case accept, decline, open }

    private static let incomingCategory = "INCOMING"
    private static let resultCategory = "RESULT"
    private static let acceptAction = "ACCEPT"
    private static let declineAction = "DECLINE"
    private static let revealAction = "REVEAL"

    var onAction: ((Action, UUID) -> Void)?
    /// Whether banners or alerts can be shown. When false, requests appear in a small window instead.
    private(set) var canShowAlerts = false
    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

    func setUp() {
        center.delegate = self
        let accept = UNNotificationAction(identifier: Self.acceptAction, title: "Accept", options: [])
        let decline = UNNotificationAction(identifier: Self.declineAction, title: "Decline", options: [.destructive])
        let reveal = UNNotificationAction(identifier: Self.revealAction, title: "Show in Finder", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.incomingCategory, actions: [accept, decline], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.resultCategory, actions: [reveal], intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshAuthorization() }
        }
    }

    /// Re-reads the notification settings (the user may have changed them in System Settings).
    func refreshAuthorization() {
        center.getNotificationSettings { settings in
            let allowed = (settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional)
                && settings.alertSetting == .enabled
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.canShowAlerts = allowed }
            }
        }
    }

    /// "Incoming files from Redmi 11i" / "5 files (132.7 MB) · PIN 4930", with Accept and Decline.
    func postIncoming(_ request: IncomingTransferRequest) {
        let content = UNMutableNotificationContent()
        let kind = request.files.isEmpty ? (request.texts.first?.kind == .url ? "link" : "text") : "files"
        content.title = "Incoming \(kind) from \(request.device.name)"
        content.body = "\(Format.countSummary(files: request.files.count, texts: request.texts.count, bytes: request.totalBytes))"
            + " · PIN \(request.pin)"
        content.categoryIdentifier = Self.incomingCategory
        content.userInfo = ["transferID": request.id.uuidString]
        content.sound = .default
        center.add(UNNotificationRequest(identifier: request.id.uuidString, content: content, trigger: nil))
    }

    /// A finished transfer. With `reveal`, clicking shows the file in Finder and the notification
    /// carries a thumbnail of it.
    func postResult(title: String, body: String, reveal: URL?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let reveal {
            content.categoryIdentifier = Self.resultCategory
            content.userInfo = ["reveal": reveal.path]
        }
        guard let reveal else {
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            return
        }
        // Post with a thumbnail if one is ready within a second, otherwise without.
        let center = self.center
        Self.thumbnailAttachment(for: reveal) { attachment in
            if let attachment { content.attachments = [attachment] }
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    /// Renders a small thumbnail into a temporary PNG. The notification system takes ownership of
    /// (moves) attachment files, so it gets this copy and never the received file itself.
    private static func thumbnailAttachment(for file: URL, completion: @escaping @MainActor (UNNotificationAttachment?) -> Void) {
        let once = Once()
        let finish: @Sendable (URL?) -> Void = { png in
            guard once.claim() else {
                if let png { try? FileManager.default.removeItem(at: png) }
                return
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    var attachment: UNNotificationAttachment?
                    if let png {
                        attachment = try? UNNotificationAttachment(identifier: "thumbnail", url: png, options: nil)
                        if attachment == nil { try? FileManager.default.removeItem(at: png) }
                    }
                    completion(attachment)
                }
            }
        }
        let request = QLThumbnailGenerator.Request(fileAt: file, size: CGSize(width: 128, height: 128),
                                                   scale: 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            guard let cgImage = representation?.cgImage else { return finish(nil) }
            let rep = NSBitmapImageRep(cgImage: cgImage)
            guard let data = rep.representation(using: .png, properties: [:]) else { return finish(nil) }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notification-thumbnails", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let png = folder.appendingPathComponent("\(UUID().uuidString).png")
            finish((try? data.write(to: png)) != nil ? png : nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { finish(nil) }
    }

    func remove(_ id: UUID) {
        center.removeDeliveredNotifications(withIdentifiers: [id.uuidString])
        center.removePendingNotificationRequests(withIdentifiers: [id.uuidString])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let actionID = response.actionIdentifier
        let transferID = (info["transferID"] as? String).flatMap(UUID.init(uuidString:))
        let revealPath = info["reveal"] as? String
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let revealPath {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: revealPath)])
                } else if let transferID {
                    switch actionID {
                    case Self.acceptAction: self.onAction?(.accept, transferID)
                    case Self.declineAction: self.onAction?(.decline, transferID)
                    default: self.onAction?(.open, transferID)
                    }
                }
            }
        }
        completionHandler()
    }
}

/// A flag that can be claimed once, from any thread.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
