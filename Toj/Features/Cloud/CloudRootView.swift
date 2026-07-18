import SwiftUI

struct CloudRootView: View {
    private static let isRunningUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model = CloudAppModel.shared

    var body: some View {
        Group {
            switch model.launchPhase {
            case .restoringLocal:
                CloudLocalLaunchView()
            case .recoveringStore:
                CloudLocalRecoveryView(status: model.status) {
                    Task { await model.retryLocalRecovery() }
                }
            case .signedOut:
                CloudAuthView(model: model)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.985)))
            case .localReady:
                if model.storedSession == nil {
                    CloudAuthView(model: model)
                } else {
                    CloudMainView(model: model)
                        .transition(.opacity)
                }
            }
        }
        .background(TojTheme.canvas.ignoresSafeArea())
        .animation(reduceMotion ? .easeOut(duration: 0.15) : TojTheme.stateAnimation, value: model.launchPhase)
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
            guard !Self.isRunningUnitTests else { return }
            Task {
                let isActive = phase == .active
                await model.setForegroundActive(isActive)
                if isActive { await model.activateForegroundServices() }
            }
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

private struct CloudLocalLaunchView: View {
    var body: some View {
        VStack(spacing: 18) {
            TojMark(size: 76)
            ProgressView()
                .tint(TojTheme.gold)
                .accessibilityLabel("Opening encrypted messages")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TojTheme.canvas)
    }
}

private struct CloudLocalRecoveryView: View {
    let status: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.trianglebadge.exclamationmark")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(TojTheme.gold)
            Text("Encrypted messages are unavailable")
                .font(TojTheme.heading(.title2, weight: .bold))
                .foregroundStyle(TojTheme.text)
            Text(status)
                .font(.subheadline)
                .foregroundStyle(TojTheme.secondaryText)
                .multilineTextAlignment(.center)
            Button("Try Again", action: retry)
                .buttonStyle(.borderedProminent)
                .tint(TojTheme.gold)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TojTheme.canvas)
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
    case contacts
    case calls
    case chats
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

    private var unreadCount: Int {
        model.dialogs.reduce(0) { $0 + ($1.isArchived ? 0 : $1.unreadCount) }
    }

    var body: some View {
        TabView(selection: $selection) {
            Tab("Contacts", systemImage: "person.crop.circle.fill", value: .contacts) {
                CloudContactsView(model: model)
            }

            Tab("Calls", systemImage: "phone.fill", value: .calls) {
                ComingSoonView(
                    title: "Calls", systemImage: "phone.fill",
                    detail: "Recent voice and video calls will appear here."
                )
            }

            Tab("Chats", systemImage: "bubble.left.and.bubble.right.fill", value: .chats) {
                chatNavigation(path: $chatPath, focusSearchOnAppear: false)
            }
            .badge(unreadCount)

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
        .onChange(of: selection) { _, _ in
            TojFeedback.selection()
        }
        #if DEBUG
        .task {
            if ProcessInfo.processInfo.environment["TOJ_DEMO_SEARCH"] == "1" {
                selection = .search
                return
            }
            if ProcessInfo.processInfo.environment["TOJ_DEMO_CONTACTS"] == "1" {
                selection = .contacts
                return
            }
            if ProcessInfo.processInfo.environment["TOJ_DEMO_SETTINGS"] == "1" {
                selection = .settings
                return
            }
            if let dialogId = ProcessInfo.processInfo.environment["TOJ_DEMO_DIALOG"], chatPath.isEmpty {
                selection = .chats
                model.prepareConversationOpen(dialogId: dialogId)
                chatPath = [dialogId]
            }
        }
        #endif
        .sheet(isPresented: $showingCompose) {
            NewChatSheet(model: model) { dialogId in
                showingCompose = false
                selection = .chats
                model.prepareConversationOpen(dialogId: dialogId)
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
                    focusSearchOnAppear: focusSearchOnAppear,
                    onCompose: { showingCompose = true },
                    onOpen: {
                        model.prepareConversationOpen(dialogId: $0)
                        splitDialogId = $0
                    }
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
                    focusSearchOnAppear: focusSearchOnAppear,
                    onCompose: { showingCompose = true },
                    onOpen: {
                        model.prepareConversationOpen(dialogId: $0)
                        path.wrappedValue.append($0)
                    }
                )
                .navigationDestination(for: String.self) { dialogId in
                    TojConversationExperience(model: model, dialogId: dialogId)
                }
            }
        }
    }
}

// MARK: - Chats

nonisolated enum ChatSearchDrawerBehavior {
    static let height: CGFloat = 52
    static let revealDeadZone: CGFloat = 14
    static let openThreshold: CGFloat = 22
    static let closeThreshold: CGFloat = 14

    static func revealIsArmed(startingAt offset: CGFloat) -> Bool {
        offset <= height + 0.5
    }

    static func revealProgress(at offset: CGFloat, revealWasArmed: Bool) -> CGFloat {
        guard revealWasArmed else { return 0 }
        let visibleHeight = height - min(max(offset, 0), height)
        let revealRange = height - revealDeadZone
        return min(max((visibleHeight - revealDeadZone) / revealRange, 0), 1)
    }

    static func shouldOpen(wasOpen: Bool, revealWasArmed: Bool, offset: CGFloat) -> Bool {
        guard revealWasArmed else { return false }
        let clampedOffset = max(offset, 0)
        guard clampedOffset < height else { return false }
        return wasOpen
            ? clampedOffset < closeThreshold
            : height - clampedOffset >= openThreshold
    }
}

private struct CloudChatsView: View {
    @Bindable var model: CloudAppModel
    @Binding var query: String
    @Binding var searchScope: SearchScope
    let focusSearchOnAppear: Bool
    let onCompose: () -> Void
    var onOpen: ((String) -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isEditing = false
    @State private var isSearchDrawerOpen = false
    @State private var searchScrollOffset = ChatSearchDrawerBehavior.height
    @State private var searchRevealWasArmed = true
    @FocusState private var searchFocused: Bool

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var filteredDialogs: [CloudAppModel.Dialog] {
        model.dialogs(matching: query, scope: searchScope)
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        searchDrawer
                            .id("chat-search")
                        Color.clear
                            .frame(height: 0)
                            .id("chat-list-top")

                        if isSearching, model.capabilities.contains(.richSearch) {
                            TojPillFilter(items: SearchScope.allCases, selection: $searchScope) { $0.title }
                                .padding(.bottom, 6)
                                .accessibilityLabel("Search filters")
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
                    .frame(minHeight: geometry.size.height + 54, alignment: .top)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 26)
                }
                .scrollDismissesKeyboard(.interactively)
                .onScrollGeometryChange(for: CGFloat.self) { scrollGeometry in
                    normalizedScrollOffset(scrollGeometry)
                } action: { _, newOffset in
                    if !searchRevealWasArmed, newOffset < ChatSearchDrawerBehavior.height {
                        searchScrollOffset = ChatSearchDrawerBehavior.height
                        proxy.scrollTo("chat-list-top", anchor: .top)
                    } else {
                        searchScrollOffset = newOffset
                    }
                }
                .onScrollPhaseChange { oldPhase, newPhase, context in
                    let offset = normalizedScrollOffset(context.geometry)
                    if newPhase == .tracking {
                        searchRevealWasArmed = ChatSearchDrawerBehavior.revealIsArmed(startingAt: offset)
                        return
                    }
                    guard oldPhase == .interacting,
                          newPhase == .decelerating || newPhase == .idle else { return }
                    settleSearchDrawer(
                        at: offset,
                        using: proxy
                    )
                }
                .onAppear {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(80))
                        #if DEBUG
                        if ProcessInfo.processInfo.environment["TOJ_DEMO_EDIT"] == "1" {
                            isEditing = true
                        }
                        #endif
                        if focusSearchOnAppear {
                            isSearchDrawerOpen = true
                            searchRevealWasArmed = true
                            withAnimation(reduceMotion ? .easeOut(duration: 0.14) : TojTheme.stateAnimation) {
                                proxy.scrollTo("chat-search", anchor: .top)
                            }
                            searchFocused = true
                        } else {
                            isSearchDrawerOpen = false
                            searchRevealWasArmed = true
                            proxy.scrollTo("chat-list-top", anchor: .top)
                        }
                    }
                }
            }
        }
        .background(TojTheme.canvas)
        .navigationTitle("Chats")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(isEditing ? "Done" : "Edit") {
                    withAnimation(reduceMotion ? .easeOut(duration: 0.14) : TojTheme.stateAnimation) {
                        isEditing.toggle()
                    }
                    TojFeedback.selection()
                }
                .font(.body.weight(.medium))
                .foregroundStyle(TojTheme.text)
            }
            ToolbarItem(placement: .principal) {
                Text("Chats")
                    .font(TojTheme.heading(.headline, weight: .semibold))
                    .foregroundStyle(TojTheme.text)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onCompose) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 17, weight: .semibold))
                }
                .buttonStyle(.glass)
                .accessibilityLabel("New chat")
            }
        }
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.replicaSyncState != .ready {
                ReplicaSyncBanner(state: model.replicaSyncState) {
                    model.retryReplicaSync()
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(
            reduceMotion ? .easeOut(duration: 0.14) : TojTheme.stateAnimation,
            value: model.replicaSyncState
        )
    }

    private var searchDrawer: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(TojTheme.secondaryText)
            TextField("Search chats", text: $query)
                .focused($searchFocused)
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
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .font(.subheadline)
        .foregroundStyle(TojTheme.text)
        .padding(.horizontal, 14)
        .frame(height: 44)
        .tojGlass(in: Capsule(), interactive: true)
        .padding(.bottom, 8)
        .opacity(Double(searchDrawerRevealProgress))
        .scaleEffect(
            x: 1,
            y: 0.92 + (0.08 * searchDrawerRevealProgress),
            anchor: .top
        )
        .offset(y: -8 * (1 - searchDrawerRevealProgress))
        .allowsHitTesting(searchDrawerRevealProgress > 0.95)
    }

    private var searchDrawerRevealProgress: CGFloat {
        ChatSearchDrawerBehavior.revealProgress(
            at: searchScrollOffset,
            revealWasArmed: searchRevealWasArmed
        )
    }

    private func normalizedScrollOffset(_ geometry: ScrollGeometry) -> CGFloat {
        geometry.contentOffset.y + geometry.contentInsets.top
    }

    private func settleSearchDrawer(at offset: CGFloat, using proxy: ScrollViewProxy) {
        let clampedOffset = max(offset, 0)
        guard clampedOffset < ChatSearchDrawerBehavior.height else {
            isSearchDrawerOpen = false
            return
        }

        let shouldOpen = ChatSearchDrawerBehavior.shouldOpen(
            wasOpen: isSearchDrawerOpen,
            revealWasArmed: searchRevealWasArmed,
            offset: clampedOffset
        )

        isSearchDrawerOpen = shouldOpen
        if !shouldOpen {
            searchFocused = false
        }

        withAnimation(reduceMotion ? .easeOut(duration: 0.14) : .snappy(duration: 0.28, extraBounce: 0.08)) {
            proxy.scrollTo(shouldOpen ? "chat-search" : "chat-list-top", anchor: .top)
        }
    }

    @ViewBuilder
    private func dialogLink(_ dialog: CloudAppModel.Dialog) -> some View {
        Group {
            if isEditing, model.capabilities.contains(.chatOrganization) {
                HStack(spacing: 0) {
                    CloudDialogRow(dialog: dialog)
                    Button {
                        withAnimation(reduceMotion ? .easeOut(duration: 0.14) : TojTheme.stateAnimation) {
                            model.archive(dialog.id)
                        }
                    } label: {
                        Image(systemName: "archivebox.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(TojTheme.gold)
                            .frame(width: 44, height: 44)
                            .background(TojTheme.raised, in: Circle())
                    }
                    .buttonStyle(.tojPressable)
                    .accessibilityLabel("Archive")
                }
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            } else if let onOpen {
                Button { onOpen(dialog.id) } label: { CloudDialogRow(dialog: dialog) }
            } else {
                NavigationLink(value: dialog.id) { CloudDialogRow(dialog: dialog) }
            }
        }
        .buttonStyle(.tojPressable)
        .accessibilityIdentifier("chat-row-\(dialog.id)")
    }

    private var emptyState: some View {
        let filtered = isSearching
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

private struct ReplicaSyncBanner: View {
    let state: ReplicaSyncState
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if state.showsProgress {
                ProgressView()
                    .controlSize(.small)
                    .tint(TojTheme.gold)
            } else {
                Image(systemName: state.systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.orange)
            }
            Text(state.title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(TojTheme.text)
                .lineLimit(1)
            Spacer(minLength: 8)
            if state.showsRetry {
                Button(action: retry) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(TojTheme.gold)
            }
        }
        .padding(.horizontal, 13)
        .frame(minHeight: 44)
        .tojGlass(in: Capsule(), interactive: state.showsRetry)
    }
}

private struct CloudDialogRow: View {
    let dialog: CloudAppModel.Dialog

    var body: some View {
        HStack(spacing: 12) {
            TojAvatar(
                title: dialog.title,
                size: 56,
                highlighted: false,
                colorIndex: dialog.profileColorIndex
            )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(dialog.title)
                        .font(TojTheme.heading(.headline, weight: .semibold))
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
                        HStack(spacing: 3) {
                            Text("Draft:")
                                .foregroundStyle(Color.red)
                            Text(draft)
                                .foregroundStyle(TojTheme.secondaryText)
                        }
                            .lineLimit(1)
                    } else {
                        if dialog.lastMessageMine, !dialog.isPending {
                            Image(systemName: "checkmark")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(TojTheme.secure)
                        }
                        if let systemImage = dialog.previewKind.systemImage {
                            Image(systemName: systemImage)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(TojTheme.secondaryText)
                        }
                        Text(dialog.subtitle)
                            .foregroundStyle(TojTheme.secondaryText)
                            .lineLimit(1)
                    }
                }
                .font(.subheadline)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 5) {
                Text(TojDateFormatting.chatList(dialog.updatedAt))
                    .font(.caption)
                    .monospacedDigit()
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
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens conversation. Long press for chat actions.")
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(TojTheme.hairline)
                .frame(height: 0.5)
                .padding(.leading, 68)
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
    let title: LocalizedStringKey
    let systemImage: String
    let detail: LocalizedStringKey

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(TojTheme.gold)
                .frame(width: 78, height: 78)
                .background(TojTheme.raised, in: Circle())
                .overlay(Circle().stroke(TojTheme.hairlineStrong, lineWidth: 0.5))
            Text(title)
                .font(TojTheme.heading(.title, weight: .bold))
            Text("Coming soon")
                .font(.headline)
                .foregroundStyle(TojTheme.secondaryText)
            Text(detail)
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
    @State private var pendingLogoutItemCount = 0
    @State private var showingDeletionWarning = false
    @State private var showingDeletionCode = false
    @State private var showingClearMedia = false
    @State private var showingProfileEditor = false
    @State private var profilePhotoData: Data?

    private var displayName: String {
        let candidate = model.storedSession?.displayName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return candidate.isEmpty ? String(localized: "Toj") : candidate
    }

    private var phone: String {
        model.storedSession?.phone ?? ""
    }

    private var profilePhotoAccountId: String? {
        model.storedSession?.session.accountId
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 20) {
                    ZStack(alignment: .topTrailing) {
                        SettingsProfileCard(
                            displayName: displayName,
                            phone: phone,
                            photoData: profilePhotoData,
                            colorIndex: model.profileDetails.colorIndex
                        )

                        Button {
                            showingProfileEditor = true
                            TojFeedback.selection()
                        } label: {
                            Text("Edit")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(TojTheme.text)
                                .padding(.horizontal, 17)
                                .frame(height: 44)
                                .contentShape(Capsule())
                                .tojGlass(in: Capsule(), interactive: true)
                        }
                        .buttonStyle(.tojPressable)
                        .accessibilityHint("Opens your profile details")
                        .padding(.top, 4)
                    }
                    .padding(.top, 16)

                    TojSectionCard {
                        settingsLink(
                            title: "Saved Messages",
                            icon: "bookmark.fill",
                            colors: [Color(hex: 0x4EA5FF), Color(hex: 0x2474ED)],
                            divider: true,
                            detail: "Keep notes, links and files close at hand."
                        )
                        settingsLink(
                            title: "Recent Calls",
                            icon: "phone.fill",
                            colors: [Color(hex: 0x57DC7C), Color(hex: 0x27B85A)],
                            divider: true,
                            detail: "Your voice and video call history will live here."
                        )
                        NavigationLink {
                            SettingsDevicesView(model: model)
                        } label: {
                            SettingsRowLabel(
                                title: "Devices",
                                icon: "iphone.gen3",
                                colors: [Color(hex: 0xFFC85A), Color(hex: 0xF59B22)],
                                value: model.devices.isEmpty ? nil : "\(model.devices.count)",
                                showsDivider: false
                            )
                        }
                        .buttonStyle(.tojPressable(scale: 0.985))
                    }

                    TojSectionCard {
                        settingsLink(
                            title: "Notifications and Sounds",
                            icon: "bell.badge.fill",
                            colors: [Color(hex: 0xFF746D), Color(hex: 0xF04444)],
                            divider: true,
                            detail: "Fine-tuned alerts, tones and notification controls are on the way."
                        )
                        settingsLink(
                            title: "Privacy and Security",
                            icon: "lock.fill",
                            colors: [Color(hex: 0xC4C7CE), Color(hex: 0x858B96)],
                            divider: true,
                            detail: "Advanced privacy controls and security options are coming soon."
                        )
                        NavigationLink {
                            DataStorageSettingsView(model: model)
                        } label: {
                            SettingsRowLabel(
                                title: "Data and Storage",
                                icon: "externaldrive.fill",
                                colors: [Color(hex: 0x55DE81), Color(hex: 0x22B95A)],
                                value: nil,
                                showsDivider: true
                            )
                        }
                        .buttonStyle(.tojPressable(scale: 0.985))
                        settingsLink(
                            title: "Appearance",
                            icon: "circle.lefthalf.filled",
                            colors: [Color(hex: 0x61CCFF), Color(hex: 0x299DDA)],
                            divider: true,
                            detail: "Themes, chat backgrounds and text sizing are coming soon."
                        )
                        settingsLink(
                            title: "Power Saving",
                            icon: "battery.25percent",
                            colors: [Color(hex: 0xFFC85C), Color(hex: 0xF49A22)],
                            value: "Off",
                            divider: true,
                            detail: "Power-saving controls will help Toj use less energy."
                        )
                        settingsLink(
                            title: "Language",
                            icon: "globe",
                            colors: [Color(hex: 0xCE70F4), Color(hex: 0x9D43D7)],
                            value: "English",
                            divider: false,
                            detail: "More interface languages are being prepared."
                        )
                    }

                    TojSectionCard("Call privacy") {
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

                    TojSectionCard("Info") {
                        settingsLink(
                            title: "Ask a Question",
                            icon: "questionmark.bubble.fill",
                            colors: [Color(hex: 0xFFC254), Color(hex: 0xF39A1E)],
                            divider: true,
                            detail: "A direct line to Toj support is coming soon."
                        )
                        settingsLink(
                            title: "Toj FAQ",
                            icon: "questionmark.circle.fill",
                            colors: [Color(hex: 0x63CFFF), Color(hex: 0x2D9FDC)],
                            divider: true,
                            detail: "Helpful answers and guides are being written now."
                        )
                        settingsLink(
                            title: "Toj Features",
                            icon: "lightbulb.fill",
                            colors: [Color(hex: 0xFFE95B), Color(hex: 0xF1BC19)],
                            divider: false,
                            detail: "Discover everything Toj can do as new features arrive."
                        )
                    }

                    TojSectionCard("Storage and account") {
                        SettingsAction(
                            title: model.clearingMediaCache
                                ? "Clearing downloaded media…"
                                : "Clear downloaded media",
                            systemImage: "externaldrive.badge.xmark",
                            value: ByteCountFormatter.string(fromByteCount: model.mediaCacheBytes, countStyle: .file),
                            showsDivider: true
                        ) {
                            showingClearMedia = true
                        }
                        SettingsAction(
                            title: "Sign out",
                            systemImage: "rectangle.portrait.and.arrow.right",
                            showsDivider: true
                        ) {
                            Task {
                                pendingLogoutItemCount = await model.pendingDestructiveLogoutItemCount()
                                showingSignOut = true
                            }
                        }
                        SettingsAction(
                            title: "Delete account",
                            systemImage: "trash.fill",
                            destructive: true,
                            showsDivider: false
                        ) {
                            showingDeletionWarning = true
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
            .background(TojTheme.canvas)
            .toolbar(.hidden, for: .navigationBar)
            .task(id: profilePhotoAccountId) {
                await model.loadDevices()
                await model.loadProfileDetails()
                await model.refreshMediaCacheUsage()
                if let accountId = profilePhotoAccountId {
                    profilePhotoData = await EncryptedProfilePhotoStore.load(accountId: accountId)
                } else {
                    profilePhotoData = nil
                }
                #if DEBUG
                if ProcessInfo.processInfo.environment["TOJ_DEMO_PROFILE_EDIT"] == "1" {
                    showingProfileEditor = true
                }
                #endif
            }
            .confirmationDialog(
                pendingLogoutItemCount > 0
                    ? "Discard pending work and sign out?"
                    : "Sign out of Toj?",
                isPresented: $showingSignOut,
                titleVisibility: .visible
            ) {
                Button(
                    pendingLogoutItemCount > 0
                        ? "Discard \(pendingLogoutItemCount) pending item\(pendingLogoutItemCount == 1 ? "" : "s")"
                        : "Sign out",
                    role: .destructive
                ) { Task { await model.signOut() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                if pendingLogoutItemCount > 0 {
                    Text("Pending messages, edits, or uploads have not reached the cloud and will be permanently removed from this device.")
                } else {
                    Text("Your encrypted local replica and downloaded media will be removed from this device.")
                }
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
            .fullScreenCover(isPresented: $showingProfileEditor) {
                ProfileEditView(
                    model: model,
                    persistedPhotoData: $profilePhotoData,
                    photoAccountId: profilePhotoAccountId
                )
                .presentationBackground(TojTheme.canvas)
            }
        }
    }

    @ViewBuilder
    private func settingsLink(
        title: LocalizedStringKey,
        icon: String,
        colors: [Color],
        value: LocalizedStringKey? = nil,
        divider: Bool,
        detail: LocalizedStringKey
    ) -> some View {
        NavigationLink {
            SettingsComingSoonView(title: title, systemImage: icon, colors: colors, detail: detail)
        } label: {
            SettingsRowLabel(
                title: title,
                icon: icon,
                colors: colors,
                value: value,
                showsDivider: divider
            )
        }
        .buttonStyle(.tojPressable(scale: 0.985))
    }

}

private struct SettingsProfileCard: View {
    let displayName: String
    let phone: String
    let photoData: Data?
    let colorIndex: Int

    var body: some View {
        VStack(spacing: 14) {
            SettingsProfileAvatar(
                displayName: displayName,
                photoData: photoData,
                size: 94,
                colorIndex: colorIndex
            )
                .shadow(color: TojProfilePalette.primary(colorIndex).opacity(0.18), radius: 26, y: 12)

            VStack(spacing: 4) {
                Text(displayName)
                    .font(TojTheme.heading(.title2, weight: .bold))
                    .foregroundStyle(TojTheme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Text(phone)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(TojTheme.secondaryText)
                    .contentTransition(.numericText())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .padding(.horizontal, 18)
        .accessibilityElement(children: .combine)
    }
}

struct SettingsProfileAvatar: View {
    let displayName: String
    let photoData: Data?
    let size: CGFloat
    let colorIndex: Int

    var body: some View {
        Group {
            if let photoData, let image = UIImage(data: photoData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                ZStack {
                    Circle()
                        .fill(
                            TojProfilePalette.gradient(colorIndex)
                        )
                    Text(displayName.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() } ?? "T")
                        .font(TojTheme.heading(.largeTitle, weight: .medium))
                        .foregroundStyle(.white)
                }
                .frame(width: size, height: size)
            }
        }
        .overlay(Circle().stroke(Color.white.opacity(0.16), lineWidth: 1))
        .accessibilityHidden(true)
    }
}

struct SettingsIconTile: View {
    let systemImage: String
    let colors: [Color]
    var size: CGFloat = 34

    var body: some View {
        Image(systemName: systemImage)
            .symbolRenderingMode(.monochrome)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
            )
            .overlay(RoundedRectangle(cornerRadius: size * 0.29, style: .continuous).stroke(Color.white.opacity(0.16), lineWidth: 0.5))
            .shadow(color: (colors.last ?? .clear).opacity(0.16), radius: 7, y: 3)
            .accessibilityHidden(true)
    }
}

private struct SettingsRowLabel: View {
    let title: LocalizedStringKey
    let icon: String
    let colors: [Color]
    var value: LocalizedStringKey? = nil
    let showsDivider: Bool

    var body: some View {
        HStack(spacing: 14) {
            SettingsIconTile(systemImage: icon, colors: colors)
            Text(title)
                .font(.body.weight(.medium))
                .foregroundStyle(TojTheme.text)
                .lineLimit(1)
            Spacer(minLength: 10)
            if let value {
                Text(value)
                    .font(.body)
                    .foregroundStyle(TojTheme.secondaryText)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(TojTheme.tertiaryText)
        }
        .padding(.horizontal, 15)
        .frame(minHeight: 58)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            if showsDivider {
                Rectangle()
                    .fill(TojTheme.hairlineStrong)
                    .frame(height: 0.5)
                    .padding(.leading, 63)
            }
        }
    }
}

private struct SettingsComingSoonView: View {
    let title: LocalizedStringKey
    let systemImage: String
    let colors: [Color]
    let detail: LocalizedStringKey
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animated = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack {
                Circle()
                    .fill((colors.last ?? TojTheme.accent).opacity(0.14))
                    .frame(width: 156, height: 156)
                    .blur(radius: animated ? 18 : 8)
                    .scaleEffect(animated ? 1.08 : 0.9)
                SettingsIconTile(systemImage: systemImage, colors: colors, size: 82)
                    .shadow(color: (colors.last ?? .clear).opacity(0.28), radius: 28, y: 14)
            }
            .padding(.bottom, 30)

            Text(title)
                .font(TojTheme.heading(.title, weight: .bold))
                .foregroundStyle(TojTheme.text)
                .multilineTextAlignment(.center)
            Text("Coming soon")
                .font(.headline.weight(.semibold))
                .foregroundStyle(colors.first ?? TojTheme.accent)
                .padding(.top, 8)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(TojTheme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
                .padding(.top, 10)
            Spacer()
            Text("We’re making it worth the wait.")
                .font(.caption.weight(.medium))
                .foregroundStyle(TojTheme.tertiaryText)
                .padding(.bottom, 28)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TojTheme.canvas)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                animated = true
            }
        }
    }
}

private struct SettingsDevicesView: View {
    @Bindable var model: CloudAppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 10) {
                    SettingsIconTile(
                        systemImage: "iphone.gen3",
                        colors: [Color(hex: 0xFFC85A), Color(hex: 0xF59B22)],
                        size: 72
                    )
                    Text("Active sessions")
                        .font(TojTheme.heading(.title2, weight: .bold))
                    Text("Review the devices signed in to your Toj account. You can end any session you don’t recognize.")
                        .font(.subheadline)
                        .foregroundStyle(TojTheme.secondaryText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }
                .padding(.vertical, 18)

                TojSectionCard("Devices") {
                    if model.loadingDevices && model.devices.isEmpty {
                        ProgressView("Loading devices")
                            .frame(maxWidth: .infinity)
                            .padding(24)
                    } else if model.devices.isEmpty {
                        Label("No active devices", systemImage: "iphone.slash")
                            .foregroundStyle(TojTheme.secondaryText)
                            .frame(maxWidth: .infinity)
                            .padding(24)
                    } else {
                        ForEach(Array(model.devices.enumerated()), id: \.element.id) { index, device in
                            DeviceRow(device: device, showsDivider: index < model.devices.count - 1) {
                                Task { await model.revokeDevice(device) }
                            }
                        }
                    }
                }
            }
            .padding(16)
            .padding(.bottom, 24)
        }
        .background(TojTheme.canvas)
        .navigationTitle("Devices")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.loadDevices() }
        .task { await model.loadDevices() }
    }
}

private struct DeviceRow: View {
    let device: CloudDevice
    var showsDivider = true
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
            if showsDivider {
                Rectangle().fill(TojTheme.hairline).frame(height: 0.5).padding(.leading, 62)
            }
        }
    }
}

private struct SettingsAction: View {
    let title: String
    let systemImage: String
    var value: String? = nil
    var destructive = false
    var showsDivider = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                SettingsIconTile(
                    systemImage: systemImage,
                    colors: destructive
                        ? [Color(hex: 0xFF746D), Color(hex: 0xE33E3E)]
                        : [Color(hex: 0x727986), Color(hex: 0x414752)]
                )
                Text(title)
                Spacer(minLength: 10)
                if let value {
                    Text(value)
                        .font(.body)
                        .foregroundStyle(TojTheme.secondaryText)
                }
            }
            .font(.body.weight(.medium))
            .foregroundStyle(destructive ? TojTheme.danger : TojTheme.text)
            .padding(.horizontal, 15)
            .frame(minHeight: 58)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                if showsDivider {
                    Rectangle()
                        .fill(TojTheme.hairlineStrong)
                        .frame(height: 0.5)
                        .padding(.leading, 63)
                }
            }
        }
        .buttonStyle(.tojPressable(scale: 0.985))
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
