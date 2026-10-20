// TrainingHelper - screen overlay tools for online training
// Copyright (C) 2026 Matej Forman
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify it under the terms of the
// GNU General Public License as published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version. It is distributed in the hope that it will be
// useful, but WITHOUT ANY WARRANTY. See <https://www.gnu.org/licenses/>.

import Cocoa

// MARK: - Text layout shared by the obstacle mask and the on-screen text

func textLayout(_ text: String, in size: CGSize) -> (NSAttributedString, NSRect) {
    func make(_ fs: CGFloat) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fs, weight: .heavy),
            .foregroundColor: NSColor.white
        ])
    }
    var fs = size.height * 0.62
    var a = make(fs)
    var sz = a.size()
    if sz.width > size.width * 0.86 {
        fs *= size.width * 0.86 / sz.width
        a = make(fs)
        sz = a.size()
    }
    let rect = NSRect(x: (size.width - sz.width) / 2, y: (size.height - sz.height) / 2,
                      width: sz.width, height: sz.height)
    return (a, rect)
}

/// Rasterises the text at grid resolution; true = solid cell (obstacle). Row 0 = top.
func makeMask(text: String, w: Int, h: Int) -> [Bool] {
    var bytes = [UInt8](repeating: 0, count: w * h)
    bytes.withUnsafeMutableBytes { raw in
        guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let (a, rect) = textLayout(text, in: CGSize(width: w, height: h))
        a.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
    }
    return bytes.map { $0 > 100 }
}

func hsv(_ h: Float, _ s: Float, _ v: Float) -> (Float, Float, Float) {
    let hh = (h - floor(h)) * 6
    let i = Int(hh) % 6
    let f = hh - floor(hh)
    let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
    switch i {
    case 0: return (v, t, p)
    case 1: return (q, v, p)
    case 2: return (p, v, t)
    case 3: return (p, q, v)
    case 4: return (t, p, v)
    default: return (v, p, q)
    }
}

// MARK: - 2D incompressible flow ("stable fluids" with solid obstacles)

final class Fluid {
    enum Mode { case normal, warning, finished }

    let W: Int
    let H: Int
    var u: [Float], v: [Float], u0: [Float], v0: [Float]
    var p: [Float], div: [Float], curl: [Float]
    var r: [Float], g: [Float], b: [Float]
    var r0: [Float], g0: [Float], b0: [Float]
    var solid: [Bool]
    var pixels: [UInt8]
    var time: Float = 0
    var inflow: Float = 38
    var mode: Mode = .normal
    let confinement: Float = 1.2

    init(w: Int, h: Int) {
        W = w
        H = h
        let n = w * h
        let z = [Float](repeating: 0, count: n)
        u = z; v = z; u0 = z; v0 = z; p = z; div = z; curl = z
        r = z; g = z; b = z; r0 = z; g0 = z; b0 = z
        solid = [Bool](repeating: false, count: n)
        pixels = [UInt8](repeating: 255, count: n * 4)
    }

    func setSolid(_ mask: [Bool]) {
        guard mask.count == solid.count else { return }
        solid = mask
        for k in 0..<solid.count where solid[k] {
            u[k] = 0; v[k] = 0; r[k] = 0; g[k] = 0; b[k] = 0
        }
    }

    func step(_ dt: Float) {
        time += dt
        applyInflow()
        confine(dt)
        advectVelocity(dt)
        project()
        applyBoundaries()
        advectDye(dt)
        injectDye()
    }

    @inline(__always)
    private func sample(_ f: [Float], _ x: Float, _ y: Float) -> Float {
        let xx = min(max(x, 0), Float(W) - 1.001)
        let yy = min(max(y, 0), Float(H) - 1.001)
        let i0 = Int(xx), j0 = Int(yy)
        let sx = xx - Float(i0), sy = yy - Float(j0)
        let k = j0 * W + i0
        let top = f[k] * (1 - sx) + f[k + 1] * sx
        let bot = f[k + W] * (1 - sx) + f[k + W + 1] * sx
        return top * (1 - sy) + bot * sy
    }

    private func applyInflow() {
        let wiggle = 2.5 * sin(time * 2.3)
        for j in 0..<H {
            for i in 0..<2 {
                let k = j * W + i
                if solid[k] { continue }
                u[k] = inflow
                v[k] = wiggle
            }
        }
    }

    private func confine(_ dt: Float) {
        for j in 1..<(H - 1) {
            for i in 1..<(W - 1) {
                let k = j * W + i
                curl[k] = 0.5 * ((v[k + 1] - v[k - 1]) - (u[k + W] - u[k - W]))
            }
        }
        for j in 2..<(H - 2) {
            for i in 2..<(W - 2) {
                let k = j * W + i
                if solid[k] { continue }
                let nx = 0.5 * (abs(curl[k + 1]) - abs(curl[k - 1]))
                let ny = 0.5 * (abs(curl[k + W]) - abs(curl[k - W]))
                let len = (nx * nx + ny * ny).squareRoot() + 1e-5
                let w = curl[k]
                u[k] += dt * confinement * (ny / len) * w
                v[k] -= dt * confinement * (nx / len) * w
            }
        }
    }

    private func advectVelocity(_ dt: Float) {
        u0 = u
        v0 = v
        for j in 0..<H {
            for i in 0..<W {
                let k = j * W + i
                if solid[k] { u[k] = 0; v[k] = 0; continue }
                let x = Float(i) - dt * u0[k]
                let y = Float(j) - dt * v0[k]
                u[k] = sample(u0, x, y)
                v[k] = sample(v0, x, y)
            }
        }
    }

    private func project() {
        for j in 0..<H {
            for i in 0..<W {
                let k = j * W + i
                if solid[k] { div[k] = 0; continue }
                let ul = i > 0 ? u[k - 1] : u[k]
                let ur = i < W - 1 ? u[k + 1] : u[k]
                let vu: Float = j > 0 ? v[k - W] : 0
                let vd: Float = j < H - 1 ? v[k + W] : 0
                div[k] = 0.5 * ((ur - ul) + (vd - vu))
            }
        }
        for _ in 0..<40 {
            for j in 0..<H {
                for i in 0..<W {
                    let k = j * W + i
                    if solid[k] { continue }
                    var s: Float = 0
                    var c: Float = 0
                    if i > 0 { if !solid[k - 1] { s += p[k - 1]; c += 1 } }
                    if i < W - 1 { if !solid[k + 1] { s += p[k + 1]; c += 1 } } else { c += 1 } // outflow: p = 0
                    if j > 0 { if !solid[k - W] { s += p[k - W]; c += 1 } }
                    if j < H - 1 { if !solid[k + W] { s += p[k + W]; c += 1 } }
                    if c > 0 { p[k] = (s - div[k]) / c }
                }
            }
        }
        for j in 0..<H {
            for i in 0..<W {
                let k = j * W + i
                if solid[k] { continue }
                let pc = p[k]
                var pl = pc, pr: Float = 0, pu = pc, pd = pc
                if i > 0 && !solid[k - 1] { pl = p[k - 1] }
                if i < W - 1 { pr = solid[k + 1] ? pc : p[k + 1] }
                if j > 0 && !solid[k - W] { pu = p[k - W] }
                if j < H - 1 && !solid[k + W] { pd = p[k + W] }
                u[k] -= 0.5 * (pr - pl)
                v[k] -= 0.5 * (pd - pu)
            }
        }
    }

    private func applyBoundaries() {
        for j in 0..<H {
            for i in 0..<W {
                let k = j * W + i
                if solid[k] { u[k] = 0; v[k] = 0; continue }
                u[k] = min(max(u[k], -150), 150)
                v[k] = min(max(v[k], -150), 150)
            }
            let kl = j * W
            if !solid[kl] { u[kl] = inflow }
            let kr = j * W + W - 1
            if !solid[kr] { u[kr] = u[kr - 1] }
        }
        for i in 0..<W {
            if !solid[i] { v[i] = 0 }
            let kb = (H - 1) * W + i
            if !solid[kb] { v[kb] = 0 }
        }
    }

    private func advectDye(_ dt: Float) {
        r0 = r; g0 = g; b0 = b
        let decay: Float = 0.9985
        for j in 0..<H {
            for i in 0..<W {
                let k = j * W + i
                if solid[k] { r[k] = 0; g[k] = 0; b[k] = 0; continue }
                let x = Float(i) - dt * u[k]
                let y = Float(j) - dt * v[k]
                r[k] = sample(r0, x, y) * decay
                g[k] = sample(g0, x, y) * decay
                b[k] = sample(b0, x, y) * decay
            }
        }
    }

    private func injectDye() {
        let bands = 14
        for j in 0..<H {
            let band = j * bands / H
            let on = band % 2 == 0
            let frac = Float(j) / Float(H)
            let col: (Float, Float, Float)
            switch mode {
            case .normal:   col = hsv(0.5 + 0.36 * frac, 0.85, 1.0)
            case .warning:  col = hsv(0.02 + 0.10 * frac, 0.9, 1.0)
            case .finished: col = hsv(frac + time * 0.25, 0.8, 1.0)
            }
            for i in 0..<3 {
                let k = j * W + i
                if solid[k] { continue }
                r[k] = on ? col.0 : 0
                g[k] = on ? col.1 : 0
                b[k] = on ? col.2 : 0
            }
        }
    }

    func render() {
        let n = W * H
        pixels.withUnsafeMutableBufferPointer { px in
            for k in 0..<n {
                var rr: Float, gg: Float, bb: Float
                if solid[k] {
                    rr = 0.12; gg = 0.15; bb = 0.22
                } else {
                    rr = 0.04 + r[k]; gg = 0.055 + g[k]; bb = 0.11 + b[k]
                }
                px[k * 4] = UInt8(min(max(rr, 0), 1) * 255)
                px[k * 4 + 1] = UInt8(min(max(gg, 0), 1) * 255)
                px[k * 4 + 2] = UInt8(min(max(bb, 0), 1) * 255)
                px[k * 4 + 3] = 255
            }
        }
    }

    func makeImage() -> CGImage? {
        guard let prov = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: W * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: prov, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

// MARK: - Timer view

final class FluidTimerView: NSView {
    let endDate: Date
    var fluid: Fluid
    let gridW: Int
    var lastText = ""
    var lastTick = Date()
    var finishedAt: Date?
    var timer: Timer?
    var onDoubleClick: (() -> Void)?

    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(frame: NSRect, end: Date) {
        endDate = end
        let gw = 224
        gridW = gw
        let gh = max(24, Int(Double(gw) * Double(frame.height) / Double(max(frame.width, 1))))
        fluid = Fluid(w: gw, h: gh)
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.masksToBounds = true
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    deinit { timer?.invalidate() }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() }
        super.mouseDown(with: event)
    }

    private func tick() {
        let now = Date()
        let dt = Float(min(0.05, now.timeIntervalSince(lastTick)))
        lastTick = now

        // keep grid aspect in sync with the view (fullscreen toggle, resize)
        let wantH = max(24, Int(Double(gridW) * Double(bounds.height) / Double(max(bounds.width, 1))))
        if wantH != fluid.H {
            fluid = Fluid(w: gridW, h: wantH)
            lastText = ""
        }

        let remaining = max(0, endDate.timeIntervalSince(now))
        let secs = Int(ceil(remaining))
        let text = String(format: "%02d:%02d", secs / 60, secs % 60)
        if text != lastText {
            lastText = text
            fluid.setSolid(makeMask(text: text, w: fluid.W, h: fluid.H))
        }

        if remaining <= 0 {
            if finishedAt == nil { finishedAt = now }
            fluid.mode = .finished
            fluid.inflow = 70
        } else if remaining <= 60 {
            fluid.mode = .warning
            fluid.inflow = 45
        } else {
            fluid.mode = .normal
            fluid.inflow = 38
        }

        fluid.step(dt)
        fluid.render()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if let img = fluid.makeImage() {
            ctx.interpolationQuality = .high
            ctx.draw(img, in: bounds)
        }
        let (a, rect) = textLayout(lastText, in: bounds.size)
        ctx.saveGState()
        ctx.setAlpha(0.93)
        a.draw(in: rect)
        ctx.restoreGState()
    }
}

// MARK: - Window + controller

final class TimerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close() } else { super.keyDown(with: event) }   // Esc closes
    }
}

final class FluidTimerController {
    private var window: TimerWindow?
    private var view: FluidTimerView?
    private var savedFrame: NSRect?
    private var isFull = false

    func start(minutes: Double) {
        stop()
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let size = NSSize(width: 720, height: 270)
        let frame = NSRect(x: screen.frame.midX - size.width / 2,
                           y: screen.frame.midY - size.height / 2,
                           width: size.width, height: size.height)
        let w = TimerWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.backgroundColor = .clear
        w.isOpaque = false
        w.hasShadow = true
        w.level = .floating
        w.isMovableByWindowBackground = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let v = FluidTimerView(frame: NSRect(origin: .zero, size: size),
                               end: Date().addingTimeInterval(minutes * 60))
        v.onDoubleClick = { [weak self] in self?.toggleFull() }
        w.contentView = v
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w,
                                               queue: .main) { [weak self] _ in
            self?.view?.stopTimer()
        }
        window = w
        view = v
        isFull = false
    }

    func stop() {
        view?.stopTimer()
        window?.orderOut(nil)
        window?.close()
        window = nil
        view = nil
    }

    func toggleFull() {
        guard let w = window else { return }
        if isFull, let f = savedFrame {
            w.setFrame(f, display: true, animate: false)
            w.level = .floating
        } else {
            savedFrame = w.frame
            let screen = w.screen ?? NSScreen.main ?? NSScreen.screens[0]
            w.setFrame(screen.frame, display: true, animate: false)
            w.level = .screenSaver
        }
        isFull.toggle()
        view?.layer?.cornerRadius = isFull ? 0 : 18
    }
}
