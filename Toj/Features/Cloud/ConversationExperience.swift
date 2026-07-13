import SwiftUI
import AVFoundation
import AVKit
import Combine
import PhotosUI
import Photos
import UniformTypeIdentifiers
import UIKit

nonisolated enum VoiceGestureIntent: Equatable {
    case recording
    case cancel
    case lock

    static func resolve(translation: CGSize) -> VoiceGestureIntent {
        if translation.width < -82 { return .cancel }
        if translation.height < -72 { return .lock }
        return .recording
    }
}

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
    @State private var voiceFingerDown = false
    @State private var voiceLocked = false
    @State private var voiceCancelled = false
    @State private var voiceStartTask: Task<Void, Never>?

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
            .presentationDetents([.fraction(0.72), .large])
            .presentationDragIndicator(.hidden)
            .presentationCornerRadius(34)
            .presentationBackground(TojTheme.base)
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
        .alert(item: Binding(
            get: { model.operationNotice },
            set: { if $0 == nil { model.dismissOperationNotice() } }
        )) { notice in
            if notice.opensSettings {
                return Alert(
                    title: Text(notice.title), message: Text(notice.message),
                    primaryButton: .default(Text("Open Settings")) {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                        model.dismissOperationNotice()
                    },
                    secondaryButton: .cancel { model.dismissOperationNotice() }
                )
            }
            return Alert(
                title: Text(notice.title), message: Text(notice.message),
                dismissButton: .default(Text("OK")) { model.dismissOperationNotice() }
            )
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
                                    .foregroundStyle(TojTheme.onAccent)
                                    .padding(.horizontal, 5)
                                    .frame(minWidth: 18, minHeight: 18)
                                    .background(TojTheme.accent, in: Capsule())
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
                    .buttonStyle(.tojPressable)
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
                            .foregroundStyle(TojTheme.onAccent)
                            .frame(width: 44, height: 44)
                            .background(TojTheme.accent, in: Circle())
                    }
                    .buttonStyle(.tojPressable)
                    .accessibilityLabel(model.composerMode.isEditing ? "Save edited message" : "Send")
                } else if model.capabilities.contains(.voiceNotes) {
                    voiceRecordControl
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
                .fill(model.composerMode.isRecording ? TojTheme.danger : TojTheme.accent)
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
            if model.composerMode.isRecording {
                HStack(alignment: .center, spacing: 2) {
                    ForEach(0..<12, id: \.self) { index in
                        Capsule()
                            .fill(TojTheme.danger.opacity(0.9))
                            .frame(width: 2, height: 5 + CGFloat(model.voiceRecordingLevel) * CGFloat(6 + (index % 5) * 3))
                    }
                }
                .frame(height: 28)
                .accessibilityHidden(true)
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

    @ViewBuilder
    private var voiceRecordControl: some View {
        if voiceLocked && model.composerMode.isRecording {
            HStack(spacing: 6) {
                Button {
                    voiceLocked = false
                    model.cancelVoiceRecording()
                    TojFeedback.selection()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 38, height: 38)
                        .background(TojTheme.danger.opacity(0.18), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel voice message")
                Button {
                    voiceLocked = false
                    Task { await model.finishVoiceRecording(); TojFeedback.sent() }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(TojTheme.onAccent)
                        .frame(width: 44, height: 44)
                        .background(TojTheme.accent, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Send voice message")
            }
        } else {
            Image(systemName: model.composerMode.isRecording ? "mic.fill" : "mic.fill")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(model.composerMode.isRecording ? .white : TojTheme.text)
                .frame(width: 44, height: 44)
                .background(model.composerMode.isRecording ? TojTheme.danger : TojTheme.strong, in: Circle())
                .scaleEffect(voiceFingerDown ? 1.08 : 1)
                .contentShape(Circle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged(handleVoiceDrag)
                        .onEnded(handleVoiceRelease)
                )
                .accessibilityLabel("Hold to record voice message")
                .accessibilityHint("Release to send, slide left to cancel, or slide up to lock")
        }
    }

    private func handleVoiceDrag(_ value: DragGesture.Value) {
        if !voiceFingerDown {
            voiceFingerDown = true
            voiceCancelled = false
            voiceStartTask?.cancel()
            TojFeedback.selection()
            voiceStartTask = Task {
                await model.beginVoiceRecording()
                guard !Task.isCancelled else { return }
                if !voiceFingerDown, !voiceLocked, !voiceCancelled, model.composerMode.isRecording {
                    await model.finishVoiceRecording()
                }
            }
        }
        switch VoiceGestureIntent.resolve(translation: value.translation) {
        case .cancel where !voiceCancelled:
            voiceCancelled = true
            voiceLocked = false
            voiceFingerDown = false
            voiceStartTask?.cancel()
            model.cancelVoiceRecording()
            TojFeedback.selection()
        case .lock where !voiceCancelled && !voiceLocked:
            voiceLocked = true
            TojFeedback.selection()
        default:
            break
        }
    }

    private func handleVoiceRelease(_ value: DragGesture.Value) {
        voiceFingerDown = false
        guard !voiceCancelled else { voiceCancelled = false; return }
        guard !voiceLocked else { return }
        if model.composerMode.isRecording {
            Task { await model.finishVoiceRecording(); TojFeedback.sent() }
        }
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
                        Rectangle().fill(TojTheme.accent).frame(width: 2, height: 28)
                        Text(replyPreview)
                            .font(.caption)
                            .foregroundStyle(TojTheme.secondaryText)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let media = line.media {
                    ProductionMediaBubble(
                        model: model, line: line, media: media,
                        onRetry: { model.retryFailedMessage(line) },
                        onRemove: { model.removeFailedMedia(line) }
                    )
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
                        .padding(.horizontal, isVisualMedia ? 8 : 0)
                }

                if line.media == nil, let progress = line.transferProgress, progress < 1 {
                    ProgressView(value: progress)
                        .tint(TojTheme.secure)
                        .accessibilityLabel("Uploading")
                        .accessibilityValue("\(Int(progress * 100)) percent")
                }

                if line.media == nil || !["photo", "video"].contains(line.media?.kind ?? "") || !line.text.isEmpty {
                    HStack(spacing: 4) {
                        if line.isEdited { Text("edited") }
                        if let timestamp = line.timestamp { Text(TojDateFormatting.message(timestamp)) }
                        if line.mine { Image(systemName: deliverySymbol) }
                    }
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(deliveryColor)
                }

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
            .padding(.horizontal, isVisualMedia ? 4 : 12)
            .padding(.vertical, isVisualMedia ? 4 : 9)
            .background(line.mine ? TojTheme.bubbleMine : TojTheme.strong)
            .clipShape(bubbleShape)
            .overlay(bubbleShape.stroke(line.mine ? TojTheme.gold.opacity(0.16) : TojTheme.hairline, lineWidth: 0.5))
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
            topLeadingRadius: TojRadius.bubble,
            bottomLeadingRadius: line.mine ? TojRadius.bubble : TojRadius.bubbleTail,
            bottomTrailingRadius: line.mine ? TojRadius.bubbleTail : TojRadius.bubble,
            topTrailingRadius: TojRadius.bubble,
            style: .continuous
        )
    }

    private var isVisualMedia: Bool {
        line.media.map { $0.kind == "photo" || $0.kind == "video" } ?? false
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
            .clipShape(RoundedRectangle(cornerRadius: TojRadius.tile, style: .continuous))
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

nonisolated enum MediaBubbleLayout {
    static func size(width: Int?, height: Int?, maxWidth: CGFloat = 268) -> CGSize {
        guard let width, let height, width > 0, height > 0 else {
            return CGSize(width: maxWidth, height: 180)
        }
        let ratio = CGFloat(width) / CGFloat(height)
        let desiredHeight = maxWidth / ratio
        if desiredHeight > 300 {
            return CGSize(width: min(maxWidth, max(160, 300 * ratio)), height: 300)
        }
        return CGSize(width: maxWidth, height: max(116, desiredHeight))
    }
}

private struct ProductionMediaBubble: View {
    let model: CloudAppModel
    let line: CloudAppModel.Line
    let media: CloudMedia
    let onRetry: () -> Void
    let onRemove: () -> Void
    @State private var thumbnail: UIImage?

    private var mediaSize: CGSize {
        MediaBubbleLayout.size(width: media.width, height: media.height)
    }

    var body: some View {
        Group {
            switch media.kind {
            case "photo", "video":
                ZStack {
                    if let thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFit()
                            .frame(width: mediaSize.width, height: mediaSize.height)
                            .background(.black.opacity(0.18))
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
                    if case let .failed(message) = line.delivery {
                        VStack(spacing: 8) {
                            Image(systemName: "exclamationmark.circle.fill").font(.title2)
                            Text(message).font(.caption).lineLimit(2).multilineTextAlignment(.center)
                            HStack(spacing: 8) {
                                Button("Retry", action: onRetry).buttonStyle(.borderedProminent)
                                Button("Remove", role: .destructive, action: onRemove).buttonStyle(.bordered)
                            }
                        }
                        .padding(12)
                        .background(.black.opacity(0.74), in: RoundedRectangle(cornerRadius: 14))
                        .padding(14)
                    } else if let progress = line.transferProgress, progress < 1 {
                        VStack(spacing: 7) {
                            Button(action: onRemove) {
                                ZStack {
                                    Circle().fill(.black.opacity(0.62)).frame(width: 54, height: 54)
                                    ProgressView(value: progress).tint(.white).frame(width: 42, height: 42)
                                    Image(systemName: "xmark").font(.caption.bold()).foregroundStyle(.white)
                                }
                            }
                            .buttonStyle(.plain)
                            Text(transferStatus(progress: progress))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(.black.opacity(0.66), in: Capsule())
                        }
                        .accessibilityLabel("Cancel upload")
                        .accessibilityValue(transferStatus(progress: progress))
                    }
                    VStack {
                        Spacer()
                        HStack(alignment: .bottom) {
                            Text(media.formattedDuration ?? media.formattedSize)
                            Spacer()
                            HStack(spacing: 3) {
                                if let timestamp = line.timestamp { Text(TojDateFormatting.message(timestamp)) }
                                if line.mine { Image(systemName: deliverySymbol) }
                            }
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 5)
                        .background(.black.opacity(0.58), in: Capsule())
                        .padding(8)
                    }
                }
                .frame(width: mediaSize.width, height: mediaSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .task(id: media.id) {
                    guard thumbnail == nil, let data = await model.thumbnailData(for: media) else { return }
                    thumbnail = SafeMediaImageDecoder.decode(data, maxPixelSize: 720)?.image
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

    private func transferStatus(progress: Double) -> String {
        switch line.transferStage {
        case .preparing: String(localized: "Preparing")
        case .finalizing: String(localized: "Finalizing")
        case .retrying: String(localized: "Retrying") + " · \(Int(progress * 100))%"
        case .uploading, .none: "\(Int(progress * 100))%"
        }
    }

    private var deliverySymbol: String {
        switch line.delivery {
        case .sending: "clock"
        case .sent: "checkmark"
        case .seen: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        }
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
    @State private var playbackRate: Float = 1

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
                HStack(spacing: 2) {
                    ForEach(0..<24, id: \.self) { index in
                        Capsule()
                            .fill(Double(index) / 24 <= progress ? TojTheme.secure : TojTheme.secondaryText.opacity(0.42))
                            .frame(width: 3, height: CGFloat(7 + (index * 7 % 15)))
                    }
                }
                .frame(width: 135, height: 22)
                .overlay {
                    Slider(
                        value: Binding(
                            get: { progress },
                            set: { value in
                                progress = value
                                if let player { player.currentTime = player.duration * value }
                            }
                        ), in: 0...1
                    )
                    .tint(.clear)
                    .opacity(0.02)
                }
                .accessibilityLabel("Voice message position")
                HStack {
                    Text(error ?? elapsedLabel)
                        .lineLimit(1)
                    Spacer()
                    Text(media.formattedDuration ?? "0:00")
                    Button(rateLabel) { cyclePlaybackRate() }
                        .font(.caption2.bold())
                        .buttonStyle(.plain)
                        .foregroundStyle(TojTheme.secure)
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
                loaded.enableRate = true
                loaded.rate = playbackRate
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

    private var rateLabel: String {
        playbackRate == 1 ? "1×" : playbackRate == 1.5 ? "1.5×" : "2×"
    }

    private func cyclePlaybackRate() {
        playbackRate = playbackRate == 1 ? 1.5 : playbackRate == 1.5 ? 2 : 1
        player?.enableRate = true
        player?.rate = playbackRate
    }
}

private struct ZoomablePhotoView: View {
    let image: UIImage
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .scaleEffect(scale)
            .offset(offset)
            .contentShape(Rectangle())
            .gesture(
                MagnifyGesture()
                    .onChanged { value in scale = min(5, max(1, baseScale * value.magnification)) }
                    .onEnded { _ in
                        baseScale = scale
                        if scale == 1 { offset = .zero; baseOffset = .zero }
                    }
            )
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        guard scale > 1 else { return }
                        offset = CGSize(
                            width: baseOffset.width + value.translation.width,
                            height: baseOffset.height + value.translation.height
                        )
                    }
                    .onEnded { _ in baseOffset = offset }
            )
            .onTapGesture(count: 2) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    scale = scale > 1 ? 1 : 2.5
                    baseScale = scale
                    if scale == 1 { offset = .zero; baseOffset = .zero }
                }
            }
            .accessibilityLabel("Photo")
            .accessibilityHint("Pinch or double tap to zoom")
    }
}

private struct ProductionMediaViewer: View {
    @Environment(\.dismiss) private var dismiss
    let model: CloudAppModel
    let media: CloudMedia
    @State private var photoImage: UIImage?
    @State private var player: AVPlayer?
    @State private var temporaryURL: URL?
    @State private var error: String?
    @State private var downloadProgress = 0.0
    @State private var saveMessage: String?

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
                } else if media.kind == "photo", let photoImage {
                    ZoomablePhotoView(image: photoImage).padding(.vertical, 60)
                } else if media.kind == "video", let player {
                    VideoPlayer(player: player).onAppear { player.play() }
                } else if media.kind == "file", temporaryURL != nil {
                    VStack(spacing: 20) {
                        Image(systemName: "doc.fill").font(.system(size: 58)).foregroundStyle(TojTheme.secondaryText)
                        Text(media.displayName).font(.headline)
                        Text(media.formattedSize).foregroundStyle(TojTheme.secondaryText)
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

            if let temporaryURL, error == nil {
                VStack {
                    Spacer()
                    HStack(spacing: 12) {
                        ShareLink(item: temporaryURL) {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .frame(minWidth: 90)
                        }
                        .buttonStyle(.borderedProminent)
                        if media.kind == "photo" || media.kind == "video" {
                            Button {
                                Task { await saveToPhotos(temporaryURL) }
                            } label: {
                                Label("Save", systemImage: "square.and.arrow.down")
                                    .frame(minWidth: 90)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
        }
        .task(id: media.id) { await load() }
        .onDisappear {
            player?.pause()
            if let temporaryURL { Task { await model.removeTemporaryMediaURL(temporaryURL) } }
        }
        .alert("Media", isPresented: Binding(
            get: { saveMessage != nil }, set: { if !$0 { saveMessage = nil } }
        )) {
            Button("OK") { saveMessage = nil }
        } message: { Text(saveMessage ?? "") }
    }

    private func load() async {
        error = nil
        photoImage = nil
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
                guard let decoded = SafeMediaImageDecoder.decode(downloaded, maxPixelSize: 4_096) else {
                    throw MediaPresentationError.unreadable
                }
                photoImage = decoded.image
                temporaryURL = try await model.temporaryMediaURL(
                    data: downloaded, fileExtension: preferredFileExtension
                )
                return
            }
            let url = try await model.temporaryMediaURL(
                data: downloaded, fileExtension: preferredFileExtension
            )
            temporaryURL = url
            if media.kind == "video" {
                let asset = AVURLAsset(url: url)
                let playable = try await asset.load(.isPlayable)
                let duration = try await asset.load(.duration).seconds
                guard playable, duration.isFinite, duration > 0, duration <= 3_600,
                      let track = try await asset.loadTracks(withMediaType: .video).first
                else { throw MediaPresentationError.unreadable }
                let naturalSize = try await track.load(.naturalSize)
                let transform = try await track.load(.preferredTransform)
                let transformed = naturalSize.applying(transform)
                let width = Int64(abs(transformed.width).rounded(.up))
                let height = Int64(abs(transformed.height).rounded(.up))
                guard width > 0, height > 0, width <= 8_192, height <= 8_192,
                      width * height <= 40_000_000
                else { throw MediaPresentationError.unreadable }
                player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private var preferredFileExtension: String {
        if let value = media.fileName.map({ URL(filePath: $0).pathExtension }), !value.isEmpty {
            return value
        }
        return UTType(mimeType: media.contentType)?.preferredFilenameExtension
            ?? (media.kind == "video" ? "mp4" : media.kind == "photo" ? "jpg" : "bin")
    }

    private func saveToPhotos(_ url: URL) async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            saveMessage = "Photos access is off. You can enable it in Settings."
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                if media.kind == "video" {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                } else {
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                }
            }
            saveMessage = "Saved to Photos"
        } catch {
            saveMessage = error.localizedDescription
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
        case let .recording(seconds): String(format: "%d:%02d · Slide left to cancel · up to lock", seconds / 60, seconds % 60)
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
    @StateObject private var library = RecentMediaLibrary()
    @State private var mediaItem: PhotosPickerItem?
    @State private var photoItem: PhotosPickerItem?
    @State private var videoItem: PhotosPickerItem?
    @State private var selectedAsset: PHAsset?
    @State private var selectedFile: PreparedFileSelection?
    @State private var importingFile = false
    @State private var working = false
    @State private var error: String?
    @State private var selectionTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            attachmentHeader
            mediaContent
            attachmentControls
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TojTheme.base)
        .task { await library.load() }
        .onChange(of: mediaItem) { _, item in
            guard let item else { return }
            selectedFile = nil
            selectionTask?.cancel()
            selectionTask = Task { await loadMedia(item) }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            selectedFile = nil
            selectionTask?.cancel()
            selectionTask = Task { await loadPhoto(item) }
        }
        .onChange(of: videoItem) { _, item in
            guard let item else { return }
            selectedFile = nil
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

    private var attachmentHeader: some View {
        ZStack {
            Capsule()
                .fill(Color.white.opacity(0.18))
                .frame(width: 42, height: 5)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 8)

            HStack {
                Button(action: onDone) {
                    Image(systemName: "xmark")
                        .font(.system(size: 19, weight: .semibold))
                        .frame(width: 48, height: 48)
                        .background(TojTheme.strong, in: Circle())
                        .overlay(Circle().stroke(TojTheme.hairlineStrong, lineWidth: 0.5))
                }
                .buttonStyle(.tojPressable)
                .foregroundStyle(TojTheme.text)
                .accessibilityLabel("Close attachments")

                Spacer()
                if selectedFile != nil {
                    AttachmentFileTitle()
                } else {
                    PhotosPicker(selection: $mediaItem, matching: .any(of: [.images, .videos])) {
                        AttachmentLibraryTitle()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Browse photo and video library")
                }
                Spacer()
                Color.clear.frame(width: 48, height: 48)
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
        }
        .frame(height: 82)
    }

    @ViewBuilder
    private var mediaContent: some View {
        if let selectedFile {
            SelectedFilePreview(
                file: selectedFile,
                onReplace: { importingFile = true },
                onRemove: {
                    self.selectedFile = nil
                    error = nil
                    TojFeedback.selection()
                }
            )
        } else {
            switch library.authorizationStatus {
        case .authorized, .limited:
            if library.assets.isEmpty {
                attachmentEmptyState(
                    title: "No recent media",
                    detail: "Choose a photo or video from the library, or send a file.",
                    icon: "photo.on.rectangle.angled"
                )
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3),
                        spacing: 2
                    ) {
                        ForEach(library.assets, id: \.localIdentifier) { asset in
                            RecentMediaTile(
                                asset: asset,
                                selected: selectedAsset?.localIdentifier == asset.localIdentifier,
                                disabled: working
                            ) {
                                guard !working else { return }
                                selectedAsset = selectedAsset?.localIdentifier == asset.localIdentifier ? nil : asset
                                error = nil
                                TojFeedback.selection()
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        case .denied, .restricted:
            photoPrivacyState
        case .notDetermined:
            VStack(spacing: 12) {
                ProgressView().tint(TojTheme.gold)
                Text("Loading recent media…")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(TojTheme.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            @unknown default:
                attachmentEmptyState(
                    title: "Choose something to send",
                    detail: "Photos, videos, and files are available below.",
                    icon: "paperclip"
                )
            }
        }
    }

    private func attachmentEmptyState(
        title: LocalizedStringKey,
        detail: LocalizedStringKey,
        icon: String
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(TojTheme.gold)
                .frame(width: 62, height: 62)
                .background(TojTheme.strong, in: Circle())
            Text(title)
                .font(TojTheme.heading(.headline, weight: .bold))
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(TojTheme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 290)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var photoPrivacyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(TojTheme.gold)
                .frame(width: 62, height: 62)
                .background(TojTheme.strong, in: Circle())
            Text("Recent media is private")
                .font(TojTheme.heading(.headline, weight: .bold))
            Text("Use Photo below, or allow access to show previews here.")
                .font(.subheadline)
                .foregroundStyle(TojTheme.secondaryText)
                .multilineTextAlignment(.center)
            Button("Open Settings") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
            .buttonStyle(.bordered)
            .tint(TojTheme.gold)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var attachmentControls: some View {
        VStack(spacing: 10) {
            if working {
                HStack(spacing: 12) {
                    ProgressView().tint(TojTheme.gold)
                    Text("Loading attachment…")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("Cancel", role: .cancel) { cancelSelection() }
                        .font(.subheadline.weight(.semibold))
                }
                .padding(.horizontal, 16)
                .frame(height: 48)
                .background(TojTheme.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal, 12)
            } else if let selectedFile {
                Button {
                    sendFile(selectedFile)
                } label: {
                    Label("Send file", systemImage: "arrow.up")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(TojTheme.onAccent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(TojTheme.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.tojPressable)
                .padding(.horizontal, 12)
            } else if selectedAsset != nil {
                Button {
                    guard let selectedAsset else { return }
                    selectionTask?.cancel()
                    selectionTask = Task {
                        if selectedAsset.mediaType == .video {
                            await loadVideo(selectedAsset)
                        } else {
                            await loadPhoto(selectedAsset)
                        }
                    }
                } label: {
                    Label(
                        selectedAsset?.mediaType == .video ? "Send video" : "Send photo",
                        systemImage: "arrow.up"
                    )
                        .font(.headline.weight(.bold))
                        .foregroundStyle(TojTheme.onAccent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(TojTheme.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.tojPressable)
                .padding(.horizontal, 12)
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 16)
            }

            HStack(spacing: 3) {
                Button {
                    selectedAsset = nil
                    selectedFile = nil
                    Task { await library.load() }
                } label: {
                    AttachmentActionLabel(title: "Recents", icon: "photo.stack.fill", selected: true)
                }
                .buttonStyle(.tojPressable)

                PhotosPicker(selection: $photoItem, matching: .images) {
                    AttachmentActionLabel(title: "Photo", icon: "photo.fill")
                }
                .buttonStyle(.tojPressable)

                PhotosPicker(selection: $videoItem, matching: .videos) {
                    AttachmentActionLabel(title: "Video", icon: "video.fill")
                }
                .buttonStyle(.tojPressable)

                Button { importingFile = true } label: {
                    AttachmentActionLabel(title: "File", icon: "doc.fill", selected: selectedFile != nil)
                }
                .buttonStyle(.tojPressable)
            }
            .disabled(working)
            .padding(8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(TojTheme.hairlineStrong, lineWidth: 0.5)
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
        .padding(.top, 8)
        .background(TojTheme.base.opacity(0.96))
    }

    private func loadMedia(_ item: PhotosPickerItem) async {
        if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
            await loadVideo(item)
        } else {
            await loadPhoto(item)
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem) async {
        working = true
        defer { working = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw PickerError.unreadable
            }
            try Task.checkCancellation()
            try await prepareAndSendPhoto(data)
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadPhoto(_ asset: PHAsset) async {
        working = true
        defer { working = false }
        do {
            let data = try await MediaAssetDataLoader.imageData(for: asset)
            try Task.checkCancellation()
            try await prepareAndSendPhoto(data)
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func prepareAndSendPhoto(_ data: Data) async throws {
        guard let prepared = await Task.detached(priority: .userInitiated, operation: {
            SafeMediaImageDecoder.preparePhotoUpload(data)
        }).value else { throw PickerError.unreadable }
        try Task.checkCancellation()
        working = false
        selectionTask = nil
        Task {
            await model.sendMedia(
                data: prepared.data, kind: "photo", contentType: prepared.contentType,
                fileName: "Photo.\(prepared.filenameExtension)",
                width: prepared.pixelWidth, height: prepared.pixelHeight,
                thumbnail: prepared.thumbnail
            )
        }
        onDone()
    }

    private func loadVideo(_ item: PhotosPickerItem) async {
        working = true
        defer { working = false }
        do {
            guard let source = try await item.loadTransferable(type: Data.self) else { throw PickerError.unreadable }
            try Task.checkCancellation()
            let data = try await MediaAssetDataLoader.fittedVideoData(source)
            try Task.checkCancellation()
            try await prepareAndSendVideo(data)
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadVideo(_ asset: PHAsset) async {
        working = true
        defer { working = false }
        do {
            let data = try await MediaAssetDataLoader.videoData(for: asset)
            try Task.checkCancellation()
            try await prepareAndSendVideo(data)
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func prepareAndSendVideo(_ data: Data) async throws {
        guard data.count <= 25 * 1024 * 1024 else { throw PickerError.tooLarge }
        guard let container = SafeMediaVideoInspector.container(for: data) else {
            throw PickerError.unsupportedVideo
        }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "toj-video-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "source.\(container.filenameExtension)")
        try data.write(to: url, options: [.atomic, .completeFileProtection])

        let videoAsset = AVURLAsset(url: url)
        let duration = try await videoAsset.load(.duration)
        guard duration.seconds.isFinite, duration.seconds > 0 else { throw PickerError.unsupportedVideo }
        guard let track = try await videoAsset.loadTracks(withMediaType: .video).first else {
            throw PickerError.unsupportedVideo
        }
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let size = naturalSize.applying(transform)
        let dimensions = (Int(abs(size.width)), Int(abs(size.height)))
        guard dimensions.0 > 0, dimensions.1 > 0 else { throw PickerError.unsupportedVideo }

        let generator = AVAssetImageGenerator(asset: videoAsset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        let image = try await generator.image(at: .zero).image
        let thumbnail = SafeMediaImageDecoder.thumbnailData(UIImage(cgImage: image))
        try Task.checkCancellation()
        working = false
        selectionTask = nil
        Task {
            await model.sendMedia(
                data: data, kind: "video", contentType: container.contentType,
                fileName: "Video.\(container.filenameExtension)",
                durationMs: Int64(duration.seconds * 1_000),
                width: dimensions.0, height: dimensions.1, thumbnail: thumbnail
            )
        }
        onDone()
    }

    private func loadFile(_ result: Result<URL, Error>) async {
        working = true
        defer { working = false }
        do {
            let url = try result.get()
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [
                .contentTypeKey, .fileSizeKey, .isDirectoryKey, .isRegularFileKey,
            ])
            guard values.isDirectory != true else { throw PickerError.unreadable }
            if let fileSize = values.fileSize, fileSize > 25 * 1024 * 1024 {
                throw PickerError.tooLarge
            }
            let data = try Data(contentsOf: url)
            guard !data.isEmpty else { throw PickerError.emptyFile }
            guard data.count <= 25 * 1024 * 1024 else { throw PickerError.tooLarge }
            guard let fileName = SafeMediaFileMetadata.sanitizedFileName(url.lastPathComponent) else {
                throw PickerError.invalidFileName
            }
            try Task.checkCancellation()
            selectedAsset = nil
            selectedFile = PreparedFileSelection(
                data: data,
                fileName: fileName,
                contentType: values.contentType?.preferredMIMEType ?? "application/octet-stream"
            )
            working = false
            selectionTask = nil
            error = nil
            TojFeedback.selection()
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func sendFile(_ file: PreparedFileSelection) {
        selectedFile = nil
        selectionTask = nil
        Task {
            await model.sendMedia(
                data: file.data, kind: "file",
                contentType: file.contentType,
                fileName: file.fileName
            )
        }
        onDone()
    }

    private func cancelSelection() {
        selectionTask?.cancel()
        selectionTask = nil
        model.cancelComposerMode()
        working = false
        onDone()
    }
}

private struct AttachmentLibraryTitle: View {
    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 5) {
                Text("Recent media")
                    .font(TojTheme.heading(.headline, weight: .bold))
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(TojTheme.secondaryText)
            }
            Text("Encrypted before upload")
                .font(.caption2.weight(.medium))
                .foregroundStyle(TojTheme.secure)
        }
    }
}

private struct AttachmentFileTitle: View {
    var body: some View {
        VStack(spacing: 2) {
            Text("File ready")
                .font(TojTheme.heading(.headline, weight: .bold))
            Text("Encrypted before upload")
                .font(.caption2.weight(.medium))
                .foregroundStyle(TojTheme.secure)
        }
    }
}

nonisolated private struct PreparedFileSelection: Sendable {
    let data: Data
    let fileName: String
    let contentType: String

    var byteSize: Int64 { Int64(data.count) }
}

private struct SelectedFilePreview: View {
    let file: PreparedFileSelection
    let onReplace: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [TojTheme.strong, TojTheme.raised],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .stroke(TojTheme.gold.opacity(0.22), lineWidth: 1)
                    )
                Image(systemName: FileAttachmentPresentation.icon(for: file.contentType))
                    .font(.system(size: 48, weight: .medium))
                    .foregroundStyle(TojTheme.gold)
                Text(FileAttachmentPresentation.extensionLabel(file.fileName))
                    .font(.caption2.weight(.black))
                    .foregroundStyle(TojTheme.onAccent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(TojTheme.gold, in: Capsule())
                    .padding(12)
            }
            .frame(width: 136, height: 136)

            VStack(spacing: 5) {
                Text(file.fileName)
                    .font(TojTheme.heading(.headline, weight: .bold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(ByteCountFormatter.string(fromByteCount: file.byteSize, countStyle: .file))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(TojTheme.secondaryText)
                Label("Ready for encrypted upload", systemImage: "lock.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TojTheme.secure)
            }

            HStack(spacing: 10) {
                Button(action: onReplace) {
                    Label("Replace", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(TojTheme.text)
                Button(role: .destructive, action: onRemove) {
                    Label("Remove", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

nonisolated private enum FileAttachmentPresentation {
    static func icon(for contentType: String) -> String {
        if contentType == "application/pdf" { return "doc.richtext.fill" }
        if contentType.hasPrefix("image/") { return "photo.fill" }
        if contentType.hasPrefix("video/") { return "film.fill" }
        if contentType.hasPrefix("audio/") { return "waveform" }
        if contentType.hasPrefix("text/") { return "doc.text.fill" }
        if contentType.contains("zip") || contentType.contains("archive") || contentType.contains("compressed") {
            return "archivebox.fill"
        }
        return "doc.fill"
    }

    static func extensionLabel(_ fileName: String) -> String {
        let value = URL(fileURLWithPath: fileName).pathExtension
        return value.isEmpty ? "FILE" : String(value.prefix(5)).uppercased()
    }
}

private struct AttachmentActionLabel: View {
    nonisolated let title: String
    nonisolated let icon: String
    nonisolated let selected: Bool

    nonisolated init(title: String, icon: String, selected: Bool = false) {
        self.title = title
        self.icon = icon
        self.selected = selected
    }

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .frame(height: 24)
            Text(LocalizedStringKey(title))
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(selected ? TojTheme.gold : TojTheme.text)
        .frame(maxWidth: .infinity)
        .frame(height: 58)
        .background(
            selected ? TojTheme.gold.opacity(0.13) : Color.clear,
            in: RoundedRectangle(cornerRadius: 19, style: .continuous)
        )
    }
}

@MainActor
private final class RecentMediaLibrary: ObservableObject {
    @Published private(set) var authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published private(set) var assets: [PHAsset] = []

    func load() async {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        authorizationStatus = status
        guard status == .authorized || status == .limited else {
            assets = []
            return
        }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 90
        let result = PHAsset.fetchAssets(with: options)
        var recent: [PHAsset] = []
        recent.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            if asset.mediaType == .image || asset.mediaType == .video {
                recent.append(asset)
            }
        }
        assets = recent
    }
}

private struct RecentMediaTile: View {
    let asset: PHAsset
    let selected: Bool
    let disabled: Bool
    let action: () -> Void
    @State private var image: UIImage?
    @State private var requestID = PHInvalidImageRequestID

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle()
                        .fill(TojTheme.strong)
                        .overlay(ProgressView().tint(TojTheme.secondaryText))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            ZStack {
                Circle()
                    .fill(selected ? TojTheme.gold : Color.black.opacity(0.28))
                Circle()
                    .stroke(selected ? TojTheme.gold : Color.white.opacity(0.88), lineWidth: 2)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.black))
                        .foregroundStyle(TojTheme.onAccent)
                }
            }
            .frame(width: 27, height: 27)
            .padding(8)

            if asset.mediaType == .video {
                HStack(spacing: 4) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9, weight: .bold))
                    Text(Self.durationText(asset.duration))
                        .font(.caption2.weight(.bold).monospacedDigit())
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(Color.black.opacity(0.62), in: Capsule())
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(7)
            }

            if disabled {
                Color.black.opacity(0.24)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .overlay(
            Rectangle()
                .stroke(selected ? TojTheme.gold : Color.clear, lineWidth: 3)
        )
        .onAppear(perform: requestThumbnail)
        .onDisappear {
            if requestID != PHInvalidImageRequestID {
                PHImageManager.default().cancelImageRequest(requestID)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(asset.mediaType == .video ? "Recent video" : "Recent photo")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func requestThumbnail() {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        requestID = PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: 420, height: 420),
            contentMode: .aspectFill,
            options: options
        ) { result, info in
            guard let result, (info?[PHImageCancelledKey] as? Bool) != true else { return }
            image = result
        }
    }

    nonisolated private static func durationText(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private enum MediaAssetDataLoader {
    private static let maxBytes = 25 * 1024 * 1024

    static func imageData(for asset: PHAsset) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.version = .current
            options.isNetworkAccessAllowed = true
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) {
                data, _, _, info in
                if (info?[PHImageCancelledKey] as? Bool) == true {
                    continuation.resume(throwing: CancellationError())
                } else if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                } else if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: PickerError.unreadable)
                }
            }
        }
    }

    static func videoData(for asset: PHAsset) async throws -> Data {
        let source = try await videoAsset(for: asset).asset
        if let sourceURL = (source as? AVURLAsset)?.url,
           let size = try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size <= maxBytes {
            return try Data(contentsOf: sourceURL)
        }

        return try await exportForUpload(source)
    }

    static func fittedVideoData(_ data: Data) async throws -> Data {
        guard data.count > maxBytes else { return data }
        guard let container = SafeMediaVideoInspector.container(for: data) else {
            throw PickerError.unsupportedVideo
        }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "toj-video-source-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appending(path: "source.\(container.filenameExtension)")
        try data.write(to: sourceURL, options: [.atomic, .completeFileProtection])
        return try await exportForUpload(AVURLAsset(url: sourceURL))
    }

    private static func exportForUpload(_ source: AVAsset) async throws -> Data {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "toj-video-export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appending(path: "video.mp4")

        let duration = try await source.load(.duration)
        _ = try await source.load(.tracks)
        let preferredPreset = duration.seconds.isFinite && duration.seconds <= 60
            ? AVAssetExportPreset1280x720 : AVAssetExportPresetMediumQuality
        let preferredCompatible = await AVAssetExportSession.compatibility(
            ofExportPreset: preferredPreset, with: source, outputFileType: .mp4
        )
        let preset: String
        if preferredCompatible {
            preset = preferredPreset
        } else if await AVAssetExportSession.compatibility(
            ofExportPreset: AVAssetExportPresetMediumQuality, with: source, outputFileType: .mp4
        ) {
            preset = AVAssetExportPresetMediumQuality
        } else {
            throw PickerError.unsupportedVideo
        }
        guard let exporter = AVAssetExportSession(asset: source, presetName: preset) else {
            throw PickerError.unsupportedVideo
        }
        exporter.shouldOptimizeForNetworkUse = true
        try await exporter.export(to: outputURL, as: .mp4)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: outputURL.path)
        let data = try Data(contentsOf: outputURL)
        guard data.count <= maxBytes else { throw PickerError.tooLarge }
        return data
    }

    private static func videoAsset(for asset: PHAsset) async throws -> VideoAssetReference {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.version = .current
            options.isNetworkAccessAllowed = true
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) {
                result, _, info in
                if (info?[PHImageCancelledKey] as? Bool) == true {
                    continuation.resume(throwing: CancellationError())
                } else if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                } else if let result {
                    continuation.resume(returning: VideoAssetReference(asset: result))
                } else {
                    continuation.resume(throwing: PickerError.unreadable)
                }
            }
        }
    }
}

private final class VideoAssetReference: @unchecked Sendable {
    let asset: AVAsset

    init(asset: AVAsset) {
        self.asset = asset
    }
}

private enum PickerError: LocalizedError {
    case unreadable, emptyFile, tooLarge, unsupportedVideo, invalidFileName
    var errorDescription: String? {
        switch self {
        case .unreadable: String(localized: "That item could not be read")
        case .emptyFile: String(localized: "Empty files cannot be sent")
        case .tooLarge: String(localized: "That file is larger than 25 MB")
        case .unsupportedVideo: String(localized: "That video format could not be prepared")
        case .invalidFileName: String(localized: "That file name is not supported")
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
            .background(TojTheme.raised, in: RoundedRectangle(cornerRadius: TojRadius.field, style: .continuous))
        }
        .buttonStyle(.tojPressable)
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
