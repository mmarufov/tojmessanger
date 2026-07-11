import SwiftUI

struct CloudRootView: View {
    private static let isRunningUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = CloudAppModel()

    var body: some View {
        Group {
            if model.storedSession == nil {
                CloudAuthView(model: model)
            } else {
                CloudChatView(model: model)
            }
        }
        .task {
            guard !Self.isRunningUnitTests else { return }
            await model.start()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, !Self.isRunningUnitTests else { return }
            Task { await model.resume() }
        }
    }
}

private struct CloudAuthView: View {
    @Bindable var model: CloudAppModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Phone number", text: $model.phone)
                        .textContentType(.telephoneNumber)
                        .keyboardType(.phonePad)
                    TextField("Display name", text: $model.displayName)
                        .textContentType(.name)
                }

                Section {
                    Button("Request code") {
                        Task { await model.requestCode() }
                    }
                    .disabled(!model.canRequestCode)

                    if model.authRequestInFlight {
                        ProgressView("Sending code")
                    } else if model.resendSeconds > 0 {
                        Text("You can request another code in \(model.resendSeconds)s")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if model.requestedCode {
                        TextField("Code", text: $model.code)
                            .textContentType(.oneTimeCode)
                            .keyboardType(.numberPad)
                        Button(model.authVerifyInFlight ? "Signing in…" : "Sign in") {
                            Task { await model.verifyCode() }
                        }
                        .disabled(!model.canVerifyCode)
                    }
                }

                Section {
                    Text(model.status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Toj")
        }
    }
}

private struct CloudChatView: View {
    @Bindable var model: CloudAppModel
    @State private var path: [String] = []
    @State private var showingDevices = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    HStack {
                        Image(systemName: "phone")
                            .foregroundStyle(.secondary)
                        TextField("Peer phone", text: $model.peerPhone)
                            .textContentType(.telephoneNumber)
                            .keyboardType(.phonePad)
                        Button {
                            Task {
                                if let dialogId = await model.openPeer() {
                                    path = [dialogId]
                                }
                            }
                        } label: {
                            Image(systemName: "arrow.up.forward")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.peerPhone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } footer: {
                    Text(model.status)
                }

                Section("Chats") {
                    if model.dialogs.isEmpty {
                        ContentUnavailableView("No chats", systemImage: "bubble.left.and.bubble.right")
                    } else {
                        ForEach(model.dialogs) { dialog in
                            NavigationLink(value: dialog.id) {
                                CloudDialogRow(dialog: dialog)
                            }
                        }
                    }
                }
            }
            .navigationTitle(model.storedSession?.displayName.isEmpty == false ? model.storedSession?.displayName ?? "Toj" : "Toj")
            .toolbar {
                Button {
                    showingDevices = true
                } label: {
                    Image(systemName: "iphone.gen3")
                }
                .accessibilityLabel("Devices")
                Button("Sign out") {
                    Task { await model.signOut() }
                }
            }
            .navigationDestination(for: String.self) { dialogId in
                CloudConversationView(model: model, dialogId: dialogId)
            }
            .sheet(isPresented: $showingDevices) {
                CloudDevicesView(model: model)
            }
        }
    }
}

private struct CloudDevicesView: View {
    @Bindable var model: CloudAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingDeletionWarning = false
    @State private var showingDeletionCode = false

    var body: some View {
        NavigationStack {
            List {
                if model.loadingDevices && model.devices.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView("Loading devices")
                        Spacer()
                    }
                } else {
                    ForEach(model.devices) { device in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: device.platform == "ios" ? "iphone" : "desktopcomputer")
                                Text(device.deviceName.flatMap { $0.isEmpty ? nil : $0 } ?? device.platform.capitalized)
                                    .font(.headline)
                                if device.current {
                                    Text("This device")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(lastSeenText(device))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if !device.current {
                                Button("Sign out", role: .destructive) {
                                    Task { await model.revokeDevice(device) }
                                }
                            }
                        }
                    }
                }

                Section("Account") {
                    Button("Delete Account", role: .destructive) {
                        showingDeletionWarning = true
                    }
                    .disabled(model.accountDeletionInFlight)
                }
            }
            .overlay {
                if !model.loadingDevices && model.devices.isEmpty {
                    ContentUnavailableView("No active devices", systemImage: "iphone.slash")
                }
            }
            .navigationTitle("Devices")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Done") { dismiss() }
            }
            .task { await model.loadDevices() }
            .refreshable { await model.loadDevices() }
            .confirmationDialog(
                "Delete your Toj account?",
                isPresented: $showingDeletionWarning,
                titleVisibility: .visible
            ) {
                Button("Request Deletion Code", role: .destructive) {
                    Task {
                        if await model.requestAccountDeletionCode() {
                            showingDeletionCode = true
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your phone number, profile name, sessions, and push tokens will be erased. Messages already delivered remain in the other participants’ chat history.")
            }
            .sheet(isPresented: $showingDeletionCode) {
                AccountDeletionView(model: model)
            }
        }
    }

    private func lastSeenText(_ device: CloudDevice) -> String {
        let raw = device.lastSeenAt ?? device.createdAt
        guard let date = ISO8601DateFormatter.toj.date(from: raw) else {
            return "Activity time unavailable"
        }
        return "Active \(RelativeDateTimeFormatter.toj.localizedString(for: date, relativeTo: Date()))"
    }
}

private struct AccountDeletionView: View {
    @Bindable var model: CloudAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingFinalConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("6-digit code", text: $model.accountDeletionCode)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                    Button("Request New Code") {
                        Task { _ = await model.requestAccountDeletionCode() }
                    }
                    .disabled(model.accountDeletionInFlight)
                } header: {
                    Text("Verification")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("For your security, account deletion requires a fresh verification code.")
                        Text(model.status)
                    }
                }

                Section {
                    Button("Permanently Delete Account", role: .destructive) {
                        showingFinalConfirmation = true
                    }
                    .disabled(model.accountDeletionInFlight || model.accountDeletionCode.filter(\.isNumber).count != 6)
                } footer: {
                    Text("This cannot be undone. You may register the same phone number later, but it creates a new account.")
                }

                if model.accountDeletionInFlight {
                    HStack {
                        Spacer()
                        ProgressView("Deleting account")
                        Spacer()
                    }
                }
            }
            .navigationTitle("Delete Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Cancel") {
                    model.cancelAccountDeletion()
                    dismiss()
                }
                    .disabled(model.accountDeletionInFlight)
            }
            .alert("Permanently delete account?", isPresented: $showingFinalConfirmation) {
                Button("Delete Forever", role: .destructive) {
                    Task {
                        if await model.deleteAccount() { dismiss() }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("All devices will be signed out and your identifying account data will be erased.")
            }
            .interactiveDismissDisabled(model.accountDeletionInFlight)
            .onChange(of: model.storedSession == nil) { _, signedOut in
                if signedOut { dismiss() }
            }
            .onDisappear { model.cancelAccountDeletion() }
        }
    }
}

private extension ISO8601DateFormatter {
    static let toj: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private extension RelativeDateTimeFormatter {
    static let toj: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}

private struct CloudDialogRow: View {
    let dialog: CloudAppModel.Dialog

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.fill")
                .font(.title2)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(dialog.title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    if dialog.isPending {
                        Text("Sending")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(dialog.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct CloudConversationView: View {
    @Bindable var model: CloudAppModel
    let dialogId: String

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if model.canLoadEarlier {
                            Button {
                                Task { await model.loadEarlier() }
                            } label: {
                                Label(model.loadingEarlier ? "Loading" : "Earlier", systemImage: "arrow.up")
                            }
                            .buttonStyle(.bordered)
                            .disabled(model.loadingEarlier)
                            .padding(.bottom, 4)
                        }

                        ForEach(model.lines) { line in
                            CloudBubble(line: line)
                                .id(line.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: model.lines) {
                    if let last = model.lines.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("Message", text: $model.draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.activeDialogId != dialogId || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
            .background(.bar)
        }
        .navigationTitle(model.dialogTitle(dialogId))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: dialogId) {
            await model.selectDialog(dialogId)
        }
    }

    private func send() {
        Task { await model.sendDraft() }
    }
}

private struct CloudBubble: View {
    let line: CloudAppModel.Line

    var body: some View {
        HStack {
            if line.mine { Spacer(minLength: 44) }
            VStack(alignment: line.mine ? .trailing : .leading, spacing: 4) {
                Text(line.text)
                    .font(.body)
                if line.mine {
                    Text(statusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(line.mine ? Color.blue.opacity(0.18) : Color.gray.opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            if !line.mine { Spacer(minLength: 44) }
        }
    }

    private var statusText: String {
        switch line.delivery {
        case .sending: "Sending"
        case .sent: "Sent"
        case .seen: "Seen"
        case .failed: "Failed"
        }
    }
}

#Preview {
    CloudRootView()
}
