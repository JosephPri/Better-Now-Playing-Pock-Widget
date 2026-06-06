//
//  NowPlayingItemView.swift
//  Better Now Playing
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

    /// The effective maxWidth to apply, accounting for fixed-width mode.
    /// In dynamic mode this is 160 + artworkWidthBonus (unchanged behaviour).
    /// In fixed mode it is the user-entered pixel value + artworkWidthBonus so the
    /// image size correction in updateConstraint() still works correctly.
    private var effectiveMaxWidth: CGFloat {
        if Preferences[.fixedWidthEnabled] {
            let pixels: Int = Preferences[.fixedWidthPixels]
            let base = CGFloat(max(40, pixels))  // clamp to a sensible minimum
            return base + artworkWidthBonus
        }
        return 160 + artworkWidthBonus
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
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFixedWidthChange),
            name: Notification.Name(didChangeFixedWidthNotification),
            object: nil
        )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self, name: Notification.Name(didChangeFixedWidthNotification), object: nil)
    }
    
    @objc private func handleFixedWidthChange() {
        // Re-apply the current item with the new width setting
        updateUIState(for: nowPLayingItem)
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

        // In fixed-width mode, always use exactly effectiveMaxWidth regardless of
        // how wide the text content measures — this is what locks the widget size.
        let cappedWidth: CGFloat
        if Preferences[.fixedWidthEnabled] {
            cappedWidth = effectiveMaxWidth
        } else {
            cappedWidth = maxWidth > 0 ? min(correctedWidth, maxWidth) : correctedWidth
        }

        if let widthConstraint = container.constraints.first(where: { $0.identifier == "contentContainer.width" }) {
            widthConstraint.constant = cappedWidth
        }
    }
    
    override func layout() {
        super.layout()
        if !shouldHideIcon {
            let radius = imageView.bounds.height / 2 * 0.35
            imageView.layer?.cornerRadius = radius
            // Keep anchor point at center for bounce animation
            if let layer = imageView.layer, layer.anchorPoint != CGPoint(x: 0.5, y: 0.5) {
                let frame = layer.frame
                layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                layer.frame = frame
            }
            // Keep glow overlay frame in sync with image size if it exists
            imageView.layer?.sublayers?
                .filter { $0.name == "glowOverlayLayer" }
                .forEach {
                    $0.frame = imageView.layer!.bounds
                    $0.cornerRadius = radius
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
    
    /// Returns the average luminance of the current artwork (0=black, 1=white)
    private func artworkLuminance() -> CGFloat {
        guard let image = imageView.image,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return 0.5 }
        // Scale down to 1x1 to get average color cheaply
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &pixel, width: 1, height: 1,
                                  bitsPerComponent: 8, bytesPerRow: 4,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0.5 }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let r = CGFloat(pixel[0]) / 255
        let g = CGFloat(pixel[1]) / 255
        let b = CGFloat(pixel[2]) / 255
        // Perceived luminance formula
        return 0.299 * r + 0.587 * g + 0.114 * b
    }

    private func startGlowAnimation() {
        stopGlowAnimation()
        guard let imageLayer = imageView?.layer else { return }
        
        // Choose glow color and direction based on artwork luminance
        let luminance = artworkLuminance()
        let glowLayer = CAGradientLayer()
        glowLayer.frame = imageLayer.bounds
        glowLayer.cornerRadius = imageLayer.cornerRadius
        glowLayer.masksToBounds = true
        glowLayer.zPosition = 1000
        glowLayer.name = "glowOverlayLayer"
        glowLayer.type = .radial
        glowLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        glowLayer.opacity = 0
        
        // Scale glow opacity with luminance — light art needs stronger glow to be visible
        let glowOpacity = Float(0.5 + (luminance * 0.5))  // range: 0.5 (dark) to 1.0 (light)
        let gradientAlpha = 0.9 + (luminance * 0.1)       // range: 0.9 (dark) to 1.0 (light)
        
        glowLayer.colors = [
            NSColor.white.withAlphaComponent(gradientAlpha).cgColor,
            NSColor.white.withAlphaComponent(0.0).cgColor
        ]
        glowLayer.endPoint = CGPoint(x: 0.6, y: 0.6)
        glowLayer.compositingFilter = "screenBlendMode"
        imageLayer.addSublayer(glowLayer)
        
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.0
        pulse.toValue = glowOpacity
        pulse.duration = 1.5
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(controlPoints: 0.45, 0.0, 0.55, 1.0)
        glowLayer.add(pulse, forKey: "kGlowAnimationKey")
        
        let expand = CABasicAnimation(keyPath: "endPoint")
        expand.fromValue = CGPoint(x: 0.6, y: 0.6)
        expand.toValue = CGPoint(x: 1.2, y: 1.2)
        expand.duration = 1.5
        expand.autoreverses = true
        expand.repeatCount = .infinity
        expand.timingFunction = CAMediaTimingFunction(controlPoints: 0.45, 0.0, 0.55, 1.0)
        glowLayer.add(expand, forKey: "kGlowExpandKey")
    }
    
    private func stopGlowAnimation() {
        imageView?.layer?.removeAnimation(forKey: "kDimAnimationKey")
        imageView?.layer?.opacity = 1.0
        imageView?.layer?.sublayers?
            .filter { $0.name == "glowOverlayLayer" }
            .forEach { $0.removeFromSuperlayer() }
        imageView?.layer?.superlayer?.sublayers?
            .filter { $0.name == "glowShadowLayer" }
            .forEach { $0.removeFromSuperlayer() }
        imageView?.layer?.superlayer?.superlayer?.sublayers?
            .filter { $0.name == "glowShadowLayer" }
            .forEach { $0.removeFromSuperlayer() }
    }
    
    internal func updateUIState(for item: NowPlayingItem?) {
        self.nowPLayingItem = item
        defer {
            updateForNowPlayingState()
        }
        guard let item = self.nowPLayingItem, let client = item.client else {
            let appBundleIdentifier: String = Preferences[.defaultPlayer]
            imageView.image = NSWorkspace.shared.applicationIcon(for: appBundleIdentifier, fallbackFileType: "mp3")
            maxWidth = effectiveMaxWidth
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
        maxWidth = effectiveMaxWidth
        
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
        let playing = self.nowPLayingItem?.isPlaying ?? false
        if Preferences[.animateIconWhilePlaying], playing {
            self.startSmoothBounceAnimation()
        } else {
            self.stopBounceAnimation()
        }
        if playing && Preferences[.artworkGlow] {
            self.startGlowAnimation()
        } else {
            self.stopGlowAnimation()
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
        self.stopGlowAnimation()
    }
    
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        self.updateUIState(for: nowPLayingItem)
    }
    
}
