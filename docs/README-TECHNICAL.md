# Better Now Playing - Pock Widget (Technical Documentation)

This document explains how the widget works internally. For installation and usage instructions, see [README.md](README.md).

---

## Architecture Overview

The widget consists of several Swift components that work together to display Now Playing information on the Touch Bar:

```
┌─────────────────────────────────────────────────────────┐
│                    NowPlayingWidget                     │
│              (PKWidget - entry point)                   │
└─────────────────────┬───────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────┐
│                    NowPlayingView                       │
│         (PKView - UI container + controls)             │
│  ┌─────────────┬──────────────┬──────────────────────┐ │
│  │ Previous    │  ItemView    │  Next                │ │
│  │  Button    │  (artwork,   │  Button              │ │
│  │            │   title,     │                      │ │
│  │            │   artist)    │                      │ │
│  └─────────────┴──────────────┴──────────────────────┘ │
└─────────────────────┬───────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────┐
│                   NowPlayingHelper                       │
│   (Coordinates data flow and system notifications)     │
└─────────────────────┬───────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────┐
│                MediaRemoteAdapter                        │
│   (Swift wrapper around the Perl adapter script)       │
│                                                         │
│   spawns: mediaremote-adapter.pl (Perl)                │
│       │                                                 │
│       ▼                                                 │
│   mediaremote-adapter (C++ framework)                  │
│                                                         │
│       │                                                 │
│       ▼                                                 │
│   MediaRemote.framework (Apple private API)            │
└─────────────────────────────────────────────────────────┘
```

---

## Core Components

### 1. NowPlayingWidget (PKWidget)

**File:** `Sources/NowPlayingWidget.swift`

Entry point for Pock. It:
- Registers the widget with Pock via `PKWidget` protocol
- Sets the custom preference pane (`NowPlayingPreferencePane`)
- Creates the main view (`NowPlayingView`) with size 120x30

```swift
class NowPlayingWidget: PKWidget {
    static var identifier: String = "NowPlayingWidget"
    var customizationLabel: String = "Better Now Playing"
    var view: NSView!
    
    static var preferenceClass: PKWidgetPreference.Type? = NowPlayingPreferencePane.self
    
    required init() {
        view = NowPlayingView(frame: NSRect(x: 0, y: 0, width: 120, height: 30), shouldLoadHelper: true)
    }
}
```

### 2. NowPlayingView (PKView)

**File:** `Sources/NowPlayingView.swift`

The main UI view. Handles:
- Displaying album artwork, title, and artist
- Play/Pause, Previous, Next buttons
- Widget styles (default, onlyInfo, playPause)
- Gesture handling (tap to play/pause, swipe to skip)
- Visibility control (hiding when no media is playing)

Key UI states:
```swift
enum NowPlayingWidgetStyle: Int {
    case default      // Previous + Info + Next (full controls)
    case onlyInfo     // Just the track info (no buttons)
    case playPause    // Previous + Play/Pause + Next
}
```

Gestures:
- **Tap:** Toggle play/pause
- **Swipe Left:** Previous track
- **Swipe Right:** Next track
- **Long Press:** Launch the music app

### 3. NowPlayingHelper

**File:** `Sources/NowPlayingHelper.swift`

The "brain" of the widget. Manages:

**Data Flow:**
1. Subscribes to MediaRemoteAdapter notifications
2. Updates `currentNowPlayingItem` with fresh data
3. Notifies the view to redraw

**System Event Handling:**
- Monitors app launches/terminations (restarts stream when music apps start)
- Monitors sleep/wake cycles (stops/restarts adapter)
- Suppresses the built-in macOS Now Playing Touch Bar icon via `launchctl`

**Inactivity Timer:**
- Can auto-hide the widget after a configurable timeout when paused
- Resets when playback resumes

### 4. MediaRemoteAdapter

**File:** `Sources/MediaRemoteAdapter.swift`

Swift wrapper that communicates with the Perl adapter script. Provides:

**Public API:**
```swift
func startStreaming()   // Begin receiving live updates
func stopStreaming()    // Stop updates
func getNowPlayingInfo(completion: (NowPlayingInfo?) -> Void)  // Request current state
func sendCommand(_ command: MediaRemoteCommand)  // Play, Pause, Next, Previous
```

**Key Features:**
- **Debouncing:** Batches rapid updates (every 150ms)
- **Command Suppression:** Ignores stale updates after skip commands (300ms)
- **Thread Safety:** Uses serial queue for all state mutations
- **Process Management:** Spawns/reap the Perl script

---

## How Data Flow Works

### 1. Initialization (on widget load)

```
NowPlayingWidget.init()
    │
    ▼
NowPlayingView.init(shouldLoadHelper: true)
    │
    ▼
NowPlayingHelper.init()
    │
    ├─► MediaRemoteAdapter.shared.startStreaming()
    │       └─► Spawns: perl mediaremote-adapter.pl ... stream
    │
    ├─► suppressNowPlayingTouchUI()
    │       └─► launchctl disable com.apple.NowPlayingTouchUI
    │
    └─► updateFromAdapter()
            └─► MediaRemoteAdapter.getNowPlayingInfo()
```

### 2. Receiving Updates (streaming)

```
User plays music in Apple Music / Spotify
    │
    ▼
MediaRemote.framework (system private API)
    │
    ▼
mediaremote-adapter (C++ framework)
    │
    ▼
mediaremote-adapter.pl (Perl script)
    │
    ▼ stdout JSON stream
MediaRemoteAdapter.handleStreamData()
    │
    ├─► Parse JSON → NowPlayingInfo
    ├─► Debounce (batch rapid changes)
    └─► Post Notification:
            .mediaRemoteAdapterNowPlayingInfoDidChange
            .mediaRemoteAdapterNowPlayingApplicationDidChange
            .mediaRemoteAdapterIsPlayingDidChange
    │
    ▼
NowPlayingHelper receives notification
    │
    ▼
Updates currentNowPlayingItem
    │
    ▼
Notifies NowPlayingView.updateContentViews()
    │
    ▼
View redraws with new track info
```

### 3. User Interactions

```
User taps on widget
    │
    ▼
NowPlayingView.configureUIElements()
    │
    ▼
Gesture recognized → togglePlayPause() / skipToNextItem() / etc.
    │
    ▼
NowPlayingHelper.sendCommand()
    │
    ▼
MediaRemoteAdapter.sendCommand()
    │
    ▼
Spawns: perl mediaremote-adapter.pl ... <command>
    │
    ▼
Perl → C++ framework → MediaRemote.framework
    │
    ▼
System executes: Play/Pause/Next/Previous
```

---

## The MediaRemoteAdapter Workaround

**The Problem:** In macOS 15.4, Apple privatized the MediaRemote framework. Third-party apps can no longer directly use `MediaRemote.framework` to read what's playing.

**The Solution:** The `mediaremote-adapter` is a system utility that still has access to the private API. It's built from source in `mediaremote-adapter/` and bundled with the widget.

**Flow:**
```
Our App (sandboxed)  ──►  mediaremote-adapter.pl  ──►  mediaremote-adapter (C++)
                              (Ruby/Perl)                (unsandboxed)
                                                          │
                                                          ▼
                                                  MediaRemote.framework
                                                  (Apple private API)
```

**Why a Perl script?** The adapter is invoked as a subprocess, and Perl can easily spawn the C++ framework while passing the system framework path.

---

## Suppressing macOS Built-in Now Playing

The built-in Touch Bar icon (a bar graph in a circle) would appear alongside our widget, which is redundant and annoying.

**Solution:** Use `launchctl` to disable the `NowPlayingTouchUI` agent:

```bash
launchctl disable system/com.apple.NowPlayingTouchUI
```

The widget includes a `killTimer` that polls every 0.3s to kill the process if it respawns, and re-suppresses it on system wake.

---

## Widget Styles

| Style | Layout | Description |
|-------|--------|-------------|
| `default` | ⏮ 🎵 ⏭ | Full controls + track info with album art |
| `onlyInfo` | 🎵 | Track info only, no buttons |
| `playPause` | ⏮ ▶/⏸ ⏭ | Compact with play/pause button |

---

## Configuration (Preferences)

The widget reads preferences via the `Preferences` class:

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `hideNowPlayingIfNoMedia` | Bool | `false` | Hide widget when nothing is playing |
| `defaultPlayer` | String | `com.apple.Music` | Default player to show |
| `nowPlayingWidgetStyle` | Int | `0` | Widget style (0=default, 1=onlyInfo, 2=playPause) |
| `hideAfterInactivity` | Bool | `false` | Auto-hide after timeout when paused |
| `inactivityTimeout` | Int | `30` | Seconds before hiding when paused |
| `artworkSize` | Int | `30` | Album art size in pixels |
| `artworkGlow` | Bool | `true` | Enable glow effect on artwork |

---

## Files Structure

```
Better Now Playing/
├── Sources/
│   ├── NowPlayingWidget.swift      # PKWidget entry point
│   ├── NowPlayingView.swift        # Main UI view
│   ├── NowPlayingItemView.swift    # Album art + text display
│   ├── NowPlayingItem.swift        # Data model
│   ├── NowPlayingHelper.swift      # Data + event coordination
│   ├── MediaRemoteAdapter.swift    # Perl script wrapper
│   ├── NowPlayingWidgetStyle.swift # Style definitions
│   └── Preferences.swift           # Settings management
├── NowPlayingPreferencePane/
│   └── NowPlayingPreferencePane.swift  # Settings UI
└── Resources/
    └── mediaremote-adapter.pl          # Perl adapter script
```

---

## Building from Source

```bash
# 1. Clone and init submodules
git clone https://github.com/JosephPri/Better-Now-Playing-Pock-Widget.git
cd Better-Now-Playing-Pock-Widget
git submodule update --init

# 2. Install CocoaPods dependencies
pod install

# 3. Build the mediaremote-adapter
cd ./mediaremote-adapter
mkdir -p build && cd build
cmake ..
make

# 4. Open in Xcode
cd ../..
open "Better Now Playing.xcworkspace"

# 5. Build (⌘B) - Pock will automatically install the widget
```

---

## Widget Update Resilience

During song transitions, the system's MediaRemote framework can briefly send empty or
incomplete updates (no `bundleIdentifier`, no `title`, `isPlaying = false`). Without
proper handling, these transient states cause the widget to disappear and fail to
recover when the new song data arrives.

This is especially common with **non-standard audio sources** like web browsers
(Chrome, Safari, Firefox, Arc, etc.) that aren't in the traditional "music app" list.

### The Problem

Three layers of code could independently wipe the widget state during transitions:

1. **`MediaRemoteAdapter.handleStreamUpdate`** — Received an "empty full update"
   and cleared `_currentInfo` to `nil` when the audio source wasn't a hardcoded
   music app.

2. **`NowPlayingHelper.updateMediaContent`** — When `currentInfo` was `nil`, only
   preserved existing state if Music/Spotify/iTunes was running. For browsers,
   it called `updateWithInfo(nil)` which cleared the client.

3. **`NowPlayingView.updateContentViews`** — Called `removeArrangedSubviews()` when
   `shouldHideWidget` was true, which **destroyed** the `itemView` (set it to `nil`).
   Recreating it on the next update lost all internal state.

### The Fix

**`MediaRemoteAdapter.swift`** — Empty update protection now checks if we already
have *any* valid state (`bundleIdentifier` or `title`), regardless of which app
produced it. Transient empty updates no longer wipe state.

**`NowPlayingHelper.swift`** — Two changes:
- `updateMediaContent`: If we already have a client set from *any* source (including
  browsers), we preserve the existing state during `nil` transitions instead of
  requiring a hardcoded music app to be running.
- `updateWithInfo(nil)`: Same approach — preserves the existing client rather than
  replacing it only when a known music app is detected.
- `periodicRefresh`: Now also runs when `isPlaying` is false but a client is set,
  covering the brief `isPlaying = false` window during song transitions.

**`NowPlayingView.swift`** — `updateContentViews()` now **hides** subviews
(via `isHidden = true`) instead of destroying them. This preserves the `itemView`
reference and its internal state across hide/show cycles. Views are only destroyed
in `deinit` or when the widget style changes via `configureUIElements()`.

```
Song Change Timeline (Before Fix):
────────────────────────────────────────────
t0: Song A playing          → Widget visible ✓
t1: Transition (nil update) → Widget destroyed ✗
t2: Song B arrives          → Widget stays hidden ✗ (itemView was nil)

Song Change Timeline (After Fix):
────────────────────────────────────────────
t0: Song A playing          → Widget visible ✓
t1: Transition (nil update) → State preserved, view hidden ✓
t2: Song B arrives          → Widget unhidden with new data ✓
```

---

## Troubleshooting

**Widget not appearing in Touch Bar:**
- Make sure Pock is running and the widget is added via Customize Pock

**Widget not updating when changing songs:**
- This was a known issue where transient empty updates from the MediaRemote framework
  caused the widget to disappear during song transitions. The fix preserves existing
  state during these transitions.
- If you're using a browser as your audio source, make sure you're running the latest
  version with the widget update resilience fix.
- Check console logs for `[NowPlayingHelper]` messages — you should see
  "preserving existing client" or "preserving state during nil transition" during
  song changes.

**Album art not showing:**
- Check that the mediaremote-adapter framework was built correctly
- Try with a track that has embedded artwork

**Widget shows but controls don't work:**
- Ensure Accessibility permissions are granted to Pock

**macOS 15.4+ not working:**
- Verify the mediaremote-adapter was built from source with CMake
- Check console logs for `[MediaRemoteAdapter]` messages