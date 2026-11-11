// A small demo: `swift run MorpheumDemo` on a Mac. Pick a pair, then morph
// it with the spring or scrub it with the slider.

import Morpheum
import SwiftUI

struct Pair: Identifiable {
    let id: String
    let from: MorphContent
    let to: MorphContent
}

let pairs: [Pair] = [
    Pair(id: "Weight",
         from: .text("Morph", style: .system(size: 72, weight: .ultraLight)),
         to: .text("Morph", style: .system(size: 72, weight: .black))),
    Pair(id: "Words",
         from: .text("Amethyst", style: .system(size: 64, weight: .medium)),
         to: .text("Citrine", style: .system(size: 64, weight: .medium))),
    Pair(id: "Fonts",
         from: .text("Serif", style: .system(size: 64, weight: .regular, design: .serif, color: .indigo)),
         to: .text("Rounded", style: .system(size: 64, weight: .heavy, design: .rounded, color: .orange))),
    Pair(id: "Size",
         from: .text("Title", style: .system(size: 24, weight: .semibold, kerning: 12)),
         to: .text("Title", style: .system(size: 80, weight: .bold, kerning: -2))),
    Pair(id: "Send",
         from: .text("Send", style: .system(size: 56, weight: .semibold, color: .blue)),
         to: .symbol("paperplane.fill", size: 56, weight: .semibold, color: .blue)),
    Pair(id: "Save",
         from: .text("Save", style: .system(size: 56, weight: .semibold, color: .blue)),
         to: .symbol("checkmark", size: 56, weight: .semibold, color: .blue)),
    Pair(id: "Symbols",
         from: .symbol("heart", size: 72, color: .pink),
         to: .symbol("star.fill", size: 72, color: .orange)),
]

/// The two patterns the apps use: a final action button and an icon switch,
/// both stock controls with a morphing label.
struct ControlsRow: View {
    enum Saving { case idle, saving, saved }
    @State private var saving = Saving.idle
    @State private var bookmarked = false

    private var saveLabel: MorphContent {
        let style = MorphStyle.system(size: 17, weight: .semibold, color: .white)
        return switch saving {
        case .idle: .text("Save", style: style)
        case .saving: .text("Saving", style: style)
        case .saved: .symbol("checkmark", size: 17, weight: .semibold, color: .white, accessibilityLabel: "Saved")
        }
    }

    var body: some View {
        HStack(spacing: 20) {
            Button {
                guard saving == .idle else { saving = .idle; return }
                saving = .saving
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    saving = .saved
                }
            } label: {
                AnimatedMorph(saveLabel).frame(minWidth: 70)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button { bookmarked.toggle() } label: {
                AnimatedMorph(.symbol(bookmarked ? "bookmark.fill" : "bookmark", size: 22, color: .accentColor,
                                      accessibilityLabel: bookmarked ? "Bookmarked" : "Bookmark"))
            }
            .buttonStyle(.borderless)
        }
    }
}

struct DemoView: View {
    @State private var selected = pairs[0].id
    @State private var progress = 0.0
    @State private var engine = MorphEngine.auto

    var body: some View {
        let pair = pairs.first { $0.id == selected }!
        VStack(spacing: 28) {
            Picker("Pair", selection: $selected) {
                ForEach(pairs) { Text($0.id).tag($0.id) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Picker("Engine", selection: $engine) {
                Text("Auto").tag(MorphEngine.auto)
                Text("Strokes").tag(MorphEngine.strokes)
                Text("Outlines").tag(MorphEngine.outline)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 280)

            MorphBetween(from: pair.from, to: pair.to, progress: progress)
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

            Divider()
            ControlsRow()
        }
        .morphEngine(engine)
        .padding(32)
        .frame(minWidth: 640)
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
        WindowGroup("Morpheum") { DemoView() }
            .windowResizability(.contentSize)
    }
}
