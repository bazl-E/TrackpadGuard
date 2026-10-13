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
//  - Smooth pointer (optional): after a press the trackpad driver can still stop the pointer
//    for ~300 ms. While it is stopped and the finger keeps moving, the pointer is moved frame
//    by frame at the speed macOS itself uses for that finger speed (learned per speed band),
//    and it stops the moment the driver moves the pointer again, so it never overshoots.
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
let typingGrace = 0.25        // ignore taps this soon after a key press (palm brushes seen at 8-178 ms)
let twoFingerLandSpread = 0.15 // both fingers of a two-finger tap must land this close together
let magic: Int64 = 0x5450_4744 // marks our own synthetic events ("TPGD")
let sensorScrollWindow = 1.0  // max length of one sensor-scroll episode after a two-finger false press
let scrollGainY = defaults.object(forKey: "scrollGainY") as? Double ?? 1800 // pixels per trackpad height
let scrollGainX = scrollGainY * 1.6 // the trackpad is ~1.6x wider than tall
let freezeWindow = defaults.object(forKey: "freezeWindow") as? Double ?? 0.45 // driver slow-down after a press

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
var touchPresses = 0 // false presses blocked during the current touch
// Pointer smoothing (also guarded by lock)
var singleFinger: (path: Int32, x: Float, y: Float)?  // when exactly one finger is down
var freezeUntil: Double = 0              // set when a press is blocked
// Scrolling from the raw sensor while a false press has frozen a two-finger scroll.
var sensorScrollUntil: Double = 0
var prevPair: (x: Float, y: Float)?
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
    var sensorScroll: (Double, Double)?
    if active == 2 {
        let pair = ((points[0].1 + points[1].1) / 2, (points[0].2 + points[1].2) / 2)
        if t < sensorScrollUntil, let p = prevPair {
            sensorScroll = (Double(pair.0 - p.x) * scrollGainX, Double(pair.1 - p.y) * scrollGainY)
        }
        prevPair = (pair.0, pair.1)
    } else {
        prevPair = nil
        sensorScrollUntil = 0 // episode ends when the two-finger contact ends
    }
    if active > 0 {
        if fingersDown == 0 {
            touchStart = t
            touchMaxFingers = 0
            touchMaxMove = 0
            touchMaxSize = 0
            touchStartPos.removeAll()
            touchLandTimes.removeAll()
            touchPresses = 0
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
        // Diagnostics: a short, mostly still touch that had a false press but made no click
        // is probably a click attempt we missed; record why it did not count as a tap.
        let dur = t - touchStart
        if tap == 0 && touchPresses > 0 && dur < 1.0 && touchMaxMove < 0.1 && touchMaxFingers <= 2 {
            var why: [String] = []
            if dur >= tapMaxDuration { why.append("too long") }
            if touchMaxMove >= tapMaxMove { why.append("moved") }
            if touchMaxSize >= tapMaxSize { why.append("large contact") }
            if touchMaxFingers == 2 && why.isEmpty { why.append("fingers landed apart") }
            log(String(format: "no click for touch: %.0f ms, moved %.3f, %d finger(s), %d press(es) [%@]",
                       dur * 1000, touchMaxMove, touchMaxFingers, touchPresses, why.joined(separator: ", ")))
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
    if let (dx, dy) = sensorScroll {
        // Trackpad y grows upward; screen-style deltas grow downward.
        DispatchQueue.main.async { postSensorScroll(dx: dx, dy: -dy) }
    }
    return 0
}

// MARK: - Pointer smoothing (experimental)
// After a false press the driver may stop moving the pointer for up to ~300 ms. While the
// driver has sent no pointer motion for `stallTime` and the finger is clearly moving, the
// pointer is moved frame by frame from the raw finger motion, at the gain macOS itself uses
// for that finger speed (learned per speed band during normal movement). As soon as the
// driver moves the pointer again, filling stops: it only ever replaces missing motion.
let stallTime = 0.025
let fillMinSpeed = 0.08       // trackpad heights per second; slower is aiming or click wobble
let trackpadAspect = 1.6      // width / height, to measure finger motion in equal units
let speedBandEdges: [Double] = [0.05, 0.1, 0.2, 0.4, 0.8, 1.6] // trackpad heights per second
var bandGain = [Double](repeating: 0, count: 7)   // pointer points per trackpad height
var bandSamples = [Int](repeating: 0, count: 7)
var lastDriverMotion: Double = 0                 // main thread: last real pointer motion event
var fillPrev: (path: Int32, t: Double, x: Float, y: Float)?
var freeze: (t0: Double, path: Int32)?

func speedBand(_ v: Double) -> Int { speedBandEdges.firstIndex { v < $0 } ?? speedBandEdges.count }

func gainFor(speed v: Double) -> Double? {
    let b = speedBand(v)
    if bandSamples[b] >= 5 { return bandGain[b] }
    // Nearest band with enough data.
    for d in 1..<bandGain.count {
        for c in [b - d, b + d] where c >= 0 && c < bandGain.count && bandSamples[c] >= 5 { return bandGain[c] }
    }
    return nil
}

func beginFreeze() {
    guard smoothPointer else { freeze = nil; return }
    let t = now()
    lock.lock()
    let f = singleFinger
    freezeUntil = t + freezeWindow
    lock.unlock()
    if let f = f { freeze = (t, f.path); fillPrev = nil } else { freeze = nil }
}

func smoothStep(path: Int32, x: Float, y: Float) {
    guard smoothPointer, blockClicks, gTap != nil, let fz = freeze else { return }
    let t = now()
    guard t - fz.t0 < freezeWindow, path == fz.path else { freeze = nil; return }
    defer { fillPrev = (path, t, x, y) }
    guard let p = fillPrev, p.path == path, t - p.t > 0.001, t - p.t < 0.05 else { return }
    let dx = Double(x - p.x) * trackpadAspect, dy = Double(y - p.y) // trackpad heights
    let dist = hypot(dx, dy), speed = dist / (t - p.t)
    // The driver is moving the pointer itself, or the finger is barely moving: leave it alone.
    guard t - lastDriverMotion > stallTime, speed > fillMinSpeed, let g = gainFor(speed: speed) else { return }
    let mx = dx * g, my = -dy * g // trackpad y grows upward, screen y downward
    guard let c = CGEvent(source: nil)?.location else { return }
    let target = clampToDisplays(CGPoint(x: c.x + mx, y: c.y + my), from: c)
    guard let e = CGEvent(mouseEventSource: synthSource, mouseType: .mouseMoved, mouseCursorPosition: target, mouseButton: .left) else { return }
    e.setIntegerValueField(.eventSourceUserData, value: magic)
    e.setIntegerValueField(.mouseEventDeltaX, value: Int64(mx.rounded()))
    e.setIntegerValueField(.mouseEventDeltaY, value: Int64(my.rounded()))
    e.flags = CGEventSource.flagsState(.combinedSessionState)
    e.post(tap: .cghidEventTap)
    if smoothedPoints == 0 || fz.t0 != lastSmoothedFreezeStart { smoothedFreezes += 1; lastSmoothedFreezeStart = fz.t0 }
    smoothedPoints += hypot(mx, my)
}
var lastSmoothedFreezeStart = 0.0

// Learn macOS's pointer gain per finger-speed band from normal movement (no recent press).
var learnPrev: (t: Double, path: Int32, x: Float, y: Float, c: CGPoint)?
func learnPointerSpeed() {
    let t = now()
    lock.lock()
    let finger = singleFinger
    let frozen = t < freezeUntil + 0.1
    lock.unlock()
    guard let f = finger, !frozen, let c = CGEvent(source: nil)?.location else { learnPrev = nil; return }
    defer { learnPrev = (t, f.path, f.x, f.y, c) }
    guard let p = learnPrev, p.path == f.path, t - p.t < 0.15 else { return }
    let dist = hypot(Double(f.x - p.x) * trackpadAspect, Double(f.y - p.y))
    guard dist > 0.003 else { return }
    let g = hypot(Double(c.x - p.c.x), Double(c.y - p.c.y)) / dist
    guard g > 100 && g < 10000 else { return }
    let b = speedBand(dist / (t - p.t))
    bandGain[b] = bandSamples[b] == 0 ? g : bandGain[b] * 0.85 + g * 0.15
    bandSamples[b] += 1
    if bandSamples[b] == 5 { log(String(format: "learned pointer gain for speed band %d: %.0f", b, bandGain[b])) }
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
    let sinceKey = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
    if sinceKey < typingGrace {
        log(String(format: "tap ignored (typing, %.0f ms after a key)", sinceKey * 1000))
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
// Where the pointer was when a false press turned a scroll into a drag. The driver keeps
// adding the drag motion to its own pointer position, so when the episode ends the pointer
// is warped back here; otherwise it would jump by the whole accumulated distance.
var scrollPin: CGPoint?

func endScrollPin() {
    guard let pin = scrollPin else { return }
    scrollPin = nil
    CGWarpMouseCursorPosition(pin)
    CGAssociateMouseAndMouseCursorPosition(1) // no input pause after the warp
    log("pointer kept in place after a false press during scrolling")
}
let naturalScrolling = UserDefaults(suiteName: ".GlobalPreferences")?.object(forKey: "com.apple.swipescrolldirection") as? Bool ?? true
var recoveredScrolls = 0

var scrollRemainder = (x: 0.0, y: 0.0)
func postSensorScroll(dx: Double, dy: Double) {
    let x = dx + scrollRemainder.x, y = dy + scrollRemainder.y
    let ix = x.rounded(.towardZero), iy = y.rounded(.towardZero)
    scrollRemainder = (x - ix, y - iy)
    postScroll(dx: Int64(ix), dy: Int64(iy))
}

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
    if recoveredScrolls % 20 == 1 { log("scrolling from the sensor during a false press (\(recoveredScrolls) events so far)") }
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
        if suppressL { suppressL = false; endScrollPin(); return nil }
    case .rightMouseUp:
        if suppressR { suppressR = false; endScrollPin(); return nil }
    case .mouseMoved:
        lastDriverMotion = now()
    case .leftMouseDragged, .rightMouseDragged:
        lastDriverMotion = now()
        if (type == .leftMouseDragged && suppressL) || (type == .rightMouseDragged && suppressR) {
            lock.lock(); let fingers = fingersDown; lock.unlock()
            if fingers >= 2 {
                // A false press during a two-finger scroll makes the driver freeze, then send
                // drags instead of scrolling. Scrolling comes from the raw sensor meanwhile
                // (see the multitouch callback); the drags must not move the pointer.
                if scrollPin == nil { scrollPin = CGEvent(source: nil)?.location }
                event.type = .mouseMoved
                if let pin = scrollPin { event.location = pin }
                event.setIntegerValueField(.mouseEventDeltaX, value: 0)
                event.setIntegerValueField(.mouseEventDeltaY, value: 0)
                return pass
            }
            if scrollPin != nil {
                // Fingers went from two to one during the press: resync before moving again.
                endScrollPin()
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
            lock.lock(); touchPresses += 1; lock.unlock()
            beginFreeze()
            if fingers == 2 {
                lock.lock(); sensorScrollUntil = now() + sensorScrollWindow; lock.unlock()
                scrollRemainder = (0, 0)
            }
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
    for t: CGEventType in [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .mouseMoved,
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
