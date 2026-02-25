//
//  NowPlayingWidget.swift
//  Better Now Playing
//
//  Created by Pierluigi Galdi on 08/01/2020.
//  Copyright © 2019 Pierluigi Galdi. All rights reserved.
//  Modified by JosephPri
//

import Foundation
import AppKit
import PockKit

class NowPlayingWidget: PKWidget {
    static var identifier: String = "NowPlayingWidget"
    var customizationLabel: String = "Better Now Playing"
    var view: NSView!
    
    static var preferenceClass: PKWidgetPreference.Type? = NowPlayingPreferencePane.self
    
    required init() {
        view = NowPlayingView(frame: NSRect(x: 0, y: 0, width: 120, height: 30), shouldLoadHelper: true)
    }
    
    deinit {
        NSLog("[NOW_PLAYING]: NowPlayingWidget - deinit")
        view.removeFromSuperview()
        view = nil
    }
    
}
