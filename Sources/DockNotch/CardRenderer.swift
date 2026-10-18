import AppKit
import SwiftUI

/// Development aid: `DockNotch --render <dir> [--sample]` writes every card to a PNG,
/// using live data from gh, or made-up data that fills every card with `--sample`.
@MainActor
enum CardRenderer {
    static func run(outputDirectory: String, sample: Bool) async {
        let store = NotchStore()
        if sample {
            store.load(.sample)
        } else {
            await store.refresh()
        }
        if let snapshot = store.snapshot {
            store.avatars.preload(snapshot.avatarURLs)
            for _ in 0..<50 where store.avatars.images.count < Set(snapshot.avatarURLs).count {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        let directory = URL(fileURLWithPath: outputDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let kinds = store.cards.isEmpty ? [store.current] : store.cards
        for kind in kinds {
            store.select(kind)
            let canvas = NotchView(store: store)
                .environment(\.notchIsStatic, true)
                .frame(
                    width: store.pillSize.width + notchShadowPadding * 2,
                    height: store.pillSize.height + notchShadowPadding * 2
                )
                .background(LinearGradient(
                    colors: [Color(red: 0.35, green: 0.55, blue: 0.85), Color(red: 0.55, green: 0.35, blue: 0.75)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
            let renderer = ImageRenderer(content: canvas)
            renderer.scale = 2
            guard let image = renderer.cgImage else { continue }
            let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            let url = directory.appendingPathComponent("\(kind.rawValue).png")
            try? png?.write(to: url)
            print(url.path)
        }
    }
}

private struct StaticRenderKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True when drawing a still image, so views skip their entrance animations.
    var notchIsStatic: Bool {
        get { self[StaticRenderKey.self] }
        set { self[StaticRenderKey.self] = newValue }
    }
}

extension Snapshot {
    static var sample: Snapshot {
        let url = URL(string: "https://github.com")!
        return Snapshot(
            login: "octocat",
            contributions: Contributions(
                total: 1_346, thisWeek: 68, lastWeek: 31,
                weekly: [12, 18, 9, 22, 30, 14, 26, 41, 19, 35, 28, 44, 38, 52, 31, 47, 58, 40, 63, 49, 71, 55, 31, 68]
            ),
            openPRs: OpenPRs(total: 7, approved: 3, changesRequested: 1, awaitingReview: 2, drafts: 1),
            reviewQueue: ReviewQueue(
                count: 4,
                latest: PRRef(repo: "api", number: 812, title: "Rate-limit the webhook retries", url: url),
                latestAuthor: "mona",
                latestAvatar: URL(string: "https://avatars.githubusercontent.com/u/583231?s=128")
            ),
            checks: Checks(
                passing: 5, failing: 1, pending: 1,
                firstFailing: PRRef(repo: "web", number: 233, title: "Move settings into a sheet", url: url)
            ),
            merged: Merged(count: 3, latest: PRRef(repo: "web", number: 229, title: "Faster cold start", url: url)),
            latestComment: Comment(
                id: "sample", author: "mona",
                avatar: URL(string: "https://avatars.githubusercontent.com/u/583231?s=128"),
                byViewer: false, text: "Looks great. Could you add a test for the empty state before we merge?",
                date: .now.addingTimeInterval(-720), url: url,
                pr: PRRef(repo: "web", number: 233, title: "Move settings into a sheet", url: url)
            )
        )
    }
}
