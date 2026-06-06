//
//  NowPlayingView.swift
//  Better Now Playing
//
//  Created by Pierluigi Galdi on 14/12/2019.
//  Copyright © 2019 Pierluigi Galdi. All rights reserved.
//

import Foundation
import AppKit
import PockKit
import TinyConstraints

fileprivate let playIconName  = NSImage.touchBarPlayTemplateName
fileprivate let pauseIconName = NSImage.touchBarPauseTemplateName
fileprivate let previousIcon = NSImage(named: NSImage.touchBarRewindTemplateName)!
fileprivate let nextIcon     = NSImage(named: NSImage.touchBarFastForwardTemplateName)!

fileprivate extension NSButton {
    static func build(image: NSImage, target: Any?, action: Selector?) -> NSButton {
        let button = NSButton(image: image, target: target, action: action)
        button.imageScaling = .scaleProportionallyDown
        button.bezelStyle = .circular
        button.bezelColor = .red
        button.isBordered = false
        button.width(18)
        return button
    }
}

class NowPlayingView: PKView {
    
    /// UI
    private let stackView: NSStackView = NSStackView(frame: .zero)
    
    /// Contents UI
    private var itemView:        NowPlayingItemView?
    private var playPauseButton: NSButton?
    private var previousButton:  NSButton {
        return NSButton.build(image: previousIcon, target: self, action: #selector(skipToPreviousItem))
    }
    private var nextButton: NSButton {
        return NSButton.build(image: nextIcon, target: self, action: #selector(skipToNextItem))
    }
    
    /// Core
    private var shouldHideWidget: Bool {
        // Inactivity timeout takes priority — always hide when it fires
        if helper?.shouldHideDueToInactivity == true { return true }
        if Preferences[.hideNowPlayingIfNoMedia] {
            guard let item = item else {
                return true
            }
            return item.client == nil || (item.title == nil && item.album == nil && item.isPlaying == false)
        }
        return false
    }
    
    /// Styles
    public var style: NowPlayingWidgetStyle {
        return NowPlayingWidgetStyle(rawValue: Preferences[.nowPlayingWidgetStyle]) ?? .default
    }
    
    /// Data
    private var helper: NowPlayingHelper?
    private var updateBanner: UpdateBannerView?
    public var item: NowPlayingItem? {
        return helper?.currentNowPlayingItem
    }
    
    deinit {
        NSLog("[NOW_PLAYING]: NowPlayingView - deinit")
        NotificationCenter.default.removeObserver(self, name: Notification.Name(didChangeNowPlayingWidgetStyle), object: nil)
        NotificationCenter.default.removeObserver(self, name: Notification.Name(didChangeArtworkSizeNotification), object: nil)
        NotificationCenter.default.removeObserver(self, name: Notification.Name(didChangeArtworkGlowNotification), object: nil)
        NotificationCenter.default.removeObserver(self, name: .nowPlayingInactivityDidChange, object: nil)
        NotificationCenter.default.removeObserver(self, name: Notification.Name(didChangeInactivityTimeoutNotification), object: nil)
        helper = nil
        itemView?.removeFromSuperview()
        itemView = nil
        subviews.forEach({ $0.removeFromSuperview() })
    }
    
    /// Notifications
    private func registerForNotifications() {
        NSLog("[NOW_PLAYING]: NowPlayingView - register for notifications")
        NotificationCenter.default.addObserver(self, selector: #selector(configureUIElements), name: Notification.Name(didChangeNowPlayingWidgetStyle), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleArtworkSizeChange), name: Notification.Name(didChangeArtworkSizeNotification), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleArtworkGlowChange), name: Notification.Name(didChangeArtworkGlowNotification), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleInactivityChange), name: .nowPlayingInactivityDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleInactivityPreferenceChange), name: Notification.Name(didChangeInactivityTimeoutNotification), object: nil)
    }
    
    convenience init(frame: NSRect, shouldLoadHelper: Bool) {
        self.init(frame: frame)
        configureStackView()
        configureUIElements()
        if shouldLoadHelper {
            helper = NowPlayingHelper(forView: self)
            registerForNotifications()
        }
        UpdateChecker.checkForUpdate { [weak self] available, version in
            guard available, let self = self else { return }
            let banner = UpdateBannerView(frame: .zero)
            self.updateBanner = banner
            self.stackView.addArrangedSubview(banner)
        }
    }
    
    /// Configuration
    private func configureStackView() {
        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.distribution = .fillProportionally
        addSubview(stackView)
        stackView.edgesToSuperview()
    }
    
    @objc private func handleArtworkSizeChange() {
        // Just re-layout the existing itemView without rebuilding it or clearing state
        itemView?.updateConstraint()
        itemView?.needsLayout = true
        itemView?.layout()
    }
    
    @objc private func handleArtworkGlowChange() {
        itemView?.updateUIState(for: item)
    }
    
    /// Called when the inactivity timer fires or resets — show or hide the widget accordingly.
    @objc private func handleInactivityChange() {
        updateContentViews()
    }
    
    /// Called when the user changes the inactivity preference in the pref pane —
    /// restart the timer with the new settings (helper handles the logic).
    @objc private func handleInactivityPreferenceChange() {
        helper?.resetInactivityTimer()
        updateContentViews()
    }
    
    @objc private func configureUIElements() {
        removeArrangedSubviews()
        defer {
            addArrangedSubviews()
        }
        switch style {
        case .default, .onlyInfo:
            guard itemView == nil else {
                break
            }
            itemView = NowPlayingItemView(leftToRight: true)
            setupGestureHandlers()
        case .playPause:
            guard playPauseButton == nil else {
                break
            }
            let icon = NSImage(named: item?.isPlaying ?? false ? pauseIconName : playIconName)!
            playPauseButton = NSButton.build(image: icon, target: self, action: #selector(togglePlayPause))
        }
    }
    
    private func removeArrangedSubviews() {
        for view in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        playPauseButton = nil
        itemView        = nil
    }
    
    private func addArrangedSubviews() {
        guard !shouldHideWidget else {
            return
        }
        let views: [NSView]
        switch style {
        case .default:
            views = [previousButton, itemView!, nextButton]
            stackView.spacing = 8
        case .onlyInfo:
            views = [itemView!]
            stackView.spacing = 0
        case .playPause:
            views = [previousButton, playPauseButton!, nextButton]
            stackView.spacing = 22
        }
        for view in views {
            stackView.addArrangedSubview(view)
        }
    }
    
    private func setupGestureHandlers() {
        switch self.style {
        case .playPause:
            itemView?.didTap        = nil
            itemView?.didSwipeLeft  = nil
            itemView?.didSwipeRight = nil
        case .default, .onlyInfo:
            itemView?.didTap        = { [unowned self] in self.togglePlayPause()    }
            itemView?.didSwipeLeft  = { [unowned self] in self.skipToPreviousItem() }
            itemView?.didSwipeRight = { [unowned self] in self.skipToNextItem()     }
        }
    }
    
    /// Update
    @objc internal func updateContentViews() {
        print("[NowPlayingView] updateContentViews called - shouldHideWidget: \(shouldHideWidget)")
        
        if shouldHideWidget {
            print("[NowPlayingView] updateContentViews - hiding widget")
            // Hide subviews rather than destroying them so we don't lose state
            for view in stackView.arrangedSubviews {
                view.isHidden = true
            }
            return
        }
        
        // Ensure views exist
        if stackView.arrangedSubviews.isEmpty {
            print("[NowPlayingView] updateContentViews - stackView empty, configuring UI")
            configureUIElements()
        } else {
            // Unhide any previously hidden subviews
            for view in stackView.arrangedSubviews {
                view.isHidden = false
            }
        }
        
        print("[NowPlayingView] updateContentViews - style: \(style)")
        
        switch style {
        case .default, .onlyInfo:
            print("[NowPlayingView] updateContentViews - updating itemView with item: \(item?.title ?? "nil")")
            itemView?.updateUIState(for: item)
        case .playPause:
            print("[NowPlayingView] updateContentViews - updating playPauseButton")
            playPauseButton?.image = NSImage(named: item?.isPlaying ?? false ? pauseIconName : playIconName)!
        }
    }
    internal func reloadNowPlayingData() {
        itemView?.updateUIState(for: item)
    }
    
    /// Handlers
    @objc private func togglePlayPause() {
        if NSWorkspace.shared.runningApplications.compactMap({ $0.bundleIdentifier }).contains(item?.client?.bundleIdentifier ?? ""), item?.title != nil {
            helper?.togglePlayingState()
        } else {
            didLongPressHandler()
        }
    }
    
    @objc private func skipToNextItem() {
        helper?.skipToNextTrack()
    }
    
    @objc private func skipToPreviousItem() {
        helper?.skipToPreviousTrack()
    }
    
    override func didLongPressHandler() {
        guard let id = item?.client?.bundleIdentifier else {
            return
        }
        NSWorkspace.shared.launchApplication(
            withBundleIdentifier: id,
            options: [],
            additionalEventParamDescriptor: nil,
            launchIdentifier: nil
        )
    }
    
}
