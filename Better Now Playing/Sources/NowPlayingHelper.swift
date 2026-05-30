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
    /// One-shot timer that fires when the user's chosen inactivity period expires
    private var inactivityTimer: Timer?
    /// Tracks whether the widget is currently hidden due to inactivity timeout
    private var isHiddenDueToInactivity: Bool = false
    
    internal init(forView: NowPlayingView) {
        NSLog("[NOW_PLAYING]: NowPlayingHelper - init")
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
    
    /// Called whenever the play state changes. Starts the countdown when paused,
    /// cancels it (and unhides) when playback resumes.
    internal func resetInactivityTimer() {
        let isPlaying = currentNowPlayingItem?.isPlaying ?? false
        
        if isPlaying {
            // Playback resumed — cancel any running timer and unhide immediately
            inactivityTimer?.invalidate()
            inactivityTimer = nil
            if isHiddenDueToInactivity {
                isHiddenDueToInactivity = false
                NotificationCenter.default.post(name: .nowPlayingInactivityDidChange, object: nil)
            }
        } else {
            // Paused (or stopped) — start the countdown if the feature is enabled
            // and a timer isn't already running
            guard Preferences[.hideAfterInactivity] else {
                inactivityTimer?.invalidate()
                inactivityTimer = nil
                return
            }
            guard inactivityTimer == nil else { return }   // already counting down
            let timeout: Int = Preferences[.inactivityTimeout]
            guard timeout > 0 else { return }
            let timer = Timer(timeInterval: TimeInterval(timeout), repeats: false) { [weak self] _ in
                self?.handlePauseTimeout()
            }
            RunLoop.main.add(timer, forMode: .common)
            inactivityTimer = timer
            print("[NowPlayingHelper] Pause timeout started — will hide in \(timeout)s")
        }
    }
    
    private func handlePauseTimeout() {
        print("[NowPlayingHelper] Pause timeout fired — hiding widget")
        isHiddenDueToInactivity = true
        NotificationCenter.default.post(name: .nowPlayingInactivityDidChange, object: nil)
    }
    
    private func stopInactivityTimer() {
        inactivityTimer?.invalidate()
        inactivityTimer = nil
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
        stopInactivityTimer()
        
        // Cancel any pending artwork fallback
        artworkFallbackWorkItem?.cancel()
        artworkFallbackWorkItem = nil
        
        // Stop the adapter
        MediaRemoteAdapter.shared.stopStreaming()
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
    }
    
    @objc private func handleSystemWake(_ notification: Notification) {
        print("[NowPlayingHelper] System woke - restarting adapter and restoring widget")
        
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
            
            // Restore the default client so widget is visible even if nothing is playing
            let customDefaultPlayerIdentifier: String = Preferences[.defaultPlayer]
            let displayName = NSWorkspace.shared.applicationName(for: customDefaultPlayerIdentifier)
            let icon = NSWorkspace.shared.applicationIcon(for: customDefaultPlayerIdentifier, fallbackFileType: "mp3")
            self.currentNowPlayingItem?.client = NowPlayingItem.Client(
                bundleIdentifier: customDefaultPlayerIdentifier,
                parentApplicationBundleIdentifier: nil,
                displayName: displayName,
                icon: icon
            )
            
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
        NSLog("[NOW_PLAYING]: NowPlayingHelper - deinit")
        view = nil
        currentNowPlayingItem = nil
        unregisterForNotifications()
    }
    
}

extension NowPlayingHelper {
    
    public func togglePlayingState() {
        print("[NowPlayingHelper] togglePlayingState called")
        MediaRemoteAdapter.shared.sendCommand(.togglePlayPause)
    }
    
    public func skipToNextTrack() {
        print("[NowPlayingHelper] skipToNextTrack called")
        MediaRemoteAdapter.shared.sendCommand(.nextTrack)
    }
    
    public func skipToPreviousTrack() {
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
