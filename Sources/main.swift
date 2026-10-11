// TrackpadGuard: a menu bar workaround for MacBook Force Touch trackpads whose force
// sensor fires clicks on its own (often a swelling battery pressing on the trackpad).
//
//  - Block false clicks: hardware clicks that arrive while a finger is on the pad
//    (or just lifted) are dropped, and their drags become plain pointer moves.
//    Real taps, read from the raw touch sensor, become clicks instead
//    (1 finger = left, 2 fingers = right). Three-finger drag is let through.
//  - Calm force response: tells the trackpad driver to stop reacting to force. The
//    sensor still reports false presses (they are blocked above), but the driver no
//    longer turns two-finger scrolls into drags, and its pointer freeze after each
//    press happens about half as often.
//  - Smooth pointer (optional, off by default: macOS's speed-dependent pointer acceleration
//    makes it overshoot when you slow down to click): after a press the trackpad driver can still freeze or slow the pointer
//    for about 300 ms (to stop it wobbling while you click). With a faulty sensor that
//    happens constantly, so during that window the pointer is kept where the raw finger
//    motion says it should be, at the speed measured just before the press.
//  - Silence vibration: turns off "SystemActuations" on the trackpad actuator, which
//    stops the haptic tap that every false press triggers. Restored on quit.
//  - Open at login.
//
// Ctrl+Option+Cmd+B toggles click blocking.
// Uses the private MultitouchSupport framework; tested on a 14" MacBook Pro (M2 Pro).
import AppKit
import ApplicationServices
import CoreGraphics
import ServiceManagement

// MARK: - Logging
let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/TrackpadGuard.log")
let logQueue = DispatchQueue(label: "trackpadguard.log")
let logFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return f
}()
func log(_ s: String) {
    let date = Date()
    logQueue.async {
        let line = logFormatter.string(from: date) + " " + s + "\n"
        guard let data = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: logURL)
        }
    }
}
if let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
   (attrs[.size] as? Int ?? 0) > 2_000_000 {
    try? FileManager.default.removeItem(at: logURL)
}

func now() -> Double { ProcessInfo.processInfo.systemUptime }

// MARK: - Settings
let defaults = UserDefaults.standard
defaults.register(defaults: ["blockClicks": true, "silenceVibration": true, "calmForce": true, "smoothPointer": false])
var blockClicks = defaults.bool(forKey: "blockClicks")
var silenceVibration = defaults.bool(forKey: "silenceVibration")
var calmForce = defaults.bool(forKey: "calmForce")
var smoothPointer = defaults.bool(forKey: "smoothPointer")

// MARK: - Tuning
let tapMaxDuration = 0.30     // seconds a tap may last
let tapMaxMove: Float = 0.035 // normalized trackpad distance a tap may move
let tapMaxSize: Float = 1.5   // bigger contacts (palms) never count as taps
let liftGrace = 1.0           // clicks this soon after a lift are macOS's own tap-to-click (a two-finger
                              // tap arrives ~0.3 s late while macOS waits for a possible double tap)
let typingGrace = 0.4         // ignore taps this soon after a key press
let twoFingerLandSpread = 0.15 // both fingers of a two-finger tap must land this close together
let magic: Int64 = 0x5450_4744 // marks our own synthetic events ("TPGD")
let freezeWindow = defaults.object(forKey: "freezeWindow") as? Double ?? 0.45 // driver slow-down after a press
// Only smooth fast movement: macOS slows the pointer for slow, precise finger motion, so a
// speed measured earlier would overshoot while you aim. Normalized trackpad units / second.
let smoothMinSpeed = defaults.object(forKey: "smoothMinSpeed") as? Double ?? 0.25
// Err on the side of less movement: overshooting a click target is worse than a tiny lag.
let smoothGainScale = defaults.object(forKey: "smoothGainScale") as? Double ?? 0.85

// MARK: - Touch state (written on the multitouch thread, guarded by lock)
let lock = NSLock()
var fingersDown = 0
var lastContact: Double = -10
var touchStart: Double = 0
var touchMaxFingers = 0
var touchMaxMove: Float = 0
var touchMaxSize: Float = 0
var touchStartPos: [Int32: (Float, Float)] = [:]
var touchLandTimes: [Int32: Double] = [:]
// Pointer smoothing (also guarded by lock)
var singleFinger: (path: Int32, x: Float, y: Float)?  // when exactly one finger is down
var freezeUntil: Double = 0              // set when a press is blocked
var recentFinger: [(t: Double, path: Int32, x: Float, y: Float)] = [] // last ~0.25 s of the single finger

// Main-thread state
var blockedCount = 0
var tapClickCount = 0
var smoothedFreezes = 0
var smoothedPoints = 0.0
var gTap: CFMachPort?
var suppressL = false
var suppressR = false
var appDelegate: AppDelegate?
var lastSessionHandled = false // did we already click for the last touch?

// MARK: - MultitouchSupport (private framework)
typealias MTCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
typealias MTCreateListFn = @convention(c) () -> Unmanaged<CFArray>?
typealias MTCallbackFn = @convention(c) (UnsafeMutableRawPointer, MTCallback) -> Void
typealias MTStartFn = @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32
typealias MTVoidFn = @convention(c) (UnsafeMutableRawPointer) -> Void
typealias MTBoolFn = @convention(c) (UnsafeMutableRawPointer) -> Bool
typealias MTPtrFn = @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
typealias MTStatusFn = @convention(c) (UnsafeMutableRawPointer) -> Int32
typealias MTSetBoolFn = @convention(c) (UnsafeMutableRawPointer, Bool) -> Int32

struct MTFunctions {
    let createList: MTCreateListFn
    let register: MTCallbackFn
    let unregister: MTCallbackFn?
    let start: MTStartFn
    let stop: MTVoidFn?
    let isBuiltIn: MTBoolFn
    let getActuator: MTPtrFn?
    let actuatorOpen: MTStatusFn?
    let actuatorClose: MTStatusFn?
    let actuatorIsOpen: MTBoolFn?
    let getSystemActuations: MTBoolFn?
    let setSystemActuations: MTSetBoolFn?
    let getForceResponse: MTBoolFn?
    let setForceResponse: MTSetBoolFn?

    static func load() -> MTFunctions? {
        guard let h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW) else { return nil }
        func sym<T>(_ name: String, _ t: T.Type) -> T? { dlsym(h, name).map { unsafeBitCast($0, to: t) } }
        guard let createList = sym("MTDeviceCreateList", MTCreateListFn.self),
              let register = sym("MTRegisterContactFrameCallback", MTCallbackFn.self),
              let start = sym("MTDeviceStart", MTStartFn.self),
              let isBuiltIn = sym("MTDeviceIsBuiltIn", MTBoolFn.self) else { return nil }
        return MTFunctions(
            createList: createList, register: register,
            unregister: sym("MTUnregisterContactFrameCallback", MTCallbackFn.self),
            start: start, stop: sym("MTDeviceStop", MTVoidFn.self), isBuiltIn: isBuiltIn,
            getActuator: sym("MTDeviceGetMTActuator", MTPtrFn.self),
            actuatorOpen: sym("MTActuatorOpen", MTStatusFn.self),
            actuatorClose: sym("MTActuatorClose", MTStatusFn.self),
            actuatorIsOpen: sym("MTActuatorIsOpen", MTBoolFn.self),
            getSystemActuations: sym("MTActuatorGetSystemActuationsEnabled", MTBoolFn.self),
            setSystemActuations: sym("MTActuatorSetSystemActuationsEnabled", MTSetBoolFn.self),
            getForceResponse: sym("MTDeviceGetSystemForceResponseEnabled", MTBoolFn.self),
            setForceResponse: sym("MTDeviceSetSystemForceResponseEnabled", MTSetBoolFn.self))
    }
}

let mtCallback: MTCallback = { _, data, n, _, _ in
    // MTTouch is 96 bytes: pathIndex @16, state @20, normalized x/y @32/@36, size @48.
    // States 3...5 mean the finger is touching (make, touching, breaking).
    var active = 0
    var maxSize: Float = 0
    var points: [(Int32, Float, Float)] = []
    if let data = data, n > 0 {
        for i in 0..<Int(n) {
            let b = data.advanced(by: i * 96)
            let state = b.load(fromByteOffset: 20, as: Int32.self)
            guard state >= 3 && state <= 5 else { continue }
            active += 1
            points.append((b.load(fromByteOffset: 16, as: Int32.self),
                           b.load(fromByteOffset: 32, as: Float.self),
                           b.load(fromByteOffset: 36, as: Float.self)))
            maxSize = max(maxSize, b.load(fromByteOffset: 48, as: Float.self))
        }
    }
    let t = now()
    var tap = 0
    var tapStarted = 0.0
    var ended = false
    lock.lock()
    singleFinger = active == 1 ? (points[0].0, points[0].1, points[0].2) : nil
    if let f = singleFinger {
        if let last = recentFinger.last, last.path != f.path { recentFinger.removeAll() }
        recentFinger.append((t, f.path, f.x, f.y))
        if let first = recentFinger.first, t - first.t > 0.25 { recentFinger.removeFirst() }
    } else {
        recentFinger.removeAll()
    }
    let smooth = t < freezeUntil ? singleFinger : nil
    if active > 0 {
        if fingersDown == 0 {
            touchStart = t
            touchMaxFingers = 0
            touchMaxMove = 0
            touchMaxSize = 0
            touchStartPos.removeAll()
            touchLandTimes.removeAll()
        }
        for (path, x, y) in points {
            if let s = touchStartPos[path] {
                touchMaxMove = max(touchMaxMove, max(abs(x - s.0), abs(y - s.1)))
            } else {
                touchStartPos[path] = (x, y)
                touchLandTimes[path] = t
            }
        }
        touchMaxFingers = max(touchMaxFingers, active)
        touchMaxSize = max(touchMaxSize, maxSize)
        lastContact = t
    } else if fingersDown > 0 {
        ended = true
        if t - touchStart < tapMaxDuration && touchMaxMove < tapMaxMove && touchMaxSize < tapMaxSize {
            let lands = touchLandTimes.values
            let together = (lands.max() ?? 0) - (lands.min() ?? 0) < twoFingerLandSpread
            tap = touchMaxFingers == 1 ? 1 : (touchMaxFingers == 2 && together ? 2 : 0)
            tapStarted = touchStart
        }
    }
    fingersDown = active
    lock.unlock()
    if active == 0 && ended {
        DispatchQueue.main.async {
            lastSessionHandled = false
            if tap != 0 { lastSessionHandled = synthesizeClick(right: tap == 2, touchStarted: tapStarted) }
        }
    }
    if let f = smooth {
        DispatchQueue.main.async { smoothStep(path: f.path, x: f.x, y: f.y) }
    }
    return 0
}

// MARK: - Pointer smoothing
// While a freeze window is open, the pointer should be at
//   start position + gain * (finger travel since the press),
// with the gain measured from the movement just before the press. Whatever the
// driver does not deliver is topped up; the pointer is never pulled backwards.
var freeze: (t0: Double, path: Int32, fx: Float, fy: Float, c0: CGPoint, gx: Double, gy: Double)?

func beginFreeze() {
    guard smoothPointer else { freeze = nil; return }
    let t = now()
    lock.lock()
    let f = singleFinger
    freezeUntil = t + freezeWindow
    // Was this finger already moving? Look at the raw sensor over the last ~0.12 s.
    var moving = false
    if f != nil, t - touchStart > 0.12, let last = recentFinger.last,
       let old = recentFinger.first(where: { last.t - $0.t <= 0.12 }), last.t - old.t >= 0.05 {
        moving = hypot(Double(last.x - old.x), Double(last.y - old.y)) / (last.t - old.t) > smoothMinSpeed
    }
    lock.unlock()
    // A finger that was not already moving is tapping or resting: keep the driver's
    // freeze, it is what stops the pointer wobbling during a click.
    guard let f = f, moving, let c = CGEvent(source: nil)?.location else { freeze = nil; return }
    let (gx, gy, how) = currentGain()
    freeze = (t, f.path, f.x, f.y, c, gx * smoothGainScale, gy * smoothGainScale)
    log(String(format: "freeze while moving: gain x=%.0f y=%.0f (%@)", gx, gy, how))
}

func smoothStep(path: Int32, x: Float, y: Float) {
    guard blockClicks, gTap != nil, let fz = freeze, now() - fz.t0 < freezeWindow else { return }
    // A different finger (one of two lifted) is not movement: stop smoothing.
    guard path == fz.path else { freeze = nil; return }
    guard let c = CGEvent(source: nil)?.location else { return }
    let ex = Double(x - fz.fx) * fz.gx, ey = Double(y - fz.fy) * fz.gy
    var dx = ex - (c.x - fz.c0.x), dy = ey - (c.y - fz.c0.y)
    if dx * ex < 0 { dx = 0 } // already ahead on this axis: never pull back
    if dy * ey < 0 { dy = 0 }
    guard abs(dx) >= 0.5 || abs(dy) >= 0.5 else { return }
    let target = clampToDisplays(CGPoint(x: c.x + dx, y: c.y + dy), from: c)
    guard let e = CGEvent(mouseEventSource: synthSource, mouseType: .mouseMoved, mouseCursorPosition: target, mouseButton: .left) else { return }
    e.setIntegerValueField(.eventSourceUserData, value: magic)
    e.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx.rounded()))
    e.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy.rounded()))
    e.flags = CGEventSource.flagsState(.combinedSessionState)
    e.post(tap: .cghidEventTap)
    if smoothedPoints == 0 || now() - fz.t0 < 0.02 { smoothedFreezes += 1 }
    smoothedPoints += hypot(dx, dy)
}

// Pointer speed: a short history of (finger, pointer) samples taken during normal
// movement, plus a long-term average as a fallback.
var speedHistory: [(t: Double, path: Int32, x: Float, y: Float, c: CGPoint)] = []
var avgGainX = 1000.0, avgGainY = -700.0
func learnPointerSpeed() {
    let t = now()
    lock.lock()
    let finger = singleFinger
    let frozen = t < freezeUntil + 0.1
    lock.unlock()
    guard let f = finger, !frozen, let c = CGEvent(source: nil)?.location else { speedHistory.removeAll(); return }
    if let p = speedHistory.last, p.path != f.path { speedHistory.removeAll() }
    if let p = speedHistory.last {
        let fdx = Double(f.x - p.x), fdy = Double(f.y - p.y)
        if abs(fdx) > 0.004 { let g = Double(c.x - p.c.x) / fdx; if abs(g) > 100 && abs(g) < 8000 { avgGainX = avgGainX * 0.9 + g * 0.1 } }
        if abs(fdy) > 0.004 { let g = Double(c.y - p.c.y) / fdy; if abs(g) > 100 && abs(g) < 8000 { avgGainY = avgGainY * 0.9 + g * 0.1 } }
    }
    speedHistory.append((t, f.path, f.x, f.y, c))
    speedHistory.removeAll { t - $0.t > 0.5 }
}

// Pointer speed from the movement just before now, or the long-term average.
func currentGain() -> (Double, Double, String) {
    guard let last = speedHistory.last, now() - last.t < 0.12,
          let first = speedHistory.first(where: { last.t - $0.t <= 0.35 }), last.t - first.t >= 0.09 else {
        return (avgGainX, avgGainY, "average")
    }
    let fdx = Double(last.x - first.x), fdy = Double(last.y - first.y)
    var gx = avgGainX, gy = avgGainY
    if abs(fdx) > 0.01 { let g = Double(last.c.x - first.c.x) / fdx; if abs(g) > 100 && abs(g) < 8000 { gx = g } }
    if abs(fdy) > 0.01 { let g = Double(last.c.y - first.c.y) / fdy; if abs(g) > 100 && abs(g) < 8000 { gy = g } }
    return (gx, gy, "recent")
}

func clampToDisplays(_ p: CGPoint, from cur: CGPoint) -> CGPoint {
    var count: UInt32 = 0
    var ids = [CGDirectDisplayID](repeating: 0, count: 8)
    if CGGetDisplaysWithPoint(p, 8, &ids, &count) == .success, count > 0 { return p }
    guard CGGetDisplaysWithPoint(cur, 8, &ids, &count) == .success, count > 0 else { return cur }
    let b = CGDisplayBounds(ids[0])
    return CGPoint(x: min(max(p.x, b.minX), b.maxX - 1), y: min(max(p.y, b.minY), b.maxY - 1))
}

// MARK: - Built-in trackpad: touch stream + actuator
final class Trackpad {
    let mt: MTFunctions
    var list: CFArray?
    var device: UnsafeMutableRawPointer?
    var actuator: UnsafeMutableRawPointer?

    init(mt: MTFunctions) { self.mt = mt }

    func attach() {
        detach(restoreVibration: false)
        guard let arr = mt.createList()?.takeRetainedValue() else { log("no multitouch devices"); return }
        list = arr
        for i in 0..<CFArrayGetCount(arr) {
            guard let raw = CFArrayGetValueAtIndex(arr, i) else { continue }
            let dev = UnsafeMutableRawPointer(mutating: raw)
            guard mt.isBuiltIn(dev) else { continue }
            mt.register(dev, mtCallback)
            _ = mt.start(dev, 0)
            device = dev
            if let act = mt.getActuator?(dev), let open = mt.actuatorOpen {
                let st = (mt.actuatorIsOpen?(act) ?? false) ? 0 : open(act)
                if st == 0 { actuator = act } else { log(String(format: "actuator open failed 0x%08x", UInt32(bitPattern: st))) }
            }
            log("attached to built-in trackpad (actuator: \(actuator != nil ? "yes" : "no"))")
            applyVibration()
            applyForceResponse()
            return
        }
        log("built-in trackpad not found")
    }

    func detach(restoreVibration: Bool) {
        if let act = actuator {
            if restoreVibration { _ = mt.setSystemActuations?(act, true); log("vibration restored") }
            if mt.actuatorIsOpen?(act) ?? false { _ = mt.actuatorClose?(act) }
        }
        if let dev = device {
            if restoreVibration, calmForce { _ = mt.setForceResponse?(dev, true); log("force response restored") }
            mt.unregister?(dev, mtCallback)
            mt.stop?(dev)
        }
        actuator = nil
        device = nil
        list = nil
        lock.lock(); fingersDown = 0; lock.unlock()
    }

    var vibrationOn: Bool? {
        guard let act = actuator, let get = mt.getSystemActuations else { return nil }
        return get(act)
    }

    func applyVibration() {
        guard let act = actuator, let set = mt.setSystemActuations else { return }
        let st = set(act, !silenceVibration)
        log(String(format: "vibration %@ -> 0x%08x", silenceVibration ? "off" : "on", UInt32(bitPattern: st)))
    }

    var forceResponseOn: Bool? {
        guard let dev = device, let get = mt.getForceResponse else { return nil }
        return get(dev)
    }

    func applyForceResponse() {
        guard let dev = device, let set = mt.setForceResponse else { return }
        let st = set(dev, !calmForce)
        log(String(format: "force response %@ -> 0x%08x", calmForce ? "off" : "on", UInt32(bitPattern: st)))
    }

    // Timer: re-attach if the actuator went away, re-apply if macOS turned vibration back on.
    func check() {
        guard device != nil else { attach(); return }
        if let act = actuator, !(mt.actuatorIsOpen?(act) ?? true) { attach(); return }
        if silenceVibration, vibrationOn == true {
            log("vibration was turned back on; re-applying")
            applyVibration()
        }
        if calmForce, forceResponseOn == true {
            log("force response was turned back on; re-applying")
            applyForceResponse()
        }
    }
}

// MARK: - Synthetic clicks from taps
let synthSource = CGEventSource(stateID: .privateState)
var lastSynth: (t: Double, loc: CGPoint, right: Bool) = (-10, .zero, false)
var synthClickState: Int64 = 1

// fromSystem: macOS itself recognized the tap (its own tap-to-click), so trust it.
@discardableResult
func synthesizeClick(right: Bool, touchStarted: Double, fromSystem: Bool = false) -> Bool {
    guard blockClicks, gTap != nil else { return false }
    if CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown) < typingGrace {
        log("tap ignored (typing)")
        return false
    }
    if !fromSystem,
       CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .scrollWheel) < now() - touchStarted + 0.05 {
        log("tap ignored (scrolling); leaving it to macOS")
        return false
    }
    let loc = CGEvent(source: nil)?.location ?? .zero
    let t = now()
    if right == lastSynth.right && t - lastSynth.t < NSEvent.doubleClickInterval
        && hypot(loc.x - lastSynth.loc.x, loc.y - lastSynth.loc.y) < 8 {
        synthClickState = min(synthClickState + 1, 3)
    } else {
        synthClickState = 1
    }
    lastSynth = (t, loc, right)
    let (downType, upType, button): (CGEventType, CGEventType, CGMouseButton) =
        right ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
    guard let down = CGEvent(mouseEventSource: synthSource, mouseType: downType, mouseCursorPosition: loc, mouseButton: button),
          let up = CGEvent(mouseEventSource: synthSource, mouseType: upType, mouseCursorPosition: loc, mouseButton: button) else { return false }
    let flags = CGEventSource.flagsState(.combinedSessionState)
    for e in [down, up] {
        e.setIntegerValueField(.eventSourceUserData, value: magic)
        e.setIntegerValueField(.mouseEventClickState, value: synthClickState)
        e.flags = flags
    }
    down.post(tap: .cghidEventTap)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.015) { up.post(tap: .cghidEventTap) }
    tapClickCount += 1
    log("\(fromSystem ? "macOS tap" : "tap") -> \(right ? "right" : "left") click x\(synthClickState)")
    return true
}

// MARK: - Scroll recovery
let naturalScrolling = UserDefaults(suiteName: ".GlobalPreferences")?.object(forKey: "com.apple.swipescrolldirection") as? Bool ?? true
var recoveredScrolls = 0

func postScroll(dx: Int64, dy: Int64) {
    guard dx != 0 || dy != 0 else { return }
    // Natural scrolling: content follows the fingers (fingers down -> content down).
    let sign: Int32 = naturalScrolling ? 1 : -1
    guard let e = CGEvent(scrollWheelEvent2Source: synthSource, units: .pixel, wheelCount: 2,
                          wheel1: sign * Int32(clamping: dy), wheel2: sign * Int32(clamping: dx), wheel3: 0) else { return }
    e.setIntegerValueField(.eventSourceUserData, value: magic)
    e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    e.post(tap: .cghidEventTap)
    recoveredScrolls += 1
    if recoveredScrolls % 20 == 1 { log("turned a false-press drag back into scrolling (\(recoveredScrolls) events so far)") }
}

// MARK: - Event tap
let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    let pass = Unmanaged.passUnretained(event)
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = gTap { CGEvent.tapEnable(tap: t, enable: true) }
        log("event tap re-enabled")
        return pass
    }
    if event.getIntegerValueField(.eventSourceUserData) == magic { return pass }

    switch type {
    case .keyDown:
        let f = event.flags
        if event.getIntegerValueField(.keyboardEventKeycode) == 11, // B
           f.contains(.maskControl), f.contains(.maskAlternate), f.contains(.maskCommand) {
            DispatchQueue.main.async { appDelegate?.setBlockClicks(!blockClicks) }
            return nil
        }
    case .leftMouseUp:
        if suppressL { suppressL = false; return nil }
    case .rightMouseUp:
        if suppressR { suppressR = false; return nil }
    case .leftMouseDragged, .rightMouseDragged:
        if (type == .leftMouseDragged && suppressL) || (type == .rightMouseDragged && suppressR) {
            lock.lock(); let fingers = fingersDown; lock.unlock()
            if fingers >= 2 {
                // A false press during a two-finger scroll makes the driver send drags instead
                // of scrolling: turn them back into scrolling rather than moving the pointer.
                postScroll(dx: event.getIntegerValueField(.mouseEventDeltaX), dy: event.getIntegerValueField(.mouseEventDeltaY))
                return nil
            }
            event.type = .mouseMoved
        }
    case .leftMouseDown, .rightMouseDown:
        let left = type == .leftMouseDown
        guard blockClicks else { return pass }
        lock.lock()
        let fingers = fingersDown
        let sinceLift = now() - lastContact
        let maxFingers = touchMaxFingers
        lock.unlock()
        let onPad = fingers > 0 || sinceLift < liftGrace
        if onPad && !(left && maxFingers >= 3) {
            if left { suppressL = true } else { suppressR = true }
            if fingers == 0 {
                // No finger on the pad: this is macOS's own tap-to-click arriving after a lift.
                // Click for it only if we did not already click for this touch.
                if !lastSessionHandled {
                    lastSessionHandled = synthesizeClick(right: !left, touchStarted: 0, fromSystem: true)
                }
                return nil
            }
            blockedCount += 1
            beginFreeze()
            log("blocked \(left ? "left" : "right") press (fingers=\(fingers), msSinceLift=\(Int(sinceLift * 1000)))")
            return nil
        }
        if left { suppressL = false } else { suppressR = false }
        log("passed \(left ? "left" : "right") click (fingers=\(fingers), maxFingers=\(maxFingers))")
    default:
        break
    }
    return pass
}

func createTap() -> Bool {
    var mask: CGEventMask = 0
    for t: CGEventType in [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                           .leftMouseDragged, .rightMouseDragged, .keyDown] {
        mask |= CGEventMask(1) << CGEventMask(t.rawValue)
    }
    guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                      eventsOfInterest: mask, callback: tapCallback, userInfo: nil) else { return false }
    gTap = tap
    let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    return true
}

// MARK: - Menu bar app
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var item: NSStatusItem!
    var trackpad: Trackpad?
    let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let blockItem = NSMenuItem(title: "Block false clicks (Ctrl+Option+Cmd+B)", action: #selector(toggleBlock), keyEquivalent: "")
    let silenceItem = NSMenuItem(title: "Silence trackpad vibration", action: #selector(toggleSilence), keyEquivalent: "")
    let calmItem = NSMenuItem(title: "Turn off force response (fixes lag and scrolling)", action: #selector(toggleCalm), keyEquivalent: "")
    let smoothItem = NSMenuItem(title: "Smooth pointer after false presses (experimental)", action: #selector(toggleSmooth), keyEquivalent: "")
    let loginItem = NSMenuItem(title: "Open at login", action: #selector(toggleLogin), keyEquivalent: "")
    let permissionItem = NSMenuItem(title: "Grant Accessibility permission...", action: #selector(openAccessibility), keyEquivalent: "")
    var timer: Timer?
    var learnTimer: Timer?
    var trustTimer: Timer?
    var sigterm: DispatchSourceSignal?
    var tapFailures = 0
    let relaunched = CommandLine.arguments.contains("--relaunched")

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        for i in [blockItem, silenceItem, calmItem, smoothItem, loginItem, permissionItem] {
            i.target = self
            menu.addItem(i)
        }
        menu.addItem(.separator())
        let logItem = NSMenuItem(title: "Open Log", action: #selector(openLog), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)
        let quitItem = NSMenuItem(title: "Quit TrackpadGuard", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        item.menu = menu
        updateIcon()

        if let mt = MTFunctions.load() {
            let tp = Trackpad(mt: mt)
            trackpad = tp
            tp.attach()
            timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in tp.check() }
            learnTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in learnPointerSpeed() }
        } else {
            log("could not load MultitouchSupport")
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                log("woke from sleep; re-attaching")
                self?.trackpad?.attach()
            }
        }
        // Restore vibration when killed with SIGTERM (pkill, logout).
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler { NSApp.terminate(nil) }
        src.resume()
        sigterm = src

        if blockClicks { requestTapWhenTrusted(prompt: true) }
    }

    func requestTapWhenTrusted(prompt: Bool) {
        guard gTap == nil else { return }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        if AXIsProcessTrustedWithOptions(opts) {
            startTap()
            return
        }
        log("waiting for Accessibility permission")
        trustTimer?.invalidate()
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            if AXIsProcessTrusted() {
                t.invalidate()
                self?.startTap()
            }
        }
    }

    func startTap() {
        if createTap() {
            updateIcon()
            NSSound(named: "Pop")?.play()
            log("click blocking active")
            return
        }
        tapFailures += 1
        log("event tap could not be created (attempt \(tapFailures))")
        if tapFailures == 3 && !relaunched {
            // Permission granted while running sometimes needs a fresh process.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-n", Bundle.main.bundlePath, "--args", "--relaunched"]
            try? p.run()
            NSApp.terminate(nil)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.startTap() }
    }

    func setBlockClicks(_ on: Bool) {
        blockClicks = on
        defaults.set(on, forKey: "blockClicks")
        suppressL = false
        suppressR = false
        if on { requestTapWhenTrusted(prompt: true) }
        NSSound(named: on ? "Pop" : "Bottle")?.play()
        log(on ? "click blocking on" : "click blocking off")
        updateIcon()
    }

    func updateIcon() {
        guard let button = item?.button else { return }
        let symbol = blockClicks ? (gTap == nil ? "exclamationmark.triangle" : "hand.tap") : "hand.raised.slash"
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "TrackpadGuard") {
            img.isTemplate = true
            button.image = img
            button.title = ""
        } else {
            button.title = "TG"
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        let trusted = AXIsProcessTrusted()
        if !blockClicks {
            statusLine.title = "Click blocking paused"
        } else if gTap == nil {
            statusLine.title = "Needs Accessibility permission"
        } else {
            statusLine.title = "Blocked \(blockedCount) false clicks, smoothed \(smoothedFreezes) freezes"
        }
        blockItem.state = blockClicks ? .on : .off
        silenceItem.state = silenceVibration ? .on : .off
        silenceItem.isEnabled = trackpad?.actuator != nil
        calmItem.state = calmForce ? .on : .off
        smoothItem.state = smoothPointer ? .on : .off
        calmItem.isEnabled = trackpad?.mt.setForceResponse != nil
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        permissionItem.isHidden = trusted
    }

    @objc func toggleBlock() { setBlockClicks(!blockClicks) }

    @objc func toggleSilence() {
        silenceVibration.toggle()
        defaults.set(silenceVibration, forKey: "silenceVibration")
        trackpad?.applyVibration()
    }

    @objc func toggleCalm() {
        calmForce.toggle()
        defaults.set(calmForce, forKey: "calmForce")
        trackpad?.applyForceResponse()
    }

    @objc func toggleSmooth() {
        smoothPointer.toggle()
        defaults.set(smoothPointer, forKey: "smoothPointer")
        freeze = nil
    }

    @objc func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
                log("open at login: off")
            } else {
                try service.register()
                log("open at login: on (\(service.status.rawValue))")
            }
        } catch {
            log("open at login failed: \(error.localizedDescription)")
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    @objc func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        requestTapWhenTrusted(prompt: false)
    }

    @objc func openLog() { NSWorkspace.shared.open(logURL) }
    @objc func quit() { NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        trackpad?.detach(restoreVibration: true)
        log("quit")
    }
}

// MARK: - Main
let bundleID = Bundle.main.bundleIdentifier ?? "io.github.bazl-e.trackpadguard"
let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
if !others.isEmpty && !CommandLine.arguments.contains("--relaunched") {
    // Two copies would turn every tap into two clicks.
    exit(0)
}
log("launching (pid \(ProcessInfo.processInfo.processIdentifier))")
let app = NSApplication.shared
let delegate = AppDelegate()
appDelegate = delegate
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
