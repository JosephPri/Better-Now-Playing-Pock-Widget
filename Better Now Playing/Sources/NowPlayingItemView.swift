//
//  NowPlayingItemView.swift
//  Pock
//
//  Created by Pierluigi Galdi on 17/02/2019.
//  Copyright © 2019 Pierluigi Galdi. All rights reserved.
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
    private var containerConstraints: [NSLayoutConstraint] = []
    
    /// Returns the inset in points based on the artworkSize preference:
    /// 0 = Extra Large (0pt = 60px), 1 = Large (1pt = 56px), 2 = Medium (2pt = 52px), 3 = Small (3pt = 48px)
    private var artworkInset: CGFloat {
        let size: Int = Preferences[.artworkSize]
        return CGFloat(size)
    }
    
    /// The extra width the image takes beyond PKDetailView's assumed 24pt
    private var artworkWidthBonus: CGFloat {
        let imageSize = 30 - (artworkInset * 2)
        return max(0, imageSize - 24)
    }

    override func didLoad() {
        canScrollTitle = true
        canScrollSubtitle = true
        titleView.numberOfLoop = 3
        subtitleView.numberOfLoop = 1
        
        imageView.wantsLayer = true
        imageView.layer?.masksToBounds = true
        
        // Keep title and artist tight together regardless of image size
        labelsContainer.distribution = .fillEqually
        labelsContainer.spacing = 0
        labelsContainer.alignment = .leading
        
        updateUIState(for: nil)
        super.didLoad()
    }
    
    override func updateConstraint() {
        super.updateConstraint()
        guard let container = contentContainer, let superview = container.superview else { return }
        // Remove PKDetailView's asymmetric top(4)+bottom(2) insets
        superview.constraints.forEach {
            guard ($0.firstItem as? NSView == container || $0.secondItem as? NSView == container) else { return }
            if $0.firstAttribute == .top || $0.firstAttribute == .bottom ||
               $0.secondAttribute == .top || $0.secondAttribute == .bottom {
                $0.isActive = false
            }
        }
        let inset = artworkInset
        container.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.deactivate(containerConstraints)
        containerConstraints = [
            container.topAnchor.constraint(equalTo: superview.topAnchor, constant: inset),
            container.bottomAnchor.constraint(equalTo: superview.bottomAnchor, constant: -inset),
            container.leadingAnchor.constraint(equalTo: superview.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: superview.trailingAnchor)
        ]
        NSLayoutConstraint.activate(containerConstraints)
        // Make image square at full available height
        if !shouldHideIcon {
            imageView.constraints.filter { $0.firstAttribute == .width }.forEach { $0.isActive = false }
            imageView.widthAnchor.constraint(equalTo: imageView.heightAnchor).isActive = true
        }
        // Correct width constraint — PKDetailView assumes 24pt image, we use actual size
        let actualImagePt = 30 - (inset * 2)
        let correctedWidth = contentWidth - 24 + actualImagePt + contentContainer.spacing
        let cappedWidth = maxWidth > 0 ? min(correctedWidth, maxWidth) : correctedWidth
        if let widthConstraint = container.constraints.first(where: { $0.identifier == "contentContainer.width" }) {
            widthConstraint.constant = cappedWidth
        }
    }
    
    override func layout() {
        super.layout()
        if !shouldHideIcon {
            imageView.layer?.cornerRadius = imageView.bounds.height / 2 * 0.35
            // Always keep anchor point at center so bounce animation scales from center
            if let layer = imageView.layer, layer.anchorPoint != CGPoint(x: 0.5, y: 0.5) {
                let frame = layer.frame
                layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                layer.frame = frame
            }
        }
    }
    
    // PKDetailView.startBounceAnimation() is in a non-open extension so can't be overridden.
    // We add our own smoother animation directly and call this instead.
    private func startSmoothBounceAnimation() {
        stopBounceAnimation()
        guard let layer = imageView?.layer else { return }
        let bounce = CABasicAnimation(keyPath: "transform.scale")
        bounce.fromValue = 0.88
        bounce.toValue = 1.0
        bounce.duration = 1.0
        bounce.autoreverses = true
        bounce.repeatCount = .infinity
        bounce.timingFunction = CAMediaTimingFunction(controlPoints: 0.45, 0.0, 0.55, 1.0)
        layer.add(bounce, forKey: "kBounceAnimationKey")
    }
    
    internal func updateUIState(for item: NowPlayingItem?) {
        self.nowPLayingItem = item
        defer {
            updateForNowPlayingState()
        }
        guard let item = self.nowPLayingItem, let client = item.client else {
            let appBundleIdentifier: String = Preferences[.defaultPlayer]
            imageView.image = NSWorkspace.shared.applicationIcon(for: appBundleIdentifier, fallbackFileType: "mp3")
            maxWidth = 160 + artworkWidthBonus
            set(title: NSWorkspace.shared.applicationName(for: appBundleIdentifier))
            subtitleView.isHidden = true
            return
        }
        if let artwork = item.artwork {
            imageView.image = artwork
        } else {
            imageView.image = client.icon
        }
        // Set maxWidth BEFORE set(title:) so updateConstraint sees the cap in time
        maxWidth = 160 + artworkWidthBonus
        
        var title = item.title ?? (item.artist == nil ? client.displayName : "Missing title") ?? "Missing title"
        if title.isEmpty {
            title = "Missing title"
        }
        set(title: title)
        
        if let subtitle = item.artist ?? (item.title != nil ? client.displayName : nil), subtitle.isEmpty == false {
            subtitleView.isHidden = false
            set(subtitle: subtitle)
        } else {
            subtitleView.isHidden = true
        }
    }
    
    private func updateForNowPlayingState() {
        if Preferences[.animateIconWhilePlaying], self.nowPLayingItem?.isPlaying ?? false {
            self.startSmoothBounceAnimation()
        } else {
            self.stopBounceAnimation()
        }
    }
    
    override open func didTapHandler() {
        self.didTap?()
    }
    
    override open func didSwipeLeftHandler() {
        if Preferences[.invertSwipeGesture] {
            self.didSwipeRight?()
        } else {
            self.didSwipeLeft?()
        }
    }
    
    override open func didSwipeRightHandler() {
        if Preferences[.invertSwipeGesture] {
            self.didSwipeLeft?()
        } else {
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
