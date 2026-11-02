# beatlight

> **This is the `rgb` branch:** everything on `main`, plus pulsing RGB devices (mice, headsets, mousepads) through [OpenRGB](#rgb-devices-openrgb). It's experimental and not yet verified with real devices. For the stable version, use `main`.

Pulse a MacBook's keyboard backlight and trackpad haptics to whatever audio is playing.

- **Backlight** follows the bass envelope (150 Hz low-pass, 10 ms RMS frames, auto-gain over ~4 s), updated at most 30×/s.
- **Haptics** fire one short trackpad tap per detected beat (bass energy > 1.6× its ~1 s running average), rate-capped at 4/s by default and 8/s hard.
- **Audio source** is system audio via ScreenCaptureKit, or the microphone.
- **RGB devices** (optional): mice, headsets, mousepads and more pulse along through [OpenRGB](#rgb-devices-openrgb).
- Runs as a **menu bar app** (`Beatlight.app`) or a **command-line tool** (`beatlight`). Both share the same engine.

> Uses two private Apple frameworks (CoreBrightness for the backlight, MultitouchSupport for the trackpad actuator), loaded at runtime. Personal use only; a macOS update can break it. The keyboard backlight is a single zone, so there is no per-key or wave effect.

## Requirements

- MacBook with a backlit keyboard and a Force Touch trackpad (2015+)
- macOS 13 or later
- Apple's Command Line Tools (free; step 1 below). Full Xcode is not needed.

## Build and run

All commands go in **Terminal** (Applications → Utilities → Terminal, or Cmd+Space and type "Terminal").

### 1. Install Apple's Command Line Tools (one time)

```sh
xcode-select --install
```

A dialog pops up; click **Install** and wait for it to finish (a few minutes, roughly a 1 GB download). If it says the tools are already installed, you're set. To confirm, `clang --version` should print a version instead of an error.

### 2. Download beatlight

Either clone it with git (included in the Command Line Tools):

```sh
git clone https://github.com/arnan-bajaj/beatlight
cd beatlight
```

or, on this page, click **Code → Download ZIP**, double-click the ZIP in Downloads to unzip it, then:

```sh
cd ~/Downloads/beatlight-main
```

### 3. Build

```sh
bash build.sh
```

This builds two things in the same folder: `Beatlight.app` (the menu bar app) and `beatlight` (the command-line tool). It should end with `Built ./Beatlight.app`. Compiler warnings are fine; errors mean it didn't build.

### 4. Run the menu bar app

```sh
open Beatlight.app
```

A waveform icon appears in the menu bar and it starts right away. The icon is greyed out while it's stopped.

**First launch:** beatlight listens to your Mac's system audio, which macOS treats as screen recording, so it asks for permission.

1. Click **Open System Settings** in Beatlight's prompt (or go to **System Settings → Privacy & Security → Screen & System Audio Recording**; called **Screen Recording** on macOS 13–14).
2. Turn on **Beatlight**.
3. Click the menu bar icon → **Quit Beatlight**, then `open Beatlight.app` again. The permission doesn't apply until it restarts.

Don't want to grant that? Choose **Audio Source → Microphone** in the menu instead. It asks for microphone access, and the mic picks up your speakers, so play music out loud, not through headphones.

**The menu:**

| Item | What it does |
|---|---|
| Start / Stop | Stopping restores your backlight level and auto-brightness |
| Audio Source | System Audio or Microphone |
| Beat Sensitivity | Low / Medium / High (high = more beats) |
| Keyboard Backlight | Pulse the backlight with the bass |
| Arp Flicker | Flicker the backlight on synth/arpeggio notes ([details](#arp-mode)) |
| Arp Sensitivity | Low / Medium / High (high = more flickers) |
| Trackpad Haptics | Tap the trackpad on kicks (max 4 taps/s) |
| Haptic Strength | Weak / Medium / Strong |
| RGB Devices (OpenRGB) | Pulse your RGB gear too ([setup](#rgb-devices-openrgb)); lists the connected devices |
| RGB Color | A solid color, Color Cycle (new color each kick), or a smooth rainbow (steady, or faster when louder) |
| Launch at Login | Start Beatlight when you log in |

Settings are remembered. If it was running when you quit, it starts again on the next launch. It pauses while the Mac sleeps and resumes on wake. Quitting always restores the backlight.

To keep it around, move `Beatlight.app` into your Applications folder; Spotlight will find it there.

**After rebuilding:** unless you set up a signing certificate, macOS treats each new build as a different app and asks for permission again. See [Permissions keep coming back](#permissions-keep-coming-back).

#### Permissions keep coming back

`build.sh` signs the app. With no certificate it uses an "ad-hoc" signature, which is different on every build, and macOS ties the permission to the signature. So every rebuild looks like a new app, and the old entry in System Settings no longer matches. Toggling it off and on doesn't help.

Fix it once with a free self-signed certificate:

1. Open **Keychain Access** (Spotlight → "Keychain Access").
2. Menu **Keychain Access → Certificate Assistant → Create a Certificate…**
3. Name: `Beatlight Local`. Identity Type: **Self-Signed Root**. Certificate Type: **Code Signing**. Click **Create**.
4. Rebuild with `bash build.sh`. It should print `Signed with "Beatlight Local"`. If macOS asks whether `codesign` may use the key, click **Always Allow**.
5. Clear the stale permission entries once, then reopen:
   ```sh
   tccutil reset ScreenCapture com.arnanbajaj.beatlight
   open Beatlight.app
   ```
6. Allow the permission when asked, then choose **Restart Beatlight** from the menu bar icon.

From then on, rebuilds keep the permission. If you already have an **Apple Development** certificate from Xcode, `build.sh` uses that automatically instead.

Also make sure Beatlight is in the top **Screen & System Audio Recording** list, not **System Audio Recording Only**.

### 5. Or use the command line

The command-line tool needs the same permission, but for your terminal app instead of Beatlight:

1. Run `./beatlight -v` once. macOS shows a permission prompt and beatlight exits with a permission message.
2. In **System Settings → Privacy & Security → Screen & System Audio Recording**, turn on **Terminal** (or iTerm, whichever you use).
3. **Quit Terminal completely (Cmd+Q)** and reopen it, then `cd` back into the beatlight folder.

This permission applies to everything you run from that terminal app, not just beatlight. To skip it, use `./beatlight --mic -v`.

Play some music, then:

```sh
./beatlight -v
```

`-v` shows a live bass meter and flashes `BEAT` on detected beats. The keyboard should pulse and the trackpad should tap on kicks. Try `--haptic-id 3` the first time for the weakest taps, or `--no-haptics` for backlight only.

**Ctrl+C** stops it and restores your original backlight level and auto-brightness setting. If it ever exits any other way (crash, force-quit), turn auto-brightness back on in System Settings → Keyboard → "Adjust keyboard brightness in low light".

### Troubleshooting

| Message | Fix |
|---|---|
| `xcrun: error: invalid active developer path` | Command Line Tools aren't installed: redo step 1 |
| `ld: ... tapi error: malformed file ... unknown architecture` | Your Xcode is older than your Command Line Tools. `build.sh` already uses the Command Line Tools when they're installed; if you still see this, update Xcode or run `sudo xcode-select -s /Library/Developer/CommandLineTools` |
| App: "needs permission to hear your Mac's audio" | Step 4: turn on Beatlight, then **Restart Beatlight** from the menu |
| App asks for permission again after every rebuild | [Permissions keep coming back](#permissions-keep-coming-back) |
| App: "Keyboard Backlight (not available)" in the menu | Your Mac's backlight isn't supported; haptics still work |
| CLI: `no permission to capture system audio` | Step 5: turn on your terminal app, then quit and reopen it |
| CLI: `keyboard backlight not reachable` | Your Mac's backlight isn't supported; haptics still work |
| CLI: `trackpad actuator not reachable` | No Force Touch trackpad found; backlight still works |
| Meter stays empty | Nothing is playing, or (with `--mic`) the music is in headphones |

## Command-line options

| Flag | Default | Meaning |
|---|---|---|
| `--mic` | off | Listen through the microphone instead of system audio |
| `--no-backlight` | off | Don't touch the keyboard backlight |
| `--no-haptics` | off | Don't use the trackpad actuator |
| `--min X` / `--max X` | 0.05 / 1.0 | Backlight range, 0–1 |
| `--sens X` | 1.6 | Beat threshold vs. running average; lower = more beats |
| `--haptic-rate N` | 4 | Max haptic taps per second (hard cap 8) |
| `--haptic-id N` | 4 | Tap pattern: 3 weak, 4 medium, 6 strong |
| `--arp` | off | Flicker the keyboard backlight on synth/arpeggio notes |
| `--arp-sens X` | 1.5 | Arp threshold; lower = more flickers |
| `--arp-depth X` | 0.8 | Backlight flicker strength, 0–1 |
| `--rgb` | off | Also pulse RGB devices through OpenRGB ([setup](#rgb-devices-openrgb)) |
| `--rgb-color RRGGBB` | ffffff | Pulse color for RGB devices |
| `--rgb-mode MODE` | solid | `solid` (uses `--rgb-color`), `kick` (new color each kick), `rainbow` (smooth flow), `reactive` (flows faster when louder) |
| `--rgb-cycle` | off | Same as `--rgb-mode kick` |
| `-v`, `--verbose` | off | Live level meter |

### Arp mode

For songs driven by synth arpeggios (think The Weeknd), arp mode (**Arp Flicker** in the app, `--arp` on the command line) runs a 1024-point FFT every 10 ms and watches *spectral flux* between 250 Hz and 4 kHz: how much new energy shows up in new frequency bins. A new synth note moves energy into different bins even when the loudness stays flat, so it catches notes a plain volume detector misses.

Each detected note flickers the backlight: a flash when the keyboard is dim, a dip when it's bright, fading back over about 50 ms. Kicks still drive the main pulse, and the trackpad still taps on kicks only. Flickers are capped at about 12 per second, and any note within 40 ms of a kick is ignored (a kick's attack also hits the mids).

```sh
./beatlight -v --arp
```

Vocals, snares and claps also produce spectral flux, so busy tracks can flicker on more than just the synth. Raise `--arp-sens` (try 2.0) if it's too twitchy, lower it (try 1.3) if it misses notes. If flashing lights bother you, skip `--arp` or lower `--arp-depth`.

## RGB devices (OpenRGB)

beatlight can pulse other RGB gear along with the keyboard, such as a Logitech G502 Lightspeed mouse, G733 headset and POWERPLAY mat. It doesn't talk to those devices itself. [OpenRGB](https://openrgb.org) (free, open source) does, and beatlight sends it the current color up to 25 times a second over OpenRGB's local SDK server.

### Setup

1. **Quit Logitech G HUB completely** (its menu bar icon → Quit) and turn off its launch at login. G HUB and OpenRGB both try to control the lighting and will fight each other.
2. **Install and open OpenRGB** for macOS from [openrgb.org](https://openrgb.org). Allow any permission it asks for.
3. **Check your devices in OpenRGB first.** Each one should be listed, and changing its color in OpenRGB should change the real device. If a device isn't listed or doesn't respond, beatlight can't drive it either; that's an OpenRGB issue.
4. **Start OpenRGB's SDK server:** SDK Server tab → **Start Server**. To have it start automatically, launch OpenRGB with `--server`.
5. **Turn it on in beatlight:** menu → **RGB Devices (OpenRGB)**, then pick an **RGB Color**. On the command line: `./beatlight -v --rgb --rgb-color ff0000`, or `--rgb-mode rainbow`.

The menu shows "waiting for OpenRGB…" until it connects, then lists the devices it's driving. beatlight checks for OpenRGB every 3 seconds, so the order you open the two apps doesn't matter.

### What it does

- Every device OpenRGB lists is switched to its Direct mode and pulses with the same brightness as the keyboard backlight, including [arp](#arp-mode) flickers. Turn off detection in OpenRGB for anything you want left alone.
- Color modes (**RGB Color** menu). Every device shows the same color at the same moment, pulsing with the beat:
  - a **solid color**;
  - **Color Cycle**: jumps to a new hue on every kick;
  - **Rainbow (smooth)**: flows through the colors, one lap every 8 seconds;
  - **Rainbow (speeds up with the music)**: drifts slowly in quiet parts and races through the colors when the music is loud.
- The keyboard backlight is white-only hardware, so it pulses with the others but can't change color.
- Stopping or quitting beatlight puts each device back to the mode and colors it had in OpenRGB.
- The RGB output works even with the keyboard backlight turned off.

### Caveats

- **Wireless lag and battery:** color updates share the wireless link with everything else, so wireless devices may lag the keyboard slightly or skip updates. RGB also drains wireless batteries faster.
- **OpenRGB on macOS is less mature** than on Windows and Linux, and some Logitech devices have detection problems there. Step 3 tells you quickly whether your setup works.

## Hardware safety

The backlight is LEDs, so fast changes are harmless. The trackpad actuator is an electromagnetic coil built for short clicks; beatlight only sends discrete, rate-capped taps and never drives it with a continuous waveform.

## Status

The command-line tool builds on macOS with the Command Line Tools. The menu bar app is new and not yet verified on hardware. The OpenRGB client (`orgb.c`) is tested against a simulated OpenRGB server but not yet with real devices; the `MTActuatorActuate` arguments and actuation IDs are reverse-engineered and may need adjusting per Mac.
