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
    @IBOutlet private weak var showMediaArtwork:        NSButton!
    @IBOutlet private weak var invertSwipeGesture:      NSButton!
    @IBOutlet private weak var artworkSizeSlider:        NSSlider!
    
    func reset() {
        Preferences.reset()
        NotificationCenter.default.post(name: .mrPlaybackQueueContentItemsChanged, object: nil)
        NotificationCenter.default.post(name: Notification.Name(didChangeNowPlayingWidgetStyle), object: nil)
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
        showMediaArtwork.state        = Preferences[.showMediaArtwork]        ? .on : .off
        invertSwipeGesture.state      = Preferences[.invertSwipeGesture]      ? .on : .off
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
        case 2:
            Preferences[.showMediaArtwork] = button.state == .on
            updateButtonsState()
        case 3:
            Preferences[.invertSwipeGesture] = button.state == .on
        default:
            return
        }
        NotificationCenter.default.post(name: .mrPlaybackQueueContentItemsChanged, object: nil)
        NotificationCenter.default.post(name: Notification.Name(didChangeNowPlayingWidgetStyle), object: nil)
    }
    
    @IBAction private func didChangeArtworkSize(_ sender: NSSlider) {
        Preferences[.artworkSize] = sender.integerValue
        NotificationCenter.default.post(name: Notification.Name(didChangeArtworkSizeNotification), object: nil)
    }
    
}
