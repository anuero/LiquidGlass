import UIKit

// closed form, so the frame rate does not change the result
struct MorphSpring {
    var value: CGFloat
    var velocity: CGFloat = 0
    var target: CGFloat
    var response: CGFloat
    var dampingFraction: CGFloat

    init(value: CGFloat, target: CGFloat, response: CGFloat, dampingFraction: CGFloat) {
        self.value = value
        self.target = target
        self.response = response
        self.dampingFraction = dampingFraction
    }

    mutating func step(_ dt: CGFloat) {
        guard dt > 0 else { return }
        let omega = 2 * CGFloat.pi / response
        let x0 = value - target
        if dampingFraction < 1 {
            let zeta = dampingFraction
            let omegaD = omega * (1 - zeta * zeta).squareRoot()
            let decay = exp(-zeta * omega * dt)
            let b = (velocity + zeta * omega * x0) / omegaD
            let cosine = cos(omegaD * dt), sine = sin(omegaD * dt)
            value = target + decay * (x0 * cosine + b * sine)
            velocity = decay * ((b * omegaD - zeta * omega * x0) * cosine - (x0 * omegaD + zeta * omega * b) * sine)
        } else {
            let decay = exp(-omega * dt)
            let b = velocity + omega * x0
            value = target + (x0 + b * dt) * decay
            velocity = (b - omega * (x0 + b * dt)) * decay
        }
    }

    var isAtRest: Bool { abs(value - target) < 0.001 && abs(velocity) < 0.01 }

    mutating func snapIfSettled() {
        if abs(value - target) < 0.0005 && abs(velocity) < 0.005 {
            value = target
            velocity = 0
        }
    }
}

// one setShapes(animated:) in flight: a spring per shape, recoil and pulse, read back as the shapes to draw
struct MorphState {
    private struct Kick {
        let offset: CGSize
        var spring = MorphSpring(value: 0, target: 0, response: 0.25, dampingFraction: 1)
        var wentOut = false
        var cameBack = false

        mutating func advance(_ dt: CGFloat, local: CGFloat) {
            if local >= 0.05 && !wentOut { wentOut = true; spring.target = 1 }
            if local >= 0.15 && !cameBack {
                cameBack = true
                spring.target = 0
                spring.response = 0.5
                spring.dampingFraction = 0.834
            }
            if local > 0 { spring.step(dt) }
        }

        var isDone: Bool { cameBack && spring.isAtRest }
        var translation: CGSize { CGSize(width: offset.width * spring.value, height: offset.height * spring.value) }
    }

    // scale per axis is f(rising) * f(falling), f(p) = 1/m + (m - 1/m) * p
    private struct Pulse {
        let size: CGSize
        let anchor: CGPoint
        let start: CGFloat
        var rising = MorphSpring(value: 0, target: 0, response: 0.292, dampingFraction: 0.5)
        var fallingHeight = MorphSpring(value: 1, target: 1, response: 0.416, dampingFraction: 0.584)
        var fallingWidth = MorphSpring(value: 1, target: 1, response: 0.416, dampingFraction: 0.5)

        init(size: CGSize, anchor: CGPoint, start: CGFloat) {
            self.size = size
            self.anchor = anchor
            self.start = start
        }

        mutating func advance(_ dt: CGFloat, elapsed: CGFloat) {
            let local = elapsed - start
            guard local > 0 else { return }
            rising.target = 1
            if local >= 0.113 { fallingHeight.target = 0 }
            if local >= 0.142 { fallingWidth.target = 0 }
            rising.step(dt)
            fallingHeight.step(dt)
            fallingWidth.step(dt)
        }

        func isDone(elapsed: CGFloat) -> Bool {
            elapsed - start >= 0.142 && rising.isAtRest && fallingHeight.isAtRest && fallingWidth.isAtRest
        }

        func scale(maxScale: CGFloat) -> CGSize {
            func m(_ length: CGFloat) -> CGFloat {
                length > 0 ? min((length + 16) / length, maxScale).squareRoot() : 1
            }
            func f(_ p: CGFloat, _ m: CGFloat) -> CGFloat { 1 / m + (m - 1 / m) * p }
            let mw = m(size.width), mh = m(size.height)
            return CGSize(width: f(rising.value, mw) * f(fallingWidth.value, mw),
                          height: f(rising.value, mh) * f(fallingHeight.value, mh))
        }
    }

    private struct Track {
        var changed: Bool
        var start: CGFloat
        var source: CGRect
        var target: CGRect
        var progress: MorphSpring
        // 0 is full size, 1 is a fifth of it
        var shrink: MorphSpring?
        var shrinkGoal: CGFloat = 0
        var tintChanged: Bool
        var tint: MorphSpring
        var kick: Kick?
        var pulse: Pulse?
    }

    let from: [LiquidGlassShape]
    let to: [LiquidGlassShape]
    private var tracks: [Track]
    private var elapsed: CGFloat = 0
    private let maxPulse: CGFloat
    private let bulge: CGFloat

    private static let collapseDelay: CGFloat = 0.083
    private static let matchScale: CGFloat = 0.2

    init(from: [LiquidGlassShape], to: [LiquidGlassShape], bounds: CGRect, morph: LiquidGlassMorph) {
        self.from = from
        self.to = to
        self.maxPulse = morph.pulse
        self.bulge = morph.bulge
        let response = 2 * CGFloat.pi / max(1, morph.stiffness).squareRoot()
        let damping = min(max(morph.dampingRatio, 0.05), 1)
        let pulses = morph.pulse > 1.0001

        func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
            let r = a.intersection(b)
            return r.isNull ? 0 : r.width * r.height
        }
        func anchor(of partner: CGRect) -> CGPoint {
            func axis(_ value: CGFloat, _ middle: CGFloat) -> CGFloat {
                abs(value - middle) < 0.001 ? 0.5 : (value < middle ? 0 : 1)
            }
            return CGPoint(x: axis(partner.midX, bounds.midX), y: axis(partner.midY, bounds.midY))
        }
        func spring(from value: CGFloat, to target: CGFloat) -> MorphSpring {
            MorphSpring(value: value, target: target, response: response, dampingFraction: damping)
        }

        var tracks = to.indices.map { index -> Track in
            let changed = !Self.isSameRect(from[index].rect, to[index].rect)
            // a change of tint alone fades the tint and nothing else
            return Track(changed: changed, start: 0, source: from[index].rect, target: to[index].rect,
                         progress: spring(from: 0, to: 0), shrink: nil,
                         tintChanged: from[index].tint != to[index].tint, tint: spring(from: 0, to: 0),
                         kick: nil, pulse: nil)
        }

        for index in to.indices where tracks[index].changed {
            // the partner is the shape it ends inside without having started there (goes in),
            // or starts inside without ending there (comes out)
            var best: (partner: Int, collapses: Bool, area: CGFloat)?
            for other in to.indices where other != index {
                let atEnd = overlap(to[index].rect, to[other].rect)
                let atStart = overlap(from[index].rect, to[other].rect)
                if atEnd > 0 && atStart == 0 && atEnd > (best?.area ?? 0) {
                    best = (other, true, atEnd)
                } else if atStart > 0 && atEnd == 0 && atStart > (best?.area ?? 0) {
                    best = (other, false, atStart)
                }
            }

            guard let match = best else {
                // not if a mover already made it a partner, whatever the loop order
                if pulses && tracks[index].pulse == nil {
                    tracks[index].pulse = Pulse(size: to[index].rect.size, anchor: CGPoint(x: 0.5, y: 0.5), start: 0)
                }
                continue
            }
            let partnerRect = to[match.partner].rect
            let own = match.collapses ? from[index].rect : to[index].rect
            let start = match.collapses ? Self.collapseDelay : 0
            tracks[index].start = start
            if match.collapses {
                tracks[index].target = partnerRect
                tracks[index].shrink = spring(from: 0, to: 0)
                tracks[index].shrinkGoal = 1
            } else {
                tracks[index].source = partnerRect
                tracks[index].shrink = spring(from: 1, to: 1)
                tracks[index].shrinkGoal = 0
            }
            let delta = CGSize(width: own.midX - partnerRect.midX, height: own.midY - partnerRect.midY)
            if morph.kick > 0 {
                tracks[index].kick = Kick(offset: CGSize(width: delta.width * morph.kick, height: delta.height * morph.kick))
            }
            if pulses {
                let pairAnchor = anchor(of: partnerRect)
                tracks[index].pulse = Pulse(size: own.size, anchor: pairAnchor, start: start)
                tracks[match.partner].pulse = Pulse(size: partnerRect.size, anchor: pairAnchor, start: 0)
            }
        }
        self.tracks = tracks
    }

    private static func isSameRect(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5
            && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
    }

    // slices of at most 1/240 s, so a delay lands within 4 ms of where it belongs
    mutating func step(_ dt: CGFloat) {
        let slices = max(1, Int((dt * 240).rounded(.up)))
        let h = dt / CGFloat(slices)
        for _ in 0..<slices {
            elapsed += h
            for index in tracks.indices {
                let local = elapsed - tracks[index].start
                if tracks[index].tintChanged {
                    tracks[index].tint.target = 1
                    tracks[index].tint.step(h)
                    tracks[index].tint.snapIfSettled()
                }
                if tracks[index].changed {
                    if local > 0 {
                        tracks[index].progress.target = 1
                        tracks[index].progress.step(h)
                        tracks[index].progress.snapIfSettled()
                    }
                }
                if local > 0, var shrink = tracks[index].shrink {
                    shrink.target = tracks[index].shrinkGoal
                    shrink.step(h)
                    shrink.snapIfSettled()
                    tracks[index].shrink = shrink
                }
                tracks[index].kick?.advance(h, local: local)
                tracks[index].pulse?.advance(h, elapsed: elapsed)
            }
        }
    }

    var isSettled: Bool {
        tracks.allSatisfy { track in
            (!track.changed || track.progress.value == 1)
                && (!track.tintChanged || track.tint.value == 1)
                && (track.shrink?.isAtRest ?? true)
                && (track.kick?.isDone ?? true)
                && (track.pulse?.isDone(elapsed: elapsed) ?? true)
        }
    }

    // progress of the first shape to start
    var progress: CGFloat {
        guard let lead = tracks.filter({ $0.changed }).min(by: { $0.start < $1.start }) else { return 1 }
        return lead.progress.value
    }

    // thickest while a shape is halfway, zero at both ends
    var neck: CGFloat {
        let halfway = tracks.filter { $0.changed }
            .map { sin(CGFloat.pi * min(max($0.progress.value, 0), 1)) }
            .max() ?? 0
        return bulge * halfway
    }

    var scales: [CGSize] {
        tracks.map { track in
            let shrink = track.shrink.map { 1 + $0.value * (Self.matchScale - 1) } ?? 1
            let pulse = track.pulse?.scale(maxScale: maxPulse) ?? CGSize(width: 1, height: 1)
            return CGSize(width: shrink * pulse.width, height: shrink * pulse.height)
        }
    }

    var shapes: [LiquidGlassShape] {
        to.indices.map { index in
            let track = tracks[index]
            var shape = to[index]
            guard track.changed || track.tintChanged || track.pulse != nil else { return shape }
            if track.tintChanged {
                shape.tint = Self.blend(from[index].tint, to[index].tint, track.tint.value)
            }
            if track.changed {
                let p = track.progress.value
                func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * p }
                shape.rect = CGRect(x: lerp(track.source.minX, track.target.minX),
                                    y: lerp(track.source.minY, track.target.minY),
                                    width: max(0, lerp(track.source.width, track.target.width)),
                                    height: max(0, lerp(track.source.height, track.target.height)))
                shape.cornerRadius = (from[index].cornerRadius < 0 && to[index].cornerRadius < 0)
                    ? -1 : from[index].resolvedRadius() + (to[index].resolvedRadius() - from[index].resolvedRadius()) * p
            }
            if let kick = track.kick {
                let shift = kick.translation
                shape.rect = shape.rect.offsetBy(dx: shift.width, dy: shift.height)
            }
            if let shrink = track.shrink {
                let scale = 1 + shrink.value * (Self.matchScale - 1)
                if abs(scale - 1) > 1e-9 {
                    let rect = shape.rect
                    let size = CGSize(width: rect.width * scale, height: rect.height * scale)
                    shape.rect = CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                                        width: size.width, height: size.height)
                }
            }
            if let pulse = track.pulse {
                let scale = pulse.scale(maxScale: maxPulse)
                // at the ends the scale is 1 up to rounding, keep the rect exact
                if abs(scale.width - 1) > 1e-9 || abs(scale.height - 1) > 1e-9 {
                    let rect = shape.rect
                    let size = CGSize(width: rect.width * scale.width, height: rect.height * scale.height)
                    shape.rect = CGRect(x: rect.minX - (size.width - rect.width) * pulse.anchor.x,
                                        y: rect.minY - (size.height - rect.height) * pulse.anchor.y,
                                        width: size.width, height: size.height)
                }
            }
            return shape
        }
    }

    // clamped, the spring overshoots past the new tint
    private static func blend(_ a: UIColor?, _ b: UIColor?, _ t: CGFloat) -> UIColor? {
        guard a != nil || b != nil else { return nil }
        func components(_ color: UIColor) -> [CGFloat] {
            var r: CGFloat = 0, g: CGFloat = 0, bl: CGFloat = 0, al: CGFloat = 0
            color.getRed(&r, green: &g, blue: &bl, alpha: &al)
            return [r, g, bl, al]
        }
        var from = a.map(components) ?? components(b!)
        var to = b.map(components) ?? components(a!)
        if a == nil { from[3] = 0 }
        if b == nil { to[3] = 0 }
        let fraction = min(max(t, 0), 1)
        let mixed = zip(from, to).map { $0 + ($1 - $0) * fraction }
        return UIColor(red: mixed[0], green: mixed[1], blue: mixed[2], alpha: mixed[3])
    }
}
