import Foundation

struct MessagingCapabilities: OptionSet, Sendable, Equatable {
    let rawValue: UInt16

    static let chatOrganization = Self(rawValue: 1 << 0)
    static let replies = Self(rawValue: 1 << 1)
    static let editing = Self(rawValue: 1 << 2)
    static let deletion = Self(rawValue: 1 << 3)
    static let forwarding = Self(rawValue: 1 << 4)
    static let reactions = Self(rawValue: 1 << 5)
    static let media = Self(rawValue: 1 << 6)
    static let voiceNotes = Self(rawValue: 1 << 7)
    static let groups = Self(rawValue: 1 << 8)
    static let calls = Self(rawValue: 1 << 9)
    static let profiles = Self(rawValue: 1 << 10)
    static let richSearch = Self(rawValue: 1 << 11)

    static let productionText: Self = []
    static let demo: Self = [
        .chatOrganization, .replies, .editing, .deletion, .forwarding,
        .reactions, .media, .voiceNotes, .groups, .calls, .profiles, .richSearch,
    ]
}

enum MessageAction: String, CaseIterable, Identifiable, Sendable {
    case reply
    case react
    case copy
    case edit
    case forward
    case delete
    case retry
    case inspect

    var id: String { rawValue }

    var title: String {
        switch self {
        case .reply: String(localized: "Reply")
        case .react: String(localized: "React")
        case .copy: String(localized: "Copy")
        case .edit: String(localized: "Edit")
        case .forward: String(localized: "Forward")
        case .delete: String(localized: "Delete")
        case .retry: String(localized: "Retry")
        case .inspect: String(localized: "Details")
        }
    }

    var systemImage: String {
        switch self {
        case .reply: "arrowshape.turn.up.left"
        case .react: "face.smiling"
        case .copy: "doc.on.doc"
        case .edit: "pencil"
        case .forward: "arrowshape.turn.up.right"
        case .delete: "trash"
        case .retry: "arrow.clockwise"
        case .inspect: "info.circle"
        }
    }
}

enum ComposerMode: Equatable, Sendable {
    case text
    case replying(messageId: String, preview: String)
    case editing(messageId: String, original: String)
    case recording(elapsedSeconds: Int)
    case attachmentPreview(DemoAttachment)
    case uploading(DemoAttachment, progress: Double)
    case disabled(reason: String)
}

enum ConnectionViewState: Equatable, Sendable {
    case connected
    case connecting
    case offline

    var title: String {
        switch self {
        case .connected: String(localized: "Protected")
        case .connecting: String(localized: "Connecting…")
        case .offline: String(localized: "Waiting for network")
        }
    }

    var systemImage: String {
        switch self {
        case .connected: "lock.fill"
        case .connecting: "arrow.triangle.2.circlepath"
        case .offline: "wifi.slash"
        }
    }
}

enum SearchScope: String, CaseIterable, Identifiable, Sendable {
    case chats
    case people
    case messages
    case media
    case links
    case files

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chats: String(localized: "Chats")
        case .people: String(localized: "People")
        case .messages: String(localized: "Messages")
        case .media: String(localized: "Media")
        case .links: String(localized: "Links")
        case .files: String(localized: "Files")
        }
    }
}

enum DemoAttachment: Equatable, Sendable {
    case photo(name: String)
    case video(name: String, duration: String)
    case file(name: String, size: String)
    case voice(duration: String)
    case link(title: String, host: String)

    var title: String {
        switch self {
        case let .photo(name), let .video(name, _), let .file(name, _): name
        case let .voice(duration): String(localized: "Voice message \(duration)")
        case let .link(title, _): title
        }
    }
}

struct ChatListViewState: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case loading
        case empty
        case content
        case error(message: String)
        case partial(message: String)
    }

    let phase: Phase
    let query: String
    let scope: SearchScope
}

struct ConversationViewState: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case loading
        case empty
        case content
        case error(message: String)
        case partial(message: String)
    }

    let phase: Phase
    let connection: ConnectionViewState
    let unreadBelow: Int
}

struct ComposerViewState: Equatable, Sendable {
    let mode: ComposerMode
    let text: String
    let canSend: Bool
}

struct MessageViewState: Equatable, Identifiable, Sendable {
    let id: String
    let text: String
    let isMine: Bool
    let availableActions: [MessageAction]
}

struct ProfileViewState: Equatable, Sendable {
    let title: String
    let subtitle: String
    let sharedMediaCount: Int
    let sharedFileCount: Int
    let sharedLinkCount: Int
}

struct CallViewState: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case ringing
        case connecting
        case active
        case reconnecting
        case declined
        case ended
    }

    let peerName: String
    let phase: Phase
    let isMuted: Bool
    let isCameraEnabled: Bool
}
