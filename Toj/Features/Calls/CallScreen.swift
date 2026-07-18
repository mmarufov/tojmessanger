import SwiftUI

struct TojCallScreen: View {
    @Bindable var coordinator: CallCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingSecurityConfirmation = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: 0x111318), TojTheme.canvas],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Button { coordinator.minimize() } label: {
                    Image(systemName: "chevron.down")
                        .frame(width: 46, height: 46)
                }
                .buttonStyle(.glass)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .accessibilityLabel("Minimize call")
                .disabled(coordinator.state == .ended)

                Spacer()

                ZStack {
                    if !reduceMotion && coordinator.state != .active && coordinator.state != .ended {
                        Circle()
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                            .frame(width: 154, height: 154)
                            .scaleEffect(1.15)
                    }
                    TojAvatar(title: coordinator.peerName, size: 122)
                }

                Text(coordinator.peerName)
                    .font(TojTheme.heading(.title, weight: .bold))
                    .padding(.top, 22)

                callStatus
                    .font(.subheadline)
                    .foregroundStyle(statusColor)
                    .padding(.top, 7)

                if !coordinator.securityEmojis.isEmpty {
                    Button { showingSecurityConfirmation = true } label: {
                        VStack(spacing: 5) {
                            Text(coordinator.securityEmojis.joined(separator: "  "))
                                .font(.title3)
                            Text(coordinator.securityVerified ? "Verified for this call" : "Compare these emojis")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(coordinator.securityVerified ? TojTheme.secure : TojTheme.secondaryText)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(TojTheme.strong, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.tojPressable)
                    .disabled(!coordinator.canVerifySecurity)
                    .padding(.top, 18)
                    .accessibilityHint("Compare all four emojis with the person on the call")
                }

                if let failure = coordinator.failureMessage, coordinator.state == .ended {
                    Text(failure)
                        .font(.footnote)
                        .foregroundStyle(TojTheme.danger)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 34)
                        .padding(.top, 14)
                }

                Spacer()

                HStack(spacing: 18) {
                    control(
                        icon: coordinator.isMuted ? "mic.slash.fill" : "mic.fill",
                        title: "Mute",
                        selected: coordinator.isMuted
                    ) { Task { await coordinator.toggleMute() } }
                    control(
                        icon: coordinator.isSpeakerEnabled ? "speaker.wave.3.fill" : "speaker.wave.2.fill",
                        title: coordinator.audioRouteName,
                        selected: coordinator.isSpeakerEnabled
                    ) { Task { await coordinator.toggleSpeaker() } }
                }
                .disabled(coordinator.state == .ending || coordinator.state == .ended)

                if coordinator.state == .ended {
                    Button("Done") { coordinator.dismissEnded() }
                        .font(.headline)
                        .foregroundStyle(TojTheme.onAccent)
                        .frame(width: 150, height: 54)
                        .background(TojTheme.accent, in: Capsule())
                        .buttonStyle(.tojPressable)
                        .padding(.top, 34)
                        .padding(.bottom, 46)
                } else {
                    Button {
                        Task { await coordinator.requestEnd() }
                    } label: {
                        Image(systemName: "phone.down.fill")
                            .font(.system(size: 22, weight: .bold))
                            .frame(width: 68, height: 68)
                            .background(TojTheme.danger, in: Circle())
                    }
                    .buttonStyle(.tojPressable)
                    .padding(.top, 34)
                    .padding(.bottom, 46)
                    .accessibilityLabel("End call")
                }
            }
        }
        .interactiveDismissDisabled(coordinator.state != .ended)
        .confirmationDialog(
            "Do the four emojis match?",
            isPresented: $showingSecurityConfirmation,
            titleVisibility: .visible
        ) {
            Button("They match") { coordinator.markSecurityVerified() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Compare them aloud with the other person. A mismatch can indicate interference with this call.")
        }
    }

    @ViewBuilder
    private var callStatus: some View {
        if coordinator.state == .active, let connectedAt = coordinator.connectedAt {
            TimelineView(.periodic(from: connectedAt, by: 1)) { context in
                Text(duration(from: connectedAt, to: context.date))
                    .contentTransition(.numericText())
            }
        } else {
            Text(statusTitle)
        }
    }

    private var statusTitle: String {
        switch coordinator.state {
        case .idle: String(localized: "Call ended")
        case .preparing: String(localized: "Preparing secure call…")
        case .outgoingRinging: String(localized: "Ringing…")
        case .incomingRinging: String(localized: "Incoming voice call")
        case .keyExchange: String(localized: "Securing call…")
        case .connecting: String(localized: "Connecting…")
        case .active: String(localized: "Connected")
        case .reconnecting: String(localized: "Reconnecting…")
        case .ending: String(localized: "Ending call…")
        case .ended: endTitle
        }
    }

    private var endTitle: String {
        switch coordinator.endReason {
        case .declined: String(localized: "Declined")
        case .busy: String(localized: "Line busy")
        case .unanswered: String(localized: "No answer")
        case .answeredElsewhere: String(localized: "Answered on another device")
        case .networkLost: String(localized: "Connection lost")
        case .securityError: String(localized: "Security check failed")
        default: String(localized: "Call ended")
        }
    }

    private var statusColor: Color {
        coordinator.state == .ended && coordinator.failureMessage != nil
            ? TojTheme.danger : TojTheme.secondaryText
    }

    private func duration(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        if seconds >= 3_600 {
            return String(format: "%d:%02d:%02d", seconds / 3_600, (seconds / 60) % 60, seconds % 60)
        }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func control(
        icon: String,
        title: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .semibold))
                    .frame(width: 54, height: 54)
                    .background(selected ? TojTheme.text : TojTheme.strong, in: Circle())
                    .foregroundStyle(selected ? TojTheme.canvas : TojTheme.text)
                Text(title).font(.caption).lineLimit(1)
            }
            .frame(width: 94)
        }
        .buttonStyle(.tojPressable)
        .foregroundStyle(TojTheme.text)
    }
}

struct TojActiveCallPill: View {
    @Bindable var coordinator: CallCoordinator

    var body: some View {
        Button { coordinator.present() } label: {
            HStack(spacing: 9) {
                Image(systemName: "phone.fill")
                Text(coordinator.peerName)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(coordinator.state == .reconnecting ? "Reconnecting…" : "Return to call")
                    .font(.caption)
                    .foregroundStyle(TojTheme.secondaryText)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(TojTheme.text)
            .padding(.horizontal, 15)
            .frame(height: 48)
            .background(TojTheme.raised, in: Capsule())
            .overlay(Capsule().stroke(TojTheme.secure.opacity(0.5), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 15, y: 8)
        }
        .buttonStyle(.tojPressable)
        .accessibilityLabel("Return to voice call with \(coordinator.peerName)")
    }
}
