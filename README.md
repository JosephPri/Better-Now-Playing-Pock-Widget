# Better Now Playing - Pock Widget

A fixed fork of the [now-playing-widget](https://github.com/pock/now-playing-widget) Pock widget, updated to work on **macOS 15.4 and later**, where Apple privatized direct access to the MediaRemote framework.

![Touch Bar Preview](TouchBar.png)

---

## Rationale

In macOS 15.4, Apple quietly restricted the private MediaRemote framework so third-party apps could no longer use it to read what's playing. This broke the original widget (and many other apps) entirely. This fork uses a clever workaround via a system Perl script that still has access, so everything works again.

---

## Features

- **Works with all media players** - Apple Music, Spotify, YouTube, etc.
- **Revamped album art** - fully working with rounded corners and adjustable size
- **Automatically removes the built-in macOS Now Playing Touch Bar icon** (looks like bar graph in circle) It would otherwise appear alongside the widget and be quite redundant and annoying
- **Uses mediaremote-adapter** as a workaround for Apple's API privatization in macOS 15.4+

---

## Installation via `.pock` file (Recommended)

1. **Download the latest `.pock` file** from [Releases](https://github.com/JosephPri/Better-Now-Playing-Pock-Widget/releases)
2. **Install in Pock** - Double-click/open the `.pock` file, Pock installs it automatically
   > If MacOS prevents you from opening the file for security reasons, navigate to **System Settings** > **Privacy and Security** and scroll until you see `"Better Now Playing.pock" was blocked to protect your Mac` and click **Open Anyway**
3. **Configure the widget** - click the Pock icon in the menu bar, then select **Manage Widgets** (`⌘M`). Here you can choose your preferred widget layout and other settings.
4. **Add to Touch Bar** - click the Pock icon again and select **Customize Pock...** (`⌘P`), then drag the **Better Now Playing** widget down to the Touch Bar. 
   > If nothing happens after clicking **Customize Pock...**, repeat step 4 with the Widget Manager (from step 3) still open.

---

## Installation via Source Files

### What you'll need
- [Pock](https://pock.app) installed
- Xcode (free on the Mac App Store)
- CocoaPods - if you don't have it, open Terminal and run:
```
  sudo gem install cocoapods
```
- CMake - if you don't have it, install [Homebrew](https://brew.sh) then run:
```
  brew install cmake
```

### Steps
1. **Clone this repo** - open XCode, select **Clone Git Repository...**, paste `https://github.com/JosephPri/Better-Now-Playing-Pock-Widget.git` and click **Clone**.
2. **Run setup commands** - open Terminal, type "`cd `" then drag the cloned repo folder into the Terminal window and press Enter. Copy and run:
```
   git submodule update --init
   pod install
```
Type "`cd `" again, then drag the **mediaremote-adapter** folder (inside the cloned repo) into the Terminal window and press Enter. Copy and run:
```
   mkdir -p build
   cd build
   cmake ..
   make
```
You can now close Terminal.

3. **Install in Pock** - Press **⌘B** in the newly opened Xcode window, Pock installs it automatically
> On first build, Pock may give an error. Simply press **⌘B** again to rebuild and it will work correctly.
4. **Configure the widget** - click the Pock icon in the menu bar, then select **Manage Widgets** (`⌘M`). Here you can choose your preferred widget layout and other settings.
5. **Add to Touch Bar** - click the Pock icon again and select **Customize Pock...** (`⌘P`), then drag the **Better Now Playing** widget down to the Touch Bar.
   > If nothing happens after clicking **Customize Pock...**, repeat step 5 with the Widget Manager (from step 4) still open.
   
---

## Known Issues (current bugs while in beta, not limitations)

- The widget seems to stop checking for music after an extended period of time (seems to happen when MacBook is closed for a while), I should be able to fix it soon, but for now pock must be reloaded (**click Pock menu bar icon** > **Advanced** > **Reload Pock...**) when this happens.
- The widget also seems to (sometimes) stop checking for music after a playlist ends, but does seem to fix itself by closing/opening music player or clicking some random combination of media controls. This of course can also be remedied by reloading pock (**click Pock menu bar icon** > **Advanced** > **Reload Pock...**).

---

## Credits

- [ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) - the workaround that makes this all possible after Apple's API change
- [SgtSalmon/Kill-NowPlayingTouchUI](https://github.com/SgtSalmon/Kill-NowPlayingTouchUI/blob/main/LICENSE) - figured out how to kill the annoying and redundant built-in macOS Now Playing icon
- [pock/now-playing-widget](https://github.com/pock/now-playing-widget) - the original widget this is based on
- [musa11971](https://gist.github.com/musa11971/62abcfda9ce3bb17f54301fdc84d8323) - iTunes API fallback for album artwork

---

## License

MIT — see [LICENSE](LICENSE)
