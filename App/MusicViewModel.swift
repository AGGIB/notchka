import AppKit
import Observation
import SwiftUI
import MediaBridge
import NotchUI

/// Holds the current track and translates it into what the music tab shows.
///
/// Lives for the app's entire lifetime — created once in AppDelegate and not
/// tied to the notch geometry: the adapter and its perl subprocess don't care
/// where the panel is currently looking or whether the screen has a notch at all.
@MainActor
@Observable
final class MusicViewModel {
    private(set) var track: TrackDisplay?
    private(set) var artwork: Image?
    private(set) var accent: Color = .white
    private(set) var position: TimeInterval = 0

    @ObservationIgnored private let provider: any NowPlayingProvider
    @ObservationIgnored private var snapshot: NowPlayingSnapshot?
    @ObservationIgnored private var pump: Task<Void, Never>?

    init(provider: any NowPlayingProvider) {
        self.provider = provider
    }

    /// Starts the subscription pump. Call once per model lifetime.
    ///
    /// `AdapterProvider.snapshots` doesn't multicast (see its doc comment):
    /// subscribing again would split the already-flowing snapshots between two
    /// readers instead of duplicating them to both. The guard below makes start()
    /// idempotent — the caller (AppDelegate) already calls it exactly once, but
    /// the method itself should guarantee that too, not just caller discipline.
    func start() {
        guard pump == nil else { return }
        pump = Task { [weak self] in
            guard let self else { return }
            // A Task {} created inside a @MainActor method is itself isolated
            // to MainActor (it inherits the isolation of its creation site) —
            // an extra hop through MainActor.run here would be redundant on
            // top of an already-correct actor, not an added guarantee.
            for await snapshot in await provider.snapshots {
                apply(snapshot)
            }
        }
    }

    deinit {
        // Same trick and same rationale as HotkeyCenter.deinit: the compiler
        // treats a class deinit on @MainActor as nonisolated, so a direct
        // reference to pump here wouldn't pass Swift 6 checking without an
        // explicit assumeIsolated.
        MainActor.assumeIsolated {
            pump?.cancel()
        }
    }

    /// Guaranteed stop of the adapter before the app quits.
    ///
    /// Separate from deinit not just formally (deinit isn't async and can't
    /// wait for provider.shutdown() to finish), but substantively: you can't
    /// rely on deinit ever running — AppKit terminates the process via
    /// exit(), bypassing Swift's stack unwinding. The caller (AppDelegate,
    /// the SIGTERM handler) must await this method before actually
    /// terminating the process.
    func stopAdapter() async {
        pump?.cancel()
        await provider.shutdown()
    }

    /// Position is recomputed on demand rather than kept ticking: the adapter
    /// hands it over as a snapshot and doesn't update it between events (see
    /// PlaybackPosition), so the only honest approach is to recompute from
    /// the timestamp on every call. The caller (NotchRootView) must only
    /// invoke this while the panel is expanded — at rest the app should
    /// sleep, not recompute the position of a track nobody is watching.
    func refreshPosition(now: Date = Date()) {
        guard let snapshot else { return }
        position = PlaybackPosition.current(in: snapshot, at: now)
    }

    /// One-off resync that bypasses the stream and its pump.
    ///
    /// Exists because of a defect the owner found on a live machine: a short
    /// notification with sound (e.g. WhatsApp Web) hijacks the "now playing"
    /// session, and once it ends the system sometimes doesn't send an event
    /// for returning to the previous source — the adapter's long-lived
    /// stream is still alive at that point, but stays stuck on the
    /// notification's data forever, because there's simply nowhere for that
    /// event to come from. This can't be fixed by parsing what already
    /// arrived on the stream: there's nothing there (see the doc on
    /// NowPlayingProvider.refresh()).
    ///
    /// The result is applied through apply(_:) — the same path regular
    /// snapshots take from the stream in start(): track, artwork, accent,
    /// and position update the same way regardless of where the value came
    /// from. The caller (NotchRootView) must only invoke this while the
    /// panel is expanded — the same "sleep at rest" principle as
    /// refreshPosition() above: get spawns a separate perl process, and it's
    /// only justified when someone will actually see the result.
    func resync() async {
        do {
            apply(try await provider.refresh())
        } catch {
            // A misfire on a one-off request isn't a reason to blank the
            // screen: the last known track is more honest than emptiness.
            // The provider already logged the reason — nothing to duplicate here.
        }
    }

    /// Toggles play/pause.
    ///
    /// This used to be the only command the UI drove, and this doc used to
    /// explain why there's no TrackControl type for it: the skip buttons had
    /// been removed from MusicTabView (see the doc that was on
    /// playPauseButton there at the time) along with TrackControl
    /// (previous/playPause/next) — both arrows sent the same toggle code as
    /// play/pause, because the spike never empirically verified the
    /// track-switching codes, and with no other commands left there was no
    /// need for an enum and a switch over it either.
    ///
    /// The next/previous codes have since been confirmed separately (see the
    /// doc on MediaCommand), and the buttons are back — see
    /// nextTrack()/previousTrack() below. TrackControl was deliberately not
    /// restored: with three commands it would just be a second name for the
    /// same set of values that MediaCommand already has, with no semantics
    /// of its own on top of it — the UI already calls three different
    /// methods for three different taps, and there's no point wrapping them
    /// in a fourth enum that immediately gets unwrapped again by a switch
    /// over those same three MediaCommand values.
    func togglePlayback() {
        Task { try? await provider.send(.toggle) }
    }

    /// Next track. Code — see MediaCommand.next.adapterCode; that doc also
    /// covers how and by whom it was confirmed (not the same spike as
    /// play/pause/toggle).
    func nextTrack() {
        Task { try? await provider.send(.next) }
    }

    /// Previous track. Code — see MediaCommand.previous.adapterCode; that
    /// doc also covers how and by whom it was confirmed (not the same spike
    /// as play/pause/toggle).
    func previousTrack() {
        Task { try? await provider.send(.previous) }
    }

    private func apply(_ snapshot: NowPlayingSnapshot?) {
        self.snapshot = snapshot
        guard let snapshot else {
            track = nil
            artwork = nil
            accent = .white
            return
        }
        track = TrackDisplay(
            title: snapshot.title,
            artist: snapshot.artist,
            source: Self.sourceName(for: snapshot),
            duration: snapshot.duration,
            isPlaying: snapshot.isPlaying
        )
        updateArtwork(from: snapshot)
        refreshPosition()
    }

    private func updateArtwork(from snapshot: NowPlayingSnapshot) {
        guard let data = snapshot.artworkData,
              let image = NSImage(data: data),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            artwork = nil
            return
        }
        artwork = Image(nsImage: image)
        if let colour = ArtworkAccent.color(from: cgImage) { accent = colour }
    }

    /// Human-readable source name instead of a bundle id.
    ///
    /// Safari — and in principle any browser that renders media in a
    /// separate helper process — hands MediaRemote the bundle id of that
    /// process, not its own. Empirical finding from Task 4:
    /// `sourceBundleID == "com.apple.WebKit.GPU"` for Safari, the real app
    /// arrives in a separate field, `parentApplicationBundleID`.
    ///
    /// This deliberately uses that field as sent by the adapter, rather than
    /// a hardcoded "known helper → name" table: such a table would only
    /// solve the problem for browsers already seen and would reproduce the
    /// same bug for any helper process not previously encountered. When
    /// parentApplicationBundleID is present — use it. When it's absent
    /// (sourceBundleID is already the real app, or the adapter didn't
    /// recognize the source as someone's helper), fall back to
    /// sourceBundleID as before; if that also doesn't resolve to an app via
    /// NSWorkspace, show the bundle id as plain text — not the prettiest,
    /// but honest behavior, no worse than what existed before this task for
    /// any unrecognized source.
    private static func sourceName(for snapshot: NowPlayingSnapshot) -> String {
        let bundleID = snapshot.parentApplicationBundleID ?? snapshot.sourceBundleID
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        return FileManager.default.displayName(atPath: url.path)
    }
}
