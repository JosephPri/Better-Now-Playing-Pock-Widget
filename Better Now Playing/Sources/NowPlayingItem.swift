//
//  NowPlayingItem.swift
//  Better Now Playing
//
//  Created by Pierluigi Galdi on 17/02/2019.
//  Copyright © 2019 Pierluigi Galdi. All rights reserved.
//  Modified by JosephPri

import Foundation
import AppKit

class NowPlayingItem {
    /// Info
    struct Client {
        let bundleIdentifier: String?
        let parentApplicationBundleIdentifier: String?
        let displayName: String?
        let icon: NSImage?
    }
    /// Data
    public var client: Client?
    public var title: String?
    public var album: String?
    public var artist: String?
    public var artwork: NSImage?
    public var isPlaying: Bool = false
    /// Compound
    public var searchTerm: String? {
        guard let title = title else { return nil }
        // Include album in the search term when available so the iTunes API
        // returns the correct release rather than the most popular result.
        var components: [String] = [title]
        if let artist = artist { components.append(artist) }
        if let album  = album  { components.append(album)  }
        return components
            .joined(separator: " ")
            .replacingOccurrences(of: " ", with: "+")
            .addingPercentEncoding(withAllowedCharacters: .urlHostAllowed)
    }
}
