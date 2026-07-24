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
            payload.type == "voice_call" || payload.type == "video_call"
        else {
            return Self(title: String(localized: "Voice call"), systemImage: "phone.fill", duration: nil)
        }
        let isVideo = payload.type == "video_call"
        let callName = isVideo ? String(localized: "video call") : String(localized: "voice call")
        let callerIsCurrentAccount = currentAccountId.flatMap { current in
            payload.callerAccountId.map { $0 == current }
        } ?? fallbackCallerIsCurrentAccount

        let title: String
        let icon: String
        switch payload.outcome {
        case "completed":
            title = callerIsCurrentAccount
                ? String(localized: "Outgoing \(callName)")
                : String(localized: "Incoming \(callName)")
            icon = isVideo ? "video.fill"
                : callerIsCurrentAccount ? "phone.arrow.up.right.fill" : "phone.arrow.down.left.fill"
        case "declined":
            title = callerIsCurrentAccount
                ? String(localized: "\(callName.capitalized) declined")
                : String(localized: "Declined \(callName)")
            icon = "phone.down.fill"
        case "missed":
            title = callerIsCurrentAccount
                ? String(localized: "Unanswered \(callName)")
                : String(localized: "Missed \(callName)")
            icon = "phone.badge.xmark.fill"
        case "busy":
            title = String(localized: "Line busy")
            icon = "phone.down.fill"
        case "cancelled":
            title = String(localized: "Cancelled \(callName)")
            icon = "phone.down.fill"
        case "failed":
            title = String(localized: "\(callName.capitalized) failed")
            icon = "exclamationmark.phone.fill"
        default:
            title = callName.capitalized
            icon = isVideo ? "video.fill" : "phone.fill"
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
            (payload.type == "voice_call" || payload.type == "video_call"),
            let callerAccountId = payload.callerAccountId
        else { return nil }
        return callerAccountId == currentAccountId
    }
}
