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
                .foregroundStyle(TojTheme.canvas)
                .background(TojTheme.text, in: Capsule())
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
        .background(TojTheme.raised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
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

private struct CloudChatsView: View {
    @Bindable var model: CloudAppModel
    @Binding var query: String
    @Binding var searchScope: SearchScope
    let searchFocused: FocusState<Bool>.Binding
    let focusSearchOnAppear: Bool
    let onCompose: () -> Void
    var onOpen: ((String) -> Void)? = nil

    private var filteredDialogs: [CloudAppModel.Dialog] { model.dialogs(matching: query, scope: searchScope) }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                header
                searchField
                if model.capabilities.contains(.richSearch), !query.isEmpty {
                    searchScopes
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
        .buttonStyle(.plain)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Chats")
                    .font(TojTheme.heading(.largeTitle, weight: .bold))
                    .foregroundStyle(TojTheme.text)
                Label("Protected", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(TojTheme.secondaryText)
            }
            Spacer()
            Button(action: onCompose) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 46, height: 46)
            }
            .buttonStyle(.glass)
            .accessibilityLabel("New chat")
        }
        .padding(.top, 12)
        .padding(.bottom, 15)
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
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(SearchScope.allCases) { scope in
                    Button {
                        searchScope = scope
                        TojFeedback.selection()
                    } label: {
                        Text(scope.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(searchScope == scope ? TojTheme.canvas : TojTheme.secondaryText)
                            .padding(.horizontal, 13)
                            .frame(height: 32)
                            .background(searchScope == scope ? TojTheme.text : TojTheme.raised, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .scrollIndicators(.hidden)
        .contentMargins(.horizontal, 0)
        .padding(.vertical, 5)
        .accessibilityLabel("Search filters")
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            TojMark(size: 66)
            Text(query.isEmpty ? "No chats yet" : "No results")
                .font(TojTheme.heading(.title3))
                .foregroundStyle(TojTheme.text)
            Text(query.isEmpty ? "Start a private conversation with someone you know." : "Try another name or message.")
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
                            .foregroundStyle(TojTheme.canvas)
                            .frame(minWidth: 21, minHeight: 21)
                            .padding(.horizontal, dialog.unreadCount > 99 ? 3 : 0)
                            .background(TojTheme.text, in: Capsule())
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
                .fill(Color.white.opacity(0.055))
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
                .overlay(Capsule().stroke(Color.white.opacity(0.09), lineWidth: 0.5))

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
                .tint(TojTheme.text)
                .foregroundStyle(TojTheme.canvas)
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

// MARK: - Conversation

private struct CloudConversationView: View {
    @Bindable var model: CloudAppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var composerFocused: Bool
    let dialogId: String

    private var canSend: Bool {
        model.activeDialogId == dialogId
            && !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            conversationHeader
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        Label("Protected conversation", systemImage: "lock.fill")
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

                        ForEach(model.lines) { line in
                            CloudBubble(line: line)
                                .id(line.id)
                                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97, anchor: line.mine ? .bottomTrailing : .bottomLeading)))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                }
                .scrollDismissesKeyboard(.interactively)
                .defaultScrollAnchor(.bottom)
                .onChange(of: model.lines) { _, lines in
                    guard let last = lines.last else { return }
                    withAnimation(reduceMotion ? .easeOut(duration: 0.12) : TojTheme.microAnimation) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .background(TojTheme.canvas)
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .task(id: dialogId) { await model.selectDialog(dialogId) }
        .onDisappear { model.deselectDialog(dialogId) }
        .animation(reduceMotion ? .easeOut(duration: 0.12) : TojTheme.microAnimation, value: model.lines)
    }

    private var conversationHeader: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .bold))
                        .frame(width: 46, height: 46)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Back")

                VStack(spacing: 1) {
                    Text(model.dialogTitle(dialogId))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(TojTheme.text)
                        .lineLimit(1)
                    Label("Protected", systemImage: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(TojTheme.secure)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .padding(.horizontal, 14)
                .tojGlass(in: Capsule())

                TojAvatar(title: model.dialogTitle(dialogId), size: 46)
                    .padding(2)
                    .tojGlass(in: Circle())
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $model.draft, axis: .vertical)
                .focused($composerFocused)
                .lineLimit(1...5)
                .font(.body)
                .foregroundStyle(TojTheme.text)
                .padding(.leading, 10)
                .padding(.vertical, 12)
                .submitLabel(.send)
                .onSubmit {
                    if canSend { send() }
                }

            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(canSend ? TojTheme.canvas : TojTheme.secondaryText)
                    .frame(width: 44, height: 44)
                    .background(canSend ? TojTheme.text : TojTheme.strong, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
        .padding(6)
        .tojGlass(in: Capsule(), interactive: true)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(TojTheme.canvas.opacity(0.94))
    }

    private func send() {
        guard canSend else { return }
        TojFeedback.sent()
        Task { await model.sendDraft() }
    }
}

private struct CloudBubble: View {
    let line: CloudAppModel.Line

    var body: some View {
        HStack {
            if line.mine { Spacer(minLength: 54) }

            VStack(alignment: line.mine ? .trailing : .leading, spacing: 4) {
                Text(line.text)
                    .font(.body)
                    .foregroundStyle(TojTheme.text)
                    .textSelection(.enabled)

                HStack(spacing: 4) {
                    if let timestamp = line.timestamp {
                        Text(TojDateFormatting.message(timestamp))
                    }
                    if line.mine { Image(systemName: deliverySymbol) }
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(deliveryColor)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(line.mine ? Color(hex: 0x202116) : TojTheme.strong)
            .clipShape(UnevenRoundedRectangle(
                topLeadingRadius: 20,
                bottomLeadingRadius: line.mine ? 20 : 6,
                bottomTrailingRadius: line.mine ? 6 : 20,
                topTrailingRadius: 20,
                style: .continuous
            ))
            .overlay {
                UnevenRoundedRectangle(
                    topLeadingRadius: 20,
                    bottomLeadingRadius: line.mine ? 20 : 6,
                    bottomTrailingRadius: line.mine ? 6 : 20,
                    topTrailingRadius: 20,
                    style: .continuous
                )
                .stroke(Color.white.opacity(line.mine ? 0.07 : 0.05), lineWidth: 0.5)
            }

            if !line.mine { Spacer(minLength: 54) }
        }
        .accessibilityElement(children: .combine)
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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
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
                    .background(TojTheme.raised, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                    settingsSection(title: "Devices") {
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

                    settingsSection(title: "Account") {
                        SettingsAction(title: "Sign out", systemImage: "rectangle.portrait.and.arrow.right") {
                            showingSignOut = true
                        }
                        SettingsAction(title: "Delete account", systemImage: "trash.fill", destructive: true) {
                            showingDeletionWarning = true
                        }
                    }

                    #if DEBUG
                    if model.isDemoMode {
                        settingsSection(title: "Design preview") {
                            NavigationLink {
                                PresentationStateGallery()
                            } label: {
                                HStack(spacing: 13) {
                                    Image(systemName: "rectangle.3.group.fill").frame(width: 28)
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
                            .buttonStyle(.plain)
                        }
                    }
                    #endif
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
            .refreshable { await model.loadDevices() }
            .background(TojTheme.canvas)
            .navigationTitle("Settings")
            .task { await model.loadDevices() }
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
            .sheet(isPresented: $showingDeletionCode) {
                AccountDeletionView(model: model)
            }
        }
    }

    private func settingsSection<Content: View>(title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(TojTheme.secondaryText)
                .textCase(.uppercase)
                .padding(.leading, 5)
            VStack(spacing: 0) { content() }
                .background(TojTheme.raised, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }
}

private struct DeviceRow: View {
    let device: CloudDevice
    let revoke: () -> Void

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: device.platform == "ios" ? "iphone" : "desktopcomputer")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 42, height: 42)
                .background(TojTheme.strong, in: Circle())
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
            }
        }
        .padding(13)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.05)).frame(height: 0.5).padding(.leading, 68)
        }
    }
}

private struct SettingsAction: View {
    let title: LocalizedStringKey
    let systemImage: String
    var destructive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: systemImage)
                    .frame(width: 28)
                Text(title)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(TojTheme.secondaryText)
            }
            .font(.body.weight(.medium))
            .foregroundStyle(destructive ? Color.red : TojTheme.text)
            .padding(.horizontal, 15)
            .frame(minHeight: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

    static func lastSeen(_ raw: String) -> String {
        guard let date = date(raw) else { return String(localized: "Activity time unavailable") }
        return date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }
}

#Preview {
    CloudRootView()
        .preferredColorScheme(.dark)
}
