# beatlight

Pulse a MacBook's keyboard backlight and trackpad haptics to whatever audio is playing.

- **Backlight** follows the bass envelope (150 Hz low-pass, 10 ms RMS frames, auto-gain over ~4 s), updated at most 30×/s.
- **Haptics** fire one short trackpad tap per detected beat (bass energy > 1.6× its ~1 s running average), rate-capped at 4/s by default and 8/s hard.
- **Audio source** is system audio via ScreenCaptureKit, or the microphone.
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
| Launch at Login | Start Beatlight when you log in |

Settings are remembered. If it was running when you quit, it starts again on the next launch. It pauses while the Mac sleeps and resumes on wake. Quitting always restores the backlight.

To keep it around, move `Beatlight.app` into your Applications folder; Spotlight will find it there.

**After rebuilding:** the app is signed locally, so macOS may treat each new build as a different app and ask for permission again. If it keeps saying it needs permission, select Beatlight in Screen & System Audio Recording, remove it with **−**, then quit and reopen Beatlight and allow it again.

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
| App: "needs permission to hear your Mac's audio" | Step 4: turn on Beatlight, then quit and reopen it. Still stuck after a rebuild? Remove it with **−** and allow it again |
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
| `-v`, `--verbose` | off | Live level meter |

### Arp mode

For songs driven by synth arpeggios (think The Weeknd), arp mode (**Arp Flicker** in the app, `--arp` on the command line) runs a 1024-point FFT every 10 ms and watches *spectral flux* between 250 Hz and 4 kHz: how much new energy shows up in new frequency bins. A new synth note moves energy into different bins even when the loudness stays flat, so it catches notes a plain volume detector misses.

Each detected note flickers the backlight: a flash when the keyboard is dim, a dip when it's bright, fading back over about 50 ms. Kicks still drive the main pulse, and the trackpad still taps on kicks only. Flickers are capped at about 12 per second, and any note within 40 ms of a kick is ignored (a kick's attack also hits the mids).

```sh
./beatlight -v --arp
```

Vocals, snares and claps also produce spectral flux, so busy tracks can flicker on more than just the synth. Raise `--arp-sens` (try 2.0) if it's too twitchy, lower it (try 1.3) if it misses notes. If flashing lights bother you, skip `--arp` or lower `--arp-depth`.

## Hardware safety

The backlight is LEDs, so fast changes are harmless. The trackpad actuator is an electromagnetic coil built for short clicks; beatlight only sends discrete, rate-capped taps and never drives it with a continuous waveform.

## Status

The command-line tool builds on macOS with the Command Line Tools. The menu bar app is new and not yet verified on hardware; the `MTActuatorActuate` arguments and actuation IDs are reverse-engineered and may need adjusting per Mac.
