//
//  NowPlayingItemView.swift
//  Better Now Playing
//
//  Created by Pierluigi Galdi on 17/02/2019.
//  Copyright © 2019 Pierluigi Galdi. All rights reserved.
//  Modified by JosephPri
//

import Foundation
import AppKit
import PockKit

extension String {
    func truncate(length: Int, trailing: String = "…") -> String {
        return self.count > length ? String(self.prefix(length)) + trailing : self
    }
}

class NowPlayingItemView: PKDetailView {
    
    /// Overrideable
    public var didTap: (() -> Void)?
    public var didSwipeLeft: (() -> Void)?
    public var didSwipeRight: (() -> Void)?
    public var didLongPress: (() -> Void)?
    
    /// Data
    private var nowPLayingItem: NowPlayingItem?
    
    /// Stored image-size constraints, created once in didLoad
    private var imageWidthConstraint: NSLayoutConstraint?
    private var imageHeightConstraint: NSLayoutConstraint?
    
    override func didLoad() {
        canScrollTitle = true
        canScrollSubtitle = true
        titleView.numberOfLoop = 3
        subtitleView.numberOfLoop = 1
        
        // Add rounded corners to imageView
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 5
        imageView.layer?.masksToBounds = true
        
        // Create image-size constraints once; activate/deactivate as needed
        if !shouldHideIcon {
            let w = imageView.widthAnchor.constraint(equalToConstant: 60)
            let h = imageView.heightAnchor.constraint(equalToConstant: 60)
            imageWidthConstraint  = w
            imageHeightConstraint = h
            NSLayoutConstraint.activate([w, h])
        }
        
        updateUIState(for: nil)
        super.didLoad()
    }
    
    // layout() override removed - constraints are set once in didLoad()
    
    internal func updateUIState(for item: NowPlayingItem?) {
        self.nowPLayingItem = item
        defer {
            updateForNowPlayingState()
        }
        guard let item = self.nowPLayingItem, let client = item.client else {
            let appBundleIdentifier: String = Preferences[.defaultPlayer]
            imageView.image = NSWorkspace.shared.applicationIcon(for: appBundleIdentifier, fallbackFileType: "mp3")
            maxWidth = 160
            set(title: NSWorkspace.shared.applicationName(for: appBundleIdentifier))
            subtitleView.isHidden = true
            return
        }
        // MARK: Artwork
        if let artwork = item.artwork {
            imageView.image = artwork
        } else {
            imageView.image = client.icon
        }
        // TODO: Localize hardcoded strings
        // MARK: Title
        var title = item.title ?? (item.artist == nil ? client.displayName : "Missing title") ?? "Missing title"
        if title.isEmpty {
            title = "Missing title"
        }
        set(title: title)
        
        // MARK: Subtitle
        if let subtitle = item.artist ?? (item.title != nil ? client.displayName : nil), subtitle.isEmpty == false {
            subtitleView.isHidden = false
            set(subtitle: subtitle)
        } else {
            subtitleView.isHidden = true
        }
    }
    
    private func updateForNowPlayingState() {
        if Preferences[.animateIconWhilePlaying], self.nowPLayingItem?.isPlaying ?? false {
            self.startBounceAnimation()
        }else {
            self.stopBounceAnimation()
        }
    }
    
    override open func didTapHandler() {
        self.didTap?()
    }
    
    override open func didSwipeLeftHandler() {
        if Preferences[.invertSwipeGesture] {
            self.didSwipeRight?()
        }else {
            self.didSwipeLeft?()
        }
    }
    
    override open func didSwipeRightHandler() {
        if Preferences[.invertSwipeGesture] {
            self.didSwipeLeft?()
        }else {
            self.didSwipeRight?()
        }
    }
    
    override func didLongPressHandler() {
        self.didLongPress?()
    }
    
    override func removeFromSuperview() {
        super.removeFromSuperview()
        self.stopBounceAnimation()
    }
    
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        self.updateUIState(for: nowPLayingItem)
    }
    
}
