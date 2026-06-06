//
//  MediaRemoteAdapter.swift
//  Better Now Playing
//
//  Created by JosephPri
//

import Foundation
import AppKit

/// Notification names that match the original MediaRemote notifications
extension Notification.Name {
    static let mediaRemoteAdapterNowPlayingInfoDidChange = Notification.Name("MediaRemoteAdapterNowPlayingInfoDidChange")
    static let mediaRemoteAdapterNowPlayingApplicationDidChange = Notification.Name("MediaRemoteAdapterNowPlayingApplicationDidChange")
    static let mediaRemoteAdapterIsPlayingDidChange = Notification.Name("MediaRemoteAdapterIsPlayingDidChange")
}

/// Swift wrapper for the mediaremote-adapter Perl script
class MediaRemoteAdapter {
    
    // MARK: - Singleton
    static let shared = MediaRemoteAdapter()
    
    // MARK: - Properties
    private var streamProcess: Process?
    private var streamPipe: Pipe?
    private var isStreaming = false
    
    // Serial queue handles ALL state mutations - no locks needed, no crashes
    private let stateQueue = DispatchQueue(label: "com.nowplaying.adapter.state")
    private var _currentInfo: NowPlayingInfo?
    private(set) var currentInfo: NowPlayingInfo? {
        get { stateQueue.sync { _currentInfo } }
        set { stateQueue.async { self._currentInfo = newValue } }
    }
    
    // Command suppression - blocks stale updates after skip commands
    // Protected by stateQueue
    private var _lastCommandTime: Date?
    private let commandSuppressionInterval: TimeInterval = 0.3
    
    // Debounce - batches rapid updates into one clean notification
    // debounceWorkItem is only ever scheduled/cancelled on main queue
    private var debounceWorkItem: DispatchWorkItem?
    private let debounceInterval: TimeInterval = 0.15
    
    // Accumulated changes during debounce window
    // Protected by stateQueue
    private var _pendingBundleIdChanged = false
    private var _pendingIsPlayingChanged = false
    
    // Paths to bundled resources
    private let perlScriptPath: String
    private let frameworkPath: String
    private let testClientPath: String?
    
    // MARK: - Initialization
    private init() {
        let bundle = Bundle(for: NowPlayingWidget.self)
        let bundlePath = bundle.bundlePath
        self.perlScriptPath = bundlePath + "/Contents/Resources/mediaremote-adapter.pl"
        self.frameworkPath  = bundlePath + "/Contents/Frameworks/MediaRemoteAdapter.framework"
        self.testClientPath = bundlePath + "/Contents/Resources/MediaRemoteAdapterTestClient"
    }
    
    // MARK: - Public API
    
    func startStreaming() {
        guard !isStreaming else { return }
        isStreaming = true
        streamProcess = Process()
        streamPipe = Pipe()
        
        guard let process = streamProcess, let pipe = streamPipe else { return }
        
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [perlScriptPath, frameworkPath, "stream", "--debounce=50"]
        process.standardOutput = pipe
        
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.count > 0 {
                self?.handleStreamData(data)
            }
        }
        
        do {
            try process.run()
            print("[MediaRemoteAdapter] Started streaming - PID: \(process.processIdentifier)")
        } catch {
            print("[MediaRemoteAdapter] Error starting stream: \(error)")
            // Reset all streaming state so startStreaming() can be retried
            streamProcess = nil
            streamPipe = nil
            isStreaming = false
        }
    }
    
    func stopStreaming() {
        guard isStreaming else { return }
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        streamProcess?.terminate()
        streamProcess = nil
        streamPipe?.fileHandleForReading.readabilityHandler = nil
        streamPipe = nil
        isStreaming = false
        // Clear cached state so the next getNowPlayingInfo call can't return stale data
        // from the previous player during the reconnect window
        stateQueue.async { self._currentInfo = nil }
        print("[MediaRemoteAdapter] Stopped streaming")
    }
    
    func getNowPlayingInfo(completion: @escaping (NowPlayingInfo?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { completion(nil); return }
            
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            process.arguments = [self.perlScriptPath, self.frameworkPath, "get"]
            process.standardOutput = pipe
            
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let info = self.parseNowPlayingData(data)
                // Store the result so subsequent diff updates have a valid base state
                if let info = info {
                    self.stateQueue.async { self._currentInfo = info }
                }
                DispatchQueue.main.async { completion(info) }
            } catch {
                print("[MediaRemoteAdapter] Error getting info: \(error)")
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }
    
    func sendCommand(_ command: MediaRemoteCommand) {
        // Record command time (on stateQueue) to suppress stale intermediate updates
        stateQueue.async { self._lastCommandTime = Date() }
        print("[MediaRemoteAdapter] Sending command: \(command)")
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            process.arguments = [self.perlScriptPath, self.frameworkPath, "send", "\(command.rawValue)"]
            
            do {
                try process.run()
                process.waitUntilExit()
                print("[MediaRemoteAdapter] Command sent: \(command)")
                
                // Force refresh after suppression window clears
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    self?.forceStateRefresh()
                }
            } catch {
                print("[MediaRemoteAdapter] Error sending command: \(error)")
            }
        }
    }
    
    private func forceStateRefresh() {
        print("[MediaRemoteAdapter] Forcing state refresh")
        getNowPlayingInfo { [weak self] info in
            guard let self = self else { return }
            self.currentInfo = info
            NotificationCenter.default.post(name: .mediaRemoteAdapterNowPlayingInfoDidChange, object: nil)
            NotificationCenter.default.post(name: .mediaRemoteAdapterIsPlayingDidChange, object: nil)
        }
    }
    
    // MARK: - Private Methods
    
    private func handleStreamData(_ data: Data) {
        guard let jsonString = String(data: data, encoding: .utf8) else { return }
        let lines = jsonString.components(separatedBy: .newlines)
        for line in lines {
            guard !line.isEmpty, let lineData = line.data(using: .utf8) else { continue }
            do {
                if let json = try JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                    handleStreamUpdate(json)
                }
            } catch { continue }
        }
    }
    
    private func handleStreamUpdate(_ json: [String: Any]) {
        guard let type = json["type"] as? String, type == "data" else { return }
        guard let payload = json["payload"] as? [String: Any] else { return }
        
        print("[MediaRemoteAdapter] Received update")
        
        // All state reads and writes happen on stateQueue to avoid data races
        stateQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Suppress updates during command window - blocks stale song flash on skip
            if let lastCmd = self._lastCommandTime {
                if Date().timeIntervalSince(lastCmd) < self.commandSuppressionInterval {
                    print("[MediaRemoteAdapter] Suppressing update - within command window")
                    return
                }
            }
            
            let isDiff = (json["diff"] as? Bool) ?? false
            let newInfo = self.parsePayload(payload, isDiff: isDiff)
            
            // Clear state if empty full update (app closed)
            if !isDiff && newInfo?.bundleIdentifier == nil && newInfo?.title == nil {
                // If we already have valid state (from any source — Music, Spotify,
                // browser, etc.), don't clear it on transient empty updates.
                // These are common during song transitions and don't mean playback stopped.
                if self._currentInfo?.bundleIdentifier != nil || self._currentInfo?.title != nil {
                    print("[MediaRemoteAdapter] Empty update but have existing state - ignoring to preserve")
                    return
                }
                
                print("[MediaRemoteAdapter] Empty update - clearing state")
                self._currentInfo = nil
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .mediaRemoteAdapterNowPlayingInfoDidChange, object: nil)
                    NotificationCenter.default.post(name: .mediaRemoteAdapterNowPlayingApplicationDidChange, object: nil)
                }
                return
            }
            
            // Track what changed for accurate notification posting
            let bundleIdChanged  = self._currentInfo?.bundleIdentifier != newInfo?.bundleIdentifier
            let isPlayingChanged = self._currentInfo?.isPlaying != newInfo?.isPlaying
            
            // Update state
            self._currentInfo = newInfo
            
            // Accumulate changes
            if bundleIdChanged  { self._pendingBundleIdChanged  = true }
            if isPlayingChanged { self._pendingIsPlayingChanged = true }
            
            // Schedule debounced flush on main queue
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.debounceWorkItem?.cancel()
                let workItem = DispatchWorkItem { [weak self] in
                    self?.flushNotifications()
                }
                self.debounceWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + self.debounceInterval, execute: workItem)
            }
        }
    }
    
    private func flushNotifications() {
        print("[MediaRemoteAdapter] Flushing notifications")
        
        // Atomically read and clear the accumulated flags
        var bundleIdChanged  = false
        var isPlayingChanged = false
        stateQueue.sync {
            bundleIdChanged  = _pendingBundleIdChanged
            isPlayingChanged = _pendingIsPlayingChanged
            _pendingBundleIdChanged  = false
            _pendingIsPlayingChanged = false
        }
        
        // Always post content changed - ensures UI updates in all edge cases
        NotificationCenter.default.post(name: .mediaRemoteAdapterNowPlayingInfoDidChange, object: nil)
        
        if bundleIdChanged {
            NotificationCenter.default.post(name: .mediaRemoteAdapterNowPlayingApplicationDidChange, object: nil)
        }
        if isPlayingChanged {
            NotificationCenter.default.post(name: .mediaRemoteAdapterIsPlayingDidChange, object: nil)
        }
    }
    
    private func parsePayload(_ payload: [String: Any], isDiff: Bool) -> NowPlayingInfo? {
        // Start from current state for diffs, fresh struct for full updates
        var info: NowPlayingInfo = isDiff ? (_currentInfo ?? NowPlayingInfo()) : NowPlayingInfo()
        
        if isDiff {
            for (key, value) in payload where value is NSNull {
                switch key {
                case "title":      info.title = nil
                case "artist":     info.artist = nil
                case "album":      info.album = nil
                case "bundleIdentifier": info.bundleIdentifier = nil
                case "parentApplicationBundleIdentifier": info.parentApplicationBundleIdentifier = nil
                case "artworkData": info.artworkData = nil; info.artworkMimeType = nil
                default: break
                }
            }
        }
        
        if let v = payload["bundleIdentifier"] as? String                  { info.bundleIdentifier = v }
        if let v = payload["parentApplicationBundleIdentifier"] as? String { info.parentApplicationBundleIdentifier = v }
        if let v = payload["playing"] as? Bool                             { info.isPlaying = v }
        else if let v = payload["playing"] as? Int                         { info.isPlaying = v == 1 }
        if let v = payload["title"]  as? String { info.title  = v }
        if let v = payload["artist"] as? String { info.artist = v }
        if let v = payload["album"]  as? String { info.album  = v }
        if let v = payload["artworkData"]     as? String { info.artworkData    = v }
        if let v = payload["artworkMimeType"] as? String { info.artworkMimeType = v }
        
        return info
    }
    
    private func parseNowPlayingData(_ data: Data) -> NowPlayingInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parsePayload(json, isDiff: false)
    }
}

// MARK: - Data Models

struct NowPlayingInfo {
    var bundleIdentifier: String?
    var parentApplicationBundleIdentifier: String?
    var isPlaying: Bool = false
    var title: String?
    var artist: String?
    var album: String?
    var artworkData: String?
    var artworkMimeType: String?
    
    // Cached decoded image - only recomputed when artworkData changes.
    // Stored as a separate var so callers can check for adapter-provided artwork
    // without triggering repeated base64 decoding.
    private var _cachedArtworkData: String?
    private var _cachedArtwork: NSImage?
    
    var artwork: NSImage? {
        mutating get {
            guard let artworkData = artworkData else {
                _cachedArtwork = nil
                _cachedArtworkData = nil
                return nil
            }
            // Only decode when the data has actually changed
            if artworkData == _cachedArtworkData, let cached = _cachedArtwork {
                return cached
            }
            guard let data = Data(base64Encoded: artworkData) else { return nil }
            let image = NSImage(data: data)
            _cachedArtworkData = artworkData
            _cachedArtwork = image
            return image
        }
    }
    
    /// True when the adapter has actually provided artwork data, regardless of
    /// whether it has been decoded yet. Use this instead of `artwork != nil` for
    /// deciding whether to fall back to the iTunes API.
    var hasAdapterArtwork: Bool { artworkData != nil }
}

enum MediaRemoteCommand: Int {
    case play = 0
    case pause = 1
    case togglePlayPause = 2
    case stop = 3
    case nextTrack = 4
    case previousTrack = 5
    case toggleShuffle = 6
    case toggleRepeat = 7
    case startForwardSeek = 8
    case endForwardSeek = 9
    case startBackwardSeek = 10
    case endBackwardSeek = 11
    case goBackFifteenSeconds = 12
    case skipFifteenSeconds = 13
}
