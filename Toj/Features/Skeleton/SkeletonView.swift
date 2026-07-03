import SwiftUI

/// Deliberately ugly M1 skeleton UI: pick a hardcoded identity, then chat.
/// Real chat UI (Liquid Glass) is milestone 4.
struct SkeletonView: View {
    @State private var model: SkeletonChatModel?
    @State private var startupError: String?

    var body: some View {
        if let model {
            SkeletonChatScreen(model: model)
        } else {
            VStack(spacing: 16) {
                Text("Toj — M1 walking skeleton")
                    .font(.headline)
                Text("Pick who this device is:")
                Button("I am Alice") { start(me: "alice", peer: "bob") }
                    .buttonStyle(.borderedProminent)
                Button("I am Bob") { start(me: "bob", peer: "alice") }
                    .buttonStyle(.borderedProminent)
                if let startupError {
                    Text(startupError).font(.footnote).foregroundStyle(.red)
                }
            }
            .padding()
            .onAppear {
                // Dev hook for scripted two-simulator demos: TOJ_ROLE=alice|bob skips the picker.
                if model == nil, let role = ProcessInfo.processInfo.environment["TOJ_ROLE"] {
                    start(me: role, peer: role == "alice" ? "bob" : "alice")
                }
            }
        }
    }

    private func start(me: String, peer: String) {
        do {
            model = try SkeletonChatModel(me: me, peer: peer)
        } catch {
            startupError = "startup failed: \(error.localizedDescription)"
        }
    }
}

private struct SkeletonChatScreen: View {
    let model: SkeletonChatModel
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            Text(model.status)
                .font(.caption)
                .frame(maxWidth: .infinity)
                .padding(6)
                .background(.yellow.opacity(0.2))

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(model.lines) { line in
                            HStack {
                                if line.mine { Spacer(minLength: 40) }
                                Text(line.mine ? "\(line.text) \(line.acked ? "✓" : "…")" : line.text)
                                    .padding(8)
                                    .background(line.mine ? Color.blue.opacity(0.2) : Color.gray.opacity(0.2))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                if !line.mine { Spacer(minLength: 40) }
                            }
                            .id(line.id)
                        }
                    }
                    .padding(.horizontal)
                }
                .onChange(of: model.lines) {
                    if let last = model.lines.last?.id {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }

            HStack {
                TextField("Message \(model.peer)…", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(sendDraft)
                Button("Send", action: sendDraft)
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .task { await model.start() }
    }

    private func sendDraft() {
        let text = draft
        draft = ""
        Task { await model.send(text) }
    }
}

#Preview {
    SkeletonView()
}
