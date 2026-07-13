import SwiftUI
import AVFoundation
import AVKit
import PhotosUI
import UniformTypeIdentifiers
import UIKit

struct TojConversationExperience: View {
    @Bindable var model: CloudAppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var composerFocused: Bool
    @State private var showingProfile = false
    @State private var showingAttachments = false
    @State private var showingForwarding = false
    @State private var forwardLine: CloudAppModel.Line?
    @State private var showingCall = false
    @State private var detailsLine: CloudAppModel.Line?
    @State private var deleteLine: CloudAppModel.Line?
    @State private var reactionLine: CloudAppModel.Line?
    @State private var initialUnreadCount = 0
    @State private var isAtBottom = true

    let dialogId: String

    private var canSend: Bool {
        model.activeDialogId == dialogId
            && !model.composerMode.isRecording
            && !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            messageTimeline
        }
        .background(TojTheme.canvas)
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .task(id: dialogId) {
            initialUnreadCount = model.dialogs.first(where: { $0.id == dialogId })?.unreadCount ?? 0
            await model.selectDialog(dialogId)
        }
        .onDisappear { model.deselectDialog(dialogId) }
        .sheet(isPresented: $showingProfile) {
            TojPeerProfileView(model: model, dialogId: dialogId) {
                showingProfile = false
                showingCall = true
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingAttachments) {
            Group {
            #if DEBUG
                if model.isDemoMode {
                    DemoAttachmentPicker { attachment in
                        model.sendDemoAttachment(attachment)
                        showingAttachments = false
                    }
                } else {
                    ProductionAttachmentPicker(model: model) { showingAttachments = false }
                }
            #else
                ProductionAttachmentPicker(model: model) { showingAttachments = false }
            #endif
            }
            .presentationDetents([.height(390)])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingForwarding) {
            DemoForwardingView(dialogs: model.dialogs) { targetDialogId in
                if let forwardLine {
                    Task { await model.forwardMessage(forwardLine, to: targetDialogId) }
                }
                forwardLine = nil
                showingForwarding = false
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $showingCall) {
            TojDemoCallView(peerName: model.dialogTitle(dialogId))
        }
        .alert("Delete message?", isPresented: Binding(
            get: { deleteLine != nil },
            set: { if !$0 { deleteLine = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let deleteLine { Task { await model.deleteMessage(deleteLine) } }
                deleteLine = nil
            }
            Button("Cancel", role: .cancel) { deleteLine = nil }
        } message: {
            Text("This removes the message for everyone in this conversation.")
        }
        .confirmationDialog(
            "Choose a reaction",
            isPresented: Binding(
                get: { reactionLine != nil },
                set: { if !$0 { reactionLine = nil } }
            ),
            titleVisibility: .visible
        ) {
            ForEach(["❤️", "👍", "😂", "🔥", "😮", "😢"], id: \.self) { reaction in
                Button(reactionLine?.myReaction == reaction ? "Remove \(reaction)" : reaction) {
                    if let reactionLine {
                        Task { await model.reactToMessage(reactionLine, reaction: reaction) }
                    }
                    reactionLine = nil
                }
            }
            Button("Cancel", role: .cancel) { reactionLine = nil }
        }
        .sheet(item: $detailsLine) { line in
            MessageDetailsView(line: line)
                .presentationDetents([.height(310)])
                .presentationDragIndicator(.visible)
        }
    }

    private var header: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .bold))
                        .frame(width: 46, height: 46)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Back")

                Button { showingProfile = model.capabilities.contains(.profiles) } label: {
                    VStack(spacing: 1) {
                        Text(model.dialogTitle(dialogId))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(TojTheme.text)
                            .lineLimit(1)
                        Label(model.connectionViewState.title, systemImage: model.connectionViewState.systemImage)
                            .font(.caption2)
                            .foregroundStyle(connectionColor)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .padding(.horizontal, 14)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .tojGlass(in: Capsule(), interactive: model.capabilities.contains(.profiles))
                .accessibilityHint(model.capabilities.contains(.profiles) ? "Opens contact and privacy details" : "Connection security status")

                Button { showingProfile = model.capabilities.contains(.profiles) } label: {
                    TojAvatar(title: model.dialogTitle(dialogId), size: 44)
                }
                .buttonStyle(.plain)
                .disabled(!model.capabilities.contains(.profiles))
                .accessibilityLabel("Open \(model.dialogTitle(dialogId)) profile")
            }
        }
    }

    private var connectionColor: Color {
        switch model.connectionViewState {
        case .connected: TojTheme.secure
        case .connecting: TojTheme.secondaryText
        case .offline: .orange
        }
    }

    private var messageTimeline: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        Label("Private conversation", systemImage: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(TojTheme.secondaryText)
                            .padding(.vertical, 8)

                        if model.canLoadEarlier {
                            Button {
                                Task { await model.loadEarlier() }
                            } label: {
                                Label(model.loadingEarlier ? "Loading" : "Earlier messages", systemImage: "arrow.up")
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                            }
                            .buttonStyle(.glass)
                            .disabled(model.loadingEarlier)
                            .padding(.bottom, 6)
                        }

                        ForEach(Array(model.lines.enumerated()), id: \.element.id) { index, line in
                            if shouldShowUnreadDivider(at: index) {
                                unreadDivider
                            }
                            TojMessageBubble(
                                model: model,
                                line: line,
                                actions: model.actions(for: line),
                                onAction: { perform($0, on: line) },
                                onSwipeReply: { model.beginReply(to: line); composerFocused = true }
                            )
                            .id(line.id)
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97, anchor: line.mine ? .bottomTrailing : .bottomLeading)))
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("timeline-bottom")
                            .onAppear { isAtBottom = true }
                            .onDisappear { isAtBottom = false }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                }
                .scrollDismissesKeyboard(.interactively)
                .defaultScrollAnchor(.bottom)
                .onChange(of: model.lines.count) { _, _ in
                    guard isAtBottom else { return }
                    scrollToLatest(proxy)
                }
                .task {
                    try? await Task.sleep(for: .milliseconds(80))
                    scrollToLatest(proxy, animated: false, clearUnread: false)
                }

                if !isAtBottom {
                    Button {
                        scrollToLatest(proxy)
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 16, weight: .bold))
                                .frame(width: 46, height: 46)
                            if initialUnreadCount > 0 {
                                Text(initialUnreadCount > 99 ? "99+" : "\(initialUnreadCount)")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(TojTheme.canvas)
                                    .padding(.horizontal, 5)
                                    .frame(minWidth: 18, minHeight: 18)
                                    .background(TojTheme.text, in: Capsule())
                                    .offset(x: 5, y: -4)
                            }
                        }
                    }
                    .buttonStyle(.glass)
                    .padding(14)
                    .transition(.opacity)
                    .accessibilityLabel("Jump to latest message")
                }
            }
        }
    }

    private var unreadDivider: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Color.white.opacity(0.12)).frame(height: 0.5)
            Text("Unread messages")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(TojTheme.secondaryText)
            Rectangle().fill(Color.white.opacity(0.12)).frame(height: 0.5)
        }
        .accessibilityLabel("Start of unread messages")
        .padding(.vertical, 7)
    }

    private func shouldShowUnreadDivider(at index: Int) -> Bool {
        initialUnreadCount > 0 && index == max(0, model.lines.count - initialUnreadCount)
    }

    private var composer: some View {
        VStack(spacing: 0) {
            if model.composerMode != .text {
                composerContext
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }

            HStack(alignment: .bottom, spacing: 7) {
                if model.capabilities.contains(.media) {
                    Button { showingAttachments = true } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 42, height: 42)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(TojTheme.secondaryText)
                    .disabled(model.composerMode.isRecording)
                    .accessibilityLabel("Add attachment")
                }

                TextField("Message", text: $model.draft, axis: .vertical)
                    .focused($composerFocused)
                    .lineLimit(1...5)
                    .font(.body)
                    .foregroundStyle(TojTheme.text)
                    .padding(.leading, model.capabilities.contains(.media) ? 0 : 10)
                    .padding(.vertical, 11)
                    .submitLabel(.send)
                    .onSubmit { if canSend { send() } }
                    .accessibilityLabel("Message")
                    .disabled(model.composerMode.isRecording)

                if canSend {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(TojTheme.canvas)
                            .frame(width: 44, height: 44)
                            .background(TojTheme.text, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(model.composerMode.isEditing ? "Save edited message" : "Send")
                } else if model.capabilities.contains(.voiceNotes) {
                    Button {
                        if model.composerMode.isRecording {
                            Task {
                                await model.finishVoiceRecording()
                                TojFeedback.sent()
                            }
                        } else {
                            Task {
                                await model.beginVoiceRecording()
                                TojFeedback.selection()
                            }
                        }
                    } label: {
                        Image(systemName: model.composerMode.isRecording ? "arrow.up" : "mic.fill")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(model.composerMode.isRecording ? TojTheme.canvas : TojTheme.text)
                            .frame(width: 44, height: 44)
                            .background(model.composerMode.isRecording ? TojTheme.text : TojTheme.strong, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(model.composerMode.isRecording ? "Send voice message" : "Record voice message")
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(TojTheme.secondaryText)
                        .frame(width: 44, height: 44)
                        .background(TojTheme.strong, in: Circle())
                        .accessibilityHidden(true)
                }
            }
            .padding(6)
            .tojGlass(in: Capsule(), interactive: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(TojTheme.canvas.opacity(0.96))
        .animation(reduceMotion ? .easeOut(duration: 0.12) : TojTheme.microAnimation, value: model.composerMode)
    }

    private var composerContext: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(model.composerMode.isRecording ? Color.red : TojTheme.secure)
                .frame(width: 3, height: 34)
                .clipShape(Capsule())
            Image(systemName: model.composerMode.contextIcon)
                .foregroundStyle(TojTheme.secondaryText)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.composerMode.contextTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TojTheme.text)
                Text(model.composerMode.contextPreview)
                    .font(.caption2)
                    .foregroundStyle(TojTheme.secondaryText)
                    .lineLimit(1)
            }
            Spacer()
            Button { model.cancelComposerMode() } label: {
                Image(systemName: "xmark")
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .foregroundStyle(TojTheme.secondaryText)
            .accessibilityLabel("Cancel")
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private func send() {
        guard canSend else { return }
        TojFeedback.sent()
        Task { await model.sendDraft() }
    }

    private func perform(_ action: MessageAction, on line: CloudAppModel.Line) {
        switch action {
        case .reply:
            model.beginReply(to: line)
            composerFocused = true
        case .react:
            reactionLine = line
        case .copy:
            UIPasteboard.general.string = line.text
            TojFeedback.selection()
        case .edit:
            model.beginEditing(line)
            composerFocused = true
        case .forward:
            forwardLine = line
            showingForwarding = true
        case .delete:
            deleteLine = line
        case .retry:
            model.retryFailedMessage(line)
        case .inspect:
            detailsLine = line
        }
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy, animated: Bool = true, clearUnread: Bool = true) {
        let action = { proxy.scrollTo("timeline-bottom", anchor: .bottom) }
        if animated {
            withAnimation(reduceMotion ? .easeOut(duration: 0.12) : TojTheme.microAnimation, action)
        } else {
            action()
        }
        isAtBottom = true
        if clearUnread { initialUnreadCount = 0 }
    }
}

private struct TojMessageBubble: View {
    let model: CloudAppModel
    let line: CloudAppModel.Line
    let actions: [MessageAction]
    let onAction: (MessageAction) -> Void
    let onSwipeReply: () -> Void
    @State private var replyOffset: CGFloat = 0
    @State private var showingMedia = false

    var body: some View {
        HStack {
            if line.mine { Spacer(minLength: 54) }

            VStack(alignment: line.mine ? .trailing : .leading, spacing: 5) {
                if line.isForwarded {
                    Label("Forwarded message", systemImage: "arrowshape.turn.up.right.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(TojTheme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let replyPreview = line.replyPreview {
                    HStack(spacing: 7) {
                        Rectangle().fill(TojTheme.secure).frame(width: 2, height: 28)
                        Text(replyPreview)
                            .font(.caption)
                            .foregroundStyle(TojTheme.secondaryText)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let media = line.media {
                    ProductionMediaBubble(model: model, media: media)
                        .contentShape(Rectangle())
                        .onTapGesture { if media.kind != "voice" { showingMedia = true } }
                } else if let attachment = line.attachment {
                    DemoAttachmentBubble(attachment: attachment)
                        .contentShape(Rectangle())
                        .onTapGesture { showingMedia = true }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint("Opens media viewer")
                }

                if !line.text.isEmpty, line.attachment == nil || line.text != line.attachment?.title {
                    Text(line.text)
                        .font(.body)
                        .foregroundStyle(TojTheme.text)
                        .textSelection(.enabled)
                }

                if let progress = line.transferProgress, progress < 1 {
                    ProgressView(value: progress)
                        .tint(TojTheme.secure)
                        .accessibilityLabel("Uploading")
                        .accessibilityValue("\(Int(progress * 100)) percent")
                }

                HStack(spacing: 4) {
                    if line.isEdited { Text("edited") }
                    if let timestamp = line.timestamp { Text(TojDateFormatting.message(timestamp)) }
                    if line.mine { Image(systemName: deliverySymbol) }
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(deliveryColor)

                if !line.reactions.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(line.reactions, id: \.self) { reaction in
                            Text(reaction)
                                .font(.caption)
                                .frame(minWidth: 28, minHeight: 24)
                                .background(TojTheme.raised, in: Capsule())
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(line.mine ? Color(hex: 0x17191D) : TojTheme.strong)
            .clipShape(bubbleShape)
            .overlay(bubbleShape.stroke(Color.white.opacity(line.mine ? 0.07 : 0.05), lineWidth: 0.5))
            .offset(x: replyOffset)
            .background(alignment: line.mine ? .trailing : .leading) {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .foregroundStyle(TojTheme.secondaryText)
                    .opacity(min(1, abs(replyOffset) / 48))
                    .offset(x: line.mine ? 28 : -28)
            }

            if !line.mine { Spacer(minLength: 54) }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 16)
                .onChanged { value in
                    let inward = line.mine ? min(0, value.translation.width) : max(0, value.translation.width)
                    replyOffset = max(-62, min(62, inward * 0.55))
                }
                .onEnded { _ in
                    if abs(replyOffset) > 28 {
                        TojFeedback.selection()
                        onSwipeReply()
                    }
                    withAnimation(TojTheme.microAnimation) { replyOffset = 0 }
                }
        )
        .contextMenu {
            ForEach(actions) { action in
                Button(role: action == .delete ? .destructive : nil) {
                    onAction(action)
                } label: {
                    Label(action.title, systemImage: action.systemImage)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityHint("Swipe to reply or use message actions")
        .accessibilityActions {
            ForEach(actions) { action in
                Button(action.title) { onAction(action) }
            }
        }
        .fullScreenCover(isPresented: $showingMedia) {
            if let media = line.media {
                ProductionMediaViewer(model: model, media: media)
            } else if let attachment = line.attachment {
                DemoMediaViewer(attachment: attachment)
            }
        }
    }

    private var bubbleShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 20,
            bottomLeadingRadius: line.mine ? 20 : 6,
            bottomTrailingRadius: line.mine ? 6 : 20,
            topTrailingRadius: 20,
            style: .continuous
        )
    }

    private var accessibilityDescription: String {
        let sender = line.mine ? String(localized: "You") : String(localized: "Contact")
        let state: String
        switch line.delivery {
        case .sending: state = String(localized: "sending")
        case .sent: state = String(localized: "sent")
        case .seen: state = String(localized: "seen")
        case .failed: state = String(localized: "failed")
        }
        return "\(sender): \(line.text), \(state)"
    }

    private var deliverySymbol: String {
        switch line.delivery {
        case .sending: "clock"
        case .sent: "checkmark"
        case .seen: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        }
    }

    private var deliveryColor: Color {
        switch line.delivery {
        case .seen: TojTheme.secure
        case .failed: .red
        default: TojTheme.secondaryText
        }
    }
}

private struct DemoAttachmentBubble: View {
    let attachment: DemoAttachment

    var body: some View {
        switch attachment {
        case let .photo(name):
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [Color(hex: 0x27333A), Color(hex: 0x101C22)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "photo.fill")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text(name)
                    .font(.caption.weight(.semibold))
                    .padding(10)
            }
            .frame(width: 230, height: 145)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        case let .video(name, duration):
            attachmentTile(icon: "play.fill", title: name, detail: duration)
        case let .file(name, size):
            attachmentTile(icon: "doc.fill", title: name, detail: size)
        case let .voice(duration):
            HStack(spacing: 10) {
                Image(systemName: "play.fill").frame(width: 34, height: 34).background(TojTheme.text, in: Circle()).foregroundStyle(TojTheme.canvas)
                Image(systemName: "waveform").foregroundStyle(TojTheme.secondaryText)
                Text(duration).font(.caption).foregroundStyle(TojTheme.secondaryText)
            }
        case let .link(title, host):
            attachmentTile(icon: "link", title: title, detail: host)
        }
    }

    private func attachmentTile(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 42, height: 42)
                .background(TojTheme.raised, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(TojTheme.secondaryText)
            }
        }
        .frame(maxWidth: 235, alignment: .leading)
    }
}

private struct ProductionMediaBubble: View {
    let model: CloudAppModel
    let media: CloudMedia
    @State private var thumbnail: UIImage?

    var body: some View {
        Group {
            switch media.kind {
            case "photo", "video":
                ZStack {
                    if let thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                    } else {
                        LinearGradient(
                            colors: [Color(hex: 0x27333A), Color(hex: 0x101C22)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                        ProgressView().tint(TojTheme.text)
                    }
                    if media.kind == "video" {
                        Image(systemName: "play.fill")
                            .font(.title2.weight(.bold))
                            .frame(width: 52, height: 52)
                            .background(.black.opacity(0.55), in: Circle())
                    }
                    VStack { Spacer(); HStack {
                        Spacer()
                        Text(media.formattedDuration ?? media.formattedSize)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .background(.black.opacity(0.62), in: Capsule())
                    }.padding(8) }
                }
                .frame(width: 235, height: 155)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .task(id: media.id) {
                    guard thumbnail == nil, let data = await model.thumbnailData(for: media) else { return }
                    thumbnail = UIImage(data: data)
                }
            case "voice":
                VoiceNotePlaybackView(model: model, media: media)
            default:
                HStack(spacing: 11) {
                    Image(systemName: "doc.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 42, height: 42)
                        .background(TojTheme.raised, in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text(media.displayName).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(media.formattedSize).font(.caption).foregroundStyle(TojTheme.secondaryText)
                    }
                }
                .frame(maxWidth: 235, alignment: .leading)
            }
        }
        .accessibilityLabel("\(media.displayName), \(media.formattedSize)")
    }
}

private struct VoiceNotePlaybackView: View {
    let model: CloudAppModel
    let media: CloudMedia
    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var isLoading = false
    @State private var progress = 0.0
    @State private var downloadProgress = 0.0
    @State private var error: String?
    @State private var loadingTask: Task<Void, Never>?
    @State private var playbackTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 10) {
            Button(action: toggle) {
                Group {
                    if isLoading { ProgressView(value: downloadProgress).tint(TojTheme.canvas) }
                    else if error != nil { Image(systemName: "arrow.clockwise") }
                    else { Image(systemName: isPlaying ? "pause.fill" : "play.fill") }
                }
                .frame(width: 38, height: 38)
                .background(TojTheme.text, in: Circle())
                .foregroundStyle(TojTheme.canvas)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 5) {
                Slider(
                    value: Binding(
                        get: { progress },
                        set: { value in
                            progress = value
                            if let player { player.currentTime = player.duration * value }
                        }
                    ),
                    in: 0...1
                )
                .tint(TojTheme.secure)
                .frame(width: 135)
                .accessibilityLabel("Voice message position")
                HStack {
                    Text(error ?? elapsedLabel)
                        .lineLimit(1)
                    Spacer()
                    Text(media.formattedDuration ?? "0:00")
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(TojTheme.secondaryText)
            }
        }
        .onDisappear {
            loadingTask?.cancel()
            playbackTask?.cancel()
            player?.stop()
        }
    }

    private var elapsedLabel: String {
        let elapsed = Int((player?.duration ?? 0) * progress)
        return String(format: "%d:%02d", elapsed / 60, elapsed % 60)
    }

    private func toggle() {
        if let player {
            if player.isPlaying {
                player.pause()
                isPlaying = false
            } else {
                player.play()
                isPlaying = true
                monitorPlayback()
            }
            return
        }
        error = nil
        isLoading = true
        downloadProgress = 0
        loadingTask?.cancel()
        loadingTask = Task {
            defer { loadingTask = nil }
            do {
                let data = try await model.mediaData(for: media) { value in
                    await MainActor.run { downloadProgress = value }
                }
                try Task.checkCancellation()
                let loaded = try AVAudioPlayer(data: data)
                guard loaded.prepareToPlay() else { throw MediaPresentationError.unreadable }
                player = loaded
                isLoading = false
                loaded.play()
                isPlaying = true
                monitorPlayback()
            } catch is CancellationError {
                isLoading = false
            } catch {
                isLoading = false
                self.error = error.localizedDescription
            }
        }
    }

    private func monitorPlayback() {
        playbackTask?.cancel()
        playbackTask = Task {
            while !Task.isCancelled, let player, player.isPlaying {
                progress = player.duration > 0 ? player.currentTime / player.duration : 0
                try? await Task.sleep(for: .milliseconds(100))
            }
            if player?.isPlaying == false, progress > 0.99 { progress = 0; player?.currentTime = 0 }
            isPlaying = false
        }
    }
}

private struct ProductionMediaViewer: View {
    @Environment(\.dismiss) private var dismiss
    let model: CloudAppModel
    let media: CloudMedia
    @State private var data: Data?
    @State private var player: AVPlayer?
    @State private var temporaryURL: URL?
    @State private var error: String?
    @State private var downloadProgress = 0.0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            TojTheme.canvas.ignoresSafeArea()
            Group {
                if let error {
                    VStack(spacing: 16) {
                        ContentUnavailableView(
                            "Could not open media", systemImage: "exclamationmark.triangle",
                            description: Text(error)
                        )
                        Button("Try again") { Task { await load() } }
                            .buttonStyle(.borderedProminent)
                    }
                } else if media.kind == "photo", let data, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFit().padding()
                } else if media.kind == "video", let player {
                    VideoPlayer(player: player).onAppear { player.play() }
                } else if media.kind == "file", let temporaryURL {
                    VStack(spacing: 20) {
                        Image(systemName: "doc.fill").font(.system(size: 58)).foregroundStyle(TojTheme.secondaryText)
                        Text(media.displayName).font(.headline)
                        Text(media.formattedSize).foregroundStyle(TojTheme.secondaryText)
                        ShareLink(item: temporaryURL) { Label("Open or share", systemImage: "square.and.arrow.up") }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    ProgressView(value: downloadProgress) {
                        Text("Downloading…")
                    }
                    .tint(TojTheme.text)
                    .frame(maxWidth: 240)
                }
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark").frame(width: 44, height: 44)
            }
            .buttonStyle(.glass)
            .padding()
        }
        .task(id: media.id) { await load() }
        .onDisappear {
            player?.pause()
            if let temporaryURL { Task { await model.removeTemporaryMediaURL(temporaryURL) } }
        }
    }

    private func load() async {
        error = nil
        data = nil
        player?.pause()
        player = nil
        if let temporaryURL { await model.removeTemporaryMediaURL(temporaryURL) }
        temporaryURL = nil
        downloadProgress = 0
        do {
            let downloaded = try await model.mediaData(for: media) { value in
                await MainActor.run { downloadProgress = value }
            }
            if media.kind == "photo" {
                guard UIImage(data: downloaded) != nil else { throw MediaPresentationError.unreadable }
                data = downloaded
                return
            }
            let ext = media.fileName.flatMap { URL(filePath: $0).pathExtension }.flatMap { $0.isEmpty ? nil : $0 }
                ?? (media.kind == "video" ? "mp4" : "bin")
            let url = try await model.temporaryMediaURL(data: downloaded, fileExtension: ext)
            temporaryURL = url
            if media.kind == "video" { player = AVPlayer(url: url) }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private enum MediaPresentationError: LocalizedError {
    case unreadable
    var errorDescription: String? { String(localized: "The downloaded media is damaged or unsupported") }
}

private extension ComposerMode {
    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }

    var isEditing: Bool {
        if case .editing = self { return true }
        return false
    }

    var contextIcon: String {
        switch self {
        case .replying: "arrowshape.turn.up.left"
        case .editing: "pencil"
        case .recording: "waveform"
        case .attachmentPreview, .uploading: "paperclip"
        case .disabled: "exclamationmark.triangle"
        case .text: "text.cursor"
        }
    }

    var contextTitle: String {
        switch self {
        case .replying: String(localized: "Replying")
        case .editing: String(localized: "Editing message")
        case .recording: String(localized: "Recording voice message")
        case .attachmentPreview: String(localized: "Attachment preview")
        case .uploading: String(localized: "Uploading")
        case .disabled: String(localized: "Messaging unavailable")
        case .text: ""
        }
    }

    var contextPreview: String {
        switch self {
        case let .replying(_, preview): preview
        case let .editing(_, original): original
        case let .recording(seconds): String(format: "0:%02d · Tap send when ready", seconds)
        case let .attachmentPreview(attachment): attachment.title
        case let .uploading(attachment, progress): "\(attachment.title) · \(Int(progress * 100))%"
        case let .disabled(reason): reason
        case .text: ""
        }
    }
}

private struct ProductionAttachmentPicker: View {
    let model: CloudAppModel
    let onDone: () -> Void
    @State private var photoItem: PhotosPickerItem?
    @State private var videoItem: PhotosPickerItem?
    @State private var importingFile = false
    @State private var working = false
    @State private var error: String?
    @State private var selectionTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Share something")
                .font(TojTheme.heading(.title, weight: .bold))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    pickerLabel("Photo", icon: "photo.fill")
                }
                PhotosPicker(selection: $videoItem, matching: .videos) {
                    pickerLabel("Video", icon: "video.fill")
                }
                Button { importingFile = true } label: { pickerLabel("File", icon: "doc.fill") }
                    .buttonStyle(.plain)
            }
            .disabled(working)
            if working {
                HStack {
                    ProgressView("Preparing encrypted upload…").tint(TojTheme.secure)
                    Spacer()
                    Button("Cancel", role: .cancel) { cancelSelection() }
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            Label("Files are encrypted in Toj's local cache before upload", systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(TojTheme.secondaryText)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TojTheme.canvas)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            selectionTask?.cancel()
            selectionTask = Task { await loadPhoto(item) }
        }
        .onChange(of: videoItem) { _, item in
            guard let item else { return }
            selectionTask?.cancel()
            selectionTask = Task { await loadVideo(item) }
        }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.data, .item]) { result in
            selectionTask?.cancel()
            selectionTask = Task { await loadFile(result) }
        }
        .onDisappear {
            selectionTask?.cancel()
            if working { model.cancelComposerMode() }
        }
    }

    nonisolated private func pickerLabel(_ title: LocalizedStringKey, icon: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon).frame(width: 36, height: 36).background(Color.white.opacity(0.08), in: Circle())
            Text(title).font(.subheadline.weight(.semibold))
            Spacer()
        }
        .padding(13)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func loadPhoto(_ item: PhotosPickerItem) async {
        working = true
        defer { working = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
                throw PickerError.unreadable
            }
            try Task.checkCancellation()
            let thumbnail = makeThumbnail(image)
            let type = item.supportedContentTypes.first
            await model.sendMedia(
                data: data, kind: "photo", contentType: type?.preferredMIMEType ?? "image/jpeg",
                fileName: "Photo.\(type?.preferredFilenameExtension ?? "jpg")",
                width: Int(image.size.width), height: Int(image.size.height),
                thumbnail: thumbnail
            )
            onDone()
        } catch { self.error = error.localizedDescription }
    }

    private func loadVideo(_ item: PhotosPickerItem) async {
        working = true
        defer { working = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { throw PickerError.unreadable }
            try Task.checkCancellation()
            let url = FileManager.default.temporaryDirectory.appending(path: "toj-picker-\(UUID().uuidString).mov")
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            defer { try? FileManager.default.removeItem(at: url) }
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            var dimensions: (Int, Int)?
            if let track = try await asset.loadTracks(withMediaType: .video).first {
                let naturalSize = try await track.load(.naturalSize)
                let transform = try await track.load(.preferredTransform)
                let size = naturalSize.applying(transform)
                dimensions = (Int(abs(size.width)), Int(abs(size.height)))
            }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            let image = try? await generator.image(at: .zero).image
            let thumbnail = image.map(UIImage.init(cgImage:)).flatMap(makeThumbnail)
            let type = item.supportedContentTypes.first
            await model.sendMedia(
                data: data, kind: "video", contentType: type?.preferredMIMEType ?? "video/quicktime",
                fileName: "Video.\(type?.preferredFilenameExtension ?? "mov")",
                durationMs: Int64(max(0, duration.seconds) * 1_000),
                width: dimensions?.0, height: dimensions?.1, thumbnail: thumbnail
            )
            onDone()
        } catch { self.error = error.localizedDescription }
    }

    private func loadFile(_ result: Result<URL, Error>) async {
        working = true
        defer { working = false }
        do {
            let url = try result.get()
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
            if let fileSize = values.fileSize, fileSize > 25 * 1024 * 1024 { throw PickerError.tooLarge }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            try Task.checkCancellation()
            await model.sendMedia(
                data: data, kind: "file",
                contentType: values.contentType?.preferredMIMEType ?? "application/octet-stream",
                fileName: url.lastPathComponent
            )
            onDone()
        } catch { self.error = error.localizedDescription }
    }

    private func makeThumbnail(_ image: UIImage) -> Data? {
        for dimension in [640.0, 480.0, 320.0] {
            guard let resized = image.preparingThumbnail(of: CGSize(width: dimension, height: dimension)) else { continue }
            for quality in [0.72, 0.55, 0.4] {
                if let data = resized.jpegData(compressionQuality: quality), data.count <= 256 * 1024 {
                    return data
                }
            }
        }
        return nil
    }

    private func cancelSelection() {
        selectionTask?.cancel()
        selectionTask = nil
        model.cancelComposerMode()
        working = false
        onDone()
    }
}

private enum PickerError: LocalizedError {
    case unreadable, tooLarge
    var errorDescription: String? {
        switch self {
        case .unreadable: String(localized: "That item could not be read")
        case .tooLarge: String(localized: "That file is larger than 25 MB")
        }
    }
}

private struct DemoAttachmentPicker: View {
    let onSelect: (DemoAttachment) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Share something")
                .font(TojTheme.heading(.title, weight: .bold))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                attachmentButton("Photo", icon: "photo.fill", attachment: .photo(name: "Photo"))
                attachmentButton("Video", icon: "video.fill", attachment: .video(name: "Evening video", duration: "0:24"))
                attachmentButton("File", icon: "doc.fill", attachment: .file(name: "Document.pdf", size: "1.8 MB"))
                attachmentButton("Link", icon: "link", attachment: .link(title: "Shared link", host: "toj.im"))
            }
            Label("Demo only — production shows connected capabilities", systemImage: "hammer.fill")
                .font(.caption)
                .foregroundStyle(TojTheme.secondaryText)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TojTheme.canvas)
    }

    private func attachmentButton(_ title: LocalizedStringKey, icon: String, attachment: DemoAttachment) -> some View {
        Button { onSelect(attachment) } label: {
            HStack(spacing: 11) {
                Image(systemName: icon).frame(width: 36, height: 36).background(TojTheme.strong, in: Circle())
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
            }
            .padding(13)
            .background(TojTheme.raised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct DemoForwardingView: View {
    let dialogs: [CloudAppModel.Dialog]
    let onDone: (String) -> Void

    var body: some View {
        NavigationStack {
            List(dialogs.filter { !$0.isArchived }) { dialog in
                Button {
                    TojFeedback.sent()
                    onDone(dialog.id)
                } label: {
                    HStack(spacing: 12) {
                        TojAvatar(title: dialog.title, size: 42)
                        Text(dialog.title).foregroundStyle(TojTheme.text)
                        Spacer()
                    }
                }
                .listRowBackground(TojTheme.raised)
            }
            .scrollContentBackground(.hidden)
            .background(TojTheme.canvas)
            .navigationTitle("Forward to")
        }
    }
}

private struct MessageDetailsView: View {
    let line: CloudAppModel.Line

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Message details").font(TojTheme.heading(.title, weight: .bold))
            Label(line.mine ? "Sent by you" : "Received from contact", systemImage: "person.fill")
            Label(line.timestamp.map(TojDateFormatting.message) ?? "Pending timestamp", systemImage: "clock")
            Label(deliveryText, systemImage: "checkmark.circle")
            if line.isEdited { Label("Edited", systemImage: "pencil") }
            Spacer()
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TojTheme.canvas)
    }

    private var deliveryText: String {
        switch line.delivery {
        case .sending: String(localized: "Queued for sending")
        case .sent: String(localized: "Sent")
        case .seen: String(localized: "Seen")
        case let .failed(reason): String(localized: "Failed: \(reason)")
        }
    }
}
