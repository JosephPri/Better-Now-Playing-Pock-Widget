//
//  NowPlayingPreferencePane.swift
//  Better Now Playing
//
//  Created by Pierluigi Galdi on 14/12/2019.
//  Modified by JosephPri
//

import Cocoa
import PockKit

extension NSNotification.Name {
    static let mrMediaRemoteNowPlayingApplicationDidChange = NSNotification.Name.mediaRemoteAdapterNowPlayingApplicationDidChange
    static let mrPlaybackQueueContentItemsChanged = NSNotification.Name.mediaRemoteAdapterNowPlayingInfoDidChange
}

class NowPlayingPreferencePane: NSViewController, PKWidgetPreference {
    
    static var nibName: NSNib.Name = "NowPlayingPreferencePane"
    
    @IBOutlet private weak var imagesStackView:         NSStackView!
    @IBOutlet private weak var defaultRadioButton:      NSButton!
    @IBOutlet private weak var onlyInfoRadioButton:     NSButton!
    @IBOutlet private weak var playPauseRadioButton:    NSButton!
    @IBOutlet private weak var hideWidgetIfNoMedia:     NSButton!
    @IBOutlet private weak var animateIconWhilePlaying: NSButton!
    @IBOutlet private weak var invertSwipeGesture:      NSButton!
    @IBOutlet private weak var artworkSizeSlider:        NSSlider!
    @IBOutlet private weak var artworkGlowCheckbox:      NSButton!
    @IBOutlet private weak var hideAfterInactivityCheckbox: NSButton!
    @IBOutlet private weak var inactivityTimeoutPopup:  NSPopUpButton!
    // Fixed width controls
    @IBOutlet private weak var fixedWidthCheckbox:      NSButton!
    @IBOutlet private weak var fixedWidthPixelField:   NSTextField!
    // Native Now Playing control
    @IBOutlet private weak var disableNativeNowPlayingCheckbox: NSButton!
    
    func reset() {
        Preferences.reset()
        NotificationCenter.default.post(name: .mrPlaybackQueueContentItemsChanged, object: nil)
        NotificationCenter.default.post(name: Notification.Name(didChangeNowPlayingWidgetStyle), object: nil)
        NotificationCenter.default.post(name: Notification.Name(didChangeFixedWidthNotification), object: nil)
        NotificationCenter.default.post(name: Notification.Name(didChangeDisableNativeNowPlayingNotification), object: nil)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        switch NowPlayingWidgetStyle(rawValue: Preferences[.nowPlayingWidgetStyle]) ?? .default {
        case .default:   defaultRadioButton.state  = .on
        case .onlyInfo:  onlyInfoRadioButton.state  = .on
        case .playPause: playPauseRadioButton.state = .on
        }
        updateButtonsState()
        setupImageViewClickGesture()
        let savedSize: Int = Preferences[.artworkSize]
        artworkSizeSlider?.integerValue = savedSize
    }
    
    private func updateButtonsState() {
        hideWidgetIfNoMedia.state     = Preferences[.hideNowPlayingIfNoMedia] ? .on : .off
        animateIconWhilePlaying.state = Preferences[.animateIconWhilePlaying] ? .on : .off
        invertSwipeGesture.state      = Preferences[.invertSwipeGesture]      ? .on : .off
        artworkGlowCheckbox?.state    = Preferences[.artworkGlow]             ? .on : .off
        let inactivityEnabled: Bool   = Preferences[.hideAfterInactivity]
        hideAfterInactivityCheckbox?.state = inactivityEnabled ? .on : .off
        inactivityTimeoutPopup?.isEnabled  = inactivityEnabled
        // Sync popup selection to stored timeout value
        let storedTimeout: Int = Preferences[.inactivityTimeout]
        if let popup = inactivityTimeoutPopup {
            let timeouts = [10, 30, 60, 120, 300, 600]
            let idx = timeouts.firstIndex(of: storedTimeout) ?? 3   // default to 120s
            if idx < popup.numberOfItems { popup.selectItem(at: idx) }
        }
        // Fixed width
        let fixedEnabled: Bool = Preferences[.fixedWidthEnabled]
        fixedWidthCheckbox?.state        = fixedEnabled ? .on : .off
        fixedWidthPixelField?.isEnabled  = fixedEnabled
        let storedPixels: Int = Preferences[.fixedWidthPixels]
        fixedWidthPixelField?.stringValue = "\(storedPixels)"
        
        // Native Now Playing
        let disableNative: Bool = Preferences[.disableNativeNowPlaying]
        disableNativeNowPlayingCheckbox?.state = disableNative ? .on : .off
    }
    
    private func setupImageViewClickGesture() {
        imagesStackView.arrangedSubviews.forEach({
            $0.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(didSelectRadioButton(_:))))
        })
    }
    
    @IBAction private func didSelectRadioButton(_ control: AnyObject) {
        let view = (control as? NSGestureRecognizer)?.view ?? control
        switch view.tag {
        case 0:
            Preferences[.nowPlayingWidgetStyle] = NowPlayingWidgetStyle.default.rawValue
            defaultRadioButton.state   = .on
            onlyInfoRadioButton.state  = .off
            playPauseRadioButton.state = .off
        case 1:
            Preferences[.nowPlayingWidgetStyle] = NowPlayingWidgetStyle.onlyInfo.rawValue
            defaultRadioButton.state   = .off
            onlyInfoRadioButton.state  = .on
            playPauseRadioButton.state = .off
        case 2:
            Preferences[.nowPlayingWidgetStyle] = NowPlayingWidgetStyle.playPause.rawValue
            defaultRadioButton.state   = .off
            onlyInfoRadioButton.state  = .off
            playPauseRadioButton.state = .on
        default:
            return
        }
        NotificationCenter.default.post(name: .mrPlaybackQueueContentItemsChanged, object: nil)
        NotificationCenter.default.post(name: Notification.Name(didChangeNowPlayingWidgetStyle), object: nil)
    }
    
    @IBAction private func didChangeCheckboxState(_ button: NSButton?) {
        guard let button = button else { return }
        switch button.tag {
        case 0:
            Preferences[.hideNowPlayingIfNoMedia] = button.state == .on
        case 1:
            Preferences[.animateIconWhilePlaying] = button.state == .on
            updateButtonsState()
        case 3:
            Preferences[.invertSwipeGesture] = button.state == .on
        case 4:
            Preferences[.artworkGlow] = button.state == .on
        case 5:
            // Disable native Now Playing Touch Bar
            let newValue = button.state == .on
            Preferences[.disableNativeNowPlaying] = newValue
            // Immediately apply the change
            NotificationCenter.default.post(name: Notification.Name(didChangeDisableNativeNowPlayingNotification), object: nil)
        default:
            return
        }
        NotificationCenter.default.post(name: .mrPlaybackQueueContentItemsChanged, object: nil)
        NotificationCenter.default.post(name: Notification.Name(didChangeNowPlayingWidgetStyle), object: nil)
    }
    
    @IBAction private func didToggleHideAfterInactivity(_ sender: NSButton) {
        Preferences[.hideAfterInactivity] = sender.state == .on
        inactivityTimeoutPopup?.isEnabled = sender.state == .on
        NotificationCenter.default.post(name: Notification.Name(didChangeInactivityTimeoutNotification), object: nil)
    }
    
    @IBAction private func didChangeInactivityTimeout(_ sender: NSPopUpButton) {
        let timeouts = [10, 30, 60, 120, 300]
        let idx = sender.indexOfSelectedItem
        let chosen = (idx >= 0 && idx < timeouts.count) ? timeouts[idx] : 30
        Preferences[.inactivityTimeout] = chosen
        NotificationCenter.default.post(name: Notification.Name(didChangeInactivityTimeoutNotification), object: nil)
    }
    
    @IBAction private func didChangeArtworkSize(_ sender: NSSlider) {
        Preferences[.artworkSize] = sender.integerValue
        NotificationCenter.default.post(name: Notification.Name(didChangeArtworkSizeNotification), object: nil)
    }
    
    @IBAction private func didToggleArtworkGlow(_ sender: NSButton) {
        Preferences[.artworkGlow] = sender.state == .on
        NotificationCenter.default.post(name: Notification.Name(didChangeArtworkGlowNotification), object: nil)
    }
    
    @IBAction private func didToggleFixedWidth(_ sender: NSButton) {
        Preferences[.fixedWidthEnabled] = sender.state == .on
        fixedWidthPixelField?.isEnabled = sender.state == .on
        NotificationCenter.default.post(name: Notification.Name(didChangeFixedWidthNotification), object: nil)
    }
    
    @IBAction private func didChangeFixedWidthPixels(_ sender: NSTextField) {
        let value = max(40, sender.integerValue)  // clamp matches NowPlayingItemView
        Preferences[.fixedWidthPixels] = value
        // Keep field text normalised (e.g. if user typed 0 or left it blank)
        sender.stringValue = "\(value)"
        NotificationCenter.default.post(name: Notification.Name(didChangeFixedWidthNotification), object: nil)
    }
    
}
