# TrackpadGuard

A small macOS menu bar app that makes a MacBook usable again when its Force Touch trackpad starts **clicking on its own**.

## The problem

On a Force Touch trackpad there is no physical button. A force sensor decides when you "clicked", and a haptic motor fakes the click feeling. When that sensor goes bad (very often because a **swelling battery** is pressing on the trackpad from below), the trackpad registers a click whenever a finger merely rests on it:

- the pointer keeps clicking and dragging things by itself
- you feel a constant "tap tap tap" from the haptic motor
- the pointer stutters, because macOS freezes pointer motion for about 300 ms after every press

The touch surface itself usually still works perfectly. Only the force sensor is lying.

> **Safety first.** If your battery is swelling, get it serviced. A swollen lithium battery can be a fire risk. This app is a workaround to keep you working until then, not a repair.

## What it does

| Feature | How |
|---|---|
| **Block false clicks** | Hardware clicks that arrive while a finger is on the trackpad are dropped, and their drags become normal pointer moves. Real taps, read directly from the raw touch sensor, become clicks instead. |
| **Turn off force response** | Tells the trackpad driver to stop reacting to force. The sensor still reports false presses (they are blocked), but the driver no longer turns two-finger scrolls into drags, and its ~300 ms pointer freeze after each press happens about half as often. Restored when you quit. |
| **Smooth pointer** (optional, off by default) | Moves the pointer from your finger motion while the driver freezes it after a false press. It removes the stutter during fast movement, but macOS's speed-dependent pointer acceleration makes it overshoot when you slow down to click, so it is off unless you enable it in the menu. |
| **Silence vibration** | Turns off system actuations on the trackpad's haptic motor, so false presses no longer buzz. Restored when you quit. |
| **Open at login** | A menu toggle. |

Taps are recognized from the raw touch sensor. When TrackpadGuard is unsure (for example a short two-finger touch that might have been the start of a scroll), it leaves the decision to macOS's own tap-to-click, so you never get two clicks for one tap.

Controls once it is running:

| You want to | Do this |
|---|---|
| Click | Tap with one finger |
| Right click | Tap with two fingers |
| Double click | Tap twice quickly |
| Drag | Three-finger drag (enable it in System Settings, Accessibility, Pointer Control, Trackpad Options) |
| Pause / resume click blocking | **Ctrl+Option+Cmd+B**, or the menu bar icon |

Pressing down to click is intentionally ignored while blocking is on, since those are exactly the false clicks.

## Install

Requires macOS 13 or later and the Xcode command line tools (`xcode-select --install`).

```bash
git clone https://github.com/bazl-E/TrackpadGuard.git
cd TrackpadGuard
./build.sh --install
```

This builds `TrackpadGuard.app`, copies it to `~/Applications` and launches it. On first launch macOS asks for **Accessibility** permission (System Settings, Privacy & Security, Accessibility). Turn TrackpadGuard on there; you will hear a "pop" when click blocking starts.

By default the app is ad-hoc signed, so after every rebuild macOS treats it as a new app and you need to switch its Accessibility permission off and on again. If you have an Apple developer certificate, sign with it and the permission survives rebuilds:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build.sh --install
```

## Is this my problem? Run the diagnostic

`./build.sh` also builds a small diagnostic tool. Run it and follow the spoken instructions (hands off, slide a finger, rest a finger, click, tap):

```bash
./build/diagnose full
```

If clicks show up as **"while finger on pad"** when you were only resting or sliding a finger, and **nothing** happens with your hands off, your force sensor is firing on its own and this app should help.

## How it works

- Raw touch data comes from Apple's private `MultitouchSupport` framework (`MTRegisterContactFrameCallback`).
- Clicks are filtered with a `CGEventTap` at the HID level (this is what needs Accessibility permission).
- The driver's reaction to force is turned off with `MTDeviceSetSystemForceResponseEnabled(device, false)`.
- The haptic motor is silenced with `MTActuatorSetSystemActuationsEnabled(actuator, false)`. Note that reprogramming the firmware click waveform did not help on the test machine: the click haptic is driven by the system, not the trackpad firmware.

Logs are written to `~/Library/Logs/TrackpadGuard.log`.

## Limitations

- Uses private Apple APIs, so a future macOS update could break it.
- Tested on a 14" MacBook Pro (M2 Pro) running macOS 27. Other Force Touch MacBooks should behave the same but are untested.
- All trackpad haptics are off while vibration silencing is on (including alignment bumps).
- Physical clicking is disabled while click blocking is on.

## License

MIT, see [LICENSE](LICENSE).
