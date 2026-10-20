// TrainingHelper - screen overlay tools for online training
// Copyright (C) 2026 Matej Forman
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify it under the terms of the
// GNU General Public License as published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version. It is distributed in the hope that it will be
// useful, but WITHOUT ANY WARRANTY. See <https://www.gnu.org/licenses/>.

import Cocoa

// MARK: - Overlay window

final class Overlay: NSWindow {
    /// Only true in annotate mode, when the overlay must receive keyboard input.
    var allowKey = false
    override var canBecomeKey: Bool { allowKey }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

// MARK: - Overlay view

final class DrawView: NSView, NSTextInputClient {
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        let s = State.shared
        addCursorRect(bounds, cursor: (s.annotating && s.tool == .text) ? .iBeam : .crosshair)
    }

    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }

    // Keyboard input while typing text goes through the input system (dead keys, accents).
    override func keyDown(with event: NSEvent) { interpretKeyEvents([event]) }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(NSResponder.deleteBackward(_:)):
            State.shared.backspace()
        default:
            break
        }
    }

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        if let a = string as? NSAttributedString {
            State.shared.appendText(a.string)
        } else if let t = string as? String {
            State.shared.appendText(t)
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let a = string as? NSAttributedString {
            State.shared.marked = a.string
        } else if let t = string as? String {
            State.shared.marked = t
        }
        State.shared.refresh()
    }

    func unmarkText() {
        State.shared.marked = ""
        State.shared.refresh()
    }

    func hasMarkedText() -> Bool { !State.shared.marked.isEmpty }

    func markedRange() -> NSRange {
        let m = State.shared.marked
        return m.isEmpty ? NSRange(location: NSNotFound, length: 0)
                         : NSRange(location: 0, length: (m as NSString).length)
    }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let s = State.shared
        if let i = s.editingIndex, i < s.items.count, case .text(let pos, _, _, let size) = s.items[i] {
            return NSRect(x: pos.x, y: pos.y - size * 1.4, width: 1, height: size * 1.2)
        }
        return .zero
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let win = window, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let s = State.shared
        let mouse = NSEvent.mouseLocation
        let onThisScreen = win.frame.contains(mouse)
        func local(_ p: NSPoint) -> NSPoint { win.convertPoint(fromScreen: p) }

        func strokePath(_ pts: [NSPoint], _ col: NSColor, _ width: CGFloat) {
            guard !pts.isEmpty else { return }
            let path = NSBezierPath()
            path.lineWidth = width
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: local(pts[0]))
            if pts.count == 1 { path.line(to: local(pts[0])) }
            for pt in pts.dropFirst() { path.line(to: local(pt)) }
            col.setStroke()
            path.stroke()
        }

        func strokeRect(_ r: NSRect, _ col: NSColor, _ width: CGFloat, _ alpha: CGFloat) {
            let rr = NSRect(origin: local(r.origin), size: r.size)
            let path = NSBezierPath(roundedRect: rr, xRadius: 4, yRadius: 4)
            col.withAlphaComponent(0.16 * alpha).setFill()
            path.fill()
            col.withAlphaComponent(alpha).setStroke()
            path.lineWidth = width
            path.stroke()
        }

        // 0) Frozen screen (annotate mode with a still image behind everything)
        if s.annotating, s.frozen, let scr = win.screen, let img = s.backdrops[displayID(of: scr)] {
            ctx.saveGState()
            ctx.interpolationQuality = .high
            ctx.draw(img, in: bounds)
            ctx.restoreGState()
        }

        // 1) Spotlight: dim everything, punch a soft hole around the cursor
        if s.spotlight {
            ctx.saveGState()
            ctx.setFillColor(NSColor.black.withAlphaComponent(Config.spotlightDim).cgColor)
            ctx.fill(bounds)
            if onThisScreen {
                let c = local(mouse)
                let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
                let clear = CGColor(red: 1, green: 1, blue: 1, alpha: 0)
                let colors = [white, white, clear] as CFArray
                if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors,
                                      locations: [0, 0.7, 1]) {
                    ctx.setBlendMode(.destinationOut)
                    ctx.drawRadialGradient(g, startCenter: c, startRadius: 0,
                                           endCenter: c, endRadius: s.spotlightRadius, options: [])
                }
            }
            ctx.restoreGState()
        }

        // 2) Persistent annotations (annotate mode)
        for (i, item) in s.items.enumerated() {
            switch item {
            case .stroke(let pts, let col, let w):
                strokePath(pts, col, w)
            case .rect(let a, let b, let col, let w):
                let r = NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                strokeRect(r, col, w, 1)
            case .text(let pos, let str, let col, let size):
                drawText(at: local(pos), string: str, color: col, size: size,
                         editing: i == s.editingIndex, marked: s.marked)
            }
        }

        // 3) Transient drawing (hold Fn+Shift) with fade
        let fade = s.alpha
        for stroke in s.strokes {
            strokePath(stroke, Config.penColor.withAlphaComponent(fade), Config.penWidth)
        }
        for r in s.rects {
            strokeRect(r.rect, Config.rectColor, 3, fade)
        }

        // 4) Click ripples
        let now = Date()
        let near = win.frame.insetBy(dx: -120, dy: -120)
        for rp in s.ripples where near.contains(rp.center) {
            let c = local(rp.center)
            for k in 0..<2 {
                let t = now.timeIntervalSince(rp.start) - Double(k) * 0.12
                if t < 0 || t > Config.rippleDuration { continue }
                let f = CGFloat(t / Config.rippleDuration)
                let eased = 1 - (1 - f) * (1 - f)
                let radius = 8 + 70 * eased
                let al = (1 - f) * (k == 0 ? 1.0 : 0.6)
                let path = NSBezierPath(ovalIn: NSRect(x: c.x - radius, y: c.y - radius,
                                                       width: radius * 2, height: radius * 2))
                path.lineWidth = 5 * (1 - f) + 1
                rp.color.withAlphaComponent(al).setStroke()
                path.stroke()
                if k == 0 {
                    rp.color.withAlphaComponent(al * 0.22).setFill()
                    path.fill()
                }
            }
        }

        // 5) Magnifier lens
        if s.magnifying && onThisScreen {
            drawLens(ctx: ctx, win: win, mouse: mouse, local: local(mouse))
        }

        // 6) Cursor halo (not while the lens is up)
        if onThisScreen && !s.magnifying {
            let c = local(mouse)
            let R = Config.haloRadius
            let path = NSBezierPath(ovalIn: NSRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2))
            Config.haloColor.withAlphaComponent(0.25).setFill()
            path.fill()
            Config.haloColor.withAlphaComponent(0.9).setStroke()
            path.lineWidth = 3
            path.stroke()
        }

        // 7) Annotate-mode frame + tool bar
        if s.annotating {
            (s.frozen ? NSColor.systemOrange : NSColor.systemBlue).withAlphaComponent(0.85).setStroke()
            let frame = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2))
            frame.lineWidth = 4
            frame.stroke()
            drawHUD()
        }
    }

    private func drawText(at p: NSPoint, string: String, color: NSColor, size: CGFloat,
                          editing: Bool, marked: String) {
        let font = NSFont.systemFont(ofSize: size, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let attr = NSMutableAttributedString(string: string, attributes: attrs)
        if editing {
            if !marked.isEmpty {
                var m = attrs
                m[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attr.append(NSAttributedString(string: marked, attributes: m))
            }
            var caret = attrs
            caret[.foregroundColor] = color.withAlphaComponent(0.55)
            attr.append(NSAttributedString(string: "|", attributes: caret))
        }
        let tb = attr.boundingRect(with: NSSize(width: 4000, height: 4000), options: [.usesLineFragmentOrigin])
        let pad: CGFloat = 8
        let box = NSRect(x: p.x - pad, y: p.y - tb.height - pad, width: tb.width + pad * 2, height: tb.height + pad * 2)
        NSColor.black.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        attr.draw(with: NSRect(x: p.x, y: p.y - tb.height, width: tb.width + 2, height: tb.height),
                  options: [.usesLineFragmentOrigin])
    }

    private func drawLens(ctx: CGContext, win: NSWindow, mouse: NSPoint, local c: NSPoint) {
        let s = State.shared
        let W = Config.lensWidth * s.lensScale
        let H = Config.lensHeight * s.lensScale
        let lens = NSRect(x: c.x - W / 2, y: c.y - H / 2, width: W, height: H)
        let corner: CGFloat = 16
        let shape = CGPath(roundedRect: lens, cornerWidth: corner, cornerHeight: corner, transform: nil)

        // backing plate with shadow
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 20,
                      color: NSColor.black.withAlphaComponent(0.5).cgColor)
        ctx.addPath(shape)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        // magnified screen content (same aspect ratio as the lens, so no distortion)
        if let img = s.live.crop(around: mouse, screenFrame: win.frame,
                                 regionWidth: W / s.zoom, regionHeight: H / s.zoom) {
            ctx.saveGState()
            ctx.addPath(shape)
            ctx.clip()
            ctx.interpolationQuality = .high
            ctx.draw(img, in: lens)
            ctx.restoreGState()
        }

        // border
        let ring = NSBezierPath(roundedRect: lens, xRadius: corner, yRadius: corner)
        ring.lineWidth = 4
        NSColor.white.setStroke()
        ring.stroke()

        // small cross marking the exact cursor position
        let cross = NSBezierPath()
        cross.lineWidth = 1.5
        cross.move(to: NSPoint(x: c.x - 9, y: c.y))
        cross.line(to: NSPoint(x: c.x + 9, y: c.y))
        cross.move(to: NSPoint(x: c.x, y: c.y - 9))
        cross.line(to: NSPoint(x: c.x, y: c.y + 9))
        NSColor.systemRed.withAlphaComponent(0.9).setStroke()
        cross.stroke()

        // zoom label
        let label = NSAttributedString(string: String(format: "×%.1f", s.zoom), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold),
            .foregroundColor: NSColor.white
        ])
        let ls = label.size()
        let pill = NSRect(x: lens.midX - ls.width / 2 - 8, y: lens.minY - ls.height - 14,
                          width: ls.width + 16, height: ls.height + 6)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 8, yRadius: 8).fill()
        label.draw(at: NSPoint(x: pill.minX + 8, y: pill.minY + 3))
    }

    private func drawHUD() {
        let s = State.shared
        let tools: [(String, Tool)] = [("P Pen", .pen), ("R Rect", .rect), ("T Text", .text)]
        let out = NSMutableAttributedString()
        let bold = NSFont.systemFont(ofSize: 14, weight: .semibold)
        for (label, t) in tools {
            let active = (t == s.tool)
            out.append(NSAttributedString(string: label + "     ", attributes: [
                .font: bold,
                .foregroundColor: active ? NSColor.systemYellow : NSColor.white.withAlphaComponent(0.75)
            ]))
        }
        let hint = s.editingIndex != nil
            ? "↩ done   ⇧↩ new line   esc"
            : "1–5 colour   ↑↓ size   ⌫ undo   X clear   esc exit"
        out.append(NSAttributedString(string: hint, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.white.withAlphaComponent(0.6)
        ]))
        let sz = out.size()
        let dot: CGFloat = 14
        let w = sz.width + dot + 44
        let rect = NSRect(x: (bounds.width - w) / 2, y: bounds.height - 92, width: w, height: sz.height + 18)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        s.color.setFill()
        NSBezierPath(ovalIn: NSRect(x: rect.minX + 16, y: rect.midY - dot / 2, width: dot, height: dot)).fill()
        out.draw(at: NSPoint(x: rect.minX + 16 + dot + 12, y: rect.minY + 9))
    }
}
