import SwiftUI

#if canImport(LiveKit)
@preconcurrency import LiveKit

struct GroupCallVideoRenderer: UIViewRepresentable {
    let reference: GroupCallVideoTrackReference
    var fill = true

    func makeUIView(context: Context) -> VideoView {
        let view = VideoView()
        view.backgroundColor = .black
        view.layoutMode = fill ? .fill : .fit
        view.mirrorMode = reference.isLocal && reference.source == .camera ? .auto : .off
        view.transitionMode = .crossDissolve
        view.track = reference.opaqueTrack as? VideoTrack
        return view
    }

    func updateUIView(_ view: VideoView, context: Context) {
        view.layoutMode = fill ? .fill : .fit
        view.mirrorMode = reference.isLocal && reference.source == .camera ? .auto : .off
        view.track = reference.opaqueTrack as? VideoTrack
        view.isEnabled = true
    }

    static func dismantleUIView(_ view: VideoView, coordinator: Void) {
        view.isEnabled = false
        view.track = nil
    }
}
#else
struct GroupCallVideoRenderer: View {
    let reference: GroupCallVideoTrackReference
    var fill = true

    var body: some View {
        Color.black
            .overlay(Image(systemName: "video.slash.fill").foregroundStyle(.secondary))
    }
}
#endif
