import Foundation
import UIKit
import UserNotifications

/// Process-local bridge between UIApplicationDelegate callbacks and the signed-in cloud model.
/// APNs tokens are intentionally not cached on disk; Apple may rotate them at any registration.
@MainActor
final class PushRegistrationCenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PushRegistrationCenter()

    typealias TokenHandler = (_ token: String, _ environment: String) async -> Void
    typealias NotificationHandler = () async -> Bool

    private var tokenHandler: TokenHandler?
    private var notificationHandler: NotificationHandler?
    private var currentToken: String?

    nonisolated static var isEnabled: Bool {
        switch Bundle.main.object(forInfoDictionaryKey: "TOJPushEnabled") {
        case let value as Bool:
            return value
        case let value as String:
            return ["1", "true", "yes"].contains(value.lowercased())
        default:
            return false
        }
    }

    static var environment: String {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }

    nonisolated static func hexadecimalToken(from data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    func install() {
        guard Self.isEnabled else { return }
        UNUserNotificationCenter.current().delegate = self
        refreshRegistration()
    }

    func bind(tokenHandler: @escaping TokenHandler, notificationHandler: @escaping NotificationHandler) {
        self.tokenHandler = tokenHandler
        self.notificationHandler = notificationHandler
        if let currentToken {
            Task { await tokenHandler(currentToken, Self.environment) }
        }
    }

    func requestAuthorization() async {
        guard Self.isEnabled else { return }
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            // A denied or failed prompt must not affect messaging. Foreground/icon-open sync remains authoritative.
        }
        refreshRegistration()
    }

    func refreshRegistration() {
        guard Self.isEnabled else { return }
        UIApplication.shared.registerForRemoteNotifications()
        deliverCurrentToken()
    }

    func receivedDeviceToken(_ data: Data) {
        guard Self.isEnabled else { return }
        let token = Self.hexadecimalToken(from: data)
        currentToken = token
        deliverCurrentToken()
    }

    func registrationFailed(_ error: Error) {
        // Registration is retried on the next launch/authorization attempt. Never log a device token.
        NSLog("APNs registration failed: %@", error.localizedDescription)
    }

    func handleRemoteNotification() async -> Bool {
        guard Self.isEnabled else { return false }
        return await notificationHandler?() ?? false
    }

    private func deliverCurrentToken() {
        guard let currentToken, let tokenHandler else { return }
        Task { await tokenHandler(currentToken, Self.environment) }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
        Task { @MainActor in
            _ = await handleRemoteNotification()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        completionHandler()
        Task { @MainActor in
            _ = await handleRemoteNotification()
        }
    }
}
