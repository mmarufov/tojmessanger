import SwiftUI

struct ContentView: View {
    var body: some View {
        Group {
            if ProcessInfo.processInfo.environment["TOJ_USE_M1_SKELETON"] == "1" {
                SkeletonView()
            } else {
                CloudRootView()
            }
        }
        .preferredColorScheme(.dark)
        .tint(TojTheme.text)
    }
}

#Preview {
    ContentView()
}
