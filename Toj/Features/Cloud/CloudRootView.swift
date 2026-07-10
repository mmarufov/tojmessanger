import SwiftUI

struct CloudRootView: View {
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
            await model.start()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
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
                    .disabled(model.phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if model.requestedCode {
                        TextField("Code", text: $model.code)
                            .textContentType(.oneTimeCode)
                            .keyboardType(.numberPad)
                        Button("Sign in") {
                            Task { await model.verifyCode() }
                        }
                        .disabled(model.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
                Button("Sign out") {
                    Task { await model.signOut() }
                }
            }
            .navigationDestination(for: String.self) { dialogId in
                CloudConversationView(model: model, dialogId: dialogId)
            }
        }
    }
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
