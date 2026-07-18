import Foundation

nonisolated struct VoiceCallServicePayload: Codable, Equatable, Sendable {
    let v: Int
    let type: String
    let callId: String
    let callerAccountId: String?
    let outcome: String
    let durationSeconds: Int?
}

nonisolated struct VoiceCallServicePresentation: Equatable, Sendable {
    let title: String
    let systemImage: String
    let duration: String?

    static func parse(
        body: String,
        callerIsCurrentAccount fallbackCallerIsCurrentAccount: Bool,
        currentAccountId: String? = nil
    ) -> Self {
        guard
            let data = body.data(using: .utf8),
            let payload = try? JSONDecoder().decode(VoiceCallServicePayload.self, from: data),
            payload.v == 1,
            payload.type == "voice_call"
        else {
            return Self(title: String(localized: "Voice call"), systemImage: "phone.fill", duration: nil)
        }
        let callerIsCurrentAccount = currentAccountId.flatMap { current in
            payload.callerAccountId.map { $0 == current }
        } ?? fallbackCallerIsCurrentAccount

        let title: String
        let icon: String
        switch payload.outcome {
        case "completed":
            title = callerIsCurrentAccount
                ? String(localized: "Outgoing voice call")
                : String(localized: "Incoming voice call")
            icon = callerIsCurrentAccount ? "phone.arrow.up.right.fill" : "phone.arrow.down.left.fill"
        case "declined":
            title = callerIsCurrentAccount
                ? String(localized: "Voice call declined")
                : String(localized: "Declined voice call")
            icon = "phone.down.fill"
        case "missed":
            title = callerIsCurrentAccount
                ? String(localized: "Unanswered voice call")
                : String(localized: "Missed voice call")
            icon = "phone.badge.xmark.fill"
        case "busy":
            title = String(localized: "Line busy")
            icon = "phone.down.fill"
        case "cancelled":
            title = String(localized: "Cancelled voice call")
            icon = "phone.down.fill"
        case "failed":
            title = String(localized: "Voice call failed")
            icon = "exclamationmark.phone.fill"
        default:
            title = String(localized: "Voice call")
            icon = "phone.fill"
        }

        let duration = payload.durationSeconds.flatMap { seconds -> String? in
            guard seconds >= 0, payload.outcome == "completed" else { return nil }
            if seconds >= 3_600 {
                return String(format: "%d:%02d:%02d", seconds / 3_600, (seconds / 60) % 60, seconds % 60)
            }
            return String(format: "%02d:%02d", seconds / 60, seconds % 60)
        }
        return Self(title: title, systemImage: icon, duration: duration)
    }

    static func callerIsCurrentAccount(body: String, currentAccountId: String?) -> Bool? {
        guard
            let currentAccountId,
            let data = body.data(using: .utf8),
            let payload = try? JSONDecoder().decode(VoiceCallServicePayload.self, from: data),
            payload.v == 1,
            payload.type == "voice_call",
            let callerAccountId = payload.callerAccountId
        else { return nil }
        return callerAccountId == currentAccountId
    }
}
