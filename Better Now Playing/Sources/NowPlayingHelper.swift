//
//  NowPlayingHelper.swift
//  Better Now Playing
//
//  Created by Pierluigi Galdi on 17/02/2019.
//  Copyright © 2019 Pierluigi Galdi. All rights reserved.
//  Modified by JosephPri
//

import Foundation
import AppKit

extension Notification.Name {
    static let nowPlayingInactivityDidChange = Notification.Name("NowPlayingInactivityDidChange")
}

class NowPlayingHelper {
    
    /// Data
    public private(set) var currentNowPlayingItem: NowPlayingItem?
    
    /// Artwork
    private var latestArtworkTask: URLSessionTask?
    /// Pending iTunes API fallback — cancelled if adapter delivers artwork first
    private var artworkFallbackWorkItem: DispatchWorkItem?
    /// Identity of the track for which we last fetched iTunes artwork,
    /// so we don't re-fetch when only isPlaying or other non-artwork fields change
    private var lastArtworkFetchKey: String?
    
    /// Ref
    internal weak var view: NowPlayingView?
    
    /// Periodic refresh timer to catch missed updates
    private var refreshTimer: Timer?
    /// Repeating timer that kills NowPlayingTouchUI if it respawns despite launchctl disable
    private var killTimer: Timer?
    /// Repeating (1s) timer that drives the pause-inactivity countdown while paused.
    /// Repeats rather than a single one-shot fire so it can be checked against
    /// wall-clock time instead of relying on a fire date that misbehaves across
    /// sleep.
    private var inactivityTicker: Timer?
    /// Wall-clock timestamp of when playback most recently transitioned to paused/stopped.
    /// nil when nothing is playing... er, when not currently counting down.
    private var pausedSince: Date?
    /// The isPlaying value we last actually reacted to. Used to ignore redundant
    /// calls to resetInactivityTimer() that don't represent a real play-state
    /// transition (several call sites invoke it defensively on every notification,
    /// periodic refresh tick, etc.) — without this, a flurry of no-op calls could
    /// restart the countdown from scratch indefinitely and the widget would never hide.
    private var lastKnownIsPlaying: Bool?
    /// Bundle identifier of the app we last evaluated the countdown for. Used to
    /// detect when the "now playing" source itself changes — e.g. Spotify quits
    /// and the adapter falls back to Apple Music, which might have already been
    /// sitting paused for ages. That's not a "just paused" moment, so it shouldn't
    /// be granted a fresh full countdown (see resetInactivityTimer).
    private var lastKnownClientBundleIdentifier: String?
    /// Tracks whether the widget is currently hidden due to inactivity timeout
    private var isHiddenDueToInactivity: Bool = false
    
    // MARK: Instance bookkeeping / wake settling
    
    /// Pock can build a second NowPlayingWidget (and so a second helper) around a
    /// sleep/wake cycle, with the old one released only afterwards. These let
    /// instances tell each other apart in the logs and let the last one out —
    /// not the first — shut the shared adapter stream down.
    private static var nextInstanceId = 0
    private static var liveInstanceCount = 0
    private let instanceId: Int
    /// How long after a wake a "playing" report is treated as unconfirmed while
    /// a pause episode is on record (see `shouldDistrustPlayingReport`).
    private static let wakeSettleSeconds: TimeInterval = 10
    private var lastWakeHandled: Date?
    /// When the user last pressed play/pause/skip on this widget. Their own
    /// action is never treated as an unconfirmed report.
    private var lastUserToggle: Date?
    private var wakeReconcileWorkItem: DispatchWorkItem?
    
    private func dbg(_ message: String) {
        print("[NowPlayingHelper#\(instanceId)] \(message)")
    }
    
    /// When the current pause "episode" began, stored in UserDefaults rather than
    /// only in this instance. All the other countdown state above lives on the
    /// helper, so if the helper is ever rebuilt (Pock re-creating the widget when
    /// the Touch Bar comes back after sleep, the app relaunching, etc.) the record
    /// of "this has been paused since X" used to vanish, and the fresh helper
    /// treated the already-paused track as if it had just been paused — showing
    /// the widget again for a whole new timeout. Cleared only when playback
    /// genuinely resumes or the feature is turned off.
    private static let pausedSinceDefaultsKey = "inactivityPausedSinceTimestamp"
    private var persistedPausedSince: Date? {
        get {
            let t = UserDefaults.standard.double(forKey: NowPlayingHelper.pausedSinceDefaultsKey)
            guard t > 0 else { return nil }
            let date = Date(timeIntervalSince1970: t)
            // A timestamp in the future (clock was changed) is meaningless — ignore it.
            return date <= Date() ? date : nil
        }
        set {
            if let date = newValue {
                UserDefaults.standard.set(date.timeIntervalSince1970, forKey: NowPlayingHelper.pausedSinceDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: NowPlayingHelper.pausedSinceDefaultsKey)
            }
        }
    }
    
    internal init(forView: NowPlayingView) {
        NowPlayingHelper.nextInstanceId += 1
        instanceId = NowPlayingHelper.nextInstanceId
        NowPlayingHelper.liveInstanceCount += 1
        NSLog("[NOW_PLAYING]: NowPlayingHelper#\(instanceId) - init (live helpers: \(NowPlayingHelper.liveInstanceCount))")
        if let _: String = Preferences[.defaultPlayer] {
            // nothing to do here
        } else {
            if #available(OSX 10.15, *) {
                Preferences[.defaultPlayer] = "com.apple.Music"
            } else {
                Preferences[.defaultPlayer] = "com.apple.iTunes"
            }
        }
        view = forView
        currentNowPlayingItem = NowPlayingItem()
        
        // Set up default client so widget shows even when nothing is playing
        let customDefaultPlayerIdentifier: String = Preferences[.defaultPlayer]
        let displayName = NSWorkspace.shared.applicationName(for: customDefaultPlayerIdentifier)
        let icon = NSWorkspace.shared.applicationIcon(for: customDefaultPlayerIdentifier, fallbackFileType: "mp3")
        currentNowPlayingItem?.client = NowPlayingItem.Client(
            bundleIdentifier: customDefaultPlayerIdentifier,
            parentApplicationBundleIdentifier: nil,
            displayName: displayName,
            icon: icon
        )
        print("[NowPlayingHelper] init - set default client: \(displayName ?? "nil")")
        
        registerForNotifications()
        
        // Start the adapter
        MediaRemoteAdapter.shared.startStreaming()
        
        // Suppress the native Now Playing Touch Bar if preference is enabled
        if Preferences[.disableNativeNowPlaying] {
            suppressNowPlayingTouchUI()
        }
        
        // Initial UI update - IMPORTANT: Do this before getting adapter state
        view?.updateContentViews()
        
        // Initial update from adapter
        updateFromAdapter()
        
        startPeriodicRefresh()
        
        // Only start kill timer if we're suppressing native Now Playing
        if Preferences[.disableNativeNowPlaying] {
            startKillTimer()
        }
        
        resetInactivityTimer()
    }
    
    private func startPeriodicRefresh() {
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.periodicRefresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }
    
    private func stopPeriodicRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
    
    private func startKillTimer() {
        // Even with launchctl disable, mediaremoted can still spawn NowPlayingTouchUI
        // directly on certain triggers (app switch, media state change). Poll every 0.5s
        // and use bootout rather than killall so launchd doesn't treat it as a crash.
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.killNowPlayingTouchUIIfRunning()
        }
        RunLoop.main.add(timer, forMode: .common)
        killTimer = timer
    }
    
    private func stopKillTimer() {
        killTimer?.invalidate()
        killTimer = nil
    }
    
    // MARK: - Pause timeout
    
    /// Called whenever the play state changes (or a preference affecting the
    /// feature changes). Starts the countdown when paused, cancels it (and
    /// unhides) when playback resumes.
    ///
    /// - Parameter forceReevaluate: pass `true` when the caller isn't reporting
    ///   a play-state transition but wants the countdown re-evaluated anyway —
    ///   e.g. the user just toggled the feature on/off or changed the timeout
    ///   in preferences. Normal callers (play-state notifications) should leave
    ///   this `false` so redundant calls are ignored instead of restarting the
    ///   countdown from scratch every time.
    internal func resetInactivityTimer(forceReevaluate: Bool = false) {
        var isPlaying = currentNowPlayingItem?.isPlaying ?? false
        
        // Right after a wake, MediaRemote can briefly report stale/transient state
        // (a paused player looking "playing"). If we honoured that, the resume
        // branch below would clear the pause episode and unhide the widget, and
        // the following "paused" report would then start a brand-new countdown.
        // While a pause episode is on record, treat such a report as still
        // paused; scheduleWakeReconcile() re-checks the real state afterwards.
        if isPlaying && !forceReevaluate && shouldDistrustPlayingReport() {
            dbg("Ignoring 'playing' report inside the post-wake settle window (pause episode on record) — treating as still paused")
            isPlaying = false
            scheduleWakeReconcile()
        }
        
        // Identify the current source the same way updateWithInfo does, so we
        // can tell "the currently-shown track just paused" apart from "we just
        // switched to showing a *different*, already-paused track/app".
        let clientBundleId = currentNowPlayingItem?.client?.parentApplicationBundleIdentifier
            ?? currentNowPlayingItem?.client?.bundleIdentifier
        let previousClientBundleId = lastKnownClientBundleIdentifier
        // Only counts as a genuine "switch" once we've actually tracked a prior
        // client — otherwise the very first evaluation at launch would always
        // look like a "switch" and skip straight to hiding.
        let clientChanged = previousClientBundleId != nil && clientBundleId != previousClientBundleId
        lastKnownClientBundleIdentifier = clientBundleId
        
        // Edge-detect: ignore calls that don't represent an actual play-state
        // change. This is the fix for "sometimes it just keeps showing" —
        // several notifications (periodic refresh, isPlaying-did-change, etc.)
        // used to call this unconditionally, and if the adapter ever reported
        // a spurious/incomplete isPlaying blip, the countdown got wiped and
        // restarted from the full timeout, over and over.
        if !forceReevaluate {
            guard lastKnownIsPlaying != isPlaying || clientChanged else { return }
        }
        let previousIsPlaying = lastKnownIsPlaying
        lastKnownIsPlaying = isPlaying
        
        if isPlaying {
            // Playback resumed — cancel any running countdown and unhide immediately
            dbg("Playback resumed — clearing pause episode (was hidden: \(isHiddenDueToInactivity))")
            stopInactivityCountdown()  // also forgets the persisted pause start
            if isHiddenDueToInactivity {
                isHiddenDueToInactivity = false
                NotificationCenter.default.post(name: .nowPlayingInactivityDidChange, object: self)
            }
        } else {
            // Paused (or stopped) — (re)start the countdown if the feature is enabled
            guard Preferences[.hideAfterInactivity] else {
                stopInactivityCountdown()
                return
            }
            let timeout: Int = Preferences[.inactivityTimeout]
            guard timeout > 0 else {
                stopInactivityCountdown()
                return
            }
            
            if clientChanged && !forceReevaluate {
                // We're now showing a different app/track than before, and it's
                // already paused — e.g. Spotify quit and the adapter fell back to
                // Apple Music's stale paused session. We have no way of knowing
                // how long *that* has actually been sitting paused for, so it
                // isn't fair to grant it a brand new full timeout as if it had
                // just paused this instant. Hide right away instead.
                dbg("Now-playing source changed to an already-paused app (\(previousClientBundleId ?? "nil") -> \(clientBundleId ?? "nil")) — hiding immediately rather than starting a fresh countdown")
                // Record it as an already-expired episode so it also stays hidden if
                // the helper is rebuilt (e.g. across sleep/wake).
                if persistedPausedSince == nil {
                    persistedPausedSince = Date().addingTimeInterval(-TimeInterval(timeout))
                }
                handlePauseTimeout()
                return
            }
            
            // Already counting down for a genuine pause edge — leave it running
            // rather than restarting the clock. A forced re-evaluation (e.g. the
            // timeout preference just changed) always restarts with the fresh value.
            guard forceReevaluate || inactivityTicker == nil else { return }
            
            // Only a real playing -> paused transition (or an explicit forced
            // re-evaluation, e.g. the timeout preference changed) starts a fresh
            // clock. Anything else — notably the first evaluation of a helper
            // that was just (re)created after sleep/wake — must RESUME the pause
            // episode already on record, otherwise a track that's been paused for
            // an hour gets a brand new full countdown.
            if previousIsPlaying == true || forceReevaluate || persistedPausedSince == nil {
                persistedPausedSince = Date()
            }
            startInactivityCountdown(timeout: TimeInterval(timeout))
        }
    }
    
    /// Starts the pause countdown, measured from the start of the current pause
    /// episode (`persistedPausedSince`). If that's already further back than the
    /// timeout, hides immediately instead of showing the widget for another cycle.
    private func startInactivityCountdown(timeout: TimeInterval) {
        inactivityTicker?.invalidate()
        let start = persistedPausedSince ?? Date()
        pausedSince = start
        let elapsed = Date().timeIntervalSince(start)
        if elapsed >= timeout {
            dbg("Paused for \(Int(elapsed))s already (timeout \(Int(timeout))s) — hiding immediately")
            handlePauseTimeout()
            return
        }
        let ticker = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tickInactivityCountdown(timeout: timeout)
        }
        RunLoop.main.add(ticker, forMode: .common)
        inactivityTicker = ticker
        dbg("Pause countdown running — will hide in \(Int(timeout - elapsed))s (fresh clock: \(elapsed < 1))")
    }
    
    /// Fires once a second while paused. Uses wall-clock elapsed time (rather
    /// than counting ticks) so a delayed/late-firing timer — e.g. right after
    /// the Mac wakes from sleep, when timers can fire in a burst to catch up —
    /// still reports/hides at the correct moment instead of over- or under-counting.
    private func tickInactivityCountdown(timeout: TimeInterval) {
        guard let pausedSince = pausedSince else {
            stopInactivityCountdown()
            return
        }
        let elapsed = Date().timeIntervalSince(pausedSince)
        let remaining = max(0, timeout - elapsed)
        if elapsed >= timeout {
            handlePauseTimeout()
        }
    }
    
    private func handlePauseTimeout() {
        dbg("Pause timeout fired — hiding widget")
        // Keep the persisted pause start: the widget is hidden *because of* that
        // episode, and must stay hidden across sleep/wake until playback resumes.
        stopInactivityCountdown(clearPersistedPause: false)
        isHiddenDueToInactivity = true
        NotificationCenter.default.post(name: .nowPlayingInactivityDidChange, object: self)
    }
    
    private func stopInactivityCountdown(clearPersistedPause: Bool = true) {
        inactivityTicker?.invalidate()
        inactivityTicker = nil
        pausedSince = nil
        if clearPersistedPause {
            persistedPausedSince = nil
        }
    }
    
    // MARK: - Wake settling
    
    /// Time of the most recent system wake, straight from the kernel. Unlike our
    /// own didWake handler this is also correct for a helper that was created
    /// *after* the wake notification had already gone out.
    private static func systemLastWakeDate() -> Date? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctlbyname("kern.waketime", &tv, &size, nil, 0) == 0, tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
    }
    
    private var wakeSettleEnd: Date? {
        let latestWake = [lastWakeHandled, NowPlayingHelper.systemLastWakeDate()].compactMap { $0 }.max()
        return latestWake?.addingTimeInterval(NowPlayingHelper.wakeSettleSeconds)
    }
    
    private var isInWakeSettle: Bool {
        guard let end = wakeSettleEnd else { return false }
        return end > Date()
    }
    
    /// A "playing" report is only distrusted while (a) we're shortly after a wake,
    /// (b) a pause episode is on record that it would wipe out, and (c) the user
    /// didn't just press play themselves.
    private func shouldDistrustPlayingReport() -> Bool {
        guard persistedPausedSince != nil || isHiddenDueToInactivity else { return false }
        guard isInWakeSettle else { return false }
        if let t = lastUserToggle, Date().timeIntervalSince(t) < 15 { return false }
        return true
    }
    
    /// Once the settle window closes, ask the adapter what's really going on and
    /// feed it through the normal path — a genuine "playing" then unhides the
    /// widget, anything else leaves the pause episode untouched.
    private func scheduleWakeReconcile() {
        guard wakeReconcileWorkItem == nil else { return }
        let delay = max(0.5, (wakeSettleEnd ?? Date()).timeIntervalSinceNow + 0.5)
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.wakeReconcileWorkItem = nil
            self.dbg("Wake settle window over — re-checking real playback state")
            MediaRemoteAdapter.shared.getNowPlayingInfo { [weak self] info in
                self?.updateWithInfo(info)
            }
        }
        wakeReconcileWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    
    /// Whether the widget should currently be suppressed due to a pause timeout.
    public var shouldHideDueToInactivity: Bool { isHiddenDueToInactivity }
    
    private func periodicRefresh() {
        // Refresh if something is playing OR if we have a client set
        // (covers transitions where isPlaying is briefly false)
        guard let currentItem = currentNowPlayingItem,
              currentItem.isPlaying || currentItem.client != nil else { return }
        
        // Get fresh state
        MediaRemoteAdapter.shared.getNowPlayingInfo { [weak self] info in
            guard let self = self else { return }
            
            // Check if any displayable field has diverged from our cached state
            let titleChanged     = self.currentNowPlayingItem?.title    != info?.title
            let artistChanged    = self.currentNowPlayingItem?.artist   != info?.artist
            let albumChanged     = self.currentNowPlayingItem?.album    != info?.album
            let isPlayingChanged = self.currentNowPlayingItem?.isPlaying != info?.isPlaying
            // Treat artwork as changed if adapter has data but we're showing nothing
            let artworkChanged   = info?.artworkData != nil && self.currentNowPlayingItem?.artwork == nil
            
            if titleChanged || artistChanged || albumChanged || isPlayingChanged || artworkChanged {
                print("[NowPlayingHelper] Periodic refresh detected state change - updating")
                self.updateWithInfo(info)
            }
        }
    }
    
    private func registerForNotifications() {
        NSLog("[NOW_PLAYING]: NowPlayingHelper - registerForNotifications")
        
        // Subscribe to MediaRemoteAdapter notifications
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(updateCurrentPlayingApp),
                                               name: .mediaRemoteAdapterNowPlayingApplicationDidChange,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(updateMediaContent),
                                               name: .mediaRemoteAdapterNowPlayingInfoDidChange,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(updateCurrentPlayingState),
                                               name: .mediaRemoteAdapterIsPlayingDidChange,
                                               object: nil)
        
        // Listen for preference changes - native Now Playing
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleDisableNativeNowPlayingChange),
                                               name: Notification.Name(didChangeDisableNativeNowPlayingNotification),
                                               object: nil)
        
        // ADDED: Listen for app launches/terminations to catch music app restarts
        NSWorkspace.shared.notificationCenter.addObserver(self,
                                                          selector: #selector(handleAppLaunched),
                                                          name: NSWorkspace.didLaunchApplicationNotification,
                                                          object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self,
                                                          selector: #selector(handleAppTerminated),
                                                          name: NSWorkspace.didTerminateApplicationNotification,
                                                          object: nil)
        
        // ADDED: Listen for sleep/wake to restore widget after lid close
        NSWorkspace.shared.notificationCenter.addObserver(self,
                                                          selector: #selector(handleSystemSleep),
                                                          name: NSWorkspace.willSleepNotification,
                                                          object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self,
                                                          selector: #selector(handleSystemWake),
                                                          name: NSWorkspace.didWakeNotification,
                                                          object: nil)
    }
    
    private func unregisterForNotifications() {
        NSLog("[NOW_PLAYING]: NowPlayingHelper - un-registerForNotifications")
        
        NotificationCenter.default.removeObserver(self, name: .mediaRemoteAdapterNowPlayingApplicationDidChange, object: nil)
        NotificationCenter.default.removeObserver(self, name: .mediaRemoteAdapterNowPlayingInfoDidChange, object: nil)
        NotificationCenter.default.removeObserver(self, name: .mediaRemoteAdapterIsPlayingDidChange, object: nil)
        
        // Remove workspace observers
        NSWorkspace.shared.notificationCenter.removeObserver(self, name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.removeObserver(self, name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.removeObserver(self, name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.removeObserver(self, name: NSWorkspace.didWakeNotification, object: nil)
        
        // Stop periodic refresh and kill timer
        stopPeriodicRefresh()
        stopKillTimer()
        // Quietly stop the ticker only. This must NOT clear the persisted pause
        // start (a helper being torn down is exactly what happens around
        // sleep/wake, and the replacement helper needs that record), and must not
        // post notifications — the view is going away too.
        inactivityTicker?.invalidate()
        inactivityTicker = nil
        pausedSince = nil
        wakeReconcileWorkItem?.cancel()
        wakeReconcileWorkItem = nil
        
        // Cancel any pending artwork fallback
        artworkFallbackWorkItem?.cancel()
        artworkFallbackWorkItem = nil
        
        // Stop the shared adapter only if no other helper is still using it —
        // otherwise a released old helper would kill the stream the new one needs.
        if NowPlayingHelper.liveInstanceCount <= 0 {
            MediaRemoteAdapter.shared.stopStreaming()
        }
    }
    
    private func updateFromAdapter() {
        print("[NowPlayingHelper] updateFromAdapter - getting initial state")
        // Get initial state from adapter
        MediaRemoteAdapter.shared.getNowPlayingInfo { [weak self] info in
            guard let self = self else { return }
            print("[NowPlayingHelper] updateFromAdapter - got info: \(info?.title ?? "nil")")
            
            // If no info, make sure we at least have the default client set
            if info == nil || (info?.bundleIdentifier == nil && info?.parentApplicationBundleIdentifier == nil) {
                print("[NowPlayingHelper] updateFromAdapter - no active client, setting default")
                let customDefaultPlayerIdentifier: String = Preferences[.defaultPlayer]
                let displayName = NSWorkspace.shared.applicationName(for: customDefaultPlayerIdentifier)
                let icon = NSWorkspace.shared.applicationIcon(for: customDefaultPlayerIdentifier, fallbackFileType: "mp3")
                self.currentNowPlayingItem?.client = NowPlayingItem.Client(
                    bundleIdentifier: customDefaultPlayerIdentifier,
                    parentApplicationBundleIdentifier: nil,
                    displayName: displayName,
                    icon: icon
                )
            }
            
            self.updateWithInfo(info)
        }
    }
    
    @objc private func updateCurrentPlayingApp(_ notification: Notification?) {
        print("[NowPlayingHelper] updateCurrentPlayingApp called")
        // Always do a fresh fetch so we get the actual current player,
        // not stale cached info from the previous app.
        MediaRemoteAdapter.shared.getNowPlayingInfo { [weak self] info in
            guard let self = self else { return }
            self.updateWithInfo(info)
        }
    }
    
    @objc private func updateMediaContent(_ notification: Notification?) {
        print("[NowPlayingHelper] updateMediaContent called")
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                print("[NowPlayingHelper] updateMediaContent - self is nil")
                return
            }
            
            print("[NowPlayingHelper] updateMediaContent - getting info from adapter")
            guard let info = MediaRemoteAdapter.shared.currentInfo else {
                print("[NowPlayingHelper] updateMediaContent - no info from adapter")
                
                // If we already have a client set (from any source — Music, Spotify,
                // browser, etc.), preserve the existing state. Transient nil updates
                // during song changes should not wipe the widget.
                if self.currentNowPlayingItem?.client != nil {
                    print("[NowPlayingHelper] Existing client present - preserving state during nil transition")
                    return
                }
                
                // No existing client — check if a known media app is running
                // and set it as the default so the widget stays visible.
                let mediaApps = ["com.apple.Music", "com.spotify.client", "com.apple.iTunes"]
                if let runningApp = NSWorkspace.shared.runningApplications.first(where: { mediaApps.contains($0.bundleIdentifier ?? "") }),
                   let bundleId = runningApp.bundleIdentifier {
                    print("[NowPlayingHelper] Media app running (\(bundleId)) - setting as client")
                    let displayName = NSWorkspace.shared.applicationName(for: bundleId)
                    let icon = NSWorkspace.shared.applicationIcon(for: bundleId, fallbackFileType: "mp3")
                    self.currentNowPlayingItem?.client = NowPlayingItem.Client(
                        bundleIdentifier: bundleId,
                        parentApplicationBundleIdentifier: nil,
                        displayName: displayName,
                        icon: icon
                    )
                } else {
                    self.updateWithInfo(nil)
                }
                return
            }
            
            print("[NowPlayingHelper] updateMediaContent - got info: \(info.title ?? "nil")")
            // Route through updateWithInfo so all artwork logic (adapter vs iTunes fallback,
            // track-change detection, stale-image clearing) lives in one place.
            self.updateWithInfo(info)
        }
    }
    
    @objc private func updateCurrentPlayingState(_ notification: Notification?) {
        print("[NowPlayingHelper] updateCurrentPlayingState called")
        
        // REMOVED: The guard that could skip updates
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            guard let info = MediaRemoteAdapter.shared.currentInfo else {
                self.currentNowPlayingItem?.isPlaying = false
                self.view?.updateContentViews()
                return
            }
            
            // Update playing state
            if info.bundleIdentifier == nil && info.parentApplicationBundleIdentifier == nil {
                self.currentNowPlayingItem?.isPlaying = false
            } else {
                self.currentNowPlayingItem?.isPlaying = info.isPlaying
            }
            
            // Play/pause counts as activity — reset the inactivity countdown
            self.resetInactivityTimer()
            
            // ALWAYS update the view
            self.view?.updateContentViews()
        }
    }
    
    @objc private func handleSystemSleep(_ notification: Notification) {
        print("[NowPlayingHelper] System going to sleep - stopping adapter")
        MediaRemoteAdapter.shared.stopStreaming()
        // Deliberately leave any running countdown alone here. `pausedSince` is
        // a plain wall-clock Date, and the ticker's elapsed-time check is also
        // wall-clock based (Date().timeIntervalSince(pausedSince)), not a tick
        // count — so it doesn't need "catching up" or resetting. If a track was
        // 8s into a 30s countdown when the Mac slept, it's correctly still 8s+
        // (real elapsed sleep time) in once the run loop resumes, instead of
        // being force-restarted at a fresh full timeout on every sleep/wake.
    }
    
    @objc private func handleSystemWake(_ notification: Notification) {
        lastWakeHandled = Date()
        dbg("System woke - restarting adapter (paused-since on record: \(persistedPausedSince != nil), hidden: \(isHiddenDueToInactivity))")
        
        // No forced show/hide or countdown reset here on purpose — see
        // handleSystemSleep. Restarting the adapter below fetches fresh info
        // through the normal updateWithInfo -> resetInactivityTimer path, which
        // only reacts to an *actual* play-state or source change (edge-detected
        // against lastKnownIsPlaying / lastKnownClientBundleIdentifier, neither
        // of which we touch here). So if playback is genuinely unchanged across
        // the sleep — still paused on the same app, or still playing — nothing
        // is disturbed: an in-progress countdown keeps counting from where it
        // was, and an already-hidden widget stays hidden instead of flashing
        // back into view. A real change (e.g. something actually got paused
        // while asleep) still starts a fresh countdown as normal, since that's
        // a genuine transition.
        
        // If a countdown was mid-flight when we slept, evaluate it against the
        // wall clock right away (Timer.fire() runs the handler without disturbing
        // the schedule) so it hides at once if the timeout passed during sleep.
        if let ticker = inactivityTicker, ticker.isValid {
            ticker.fire()
        }
        
        // Give the system a moment to fully wake before restarting
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self else { return }
            
            // Re-suppress NowPlayingTouchUI on wake if preference is enabled
            // launchd sometimes re-enables agents during sleep/wake cycles
            if Preferences[.disableNativeNowPlaying] {
                self.suppressNowPlayingTouchUI()
            }
            
            // Restart the stream
            MediaRemoteAdapter.shared.startStreaming()
            
            // Restore the default client so the widget is visible even if nothing
            // is playing — but only if there's no client already. Overwriting an
            // existing one (e.g. Spotify) with the default player made the next
            // resetInactivityTimer() look like a source change mid-wake.
            if self.currentNowPlayingItem?.client == nil {
                let customDefaultPlayerIdentifier: String = Preferences[.defaultPlayer]
                let displayName = NSWorkspace.shared.applicationName(for: customDefaultPlayerIdentifier)
                let icon = NSWorkspace.shared.applicationIcon(for: customDefaultPlayerIdentifier, fallbackFileType: "mp3")
                self.currentNowPlayingItem?.client = NowPlayingItem.Client(
                    bundleIdentifier: customDefaultPlayerIdentifier,
                    parentApplicationBundleIdentifier: nil,
                    displayName: displayName,
                    icon: icon
                )
            }
            
            // Force update the view so it reappears
            self.view?.updateContentViews()
            
            // Then get fresh state from the adapter
            self.forceFullStateRefresh()
        }
    }
    
    /// Handle changes to the "disable native Now Playing" preference
    @objc private func handleDisableNativeNowPlayingChange() {
        let shouldDisable: Bool = Preferences[.disableNativeNowPlaying]
        print("[NowPlayingHelper] handleDisableNativeNowPlayingChange - shouldDisable: \(shouldDisable)")
        
        if shouldDisable {
            // Enable suppression
            suppressNowPlayingTouchUI()
            startKillTimer()
        } else {
            // Disable suppression - re-enable the native Now Playing Touch Bar
            reenableNowPlayingTouchUI()
            stopKillTimer()
        }
    }
    
    /// Re-enable the native Now Playing Touch Bar agent via launchctl
    private func reenableNowPlayingTouchUI() {
        DispatchQueue.global(qos: .userInitiated).async {
            let enable = Process()
            enable.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            enable.arguments = ["enable", "gui/\(getuid())/com.apple.nowplayingtouchui"]
            try? enable.run()
            enable.waitUntilExit()
            
            // Boot the agent to start it immediately
            let boot = Process()
            boot.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            boot.arguments = ["boot", "gui/\(getuid())/com.apple.nowplayingtouchui"]
            try? boot.run()
            boot.waitUntilExit()
            
            print("[NowPlayingHelper] NowPlayingTouchUI re-enabled via launchctl")
        }
    }
    
    @objc private func handleAppLaunched(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        guard let bundleId = app.bundleIdentifier else { return }
        
        // Belt-and-suspenders: if it somehow launches despite the launchctl disable, kill it
        // Only do this if preference is enabled
        if Preferences[.disableNativeNowPlaying] && (bundleId == "com.apple.NowPlayingTouchUI" || app.localizedName == "NowPlayingTouchUI") {
            print("[NowPlayingHelper] NowPlayingTouchUI launched despite disable - killing and re-suppressing")
            suppressNowPlayingTouchUI()
            return
        }
        
        print("[NowPlayingHelper] App launched: \(bundleId)")
        
        let musicApps = ["com.apple.Music", "com.spotify.client", "com.apple.iTunes"]
        guard musicApps.contains(bundleId) else { return }
        
        // Restore the client immediately so the widget reappears right away,
        // before we even know if something is playing. The view uses client presence
        // to decide whether to show at all.
        let displayName = NSWorkspace.shared.applicationName(for: bundleId)
        let icon = NSWorkspace.shared.applicationIcon(for: bundleId, fallbackFileType: "mp3")
        self.currentNowPlayingItem?.client = NowPlayingItem.Client(
            bundleIdentifier: bundleId,
            parentApplicationBundleIdentifier: nil,
            displayName: displayName,
            icon: icon
        )
        self.view?.updateContentViews()
        
        // Restart the stream — mediaremoted resets its state when the active player
        // changes, so the existing Perl stream may miss the first updates.
        MediaRemoteAdapter.shared.stopStreaming()
        MediaRemoteAdapter.shared.startStreaming()
        
        // Then fetch actual playback state once the app has had a moment to start up
        print("[NowPlayingHelper] Music app launched - forcing state refresh")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.forceFullStateRefresh()
        }
    }
    
    @objc private func handleAppTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        guard let bundleId = app.bundleIdentifier else { return }
        
        print("[NowPlayingHelper] App terminated: \(bundleId)")
        
        let musicApps = ["com.apple.Music", "com.spotify.client", "com.apple.iTunes"]
        guard musicApps.contains(bundleId) else { return }
        
        // Clear stale content immediately so we never show the dead app's last song
        // on a newly launched player. Keep client set if another music app is already
        // running so the widget stays visible during the handoff.
        artworkFallbackWorkItem?.cancel()
        artworkFallbackWorkItem = nil
        lastArtworkFetchKey = nil
        currentNowPlayingItem?.title = nil
        currentNowPlayingItem?.album = nil
        currentNowPlayingItem?.artist = nil
        currentNowPlayingItem?.artwork = nil
        currentNowPlayingItem?.isPlaying = false
        
        // Check if another music app is already running and take it as the new client
        let otherRunningApp = NSWorkspace.shared.runningApplications.first(where: {
            musicApps.contains($0.bundleIdentifier ?? "") && $0.bundleIdentifier != bundleId
        })
        if let other = otherRunningApp, let otherId = other.bundleIdentifier {
            let displayName = NSWorkspace.shared.applicationName(for: otherId)
            let icon = NSWorkspace.shared.applicationIcon(for: otherId, fallbackFileType: "mp3")
            currentNowPlayingItem?.client = NowPlayingItem.Client(
                bundleIdentifier: otherId,
                parentApplicationBundleIdentifier: nil,
                displayName: displayName,
                icon: icon
            )
        } else {
            currentNowPlayingItem?.client = nil
        }
        view?.updateContentViews()
        
        // Restart the stream so it's fresh for the next active player
        MediaRemoteAdapter.shared.stopStreaming()
        MediaRemoteAdapter.shared.startStreaming()
        
        // Fetch state after stream has had time to connect
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.forceFullStateRefresh()
        }
    }
    
    private func forceFullStateRefresh() {
        print("[NowPlayingHelper] Forcing full state refresh")
        MediaRemoteAdapter.shared.getNowPlayingInfo { [weak self] info in
            guard let self = self else { return }
            print("[NowPlayingHelper] Force refresh got info: \(info?.title ?? "nil")")
            self.updateWithInfo(info)
        }
    }
    
    private func updateWithInfo(_ info: NowPlayingInfo?) {
        print("[NowPlayingHelper] updateWithInfo called")
        
        guard var info = info else {
            print("[NowPlayingHelper] updateWithInfo - no info, clearing playback state")
            artworkFallbackWorkItem?.cancel()
            artworkFallbackWorkItem = nil
            lastArtworkFetchKey = nil
            self.currentNowPlayingItem?.title = nil
            self.currentNowPlayingItem?.album = nil
            self.currentNowPlayingItem?.artist = nil
            self.currentNowPlayingItem?.artwork = nil
            self.currentNowPlayingItem?.isPlaying = false
            
            // Re-evaluate the pause timeout now that isPlaying is false — this
            // branch used to skip this entirely, so a transition straight to
            // "no info" never started the countdown.
            self.resetInactivityTimer()
            
            // If we already have a client from any source, preserve it.
            // The client will be cleared explicitly when the app terminates
            // (handleAppTerminated) or when a new app takes over.
            if self.currentNowPlayingItem?.client != nil {
                print("[NowPlayingHelper] updateWithInfo - preserving existing client")
            } else {
                // No existing client — check if a known media app is running
                let mediaApps = ["com.apple.Music", "com.spotify.client", "com.apple.iTunes"]
                if let runningApp = NSWorkspace.shared.runningApplications.first(where: {
                    mediaApps.contains($0.bundleIdentifier ?? "")
                }), let bundleId = runningApp.bundleIdentifier {
                    print("[NowPlayingHelper] updateWithInfo - Media app running (\(bundleId)), keeping widget visible")
                    let displayName = NSWorkspace.shared.applicationName(for: bundleId)
                    let icon = NSWorkspace.shared.applicationIcon(for: bundleId, fallbackFileType: "mp3")
                    self.currentNowPlayingItem?.client = NowPlayingItem.Client(
                        bundleIdentifier: bundleId,
                        parentApplicationBundleIdentifier: nil,
                        displayName: displayName,
                        icon: icon
                    )
                }
            }
            
            self.view?.updateContentViews()
            return
        }
        
        print("[NowPlayingHelper] updateWithInfo - title: \(info.title ?? "nil")")
        
        // Update client
        let bundleId = info.parentApplicationBundleIdentifier ?? info.bundleIdentifier
        let displayName = NSWorkspace.shared.applicationName(for: bundleId ?? "")
        let icon = NSWorkspace.shared.applicationIcon(for: bundleId, fallbackFileType: "mp3")
        self.currentNowPlayingItem?.client = NowPlayingItem.Client(
            bundleIdentifier: info.bundleIdentifier,
            parentApplicationBundleIdentifier: info.parentApplicationBundleIdentifier,
            displayName: displayName,
            icon: icon
        )
        
        // Detect track change so we can clear stale artwork immediately
        let newTrackKey = "\(info.title ?? "")|\(info.artist ?? "")"
        let trackChanged = newTrackKey != lastArtworkFetchKey && info.title != nil
        
        // Update content fields
        self.currentNowPlayingItem?.title = info.title
        self.currentNowPlayingItem?.album = info.album
        self.currentNowPlayingItem?.artist = info.artist
        self.currentNowPlayingItem?.isPlaying = info.isPlaying
        
        // Re-evaluate pause timeout now that isPlaying is updated
        resetInactivityTimer()
        
        // Handle artwork
        if info.hasAdapterArtwork {
            // Adapter has artwork data — decode and use it. Cancel any iTunes fallback.
            // This is always the correct artwork: it comes directly from Apple Music.
            print("[NowPlayingHelper] updateWithInfo - using artwork from adapter")
            artworkFallbackWorkItem?.cancel()
            artworkFallbackWorkItem = nil
            lastArtworkFetchKey = newTrackKey
            self.currentNowPlayingItem?.artwork = info.artwork
        } else {
            // Adapter has no artwork data for this update.
            if trackChanged {
                print("[NowPlayingHelper] updateWithInfo - track changed, polling for full state with artwork")
                artworkFallbackWorkItem?.cancel()
                artworkFallbackWorkItem = nil
                lastArtworkFetchKey = newTrackKey
                // Do NOT clear artwork yet — keep the previous song's art visible while we
                // fetch the new one. It will be overwritten atomically when ready, avoiding
                // the blank-image flash.
                
                MediaRemoteAdapter.shared.getNowPlayingInfo { [weak self] freshInfo in
                    guard let self = self else { return }
                    
                    let currentKey = "\(self.currentNowPlayingItem?.title ?? "")|\(self.currentNowPlayingItem?.artist ?? "")"
                    guard currentKey == newTrackKey else {
                        print("[NowPlayingHelper] updateWithInfo - track changed during poll, discarding")
                        return
                    }
                    
                    if var freshInfo = freshInfo, freshInfo.hasAdapterArtwork {
                        print("[NowPlayingHelper] updateWithInfo - got artwork from fresh poll")
                        self.artworkFallbackWorkItem?.cancel()
                        self.artworkFallbackWorkItem = nil
                        self.currentNowPlayingItem?.artwork = freshInfo.artwork
                        self.view?.updateContentViews()
                    } else {
                        // Poll also had no artwork — now clear old art and fall back to iTunes
                        self.currentNowPlayingItem?.artwork = nil
                        self.view?.updateContentViews()
                        let snapshot = self.currentNowPlayingItem
                        let workItem = DispatchWorkItem { [weak self] in
                            guard let self = self else { return }
                            if let adapterInfo = MediaRemoteAdapter.shared.currentInfo, adapterInfo.hasAdapterArtwork {
                                print("[NowPlayingHelper] updateWithInfo - adapter artwork arrived, skipping iTunes API")
                                return
                            }
                            print("[NowPlayingHelper] updateWithInfo - fetching artwork from iTunes API")
                            self.fetchArtwork(for: snapshot) { [weak self] image in
                                guard let self = self else { return }
                                let currentKey = "\(self.currentNowPlayingItem?.title ?? "")|\(self.currentNowPlayingItem?.artist ?? "")"
                                guard currentKey == newTrackKey else {
                                    print("[NowPlayingHelper] updateWithInfo - track changed during iTunes fetch, discarding result")
                                    return
                                }
                                print("[NowPlayingHelper] updateWithInfo - got artwork from iTunes API, applying")
                                self.currentNowPlayingItem?.artwork = image
                                self.view?.updateContentViews()
                            }
                        }
                        self.artworkFallbackWorkItem = workItem
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
                    }
                }
            } else {
                // Same track, no adapter artwork — nothing to do, keep whatever we have
                print("[NowPlayingHelper] updateWithInfo - same track, no new artwork data")
            }
        }
        
        // ALWAYS update the view with current state (artwork may load async later)
        self.view?.updateContentViews()
    }
    
    private func suppressNowPlayingTouchUI() {
        // Run off the main thread — waitUntilExit() blocks, and blocking the main
        // thread during Touch Bar layout causes a crash in NSTouchBarCustomizationPalette.
        DispatchQueue.global(qos: .userInitiated).async {
            let disable = Process()
            disable.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            disable.arguments = ["disable", "gui/\(getuid())/com.apple.nowplayingtouchui"]
            try? disable.run()
            disable.waitUntilExit()
            
            let bootout = Process()
            bootout.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            bootout.arguments = ["bootout", "gui/\(getuid())/com.apple.nowplayingtouchui"]
            try? bootout.run()
            bootout.waitUntilExit()
            
            DispatchQueue.main.async {
                self.killNowPlayingTouchUIIfRunning()
                print("[NowPlayingHelper] NowPlayingTouchUI suppressed via launchctl")
            }
        }
    }
    
    /// Lightweight check used by the repeating timer - only acts if the process
    /// is actually running, so it costs just a list lookup on the happy path.
    private func killNowPlayingTouchUIIfRunning() {
        let matches = NSWorkspace.shared.runningApplications
            .filter { $0.localizedName == "NowPlayingTouchUI" }
        guard !matches.isEmpty else { return }
        matches.forEach {
            print("[NowPlayingHelper] Killing NowPlayingTouchUI PID \($0.processIdentifier)")
            kill($0.processIdentifier, SIGKILL)
        }
    }
    
    deinit {
        NowPlayingHelper.liveInstanceCount -= 1
        NSLog("[NOW_PLAYING]: NowPlayingHelper#\(instanceId) - deinit (live helpers left: \(NowPlayingHelper.liveInstanceCount))")
        view = nil
        currentNowPlayingItem = nil
        unregisterForNotifications()
    }
    
}

extension NowPlayingHelper {
    
    public func togglePlayingState() {
        lastUserToggle = Date()
        print("[NowPlayingHelper] togglePlayingState called")
        MediaRemoteAdapter.shared.sendCommand(.togglePlayPause)
    }
    
    public func skipToNextTrack() {
        lastUserToggle = Date()
        print("[NowPlayingHelper] skipToNextTrack called")
        MediaRemoteAdapter.shared.sendCommand(.nextTrack)
    }
    
    public func skipToPreviousTrack() {
        lastUserToggle = Date()
        print("[NowPlayingHelper] skipToPreviousTrack called")
        MediaRemoteAdapter.shared.sendCommand(.previousTrack)
    }
    
}

/// Credit: https://github.com/musa11971/Music-Bar
extension NowPlayingHelper {
    /// Retrieves the artwork of the current track from Apple
    fileprivate func fetchArtwork(for item: NowPlayingItem?, _ completion: @escaping (NSImage?) -> Void) {
        /// Destroy tasks, if any was already busy
        latestArtworkTask?.cancel()
        /// Check for now playing item
        guard let item = item, let searchTerm = item.searchTerm else {
            DispatchQueue.main.async {
                completion(nil)
            }
            return
        }
        /// Start fetching artwork
        let apiURL: String = "https://itunes.apple.com/search?term=\(searchTerm)&entity=song&limit=1"
        latestArtworkTask = URLSession.fetchJSON(fromURL: URL(string: apiURL)!) { [weak self] (data, json, error) in
            if error != nil {
                print("Could not get artwork")
                DispatchQueue.main.async {
                    completion(nil)
                }
                return
            }
            if let json = json as? [String: Any] {
                if let results = json["results"] as? [[String: Any]] {
                    if results.count >= 1, let imgURL = results[0]["artworkUrl100"] as? String {
                        // Create the URL
                        guard let url = URL(string: imgURL.replacingOccurrences(of: "100x100", with: "300x300")) else {
                            DispatchQueue.main.async {
                                completion(nil)
                            }
                            return
                        }
                        // Download the artwork
                        self?.latestArtworkTask = URLSession.shared.dataTask(with: url, completionHandler: { (data, response, error) in
                            if error != nil {
                                DispatchQueue.main.async {
                                    completion(nil)
                                }
                                return
                            }
                            guard let data = data else {
                                DispatchQueue.main.async {
                                    completion(nil)
                                }
                                return
                            }
                            // CRITICAL FIX: Create NSImage on main thread
                            DispatchQueue.main.async {
                                completion(NSImage(data: data))
                            }
                        })
                        self?.latestArtworkTask?.resume()
                    } else {
                        DispatchQueue.main.async {
                            completion(nil)
                        }
                    }
                }
            }
        }
        latestArtworkTask?.resume()
    }
}

extension URLSession {
    static func fetchJSON(fromURL url: URL, completionHandler: @escaping (Data?, Any?, Error?) -> Void) -> URLSessionTask {
        let task = URLSession.shared.dataTask(with: url) { (data, response, error) in
            if error != nil {
                completionHandler(nil, nil, error)
                return
            }
            if data == nil {
                completionHandler(nil, nil, NSError(domain:"", code:401, userInfo:[ NSLocalizedDescriptionKey: "Invalid data"]))
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data!, options: .allowFragments) else {
                completionHandler(nil, nil, NSError(domain:"", code:401, userInfo:[ NSLocalizedDescriptionKey: "Invalid json"]))
                return
            }
            completionHandler(data, json, nil)
        }
        return task
    }
}

extension NSWorkspace {
    public func applicationName(for bundleIdentifier: String) -> String? {
        self.urlForApplication(withBundleIdentifier: bundleIdentifier)?.lastPathComponent.replacingOccurrences(of: ".app", with: "")
    }
    public func applicationIcon(for bundleIdentifier: String?, fallbackFileType: String? = nil) -> NSImage? {
        if let bundleIdentifier = bundleIdentifier,
           let path = NSWorkspace.shared.absolutePathForApplication(withBundleIdentifier: bundleIdentifier) {
            return NSWorkspace.shared.icon(forFile: path)
        } else {
            return NSWorkspace.shared.icon(forFileType: fallbackFileType ?? "pock")
        }
    }
}
