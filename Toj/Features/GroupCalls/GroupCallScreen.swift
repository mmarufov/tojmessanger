import SwiftUI

struct TojGroupCallScreen: View {
    @Bindable var coordinator: GroupCallCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var removalCandidate: GroupCallPresentationParticipant?

    private var controlWidth: CGFloat { dynamicTypeSize.isAccessibilitySize ? 112 : 78 }
    private var controlHeight: CGFloat { dynamicTypeSize.isAccessibilitySize ? 76 : 58 }

    private var screenTrack: GroupCallVideoTrackReference? {
        coordinator.videoTracks.first(where: { $0.source == .screenShare })
    }

    private var gridColumns: [GridItem] {
        let count = coordinator.participants.count
        return Array(
            repeating: GridItem(.flexible(), spacing: 8),
            count: count <= 1 || dynamicTypeSize.isAccessibilitySize ? 1 : 2
        )
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black, TojTheme.base.opacity(0.98), Color.black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                callHeader
                    .padding(.horizontal, 18)
                    .padding(.top, 12)

                Group {
                    if coordinator.state == .failed || coordinator.state == .ended {
                        terminalView
                    } else if let screenTrack {
                        screenShareLayout(screenTrack)
                    } else {
                        participantGrid
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                controls
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
            }
        }
        .interactiveDismissDisabled(coordinator.hasActiveCall)
        .statusBarHidden()
        .animation(reduceMotion ? nil : .snappy, value: coordinator.videoTracks.map(\.id))
        .animation(reduceMotion ? nil : .snappy, value: coordinator.participants)
        .confirmationDialog(
            "Remove participant?",
            isPresented: Binding(
                get: { removalCandidate != nil },
                set: { if !$0 { removalCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let participant = removalCandidate {
                Button("Remove \(participant.displayName)", role: .destructive) {
                    removalCandidate = nil
                    Task { await coordinator.removeParticipant(deviceId: participant.id) }
                }
            }
            Button("Cancel", role: .cancel) { removalCandidate = nil }
        } message: {
            Text("They will be removed from this call. Group membership is unchanged.")
        }
    }

    private var callHeader: some View {
        HStack(spacing: 12) {
            Button {
                coordinator.isPresented = false
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 17, weight: .bold))
                    .frame(width: 46, height: 46)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Minimize group call")

            VStack(alignment: .leading, spacing: 3) {
                Text(coordinator.title)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if coordinator.weakNetwork {
                        Label("Weak network", systemImage: "wifi.exclamationmark")
                            .labelStyle(.titleAndIcon)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
            }
            Spacer()
            if !coordinator.safetyEmojis.isEmpty {
                Text(coordinator.safetyEmojis.joined())
                    .font(.system(size: 17))
                    .accessibilityLabel(
                        "Encryption verification symbols " + coordinator.safetyEmojis.joined(separator: ", ")
                    )
            }
            Menu {
                Button("Leave call", role: .destructive) { Task { await coordinator.leave() } }
                if coordinator.canManageGroupCall {
                    Button("End for everyone", role: .destructive) {
                        Task { await coordinator.endForEveryone() }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .bold))
                    .frame(width: 46, height: 46)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("More call actions")
        }
        .foregroundStyle(.white)
    }

    private var participantGrid: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: 8) {
                ForEach(coordinator.participants) { participant in
                    participantTile(participant)
                        .aspectRatio(coordinator.participants.count == 1 ? 0.78 : 0.88, contentMode: .fit)
                }
            }
            .padding(12)
        }
    }

    private func screenShareLayout(_ track: GroupCallVideoTrackReference) -> some View {
        VStack(spacing: 10) {
            GroupCallVideoRenderer(reference: track, fill: false)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(.white.opacity(0.12), lineWidth: 1)
                }
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .accessibilityLabel("Shared screen")

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(coordinator.participants) { participant in
                        participantTile(participant)
                            .frame(width: 126, height: 150)
                    }
                }
                .padding(.horizontal, 10)
            }
            .frame(height: 160)
        }
    }

    private func participantTile(_ participant: GroupCallPresentationParticipant) -> some View {
        let track = coordinator.videoTracks.first {
            $0.participantId == participant.participantId && $0.source == .camera
        }
        return ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white.opacity(0.07))
            if let track {
                GroupCallVideoRenderer(reference: track)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            } else {
                VStack(spacing: 12) {
                    Circle()
                        .fill(TojTheme.gold.opacity(0.18))
                        .frame(width: 72, height: 72)
                        .overlay {
                            Text(initials(participant.displayName))
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(TojTheme.gold)
                        }
                    if !participant.hasCamera {
                        Image(systemName: "video.slash.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 6) {
                if participant.isSpeaking {
                    Image(systemName: "waveform")
                        .foregroundStyle(TojTheme.secure)
                }
                Text(participant.isSelf ? "You" : participant.displayName)
                    .lineLimit(1)
                if participant.connectionQuality == "poor" || participant.connectionQuality == "lost" {
                    Image(systemName: "wifi.exclamationmark")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(9)
        }
        .contextMenu {
            if coordinator.canManageGroupCall && !participant.isSelf {
                Button("Remove from call", role: .destructive) {
                    removalCandidate = participant
                }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(
                    participant.isSpeaking ? TojTheme.secure : .white.opacity(0.08),
                    lineWidth: participant.isSpeaking ? 2 : 1
                )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(participant.isSelf ? "You" : participant.displayName), "
                + (participant.isSpeaking ? "speaking" : "not speaking")
                + (participant.hasCamera ? ", camera on" : ", camera off")
        )
    }

    private var controls: some View {
        VStack(spacing: 10) {
            if let failure = coordinator.failureMessage,
               coordinator.state != .failed, coordinator.state != .ended {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    controlButton(
                        coordinator.isMuted ? "Unmute" : "Mute",
                        systemImage: coordinator.isMuted ? "mic.slash.fill" : "mic.fill",
                        active: !coordinator.isMuted
                    ) { Task { await coordinator.toggleMute() } }

                    controlButton(
                        coordinator.isCameraEnabled ? "Camera off" : "Camera on",
                        systemImage: coordinator.isCameraEnabled ? "video.fill" : "video.slash.fill",
                        active: coordinator.isCameraEnabled
                    ) { Task { await coordinator.toggleCamera() } }

                    if coordinator.isCameraEnabled {
                        controlButton("Flip", systemImage: "camera.rotate.fill", active: false) {
                            Task { await coordinator.switchCamera() }
                        }
                    }

                    if coordinator.canShareScreen {
                        controlButton(
                            coordinator.isScreenSharing ? "Stop share" : "Share screen",
                            systemImage: coordinator.isStartingScreenShare
                                ? "hourglass" : "rectangle.on.rectangle",
                            active: coordinator.isScreenSharing || coordinator.isStartingScreenShare
                        ) { Task { await coordinator.toggleScreenShare() } }
                    }

                    Button(role: .destructive) { Task { await coordinator.leave() } } label: {
                        VStack(spacing: 5) {
                            Image(systemName: "phone.down.fill")
                                .font(.system(size: 18, weight: .bold))
                            Text("Leave").font(.caption2.weight(.semibold))
                        }
                        .frame(width: controlWidth, height: controlHeight)
                        .background(TojTheme.danger, in: RoundedRectangle(cornerRadius: TojRadius.field))
                        .foregroundStyle(.white)
                    }
                    .accessibilityLabel("Leave group call")
                }
                .padding(.horizontal, 2)
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private func controlButton(
        _ title: String,
        systemImage: String,
        active: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .semibold))
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .multilineTextAlignment(.center)
            }
            .frame(width: controlWidth, height: controlHeight)
            .background(
                active ? TojTheme.gold.opacity(0.95) : Color.white.opacity(0.1),
                in: RoundedRectangle(cornerRadius: TojRadius.field)
            )
            .foregroundStyle(active ? Color.black : Color.white)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var terminalView: some View {
        VStack(spacing: 18) {
            Image(systemName: coordinator.state == .failed ? "exclamationmark.shield.fill" : "phone.down.fill")
                .font(.system(size: 48))
                .foregroundStyle(coordinator.state == .failed ? .orange : .secondary)
            Text(coordinator.state == .failed ? "Call closed" : "Call ended")
                .font(.title2.bold())
            if let message = coordinator.failureMessage {
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }
            Button("Done") { coordinator.dismissEndedCall() }
                .buttonStyle(.borderedProminent)
                .tint(TojTheme.gold)
                .foregroundStyle(.black)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusText: String {
        switch coordinator.state {
        case .idle: "Ready"
        case .preparing: "Preparing encrypted call"
        case .waitingForKey: "Securing the room"
        case .connecting: "Connecting"
        case .connected:
            switch coordinator.securityState {
            case .verified:
                "\(coordinator.participants.count) in call · end-to-end encrypted"
            case .keyReady:
                "Encryption ready · checking media"
            case .preparing, .rekeying:
                "Securing the room"
            case .failed:
                "Security check failed"
            }
        case .reconnecting: "Reconnecting — audio prioritized"
        case .ending: "Leaving"
        case .ended: "Ended"
        case .failed: "Security check failed"
        }
    }

    private var statusColor: Color {
        switch coordinator.state {
        case .connected: coordinator.securityState == .verified ? .green : .orange
        case .reconnecting, .waitingForKey: .orange
        case .failed: .red
        default: .secondary
        }
    }

    private func initials(_ name: String) -> String {
        let words = name.split(separator: " ").prefix(2)
        let value = words.compactMap(\.first).map(String.init).joined()
        return value.isEmpty ? "?" : value.uppercased()
    }
}

struct TojActiveGroupCallPill: View {
    @Bindable var coordinator: GroupCallCoordinator

    var body: some View {
        Button { coordinator.isPresented = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "person.3.fill")
                    .foregroundStyle(TojTheme.secure)
                VStack(alignment: .leading, spacing: 1) {
                    Text(coordinator.title).font(.subheadline.weight(.semibold))
                    Text(coordinator.securityState == .verified
                         ? "\(coordinator.participants.count) in end-to-end encrypted call"
                         : "\(coordinator.participants.count) in group call · checking encryption")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.up")
                    .font(.caption.bold())
            }
            .padding(.horizontal, 14)
            .frame(height: 52)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Return to \(coordinator.title) group call")
    }
}
