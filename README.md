# beatlight

Pulse a MacBook's keyboard backlight and trackpad haptics to whatever audio is playing.

- **Backlight** follows the bass envelope (150 Hz low-pass, 10 ms RMS frames, auto-gain over ~4 s), updated at most 30×/s.
- **Haptics** fire one short trackpad tap per detected beat (bass energy > 1.6× its ~1 s running average), rate-capped at 4/s by default and 8/s hard.
- **Audio source** is system audio via ScreenCaptureKit, or the microphone with `--mic`.

> Uses two private Apple frameworks (CoreBrightness for the backlight, MultitouchSupport for the trackpad actuator), loaded at runtime. Personal use only; a macOS update can break it. The keyboard backlight is a single zone, so there is no per-key or wave effect.

## Requirements

- MacBook with a backlit keyboard and a Force Touch trackpad (2015+)
- macOS 13 or later
- Apple Command Line Tools: `xcode-select --install`

## Build and run

```sh
./build.sh
./beatlight -v
```

The first run asks for **Screen & System Audio Recording** permission for your terminal app (System Settings → Privacy & Security). Enable it, quit and reopen the terminal, and run again. To skip that, use `./beatlight --mic -v`.

Ctrl-C stops it and restores the original backlight level and auto-brightness setting.

## Options

| Flag | Default | Meaning |
|---|---|---|
| `--mic` | off | Listen through the microphone instead of system audio |
| `--no-backlight` | off | Don't touch the keyboard backlight |
| `--no-haptics` | off | Don't use the trackpad actuator |
| `--min X` / `--max X` | 0.05 / 1.0 | Backlight range, 0–1 |
| `--sens X` | 1.6 | Beat threshold vs. running average; lower = more beats |
| `--haptic-rate N` | 4 | Max haptic taps per second (hard cap 8) |
| `--haptic-id N` | 4 | Tap pattern: 3 weak, 4 medium, 6 strong |
| `-v`, `--verbose` | off | Live level meter |

## Hardware safety

The backlight is LEDs, so fast changes are harmless. The trackpad actuator is an electromagnetic coil built for short clicks; beatlight only sends discrete, rate-capped taps and never drives it with a continuous waveform.

## Status

Builds on macOS with the Command Line Tools. Runtime behavior is not yet fully verified; the `MTActuatorActuate` arguments and actuation IDs are reverse-engineered and may need adjusting per Mac.
