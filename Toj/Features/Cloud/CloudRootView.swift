import SwiftUI

struct CloudRootView: View {
    private static let isRunningUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model = CloudAppModel()

    var body: some View {
        Group {
            if model.storedSession == nil {
                CloudAuthView(model: model)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.985)))
            } else {
                CloudMainView(model: model)
                    .transition(.opacity)
            }
        }
        .background(TojTheme.canvas.ignoresSafeArea())
        .animation(reduceMotion ? .easeOut(duration: 0.15) : TojTheme.stateAnimation, value: model.storedSession == nil)
        .task {
            guard !Self.isRunningUnitTests else { return }
            #if DEBUG
            if ProcessInfo.processInfo.environment["TOJ_DEMO_MODE"] == "1" {
                model.enterDemoMode()
                return
            }
            #endif
            await model.start()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, !Self.isRunningUnitTests else { return }
            Task { await model.resume() }
        }
        .overlay(alignment: .top) {
            if model.callCoordinator.hasCall,
               !model.callCoordinator.isPresented,
               model.callCoordinator.state != .ended {
                TojActiveCallPill(coordinator: model.callCoordinator)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { model.callCoordinator.isPresented },
            set: { presented in
                if !presented {
                    if model.callCoordinator.state == .ended { model.callCoordinator.dismissEnded() }
                    else { model.callCoordinator.minimize() }
                }
            }
        )) {
            TojCallScreen(coordinator: model.callCoordinator)
        }
    }
}

// MARK: - Authentication

private struct CloudAuthView: View {
    @Bindable var model: CloudAppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedField: Field?

    private enum Field { case phone, name, code }

    private var canStart: Bool {
        model.canRequestCode && !model.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer(minLength: 54)

                TojMark(size: 84)
                    .shadow(color: .black.opacity(0.65), radius: 28, y: 18)
                    .padding(.bottom, 28)

                Text(model.requestedCode ? "Enter your code" : "Welcome to Toj")
                    .font(TojTheme.heading(.largeTitle, weight: .bold))
                    .foregroundStyle(TojTheme.text)
                    .multilineTextAlignment(.center)

                Text(model.requestedCode
                     ? "We sent a six-digit code to your phone."
                     : "Fast, private messaging made for your people.")
                    .font(.subheadline)
                    .foregroundStyle(TojTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.top, 10)
                    .padding(.horizontal, 24)

                VStack(spacing: 12) {
                    if model.requestedCode {
                        TojInputField(
                            title: "Verification code",
                            placeholder: "000000",
                            text: $model.code,
                            contentType: .oneTimeCode,
                            keyboard: .numberPad
                        )
                        .focused($focusedField, equals: .code)
                        .transition(fieldTransition)
                    } else {
                        TojInputField(
                            title: "Phone number",
                            placeholder: "+992",
                            text: $model.phone,
                            contentType: .telephoneNumber,
                            keyboard: .phonePad
                        )
                        .focused($focusedField, equals: .phone)

                        TojInputField(
                            title: "Your name",
                            placeholder: "Display name",
                            text: $model.displayName,
                            contentType: .name,
                            keyboard: .default
                        )
                        .focused($focusedField, equals: .name)
                    }
                }
                .padding(.top, 34)

                if shouldShowStatus {
                    Label(model.status, systemImage: statusIsError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(statusIsError ? Color.red : TojTheme.secure)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 12)
                        .transition(.opacity)
                }

                Button(action: primaryAction) {
                    HStack(spacing: 9) {
                        if model.authRequestInFlight || model.authVerifyInFlight {
                            ProgressView().tint(TojTheme.canvas)
                        }
                        Text(model.requestedCode ? "Sign in" : "Get code")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity, minHeight: 54)
                }
                .buttonStyle(.plain)
                .foregroundStyle(TojTheme.onAccent)
                .background(TojTheme.accent, in: Capsule())
                .opacity(primaryEnabled ? 1 : 0.42)
                .disabled(!primaryEnabled)
                .padding(.top, 18)

                #if DEBUG
                Button {
                    focusedField = nil
                    model.enterDemoMode()
                } label: {
                    HStack(spacing: 11) {
                        Image(systemName: "sparkles")
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Explore demo")
                                .font(.subheadline.weight(.semibold))
                            Text("No account or SMS required")
                                .font(.caption2)
                                .foregroundStyle(TojTheme.secondaryText)
                        }
                        Spacer()
                        Image(systemName: "arrow.right")
                            .font(.caption.bold())
                    }
                    .foregroundStyle(TojTheme.text)
                    .padding(.horizontal, 18)
                    .frame(maxWidth: .infinity, minHeight: 58)
                }
                .buttonStyle(.glass)
                .padding(.top, 12)
                .accessibilityHint("Opens local sample chats without creating an account")
                #endif

                if model.requestedCode {
                    HStack(spacing: 18) {
                        Button("Change number") { model.resetAuthCode() }
                        if model.resendSeconds > 0 {
                            Text("Resend in \(model.resendSeconds)s")
                                .foregroundStyle(TojTheme.secondaryText)
                        } else {
                            Button("Send again") { Task { await model.requestCode() } }
                        }
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(TojTheme.text)
                    .padding(.top, 18)
                }

                Label("Your conversations stay private", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(TojTheme.secondaryText)
                    .symbolRenderingMode(.hierarchical)
                    .padding(.top, 26)

                Spacer(minLength: 34)
            }
            .frame(maxWidth: 430)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(TojTheme.canvas)
        .onChange(of: model.requestedCode) { _, requested in
            focusedField = requested ? .code : nil
        }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : TojTheme.stateAnimation, value: model.requestedCode)
    }

    private var fieldTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .move(edge: .trailing)), removal: .opacity)
    }

    private var primaryEnabled: Bool {
        model.requestedCode ? model.canVerifyCode : canStart
    }

    private var shouldShowStatus: Bool {
        model.status == "Code requested"
            || model.status.hasPrefix("Code request failed")
            || model.status.hasPrefix("Sign in failed")
    }

    private var statusIsError: Bool {
        let value = model.status.lowercased()
        return value.contains("failed") || value.contains("could not") || value.contains("no account")
    }

    private func primaryAction() {
        focusedField = nil
        Task {
            if model.requestedCode {
                await model.verifyCode()
            } else {
                await model.requestCode()
            }
        }
    }
}

private struct TojInputField: View {
    let title: LocalizedStringKey
    let placeholder: LocalizedStringKey
    @Binding var text: String
    let contentType: UITextContentType?
    let keyboard: UIKeyboardType

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(TojTheme.secondaryText)
                .textCase(.uppercase)
            TextField(placeholder, text: $text)
                .font(.body.weight(.medium))
                .foregroundStyle(TojTheme.text)
                .textContentType(contentType)
                .keyboardType(keyboard)
                .textInputAutocapitalization(keyboard == .default ? .words : .never)
        }
        .padding(.horizontal, 17)
        .frame(minHeight: 62)
        .background(TojTheme.raised, in: RoundedRectangle(cornerRadius: TojRadius.field, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: TojRadius.field, style: .continuous).stroke(TojTheme.hairline, lineWidth: 0.5))
    }
}

// MARK: - Main navigation

private enum MainTab: Hashable {
    case chats
    case contacts
    case settings
    case search
}

private struct CloudMainView: View {
    @Bindable var model: CloudAppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selection: MainTab = .chats
    @State private var chatPath: [String] = []
    @State private var searchPath: [String] = []
    @State private var query = ""
    @State private var searchScope: SearchScope = .chats
    @State private var showingCompose = false
    @State private var splitDialogId: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        TabView(selection: $selection) {
            Tab("Chats", systemImage: "bubble.left.and.bubble.right.fill", value: .chats) {
                chatNavigation(path: $chatPath, focusSearchOnAppear: false)
            }

            Tab("Contacts", systemImage: "person.2.fill", value: .contacts) {
                ComingSoonView()
            }

            Tab("Settings", systemImage: "gearshape.fill", value: .settings) {
                CloudSettingsView(model: model)
            }

            Tab(value: .search, role: .search) {
                chatNavigation(path: $searchPath, focusSearchOnAppear: true)
            } label: {
                Label("Search", systemImage: "magnifyingglass")
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tint(TojTheme.text)
        .background(TojTheme.canvas)
        .onChange(of: selection) { _, newValue in
            TojFeedback.selection()
            if newValue == .search {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(180))
                    searchFocused = true
                }
            }
        }
        #if DEBUG
        .task {
            if let dialogId = ProcessInfo.processInfo.environment["TOJ_DEMO_DIALOG"], chatPath.isEmpty {
                selection = .chats
                chatPath = [dialogId]
            }
        }
        #endif
        .sheet(isPresented: $showingCompose) {
            NewChatSheet(model: model) { dialogId in
                showingCompose = false
                selection = .chats
                chatPath = [dialogId]
            }
            .presentationDetents([.height(330)])
            .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private func chatNavigation(path: Binding<[String]>, focusSearchOnAppear: Bool) -> some View {
        if horizontalSizeClass == .regular {
            NavigationSplitView {
                CloudChatsView(
                    model: model,
                    query: $query,
                    searchScope: $searchScope,
                    searchFocused: $searchFocused,
                    focusSearchOnAppear: focusSearchOnAppear,
                    onCompose: { showingCompose = true },
                    onOpen: { splitDialogId = $0 }
                )
                .navigationSplitViewColumnWidth(min: 330, ideal: 390, max: 440)
            } detail: {
                if let splitDialogId {
                    TojConversationExperience(model: model, dialogId: splitDialogId)
                } else {
                    VStack(spacing: 14) {
                        TojMark(size: 64)
                        Text("Choose a conversation")
                            .font(TojTheme.heading(.title3))
                        Text("Your messages will appear here.")
                            .font(.subheadline)
                            .foregroundStyle(TojTheme.secondaryText)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(TojTheme.canvas)
                }
            }
            .navigationSplitViewStyle(.balanced)
        } else {
            NavigationStack(path: path) {
                CloudChatsView(
                    model: model,
                    query: $query,
                    searchScope: $searchScope,
                    searchFocused: $searchFocused,
                    focusSearchOnAppear: focusSearchOnAppear,
                    onCompose: { showingCompose = true }
                )
                .navigationDestination(for: String.self) { dialogId in
                    TojConversationExperience(model: model, dialogId: dialogId)
                }
            }
        }
    }
}

// MARK: - Chats

private enum ChatFolder: String, CaseIterable, Identifiable, Hashable {
    case all
    case unread
    case pinned

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .unread: String(localized: "Unread")
        case .pinned: String(localized: "Pinned")
        }
    }

    func matches(_ dialog: CloudAppModel.Dialog) -> Bool {
        switch self {
        case .all: true
        case .unread: dialog.unreadCount > 0
        case .pinned: dialog.isPinned
        }
    }
}

private struct CloudChatsView: View {
    @Bindable var model: CloudAppModel
    @Binding var query: String
    @Binding var searchScope: SearchScope
    let searchFocused: FocusState<Bool>.Binding
    let focusSearchOnAppear: Bool
    let onCompose: () -> Void
    var onOpen: ((String) -> Void)? = nil
    @State private var folder: ChatFolder = .all

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var hasActiveDialogs: Bool { model.dialogs.contains { !$0.isArchived } }

    private var filteredDialogs: [CloudAppModel.Dialog] {
        let base = model.dialogs(matching: query, scope: searchScope)
        guard !isSearching, folder != .all else { return base }
        return base.filter { folder.matches($0) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                header
                searchField
                if isSearching {
                    if model.capabilities.contains(.richSearch) { searchScopes }
                } else if hasActiveDialogs {
                    folderFilter
                }

                if filteredDialogs.isEmpty {
                    emptyState
                        .padding(.top, 92)
                } else {
                    ForEach(filteredDialogs) { dialog in
                        dialogLink(dialog)
                        .contextMenu {
                            if model.capabilities.contains(.chatOrganization) {
                                Button(dialog.isPinned ? "Unpin" : "Pin", systemImage: dialog.isPinned ? "pin.slash" : "pin") {
                                    model.togglePinned(dialog.id)
                                }
                                Button(dialog.isMuted ? "Unmute" : "Mute", systemImage: dialog.isMuted ? "speaker.wave.2" : "speaker.slash") {
                                    model.toggleMuted(dialog.id)
                                }
                                Button("Archive", systemImage: "archivebox") { model.archive(dialog.id) }
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if model.capabilities.contains(.chatOrganization) {
                                Button { model.archive(dialog.id) } label: {
                                    Label("Archive", systemImage: "archivebox")
                                }
                                .tint(TojTheme.strong)
                                Button { model.toggleMuted(dialog.id) } label: {
                                    Label(dialog.isMuted ? "Unmute" : "Mute", systemImage: dialog.isMuted ? "speaker.wave.2" : "speaker.slash")
                                }
                                .tint(.gray)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 26)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(TojTheme.canvas)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            if focusSearchOnAppear { searchFocused.wrappedValue = true }
        }
    }

    @ViewBuilder
    private func dialogLink(_ dialog: CloudAppModel.Dialog) -> some View {
        Group {
            if let onOpen {
                Button { onOpen(dialog.id) } label: { CloudDialogRow(dialog: dialog) }
            } else {
                NavigationLink(value: dialog.id) { CloudDialogRow(dialog: dialog) }
            }
        }
        .buttonStyle(.tojPressable)
    }

    private var header: some View {
        TojNavHeader("Chats", subtitle: "Protected", subtitleIcon: "lock.fill") {
            TojGlassIconButton(systemImage: "square.and.pencil", accessibilityLabel: "New chat", action: onCompose)
        }
    }

    private var folderFilter: some View {
        TojPillFilter(items: ChatFolder.allCases, selection: $folder) { $0.title }
            .padding(.bottom, 7)
            .accessibilityLabel("Chat folders")
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(TojTheme.secondaryText)
            TextField("Search chats", text: $query)
                .focused(searchFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(TojTheme.secondaryText)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .font(.subheadline)
        .foregroundStyle(TojTheme.text)
        .padding(.horizontal, 16)
        .frame(height: 46)
        .tojGlass(in: Capsule(), interactive: true)
        .padding(.bottom, 7)
    }

    private var searchScopes: some View {
        TojPillFilter(items: SearchScope.allCases, selection: $searchScope) { $0.title }
            .padding(.vertical, 5)
            .accessibilityLabel("Search filters")
    }

    private var emptyState: some View {
        let filtered = isSearching || folder != .all
        return VStack(spacing: 14) {
            TojMark(size: 66)
            Text(filtered ? "No results" : "No chats yet")
                .font(TojTheme.heading(.title3))
                .foregroundStyle(TojTheme.text)
            Text(filtered ? "Try another name, filter, or message." : "Start a private conversation with someone you know.")
                .font(.subheadline)
                .foregroundStyle(TojTheme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 300)
    }
}

private struct CloudDialogRow: View {
    let dialog: CloudAppModel.Dialog

    var body: some View {
        HStack(spacing: 13) {
            TojAvatar(title: dialog.title, size: 52, highlighted: false)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(dialog.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(TojTheme.text)
                        .lineLimit(1)
                    if dialog.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(TojTheme.secondaryText)
                    }
                    if dialog.isMuted {
                        Image(systemName: "speaker.slash.fill")
                            .font(.caption2)
                            .foregroundStyle(TojTheme.secondaryText)
                    }
                }

                HStack(spacing: 5) {
                    if dialog.isPending {
                        ProgressView().controlSize(.mini).tint(TojTheme.secondaryText)
                    }
                    if dialog.isTyping {
                        Text("typing…")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(TojTheme.secure)
                            .lineLimit(1)
                    } else if let draft = dialog.draftPreview {
                        (Text("Draft: ").foregroundStyle(Color.red) + Text(draft).foregroundStyle(TojTheme.secondaryText))
                            .font(.subheadline)
                            .lineLimit(1)
                    } else {
                        Text(dialog.subtitle)
                            .font(.subheadline)
                            .foregroundStyle(TojTheme.secondaryText)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 7) {
                Text(TojDateFormatting.chatList(dialog.updatedAt))
                    .font(.caption2)
                    .foregroundStyle(dialog.unreadCount > 0 ? TojTheme.text : TojTheme.secondaryText)
                if dialog.unreadCount > 0 {
                    HStack(spacing: 4) {
                        if dialog.mentionCount > 0 {
                            Text("@")
                                .font(.caption2.bold())
                                .foregroundStyle(TojTheme.text)
                                .frame(width: 21, height: 21)
                                .background(TojTheme.strong, in: Circle())
                                .accessibilityLabel("Mentioned")
                        }
                        Text(dialog.unreadCount > 99 ? "99+" : "\(dialog.unreadCount)")
                            .font(.caption2.bold())
                            .foregroundStyle(dialog.isMuted ? TojTheme.secondaryText : TojTheme.onAccent)
                            .frame(minWidth: 21, minHeight: 21)
                            .padding(.horizontal, dialog.unreadCount > 99 ? 3 : 0)
                            .background(dialog.isMuted ? TojTheme.strong : TojTheme.accent, in: Capsule())
                            .contentTransition(.numericText())
                            .accessibilityLabel("\(dialog.unreadCount) unread messages")
                    }
                }
            }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens conversation. Long press for chat actions.")
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(TojTheme.hairline)
                .frame(height: 0.5)
                .padding(.leading, 65)
        }
    }
}

private struct NewChatSheet: View {
    @Bindable var model: CloudAppModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var showingGroupCreation = false
    let onOpened: (String) -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("New chat")
                        .font(TojTheme.heading(.title, weight: .bold))
                    Text("Enter the phone number of a Toj user.")
                        .font(.subheadline)
                        .foregroundStyle(TojTheme.secondaryText)
                }

                HStack(spacing: 10) {
                    Image(systemName: "phone.fill")
                        .foregroundStyle(TojTheme.secondaryText)
                    TextField("Phone number", text: $model.peerPhone)
                        .textContentType(.telephoneNumber)
                        .keyboardType(.phonePad)
                        .focused($focused)
                }
                .padding(.horizontal, 16)
                .frame(height: 54)
                .background(TojTheme.raised, in: Capsule())
                .overlay(Capsule().stroke(TojTheme.hairline, lineWidth: 0.5))

                if model.status == "No account found" || model.status.hasPrefix("Open chat failed") {
                    Text(model.status)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Button {
                    Task {
                        if let dialogId = await model.openPeer() {
                            TojFeedback.sent()
                            onOpened(dialogId)
                        }
                    }
                } label: {
                    Text("Open chat")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.glassProminent)
                .tint(TojTheme.accent)
                .foregroundStyle(TojTheme.onAccent)
                .disabled(model.peerPhone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if model.capabilities.contains(.groups) {
                    Button { showingGroupCreation = true } label: {
                        Label("New group", systemImage: "person.3.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.glass)
                    .accessibilityHint("Opens the demo group creation flow")
                }

                Spacer()
            }
            .padding(22)
            .background(TojTheme.canvas)
            .toolbar(.hidden, for: .navigationBar)
        }
        .onAppear { focused = true }
        .sheet(isPresented: $showingGroupCreation) {
            DemoGroupCreationView(dialogs: model.dialogs)
        }
    }
}

// MARK: - Contacts and settings

private struct ComingSoonView: View {
    var body: some View {
        VStack(spacing: 16) {
            TojMark(size: 78)
            Text("Contacts")
                .font(TojTheme.heading(.title, weight: .bold))
            Text("Coming soon")
                .font(.headline)
                .foregroundStyle(TojTheme.secondaryText)
            Text("Your contacts will appear here in a future update.")
                .font(.subheadline)
                .foregroundStyle(TojTheme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TojTheme.canvas)
    }
}

private struct CloudSettingsView: View {
    @Bindable var model: CloudAppModel
    @State private var showingSignOut = false
    @State private var showingDeletionWarning = false
    @State private var showingDeletionCode = false
    @State private var showingClearMedia = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    TojNavHeader("Settings")

                    HStack(spacing: 14) {
                        TojAvatar(title: model.storedSession?.displayName ?? "Toj", size: 62)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.storedSession?.displayName ?? "Toj")
                                .font(TojTheme.heading(.title3, weight: .semibold))
                            Text(model.storedSession?.phone ?? "")
                                .font(.subheadline)
                                .foregroundStyle(TojTheme.secondaryText)
                        }
                        Spacer()
                    }
                    .padding(17)
                    .background(TojTheme.raised, in: RoundedRectangle(cornerRadius: TojRadius.cardLarge, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: TojRadius.cardLarge, style: .continuous).stroke(TojTheme.hairline, lineWidth: 0.5))

                    TojSectionCard("Devices") {
                        if model.loadingDevices && model.devices.isEmpty {
                            ProgressView("Loading devices")
                                .frame(maxWidth: .infinity)
                                .padding(20)
                        } else if model.devices.isEmpty {
                            Label("No active devices", systemImage: "iphone.slash")
                                .foregroundStyle(TojTheme.secondaryText)
                                .frame(maxWidth: .infinity)
                                .padding(20)
                        } else {
                            ForEach(model.devices) { device in
                                DeviceRow(device: device) {
                                    Task { await model.revokeDevice(device) }
                                }
                            }
                        }
                    }

                    TojSectionCard("Privacy") {
                        Toggle(isOn: Binding(
                            get: { model.callPreferences.hidesIPAddress },
                            set: { model.callPreferences.hidesIPAddress = $0 }
                        )) {
                            VStack(alignment: .leading, spacing: 3) {
                                Label("Hide IP address in calls", systemImage: "network.badge.shield.half.filled")
                                    .font(.body.weight(.medium))
                                Text("Routes calls through Toj relays. This improves privacy but may add latency.")
                                    .font(.caption)
                                    .foregroundStyle(TojTheme.secondaryText)
                            }
                        }
                        .tint(TojTheme.secure)
                        .padding(.horizontal, 15)
                        .frame(minHeight: 68)
                        .disabled(model.callCoordinator.state.isInProgress)
                    }

                    TojSectionCard("Account") {
                        SettingsAction(title: "Sign out", systemImage: "rectangle.portrait.and.arrow.right") {
                            showingSignOut = true
                        }
                        SettingsAction(title: "Delete account", systemImage: "trash.fill", destructive: true) {
                            showingDeletionWarning = true
                        }
                    }

                    TojSectionCard("Storage") {
                        SettingsAction(
                            title: model.clearingMediaCache
                                ? "Clearing downloaded media…"
                                : "Clear downloaded media (\(ByteCountFormatter.string(fromByteCount: model.mediaCacheBytes, countStyle: .file)))",
                            systemImage: "externaldrive.badge.xmark"
                        ) {
                            showingClearMedia = true
                        }
                    }

                    #if DEBUG
                    if model.isDemoMode {
                        TojSectionCard("Design preview") {
                            NavigationLink {
                                PresentationStateGallery()
                            } label: {
                                HStack(spacing: 13) {
                                    TojIconTile(systemImage: "rectangle.3.group.fill")
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Interface state gallery")
                                            .font(.body.weight(.medium))
                                        Text("Loading, offline, media and call fixtures")
                                            .font(.caption)
                                            .foregroundStyle(TojTheme.secondaryText)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption.bold())
                                        .foregroundStyle(TojTheme.secondaryText)
                                }
                                .foregroundStyle(TojTheme.text)
                                .padding(.horizontal, 15)
                                .frame(minHeight: 58)
                            }
                            .buttonStyle(.tojPressable)
                        }
                    }
                    #endif
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
            .refreshable { await model.loadDevices() }
            .background(TojTheme.canvas)
            .toolbar(.hidden, for: .navigationBar)
            .task {
                await model.loadDevices()
                await model.refreshMediaCacheUsage()
            }
            .confirmationDialog("Sign out of Toj?", isPresented: $showingSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { Task { await model.signOut() } }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Delete your Toj account?", isPresented: $showingDeletionWarning, titleVisibility: .visible) {
                Button("Request deletion code", role: .destructive) {
                    Task {
                        if await model.requestAccountDeletionCode() { showingDeletionCode = true }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your identifying account data will be erased. Delivered messages remain in other participants’ chat history.")
            }
            .confirmationDialog("Clear downloaded media?", isPresented: $showingClearMedia, titleVisibility: .visible) {
                Button("Clear media", role: .destructive) { Task { await model.clearMediaCache() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Pending uploads stay protected. Sent photos, videos, files and voice notes download again when opened.")
            }
            .sheet(isPresented: $showingDeletionCode) {
                AccountDeletionView(model: model)
            }
        }
    }

}

private struct DeviceRow: View {
    let device: CloudDevice
    let revoke: () -> Void

    var body: some View {
        HStack(spacing: 13) {
            TojIconTile(systemImage: device.platform == "ios" ? "iphone" : "desktopcomputer", tint: device.current ? TojTheme.secure : nil)
            VStack(alignment: .leading, spacing: 3) {
                Text(device.deviceName.flatMap { $0.isEmpty ? nil : $0 } ?? device.platform.capitalized)
                    .font(.subheadline.weight(.semibold))
                Text(device.current ? "This device" : TojDateFormatting.lastSeen(device.lastSeenAt ?? device.createdAt))
                    .font(.caption)
                    .foregroundStyle(device.current ? TojTheme.secure : TojTheme.secondaryText)
            }
            Spacer()
            if !device.current {
                Button("Sign out", role: .destructive, action: revoke)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.tojPressable)
            }
        }
        .padding(13)
        .overlay(alignment: .bottom) {
            Rectangle().fill(TojTheme.hairline).frame(height: 0.5).padding(.leading, 62)
        }
    }
}

private struct SettingsAction: View {
    let title: String
    let systemImage: String
    var destructive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                TojIconTile(systemImage: systemImage, tint: destructive ? TojTheme.danger : nil)
                Text(title)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(TojTheme.secondaryText)
            }
            .font(.body.weight(.medium))
            .foregroundStyle(destructive ? TojTheme.danger : TojTheme.text)
            .padding(.horizontal, 15)
            .frame(minHeight: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.tojPressable)
    }
}

private struct AccountDeletionView: View {
    @Bindable var model: CloudAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingFinalConfirmation = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Text("Verify deletion")
                    .font(TojTheme.heading(.title, weight: .bold))
                Text("Enter the fresh six-digit code. This action cannot be undone.")
                    .font(.subheadline)
                    .foregroundStyle(TojTheme.secondaryText)

                TextField("6-digit code", text: $model.accountDeletionCode)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($focused)
                    .padding(.horizontal, 17)
                    .frame(height: 56)
                    .background(TojTheme.raised, in: Capsule())

                Button("Request new code") {
                    Task { _ = await model.requestAccountDeletionCode() }
                }
                .disabled(model.accountDeletionInFlight)

                Button(role: .destructive) { showingFinalConfirmation = true } label: {
                    Text("Permanently delete account")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 54)
                }
                .buttonStyle(.glassProminent)
                .tint(.red)
                .disabled(model.accountDeletionInFlight || model.accountDeletionCode.filter(\.isNumber).count != 6)

                if model.accountDeletionInFlight {
                    ProgressView("Deleting account")
                }
                Spacer()
            }
            .padding(22)
            .background(TojTheme.canvas)
            .navigationTitle("Delete account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        model.cancelAccountDeletion()
                        dismiss()
                    }
                }
            }
            .alert("Permanently delete account?", isPresented: $showingFinalConfirmation) {
                Button("Delete forever", role: .destructive) {
                    Task { if await model.deleteAccount() { dismiss() } }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("All devices will be signed out and your identifying account data will be erased.")
            }
            .interactiveDismissDisabled(model.accountDeletionInFlight)
            .onAppear { focused = true }
            .onChange(of: model.storedSession == nil) { _, signedOut in if signedOut { dismiss() } }
            .onDisappear { model.cancelAccountDeletion() }
        }
    }
}

// MARK: - Formatting

enum TojDateFormatting {
    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain = ISO8601DateFormatter()

    static func date(_ raw: String) -> Date? {
        isoFractional.date(from: raw) ?? isoPlain.date(from: raw)
    }

    static func chatList(_ raw: String) -> String {
        guard let date = date(raw) else { return "" }
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day, days < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    static func message(_ raw: String) -> String {
        date(raw)?.formatted(date: .omitted, time: .shortened) ?? ""
    }

    /// Media-viewer subtitle, e.g. "today at 02:49" / "yesterday at 14:11" / "14 Jul at 09:03".
    static func mediaTimestamp(_ raw: String) -> String {
        guard let date = date(raw) else { return "" }
        let time = date.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return String(localized: "today at \(time)")
        }
        if calendar.isDateInYesterday(date) {
            return String(localized: "yesterday at \(time)")
        }
        let day = date.formatted(.dateTime.day().month(.abbreviated))
        return String(localized: "\(day) at \(time)")
    }

    static func lastSeen(_ raw: String) -> String {
        guard let date = date(raw) else { return String(localized: "Activity time unavailable") }
        return date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }

    /// In-chat date separator: "Today", "Yesterday", "July 14", or "August 11, 2025".
    static func dayHeader(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return String(localized: "Today") }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday") }
        if calendar.isDate(date, equalTo: .now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.wide).day())
        }
        return date.formatted(.dateTime.month(.wide).day().year())
    }
}

#Preview {
    CloudRootView()
        .preferredColorScheme(.dark)
}
