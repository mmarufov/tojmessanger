import SwiftUI

struct ContentView: View {
    var body: some View {
        if ProcessInfo.processInfo.environment["TOJ_USE_M1_SKELETON"] == "1" {
            SkeletonView()
        } else {
            CloudRootView()
        }
    }
}

#Preview {
    ContentView()
}
