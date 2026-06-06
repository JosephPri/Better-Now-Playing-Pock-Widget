//
//  UpdateChecker.swift
//  Better Now Playing
//
//  Created by JosephPri
//

import Foundation
import AppKit

class UpdateChecker {

    private static let appcastURL = "https://raw.githubusercontent.com/JosephPri/Better-Now-Playing-Pock-Widget/refs/heads/master/appcast.json"

    static let releasesURL = "https://github.com/JosephPri/Better-Now-Playing-Pock-Widget/releases/latest"

    // Reads the current version from the widget bundle's Info.plist
    private static var currentVersion: String {
        return Bundle(for: UpdateChecker.self).infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.00"
    }

    // Called once when the widget loads. Calls back on the main thread.
    static func checkForUpdate(completion: @escaping (_ updateAvailable: Bool, _ latestVersion: String) -> Void) {
        guard let url = URL(string: appcastURL) else { return }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        URLSession.shared.dataTask(with: request) { data, _, error in
            guard error == nil,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let latestVersion = json["name"] as? String else {
                return
            }
            let updateAvailable = isNewer(latestVersion, than: currentVersion)
            print("[UpdateChecker] remote: \(latestVersion), local: \(currentVersion), newer: \(updateAvailable)")
            DispatchQueue.main.async {
                completion(updateAvailable, latestVersion)
            }
        }.resume()
    }

    // Simple version comparison: "1.2.0" > "1.1.0" etc.
    private static func isNewer(_ remote: String, than local: String) -> Bool {
        let remoteParts = remote.split(separator: ".").compactMap { Int($0) }
        let localParts  = local.split(separator: ".").compactMap { Int($0) }
        let maxLen = max(remoteParts.count, localParts.count)
        for i in 0..<maxLen {
            let r = i < remoteParts.count ? remoteParts[i] : 0
            let l = i < localParts.count  ? localParts[i]  : 0
            if r > l { return true  }
            if r < l { return false }
        }
        return false
    }
}

class UpdateBannerView: NSView {

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0).cgColor
        layer?.cornerRadius = 6
 
        // Borderless button so clicks work, transparent so the layer shows through
        let button = NSButton(title: "", target: self, action: #selector(openReleasesPage))
        let title = NSAttributedString(string: "⬆ Update Available", attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 11, weight: .medium)
        ])
        button.attributedTitle = title
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.clear.cgColor
 
        addSubview(button)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
 
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 22).isActive = true
    }
 
    @objc private func openReleasesPage() {
        guard let url = URL(string: UpdateChecker.releasesURL) else { return }
        NSWorkspace.shared.open(url)
    }
}
 
