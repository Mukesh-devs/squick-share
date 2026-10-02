import AppKit
import QuickShareCore
import UserNotifications

/// System notifications: incoming requests (with Accept/Decline) and transfer results.
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    enum Action { case accept, decline, open }

    private static let incomingCategory = "INCOMING"
    private static let resultCategory = "RESULT"
    private static let acceptAction = "ACCEPT"
    private static let declineAction = "DECLINE"
    private static let revealAction = "REVEAL"

    var onAction: ((Action, UUID) -> Void)?
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
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func postIncoming(_ request: IncomingTransferRequest) {
        let content = UNMutableNotificationContent()
        content.title = "\(request.device.name) wants to share"
        let items = Format.summary(files: request.files.map(\.name), texts: request.texts.count)
        let size = request.totalBytes > 0 ? " (\(Format.bytes(request.totalBytes)))" : ""
        content.body = "\(items)\(size). PIN \(request.pin)"
        content.categoryIdentifier = Self.incomingCategory
        content.userInfo = ["transferID": request.id.uuidString]
        content.sound = .default
        center.add(UNNotificationRequest(identifier: request.id.uuidString, content: content, trigger: nil))
    }

    func postResult(title: String, body: String, reveal: URL?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let reveal {
            content.categoryIdentifier = Self.resultCategory
            content.userInfo = ["reveal": reveal.path]
        }
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
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
