import SwiftUI
import Testing
@testable import Morpheum

@Suite struct Timeline {
    let save = MorphContent.text("Save", style: .system(size: 17, weight: .semibold))
    let saving = MorphContent.text("Saving", style: .system(size: 17, weight: .semibold))
    let done = MorphContent.symbol("checkmark", size: 17, weight: .semibold)

    @Test func atRestANewContentTakesTheFarEnd() throws {
        let rest = MorphTimeline(save)
        let change = try #require(rest.change(to: done, shown: 1))
        // On screen is `save` at 1; `done` goes in at 0, and it heads there.
        #expect(change == MorphTimeline(from: done, to: save, target: 0))
        #expect(change.destination == done)
    }

    @Test func theSameContentChangesNothing() {
        #expect(MorphTimeline(save).change(to: save, shown: 1) == nil)
        let flying = MorphTimeline(from: done, to: save, target: 0)
        #expect(flying.change(to: done, shown: 0.4) == nil)
    }

    @Test func turningBackHeadsForTheOtherEnd() throws {
        let flying = MorphTimeline(from: done, to: save, target: 0)
        let back = try #require(flying.change(to: save, shown: 0.6))
        // Same ends, so the spring is retargeted, not restarted.
        #expect(back == MorphTimeline(from: done, to: save, target: 1))
    }

    @Test func aThirdContentReplacesTheEndFurtherFromWhatShows() throws {
        // save → saving, a little way in: saving is the far end.
        let early = MorphTimeline(from: save, to: saving, target: 1)
        #expect(early.change(to: done, shown: 0.3) == MorphTimeline(from: save, to: done, target: 1))
        // Most of the way to saving: save is the far end.
        #expect(early.change(to: done, shown: 0.8) == MorphTimeline(from: done, to: saving, target: 0))
    }

    @Test func jumpingRestsOnTheContent() {
        var timeline = MorphTimeline(from: save, to: saving, target: 1)
        timeline.jump(to: done)
        #expect(timeline == MorphTimeline(done))
    }
}

#if os(macOS)
import AppKit

/// A content to change from outside the view.
@MainActor @Observable
final class Switch {
    var content: MorphContent
    var ends = 0
    init(_ content: MorphContent) { self.content = content }
}

private struct Host: View {
    let model: Switch
    var body: some View {
        AnimatedMorph(model.content, animation: .linear(duration: 0.6)) { model.ends += 1 }
            // The timeline is what's under test: outlines plan in a moment even
            // in a debug build, where tracing strokes takes seconds.
            .morphEngine(.outline)
            .frame(width: 300, height: 120)
            .background(.white)
            .environment(\.colorScheme, .light)
    }
}

/// An `AnimatedMorph` in a real (offscreen) window, animating as an app's
/// does.
@MainActor
@Suite struct Animating {
    private func host(_ model: Switch) -> (NSWindow, NSHostingView<Host>) {
        let view = NSHostingView(rootView: Host(model: model))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 120), styleMask: [.borderless], backing: .buffered, defer: false)
        // Swift owns it: closing must not release it too (a crash in the
        // window's close animation, now and then).
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFrontRegardless()
        return (window, view)
    }

    private func wait(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    @Test func aChangeMorphsAndLands() async {
        let model = Switch(.text("Save", style: .system(size: 30, weight: .semibold)))
        let (window, _) = host(model)
        defer { window.close() }
        await wait(0.2)
        model.content = .symbol("checkmark", size: 30, weight: .semibold)
        // A 0.6 s morph; other suites share the main actor, so give it time.
        for _ in 0..<50 where model.ends == 0 { await wait(0.1) }
        #expect(model.ends == 1)
    }

    /// The window's pixels, as dark ink per pixel.
    private func snapshot(_ view: NSView) -> [UInt8] {
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        var ink: [UInt8] = []
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                ink.append(UInt8(255 - Int((rep.colorAt(x: x, y: y)?.brightnessComponent ?? 1) * 255)))
            }
        }
        return ink
    }

    private func difference(_ a: [UInt8], _ b: [UInt8]) -> Int {
        zip(a, b).filter { abs(Int($0) - Int($1)) > 64 }.count
    }

    @Test func itPassesThroughFramesBetween() async {
        let model = Switch(.text("Save", style: .system(size: 40, weight: .semibold)))
        let (window, view) = host(model)
        defer { window.close() }
        await wait(0.2)
        let start = snapshot(view)
        model.content = .symbol("checkmark", size: 40, weight: .semibold)
        // Every 50 ms for two seconds: other suites share the main actor, so
        // when the frames come varies; that some frame is neither end doesn't.
        var frames: [[UInt8]] = []
        for _ in 0..<40 {
            await wait(0.05)
            frames.append(snapshot(view))
        }
        let end = frames.last!
        #expect(difference(start, end) > 200)
        #expect(frames.contains { difference($0, start) > 50 && difference($0, end) > 50 }, "no frame between the ends")
    }

    @Test func aSupersededMorphDoesNotReportItsEnd() async {
        let model = Switch(.text("Save", style: .system(size: 30, weight: .semibold)))
        let (window, _) = host(model)
        defer { window.close() }
        await wait(0.2)
        model.content = .text("Saving", style: .system(size: 30, weight: .semibold))
        await wait(0.1)
        model.content = .symbol("checkmark", size: 30, weight: .semibold)
        await wait(1)
        #expect(model.ends == 1)
    }
}
#endif
