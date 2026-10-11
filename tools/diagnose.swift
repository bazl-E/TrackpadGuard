// Trackpad diagnostic: records raw multitouch contacts (MultitouchSupport) and
// click / pressure events (CGEventTap, listen-only) per test phase.
import Foundation
import AppKit
import CoreGraphics
import IOKit.ps

setvbuf(stdout, nil, _IOLBF, 0)

// ---------- shared state ----------
struct Ev { let t: Double; let kind: String; let a: Double; let b: Double; let x: Double; let y: Double; let phase: String }
let lock = NSLock()
var phaseName = "warmup"
var events: [Ev] = []
var currentFingers = 0
var lastContactTime: Double = -1
var lastStage = 0
var moveCount: [String: Int] = [:]
var dragCount: [String: Int] = [:]
var mtFrameCount: [String: Int] = [:]
var hoverFrameCount: [String: Int] = [:]
var gTap: CFMachPort?

func now() -> Double { ProcessInfo.processInfo.systemUptime }
func record(_ kind: String, _ a: Double = 0, _ b: Double = 0, _ x: Double = 0, _ y: Double = 0) {
    events.append(Ev(t: now(), kind: kind, a: a, b: b, x: x, y: y, phase: phaseName))
}
func onCharger() -> Bool { IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() != nil }

// ---------- MultitouchSupport (private framework) ----------
typealias MTCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
typealias MTCreateListFn = @convention(c) () -> Unmanaged<CFArray>?
typealias MTRegisterFn = @convention(c) (UnsafeMutableRawPointer, MTCallback) -> Void
typealias MTStartFn = @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32
typealias MTIsBuiltInFn = @convention(c) (UnsafeMutableRawPointer) -> Bool

let mtCallback: MTCallback = { _, data, n, _, _ in
    // MTTouch is 96 bytes: state @20, normalized x/y @32/@36, zTotal @48
    var active = 0, hover = 0
    var fx = 0.0, fy = 0.0, fz = 0.0
    if let data = data, n > 0 {
        for i in 0..<Int(n) {
            let base = data.advanced(by: i * 96)
            let state = base.load(fromByteOffset: 20, as: Int32.self)
            if state >= 3 && state <= 5 {
                if active == 0 {
                    fx = Double(base.load(fromByteOffset: 32, as: Float.self))
                    fy = Double(base.load(fromByteOffset: 36, as: Float.self))
                    fz = Double(base.load(fromByteOffset: 48, as: Float.self))
                }
                active += 1
            } else if state == 1 || state == 2 || state == 6 {
                hover += 1
            }
        }
    }
    lock.lock()
    if active > 0 { mtFrameCount[phaseName, default: 0] += 1; lastContactTime = now() }
    if hover > 0 { hoverFrameCount[phaseName, default: 0] += 1 }
    if active != currentFingers {
        if currentFingers == 0 && active > 0 { record("touchStart", Double(active), fz, fx, fy) }
        if active == 0 { record("touchEnd") }
        currentFingers = active
    }
    lock.unlock()
    return 0
}

var mtDevices = 0
if let h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW),
   let pList = dlsym(h, "MTDeviceCreateList"), let pReg = dlsym(h, "MTRegisterContactFrameCallback"),
   let pStart = dlsym(h, "MTDeviceStart") {
    let createList = unsafeBitCast(pList, to: MTCreateListFn.self)
    let register = unsafeBitCast(pReg, to: MTRegisterFn.self)
    let start = unsafeBitCast(pStart, to: MTStartFn.self)
    let isBuiltIn: MTIsBuiltInFn? = dlsym(h, "MTDeviceIsBuiltIn").map { unsafeBitCast($0, to: MTIsBuiltInFn.self) }
    if let arr = createList()?.takeRetainedValue() {
        for i in 0..<CFArrayGetCount(arr) {
            guard let raw = CFArrayGetValueAtIndex(arr, i) else { continue }
            let dev = UnsafeMutableRawPointer(mutating: raw)
            let builtIn = isBuiltIn?(dev) ?? false
            print("MT device \(i): builtIn=\(builtIn)")
            register(dev, mtCallback)
            _ = start(dev, 0)
            mtDevices += 1
        }
    }
} else {
    print("MultitouchSupport: could not load")
}
print("MT devices started: \(mtDevices)")

// ---------- HID polling (no permissions needed) ----------
let hid = CGEventSourceStateID.hidSystemState
func since(_ t: CGEventType) -> Double { CGEventSource.secondsSinceLastEventType(hid, eventType: t) }
var prevL = since(.leftMouseDown), prevR = since(.rightMouseDown), prevMv = since(.mouseMoved), prevDr = since(.leftMouseDragged)
var prevLoc = NSEvent.mouseLocation
var travel: [String: Double] = [:], heldSamples: [String: Int] = [:], samples: [String: Int] = [:]
func sample() {
    let l = since(.leftMouseDown), r = since(.rightMouseDown), mv = since(.mouseMoved), dr = since(.leftMouseDragged)
    lock.lock()
    let fingers = Double(currentFingers)
    let ms = lastContactTime < 0 ? -1 : (now() - lastContactTime) * 1000
    if l + 0.002 < prevL { record("leftDown", fingers, ms) }
    if r + 0.002 < prevR { record("rightDown", fingers, ms) }
    if mv + 0.002 < prevMv { moveCount[phaseName, default: 0] += 1 }
    if dr + 0.002 < prevDr { dragCount[phaseName, default: 0] += 1 }
    if CGEventSource.buttonState(hid, button: .left) { heldSamples[phaseName, default: 0] += 1 }
    samples[phaseName, default: 0] += 1
    let loc = NSEvent.mouseLocation
    travel[phaseName, default: 0] += hypot(loc.x - prevLoc.x, loc.y - prevLoc.y)
    lock.unlock()
    prevL = l; prevR = r; prevMv = mv; prevDr = dr; prevLoc = loc
}

// ---------- phase runner ----------
func pump(_ secs: Double) {
    let end = Date().addingTimeInterval(secs)
    while Date() < end { CFRunLoopRunInMode(.defaultMode, 0.008, false); sample() }
}
func speak(_ text: String) {
    print(">> \(text)")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    p.arguments = ["-r", "180", text]
    try? p.run()
    while p.isRunning { CFRunLoopRunInMode(.defaultMode, 0.008, false); sample() }
}
var phaseCharger: [String: String] = [:]
var phaseOrder: [String] = []
func phase(_ name: String, _ secs: Double) {
    let c0 = onCharger()
    lock.lock(); phaseName = name; lock.unlock()
    phaseOrder.append(name)
    pump(secs)
    let c1 = onCharger()
    phaseCharger[name] = (c0 == c1) ? (c0 ? "PLUGGED IN" : "ON BATTERY") : "CHANGED DURING PHASE"
    lock.lock(); phaseName = "transition"; lock.unlock()
}

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "quick"
if mode == "quick" {
    phase("quick", 3)
} else {
    speak("Second trackpad test. Charger can stay plugged in. Hands completely off the trackpad now.")
    pump(1.5)
    phase("A_handsOff", 10)
    speak("Slide one finger around to move the pointer. Do not click.")
    phase("B_slide_no_click", 15)
    speak("Now rest one finger still on the trackpad. Do not press.")
    phase("C_rest_still", 8)
    speak("Now three firm physical clicks.")
    phase("D_firm_clicks", 8)
    speak("Now three light taps.")
    phase("E_light_taps", 8)
    speak("Done. Thank you.")
}

// ---------- report ----------
lock.lock()
let evs = events
lock.unlock()
func near(_ t: Double, kind: String, within: Double, minA: Double) -> Bool {
    evs.contains { $0.kind == kind && $0.a >= minA && abs($0.t - t) <= within }
}
print("\n================ RESULTS ================")
for p in phaseOrder {
    let pe = evs.filter { $0.phase == p }
    let touches = pe.filter { $0.kind == "touchStart" }
    let downs = pe.filter { $0.kind == "leftDown" || $0.kind == "rightDown" }
    let whileTouching = downs.filter { $0.a >= 1 }
    let afterLift = downs.filter { $0.a == 0 && $0.b >= 0 && $0.b < 400 }
    let noFinger = downs.filter { $0.a == 0 && ($0.b < 0 || $0.b >= 400) }
    let held = samples[p] ?? 0 > 0 ? 100.0 * Double(heldSamples[p] ?? 0) / Double(samples[p]!) : 0
    print("\n--- \(p)  [charger: \(phaseCharger[p] ?? "?")]")
    print("  touch frames (finger on pad): \(mtFrameCount[p] ?? 0)   hover frames: \(hoverFrameCount[p] ?? 0)")
    print("  separate touches detected:     \(touches.count)")
    print(String(format: "  cursor travel: %.0f pt   move samples: %d   DRAG samples: %d   button held: %.0f%%", travel[p] ?? 0, moveCount[p] ?? 0, dragCount[p] ?? 0, held))
    print("  clicks: \(downs.count)  [while finger on pad (press-style): \(whileTouching.count) | right after lift (tap-style): \(afterLift.count) | NO finger near (phantom): \(noFinger.count)]")
    for t in touches.prefix(8) {
        print(String(format: "    touch at x=%.2f y=%.2f  size=%.2f  fingers=%d", t.x, t.y, t.b, Int(t.a)))
    }
    for d in downs.prefix(12) {
        print(String(format: "    %@ fingersOnPad=%d  msSinceContact=%.0f", d.kind, Int(d.a), d.b))
    }
}
let tr = evs.filter { $0.phase == "transition" || $0.phase == "warmup" }
print("\n(transition/speech periods: \(tr.filter { $0.kind.hasSuffix("Down") }.count) clicks, \(tr.filter { $0.kind == "touchStart" }.count) touches)")
