// A small demo: `swift run MorphTextDemo` on a Mac. Pick a pair, then morph
// it with the spring or scrub it with the slider.

import MorphText
import SwiftUI

struct Pair: Identifiable {
    let id: String
    let text: String
    let toText: String
    let from: MorphStyle
    let to: MorphStyle
}

let pairs: [Pair] = [
    Pair(id: "Weight", text: "Morph", toText: "Morph",
         from: .system(size: 72, weight: .ultraLight), to: .system(size: 72, weight: .black)),
    Pair(id: "Words", text: "Amethyst", toText: "Citrine",
         from: .system(size: 64, weight: .medium), to: .system(size: 64, weight: .medium)),
    Pair(id: "Fonts", text: "Serif", toText: "Rounded",
         from: .system(size: 64, weight: .regular, design: .serif, color: .indigo),
         to: .system(size: 64, weight: .heavy, design: .rounded, color: .orange)),
    Pair(id: "Size & spacing", text: "Title", toText: "Title",
         from: .system(size: 24, weight: .semibold, kerning: 12), to: .system(size: 80, weight: .bold, kerning: -2)),
]

struct DemoView: View {
    @State private var selected = pairs[0].id
    @State private var progress = 0.0

    var body: some View {
        let pair = pairs.first { $0.id == selected }!
        VStack(spacing: 28) {
            Picker("Pair", selection: $selected) {
                ForEach(pairs) { Text($0.id).tag($0.id) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            MorphText(pair.text, toText: pair.toText, from: pair.from, to: pair.to, progress: progress)
                .frame(height: 120)

            HStack {
                Button(progress < 0.5 ? "Morph" : "Back") {
                    withAnimation(.spring(duration: 0.7, bounce: 0.2)) {
                        progress = progress < 0.5 ? 1 : 0
                    }
                }
                .keyboardShortcut(.space, modifiers: [])
                Slider(value: $progress, in: 0...1)
            }
        }
        .padding(32)
        .frame(minWidth: 560)
        .onChange(of: selected) { progress = 0 }
    }
}

#if os(macOS)
/// A bare executable (`swift run`) isn't an app bundle: make it a regular,
/// frontmost app so its window shows.
final class DemoDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        // Launched from a shell, macOS won't hand it focus; show it anyway.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.windows.forEach { $0.orderFrontRegardless() }
        }
    }
}
#endif

@main
struct DemoApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(DemoDelegate.self) private var delegate
    #endif

    var body: some Scene {
        WindowGroup("MorphText") { DemoView() }
            .windowResizability(.contentSize)
    }
}
