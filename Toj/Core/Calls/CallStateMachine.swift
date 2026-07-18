import Foundation

nonisolated enum CallEvent: Equatable, Sendable {
    case startOutgoing
    case outgoingStarted
    case receiveIncoming
    case accept
    case remoteAccepted
    case keysConfirmed
    case mediaConnected
    case mediaDisconnected
    case mediaRecovered
    case endRequested
    case terminated(CallEndReason)
    case reset
}

nonisolated enum CallStateMachineError: Error, Equatable {
    case invalidTransition(state: CallState, event: CallEvent)
}

/// A deliberately side-effect-free reducer. CallKit, signaling and media
/// adapters perform work only after this reducer accepts an event.
nonisolated struct CallStateMachine: Equatable, Sendable {
    private(set) var state: CallState = .idle
    private(set) var direction: CallDirection?
    private(set) var endReason: CallEndReason?

    mutating func handle(_ event: CallEvent) throws {
        switch (state, event) {
        case (.idle, .startOutgoing):
            direction = .outgoing
            endReason = nil
            state = .preparing

        case (.preparing, .outgoingStarted):
            state = .outgoingRinging

        case (.idle, .receiveIncoming):
            direction = .incoming
            endReason = nil
            state = .incomingRinging

        case (.incomingRinging, .accept),
             (.outgoingRinging, .remoteAccepted):
            state = .keyExchange

        case (.keyExchange, .keysConfirmed):
            state = .connecting

        case (.connecting, .mediaConnected),
             (.reconnecting, .mediaConnected),
             (.reconnecting, .mediaRecovered):
            state = .active

        case (.active, .mediaDisconnected):
            state = .reconnecting

        case (.preparing, .endRequested),
             (.outgoingRinging, .endRequested),
             (.incomingRinging, .endRequested),
             (.keyExchange, .endRequested),
             (.connecting, .endRequested),
             (.active, .endRequested),
             (.reconnecting, .endRequested):
            state = .ending

        case (.preparing, .terminated(let reason)),
             (.outgoingRinging, .terminated(let reason)),
             (.incomingRinging, .terminated(let reason)),
             (.keyExchange, .terminated(let reason)),
             (.connecting, .terminated(let reason)),
             (.active, .terminated(let reason)),
             (.reconnecting, .terminated(let reason)),
             (.ending, .terminated(let reason)):
            endReason = reason
            state = .ended

        case (.ended, .reset):
            state = .idle
            direction = nil
            endReason = nil

        // Idempotent callbacks are expected from CallKit and the network.
        case (.preparing, .startOutgoing),
             (.outgoingRinging, .outgoingStarted),
             (.incomingRinging, .receiveIncoming),
             (.keyExchange, .accept),
             (.keyExchange, .remoteAccepted),
             (.connecting, .keysConfirmed),
             (.active, .mediaConnected),
             (.active, .mediaRecovered),
             (.reconnecting, .mediaDisconnected),
             (.ending, .endRequested),
             (.ended, .terminated),
             (.idle, .reset):
            break

        default:
            throw CallStateMachineError.invalidTransition(state: state, event: event)
        }
    }
}
