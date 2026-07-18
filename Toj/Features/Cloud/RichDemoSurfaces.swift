import SwiftUI

struct TojPeerProfileView: View {
    @Bindable var model: CloudAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var notificationsEnabled = true
    @State private var showingBlockConfirmation = false

    let dialogId: String
    let onCall: () -> Void

    private var title: String { model.dialogTitle(dialogId) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    VStack(spacing: 10) {
                        TojAvatar(title: title, size: 82)
                        Text(title)
                            .font(TojTheme.heading(.title, weight: .bold))
                        Label("Private conversation", systemImage: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(TojTheme.secure)
                    }
                    .padding(.top, 12)

                    HStack(spacing: 12) {
                        profileAction("Audio", icon: "phone.fill") { onCall() }
                            .disabled(!model.capabilities.contains(.calls))
                            .opacity(model.capabilities.contains(.calls) ? 1 : 0.42)
                        profileAction("Video", icon: "video.slash.fill") {}
                            .disabled(true)
                            .opacity(0.42)
                        profileAction("Search", icon: "magnifyingglass") { dismiss() }
                    }

                    profileSection("Privacy") {
                        profileRow("Connection", detail: "Protected", icon: "lock.fill", iconTint: TojTheme.secure, detailColor: TojTheme.secure)
                        profileRow("Devices", detail: "Tap to inspect", icon: "checkmark.shield.fill")
                        profileRow("Verification", detail: "Available when connected", icon: "person.badge.shield.checkmark")
                    }

                    profileSection("Shared content") {
                        profileRow("Media", detail: "12", icon: "photo.on.rectangle")
                        profileRow("Files", detail: "4", icon: "doc.fill")
                        profileRow("Links", detail: "7", icon: "link")
                    }

                    profileSection("Conversation") {
                        Toggle(isOn: $notificationsEnabled) {
                            Label("Notifications", systemImage: notificationsEnabled ? "bell.fill" : "bell.slash.fill")
                        }
                        .tint(TojTheme.secure)
                        .padding(.horizontal, 15)
                        .frame(minHeight: 54)

                        Button(role: .destructive) { showingBlockConfirmation = true } label: {
                            Label("Block or report", systemImage: "hand.raised.fill")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .frame(minHeight: 54)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 15)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
            .background(TojTheme.canvas)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Block or report this contact?", isPresented: $showingBlockConfirmation, titleVisibility: .visible) {
                Button("Block", role: .destructive) {
                    Task {
                        if await model.blockPeer(dialogId: dialogId) { dismiss() }
                    }
                }
                Button("Report", role: .destructive) {}
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Blocking prevents new messages and voice calls in both directions.")
            }
        }
    }

    private func profileAction(_ title: LocalizedStringKey, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .tojGlass(in: Circle(), interactive: true)
                Text(title).font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.tojPressable)
        .foregroundStyle(TojTheme.text)
    }

    private func profileSection<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        TojSectionCard(title) { content() }
    }

    private func profileRow(_ title: LocalizedStringKey, detail: LocalizedStringKey, icon: String, iconTint: Color? = nil, detailColor: Color = TojTheme.secondaryText) -> some View {
        HStack(spacing: 12) {
            TojIconTile(systemImage: icon, tint: iconTint)
            Text(title)
            Spacer()
            Text(detail).font(.caption).foregroundStyle(detailColor)
            Image(systemName: "chevron.right").font(.caption2.bold()).foregroundStyle(TojTheme.secondaryText)
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 15)
        .frame(minHeight: 56)
        .overlay(alignment: .bottom) { Rectangle().fill(TojTheme.hairline).frame(height: 0.5).padding(.leading, 57) }
    }
}

struct TojDemoCallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CallViewState.Phase = .ringing
    @State private var isMuted = false
    @State private var isCameraEnabled = true
    @State private var isSpeakerEnabled = false

    let peerName: String

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x111318), TojTheme.canvas], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.down")
                        .frame(width: 46, height: 46)
                }
                .buttonStyle(.glass)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .accessibilityLabel("Minimize call")

                Spacer()

                ZStack {
                    if !reduceMotion, (phase == .ringing || phase == .connecting) {
                        Circle()
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                            .frame(width: 154, height: 154)
                            .scaleEffect(1.15)
                    }
                    TojAvatar(title: peerName, size: 122)
                }

                Text(peerName)
                    .font(TojTheme.heading(.title, weight: .bold))
                    .padding(.top, 22)
                Text(phaseTitle)
                    .font(.subheadline)
                    .foregroundStyle(TojTheme.secondaryText)
                    .padding(.top, 7)

                Spacer()

                HStack(spacing: 18) {
                    callControl(icon: isMuted ? "mic.slash.fill" : "mic.fill", title: "Mute", selected: isMuted) { isMuted.toggle() }
                    callControl(icon: isCameraEnabled ? "video.fill" : "video.slash.fill", title: "Camera", selected: !isCameraEnabled) { isCameraEnabled.toggle() }
                    callControl(icon: "speaker.wave.2.fill", title: "Speaker", selected: isSpeakerEnabled) { isSpeakerEnabled.toggle() }
                }

                Button {
                    phase = .ended
                    TojFeedback.sent()
                    Task {
                        try? await Task.sleep(for: .milliseconds(350))
                        dismiss()
                    }
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
        .task {
            try? await Task.sleep(for: .milliseconds(800))
            phase = .connecting
            try? await Task.sleep(for: .milliseconds(700))
            phase = .active
        }
    }

    private var phaseTitle: String {
        switch phase {
        case .ringing: String(localized: "Ringing…")
        case .connecting: String(localized: "Connecting securely…")
        case .active: String(localized: "00:01")
        case .reconnecting: String(localized: "Reconnecting…")
        case .declined: String(localized: "Declined")
        case .ended: String(localized: "Call ended")
        }
    }

    private func callControl(icon: String, title: LocalizedStringKey, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .semibold))
                    .frame(width: 54, height: 54)
                    .background(selected ? TojTheme.text : TojTheme.strong, in: Circle())
                    .foregroundStyle(selected ? TojTheme.canvas : TojTheme.text)
                Text(title).font(.caption)
            }
        }
        .buttonStyle(.tojPressable)
        .foregroundStyle(TojTheme.text)
    }
}

struct DemoGroupCreationView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var groupName = ""
    @State private var step = 0

    let dialogs: [CloudAppModel.Dialog]

    var body: some View {
        NavigationStack {
            Group {
                if step == 0 { memberSelection } else { groupDetails }
            }
            .background(TojTheme.canvas)
            .navigationTitle(step == 0 ? "New group" : "Group details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(step == 0 ? "Next" : "Create") {
                        if step == 0 { step = 1 } else { TojFeedback.sent(); dismiss() }
                    }
                    .disabled(step == 0 ? selected.isEmpty : groupName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private var memberSelection: some View {
        List(dialogs.filter { !$0.isArchived }) { dialog in
            Button {
                if selected.contains(dialog.id) { selected.remove(dialog.id) } else { selected.insert(dialog.id) }
            } label: {
                HStack(spacing: 12) {
                    TojAvatar(title: dialog.title, size: 44)
                    Text(dialog.title).foregroundStyle(TojTheme.text)
                    Spacer()
                    Image(systemName: selected.contains(dialog.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected.contains(dialog.id) ? TojTheme.secure : TojTheme.secondaryText)
                }
            }
            .listRowBackground(TojTheme.raised)
        }
        .scrollContentBackground(.hidden)
    }

    private var groupDetails: some View {
        VStack(spacing: 22) {
            TojAvatar(title: groupName.isEmpty ? "Group" : groupName, size: 88)
            TextField("Group name", text: $groupName)
                .padding(.horizontal, 16)
                .frame(height: 54)
                .background(TojTheme.raised, in: Capsule())
            Text("\(selected.count) members selected")
                .font(.subheadline)
                .foregroundStyle(TojTheme.secondaryText)
            Spacer()
        }
        .padding(22)
    }
}

struct DemoMediaViewer: View {
    @Environment(\.dismiss) private var dismiss
    let attachment: DemoAttachment

    var body: some View {
        ZStack {
            TojTheme.canvas.ignoresSafeArea()
            VStack {
                HStack {
                    Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 46, height: 46) }
                        .buttonStyle(.glass)
                        .accessibilityLabel("Close media")
                    Spacer()
                    Button {} label: { Image(systemName: "square.and.arrow.up").frame(width: 46, height: 46) }
                        .buttonStyle(.glass)
                        .accessibilityLabel("Share")
                }
                .padding()
                Spacer()
                Image(systemName: mediaIcon)
                    .font(.system(size: 96, weight: .ultraLight))
                    .foregroundStyle(TojTheme.text)
                Text(attachment.title)
                    .font(TojTheme.heading(.title3))
                    .padding(.top, 20)
                Spacer()
            }
        }
    }

    private var mediaIcon: String {
        switch attachment {
        case .photo: "photo"
        case .video: "play.rectangle"
        case .file: "doc"
        case .voice: "waveform"
        case .link: "link"
        }
    }
}

struct PresentationStateGallery: View {
    private let callStates: [(String, String)] = [
        (String(localized: "Ringing"), "phone.arrow.up.right.fill"),
        (String(localized: "Connecting"), "arrow.triangle.2.circlepath"),
        (String(localized: "Active"), "phone.fill"),
        (String(localized: "Reconnecting"), "wifi.exclamationmark"),
        (String(localized: "Declined"), "phone.down.fill"),
        (String(localized: "Ended"), "checkmark.circle.fill"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                gallerySection("Connection") {
                    stateRow("Protected", detail: "Connected", icon: "lock.fill", color: TojTheme.secure)
                    stateRow("Connecting…", detail: "Syncing", icon: "arrow.triangle.2.circlepath", color: TojTheme.secondaryText)
                    stateRow("Waiting for network", detail: "Messages are queued", icon: "wifi.slash", color: .orange)
                }

                gallerySection("Message delivery") {
                    stateRow("Queued", detail: "Clock", icon: "clock", color: TojTheme.secondaryText)
                    stateRow("Sent", detail: "Single check", icon: "checkmark", color: TojTheme.secondaryText)
                    stateRow("Seen", detail: "Confirmed", icon: "checkmark.circle.fill", color: TojTheme.secure)
                    stateRow("Failed", detail: "Tap for retry", icon: "exclamationmark.circle.fill", color: .red)
                }

                gallerySection("Rich content") {
                    DemoGalleryAttachment(attachment: .photo(name: "Photo preview"))
                    DemoGalleryAttachment(attachment: .file(name: "Document.pdf", size: "1.8 MB"))
                    DemoGalleryAttachment(attachment: .voice(duration: "0:08"))
                }

                gallerySection("Call lifecycle") {
                    ForEach(callStates, id: \.0) { state in
                        stateRow(state.0, detail: "Demo fixture", icon: state.1, color: TojTheme.text)
                    }
                }

                Label("These deterministic fixtures never call the production transport.", systemImage: "hammer.fill")
                    .font(.caption)
                    .foregroundStyle(TojTheme.secondaryText)
                    .padding(.horizontal, 5)
            }
            .padding(16)
            .padding(.bottom, 24)
        }
        .background(TojTheme.canvas)
        .navigationTitle("Interface states")
    }

    private func gallerySection<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        TojSectionCard(title) { content() }
    }

    private func stateRow(_ title: String, detail: String, icon: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 28)
            Text(title).font(.subheadline.weight(.medium))
            Spacer()
            Text(detail).font(.caption).foregroundStyle(TojTheme.secondaryText)
        }
        .padding(.horizontal, 15)
        .frame(minHeight: 52)
        .overlay(alignment: .bottom) { Rectangle().fill(TojTheme.hairline).frame(height: 0.5).padding(.leading, 55) }
        .accessibilityElement(children: .combine)
    }
}

private struct DemoGalleryAttachment: View {
    let attachment: DemoAttachment

    var body: some View {
        HStack(spacing: 12) {
            TojIconTile(systemImage: icon)
            Text(attachment.title).font(.subheadline.weight(.medium))
            Spacer()
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(TojTheme.secondaryText)
        }
        .padding(.horizontal, 13)
        .frame(minHeight: 58)
    }

    private var icon: String {
        switch attachment {
        case .photo: "photo.fill"
        case .video: "video.fill"
        case .file: "doc.fill"
        case .voice: "waveform"
        case .link: "link"
        }
    }
}
