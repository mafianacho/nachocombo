import Foundation

/// The pet's pose at a moment: which picture shows (and the one fading out), and how the character is moved.
/// dx/dy in points (+dy = up), scale around the bottom centre, rotation in degrees (+ = clockwise).
public struct PetPose: Equatable {
    public var asset: String
    public var previous: String?
    /// Opacity of `asset` over `previous` (1 when there is no crossfade).
    public var mix: Double = 1
    public var dx: Double = 0
    public var dy: Double = 0
    public var scaleX: Double = 1
    public var scaleY: Double = 1
    public var rotation: Double = 0

    public init(asset: String, previous: String? = nil, mix: Double = 1, dx: Double = 0, dy: Double = 0, scaleX: Double = 1,
                scaleY: Double = 1, rotation: Double = 0) {
        self.asset = asset; self.previous = previous; self.mix = mix; self.dx = dx; self.dy = dy
        self.scaleX = scaleX; self.scaleY = scaleY; self.rotation = rotation
    }
}

/// Nacho Pet motion as a pure function of time, from the original pictures only (no new art): crossfade with a small
/// scale pop between states, breathing while idle, random blinks, a different small loop while listening, thinking
/// and answering, a hop when done, dozing off when tired, press, drag tilt and landing.
/// Twin of design/web/motion.js (same rules, same tokens); PetMotionTests replays the web model's poses.
/// Times in milliseconds on any monotonic clock.
public struct PetMotion {
    public private(set) var face: PetFace
    public private(set) var since: Double
    public var reduceMotion: Bool
    private var from: String?
    private let seed: UInt32
    private var pressedAt: Double?
    private var releasedAt: Double?
    private var pressDepth = 0.0
    private var tiltFrom = 0.0, tiltTo = 0.0, tiltSince = 0.0
    private var landedAt: Double?

    private typealias M = PetTokens.Motion
    private typealias A = PetTokens.MotionAmount
    private static let standard = PetCurve(PetTokens.Curve.standard)
    private static let emphasized = PetCurve(PetTokens.Curve.emphasized)

    /// Pictures with an eyes-shut twin of the same pose, for blinks.
    public static func blinkAsset(_ face: PetFace) -> String? {
        switch face {
        case .idle: return "eyes-closed"
        case .listening: return "calling-eyeless"
        default: return nil
        }
    }

    public init(face: PetFace = .idle, at t: Double = 0, reduceMotion: Bool = false, seed: UInt32 = 1) {
        self.face = face
        since = t
        self.reduceMotion = reduceMotion
        self.seed = seed
        tiltSince = t
    }

    public mutating func setFace(_ next: PetFace, at t: Double) {
        guard next != face else { return }
        from = asset(at: t)
        face = next
        since = t
    }

    public mutating func press(at t: Double) { pressedAt = t; releasedAt = nil }
    public mutating func release(at t: Double) { pressDepth = pressAmount(t); pressedAt = nil; releasedAt = t }

    /// While dragging: horizontal speed in points per second leans the character into the move.
    public mutating func drag(velocityX: Double, at t: Double) {
        tiltFrom = tilt(t)
        tiltTo = min(A.dragTiltMax, max(-A.dragTiltMax, velocityX * A.dragTiltPerSpeed))
        tiltSince = t
    }

    /// Let go after a drag: straightens up and lands with a small squash.
    public mutating func drop(at t: Double) {
        tiltFrom = tilt(t)
        tiltTo = 0
        tiltSince = t
        landedAt = t
    }

    /// The picture without the crossfade: blinks and dozing swap to an eyes-shut twin.
    public func asset(at t: Double) -> String {
        let base = face.assetName
        if reduceMotion { return base }
        let age = t - since
        if let shut = PetMotion.blinkAsset(face) {
            var b = since
            var n: UInt32 = 0
            while true {
                b += M.blinkMin + PetMotion.random(seed, n) * (M.blinkMax - M.blinkMin)
                if b > t { break }
                if t < b + M.blink { return shut }
                n += 1
            }
        }
        if face == .tired, age.truncatingRemainder(dividingBy: M.drowsePeriod) >= M.drowsePeriod - M.drowseClosed { return "eyes-closed" }
        return base
    }

    /// Frames are needed while anything moves; with reduced motion only during a crossfade.
    public func isAnimating(at t: Double) -> Bool { !reduceMotion || (from != nil && t - since < M.transition) }

    public func pose(at t: Double) -> PetPose {
        let age = t - since
        var p = PetPose(asset: asset(at: t), previous: nil)
        if let f = from, age < M.transition {
            let k = PetMotion.clamp(age / M.transition)
            p.previous = f
            p.mix = PetMotion.standard.y(k)
            if !reduceMotion {
                let pop = A.transitionScale * sin(Double.pi * k)
                p.scaleX += pop
                p.scaleY += pop
            }
        }
        if reduceMotion { return PetMotion.rounded(p) }
        func breath(_ slow: Double) {
            let w = PetMotion.wave(age / (M.petBreath * slow))
            p.dy += A.breathLift * w
            p.scaleY *= 1 + A.breathScale * w
            p.scaleX *= 1 - A.breathScale * 0.4 * w
        }
        switch face {
        case .idle, .waiting: breath(1)
        case .listening:
            p.dy += A.listenLift * PetMotion.wave(age / M.listenPeriod)
            p.rotation += A.listenTilt * sin(Double.pi * age / M.listenPeriod)
        case .thinking:
            p.rotation += A.thinkTilt * sin(2 * Double.pi * age / M.thinkPeriod)
            p.dy += A.thinkLift * PetMotion.wave(age / M.thinkPeriod)
        case .speaking:
            let w = PetMotion.wave(age / M.speakPeriod)
            p.dy += A.speakLift * w
            p.scaleY *= 1 + A.speakScale * w
            p.scaleX *= 1 - A.speakScale * 0.5 * w
        case .happy:
            if age < M.happyHop {
                let k = age / M.happyHop
                p.dy += A.happyHopHeight * 4 * k * (1 - k)
            } else if age < M.happyHop + M.land {
                let d = 1 - PetMotion.standard.y((age - M.happyHop) / M.land)
                p.scaleY *= 1 - A.landSquash * d
                p.scaleX *= 1 + A.landSquash * d
            } else {
                breath(1)
            }
        case .tired:
            breath(A.tiredBreathSlow)
            let c = age.truncatingRemainder(dividingBy: M.drowsePeriod), start = M.drowsePeriod - M.drowseClosed
            if c >= start {
                let nod = sin(Double.pi * (c - start) / M.drowseClosed)
                p.dy -= 1.5 * nod
                p.rotation += 2 * nod
            }
        case .sleeping: breath(A.sleepBreathSlow)
        }
        let press = pressAmount(t)
        if press != 0 {
            let s = 1 - (1 - A.pressScale) * press
            p.scaleX *= s
            p.scaleY *= s
        }
        p.rotation += tilt(t)
        if let l = landedAt, t - l < M.land {
            let d = 1 - PetMotion.standard.y((t - l) / M.land)
            p.scaleY *= 1 - A.landSquash * d
            p.scaleX *= 1 + A.landSquash * d
        }
        return PetMotion.rounded(p)
    }

    private func tilt(_ t: Double) -> Double {
        let k = 1 - exp(-(t - tiltSince) / 80)
        return tiltFrom + (tiltTo - tiltFrom) * PetMotion.clamp(k)
    }

    private func pressAmount(_ t: Double) -> Double {
        if let p = pressedAt { return PetMotion.standard.y(PetMotion.clamp((t - p) / M.press)) }
        if let r = releasedAt { return pressDepth * (1 - PetMotion.emphasized.y(PetMotion.clamp((t - r) / (M.press * 2)))) }
        return 0
    }

    // MARK: helpers shared with motion.js

    /// lowbias32 hash → [0, 1); same numbers as motion.js `rand`.
    public static func random(_ seed: UInt32, _ n: UInt32) -> Double {
        var x = seed ^ ((n &+ 1) &* 0x9E37_79B9)
        x ^= x >> 16
        x = x &* 0x7FEB_352D
        x ^= x >> 15
        x = x &* 0x846C_A68B
        x ^= x >> 16
        return Double(x) / 4_294_967_296
    }

    static func clamp(_ v: Double) -> Double { min(1, max(0, v)) }
    static func wave(_ phase: Double) -> Double { 0.5 - 0.5 * cos(2 * Double.pi * phase) }

    static func rounded(_ p: PetPose) -> PetPose {
        func r(_ v: Double) -> Double { let x = (v * 1e4).rounded() / 1e4; return x == 0 ? 0 : x }
        var q = p
        q.mix = r(p.mix); q.dx = r(p.dx); q.dy = r(p.dy); q.scaleX = r(p.scaleX); q.scaleY = r(p.scaleY); q.rotation = r(p.rotation)
        return q
    }
}

/// When the pet may draw frames: only while it is on screen, the displays are awake, no full-screen app is in front,
/// and something moves (or the user is touching it). Otherwise the frame timer stops: no CPU while idle.
public struct PetAnimationGate: Equatable {
    public var windowVisible = true
    public var displaysAsleep = false
    public var fullScreenAppInFront = false
    public var interacting = false

    public init() {}

    public var allowsMotion: Bool { windowVisible && !displaysAsleep && !fullScreenAppInFront }

    public func needsFrames(_ motion: PetMotion, at t: Double) -> Bool {
        allowsMotion && (motion.isAnimating(at: t) || interacting)
    }
}

/// A CSS `cubic-bezier(x1, y1, x2, y2)` easing curve (tokens.json `curve`), solved the same way as motion.js.
public struct PetCurve {
    public let x1: Double, y1: Double, x2: Double, y2: Double

    public init(_ spec: String) {
        let inner = spec.drop(while: { $0 != "(" }).dropFirst().prefix(while: { $0 != ")" })
        let v = inner.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
        precondition(v.count == 4, "cubic-bezier needs four numbers: \(spec)")
        x1 = v[0]; y1 = v[1]; x2 = v[2]; y2 = v[3]
    }

    public func y(_ x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        func bx(_ u: Double) -> Double { 3 * x1 * u * (1 - u) * (1 - u) + 3 * x2 * u * u * (1 - u) + u * u * u }
        func by(_ u: Double) -> Double { 3 * y1 * u * (1 - u) * (1 - u) + 3 * y2 * u * u * (1 - u) + u * u * u }
        var lo = 0.0, hi = 1.0
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if bx(mid) < x { lo = mid } else { hi = mid }
        }
        return by((lo + hi) / 2)
    }
}
