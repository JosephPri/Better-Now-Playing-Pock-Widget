//
//  Preferences.swift
//  BetterNowPlaying
//
//  Adapted from Pierluigi Galdi on 08/01/2020.
//  Copyright © 2020 Pierluigi Galdi. All rights reserved.
//
import Foundation

internal let didChangeNowPlayingWidgetStyle = "didChangeNowPlayingWidgetStyle"

internal struct Preferences {
    internal enum Keys: String {
        case nowPlayingWidgetStyle
        case hideNowPlayingIfNoMedia
        case animateIconWhilePlaying
        case showMediaArtwork
        case invertSwipeGesture
        case defaultPlayer
    }
    static subscript<T>(_ key: Keys) -> T {
        get {
            guard let value = UserDefaults.standard.value(forKey: key.rawValue) as? T else {
                switch key {
                case .nowPlayingWidgetStyle:
                    return "onlyInfo" as! T
                case .hideNowPlayingIfNoMedia:
                    return false as! T
                case .animateIconWhilePlaying:
                    return false as! T
                case .showMediaArtwork:
                    return true as! T
                case .invertSwipeGesture:
                    return false as! T
                case .defaultPlayer:
                    if #available(OSX 10.15, *) {
                        return "com.apple.Music" as! T
                    } else {
                        return "com.apple.iTunes" as! T
                    }
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
        Preferences[.hideNowPlayingIfNoMedia] = false
        Preferences[.animateIconWhilePlaying] = false
        Preferences[.showMediaArtwork] = true
        Preferences[.invertSwipeGesture] = false
        if #available(OSX 10.15, *) {
            Preferences[.defaultPlayer] = "com.apple.Music"
        } else {
            Preferences[.defaultPlayer] = "com.apple.iTunes"
        }
    }
}
