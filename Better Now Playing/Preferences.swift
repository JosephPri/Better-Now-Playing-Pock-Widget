//
//  Preferences.swift
//  BetterNowPlaying
//
//  Adapted from Pierluigi Galdi on 08/01/2020.
//  Copyright © 2020 Pierluigi Galdi. All rights reserved.
//
import Foundation

internal let didChangeNowPlayingWidgetStyle = "didChangeNowPlayingWidgetStyle"
internal let didChangeArtworkSizeNotification = "didChangeArtworkSize"
internal let didChangeArtworkGlowNotification = "didChangeArtworkGlow"
internal let didChangeInactivityTimeoutNotification = "didChangeInactivityTimeout"
internal let didChangeFixedWidthNotification = "didChangeFixedWidth"
internal let didChangeDisableNativeNowPlayingNotification = "didChangeDisableNativeNowPlaying"

internal struct Preferences {
    internal enum Keys: String {
        case nowPlayingWidgetStyle
        case hideNowPlayingIfNoMedia
        case animateIconWhilePlaying
        case invertSwipeGesture
        case defaultPlayer
        case artworkSize
        case artworkGlow
        /// Whether to hide the widget after a period of inactivity (no playback).
        case hideAfterInactivity
        /// Seconds of inactivity before the widget hides. 0 = disabled.
        case inactivityTimeout
        /// Whether the widget should use a fixed width instead of resizing with text.
        case fixedWidthEnabled
        /// The fixed width size
        case fixedWidthPixels
        /// Whether to suppress the native macOS Now Playing Touch Bar (show only our widget)
        case disableNativeNowPlaying
    }
    static subscript<T>(_ key: Keys) -> T {
        get {
            guard let value = UserDefaults.standard.value(forKey: key.rawValue) as? T else {
                switch key {
                case .nowPlayingWidgetStyle:
                    return "onlyInfo" as! T
                case .hideNowPlayingIfNoMedia:
                    return true as! T
                case .animateIconWhilePlaying:
                    return false as! T
                case .invertSwipeGesture:
                    return false as! T
                case .defaultPlayer:
                    if #available(OSX 10.15, *) {
                        return "com.apple.Music" as! T
                    } else {
                        return "com.apple.iTunes" as! T
                    }
                case .artworkGlow:
                    return true as! T
                case .artworkSize:
                    return 0 as! T
                case .hideAfterInactivity:
                    return true as! T
                case .inactivityTimeout:
                    return 120 as! T
                case .fixedWidthEnabled:
                    return false as! T
                case .fixedWidthPixels:
                    return 100 as! T
                case .disableNativeNowPlaying:
                    return true as! T
                }
            }
            return value
        }
        set {
            UserDefaults.standard.setValue(newValue, forKey: key.rawValue)
        }
    }

    static func reset() {
        Preferences[.nowPlayingWidgetStyle] = "onlyInfo"
        Preferences[.hideNowPlayingIfNoMedia] = true
        Preferences[.animateIconWhilePlaying] = false
        Preferences[.invertSwipeGesture] = false
        Preferences[.artworkGlow] = true
        Preferences[.artworkSize] = 0
        Preferences[.hideAfterInactivity] = true
        Preferences[.inactivityTimeout] = 120
        Preferences[.fixedWidthEnabled] = false
        Preferences[.fixedWidthPixels] = 100
        Preferences[.disableNativeNowPlaying] = true
        if #available(OSX 10.15, *) {
            Preferences[.defaultPlayer] = "com.apple.Music"
        } else {
            Preferences[.defaultPlayer] = "com.apple.iTunes"
        }
    }
}
