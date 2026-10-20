// TrainingHelper - screen overlay tools for online training
// Copyright (C) 2026 Matej Forman
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify it under the terms of the
// GNU General Public License as published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version. It is distributed in the hope that it will be
// useful, but WITHOUT ANY WARRANTY. See <https://www.gnu.org/licenses/>.

import Cocoa

// MARK: - Settings (tweak to taste)

enum Config {
    // Hold Fn+Shift to draw (fades after release); add Option for a rectangle.
    static let holdFlags: NSEvent.ModifierFlags = [.function, .shift]
    static let rectExtraFlag: NSEvent.ModifierFlags = .option

    // Hold Fn+Control for the magnifier; scroll wheel changes the zoom.
    static let magnifyFlags: NSEvent.ModifierFlags = [.function, .control]

    // Hotkeys (Control+Option + S / A / F) are registered in App.swift.

    static let fadeDelay: TimeInterval = 0.7
    static let fadeDuration: TimeInterval = 0.6

    static let penColor = NSColor.systemRed
    static let penWidth: CGFloat = 4
    static let rectColor = NSColor.systemYellow

    static let haloRadius: CGFloat = 30
    static let haloColor = NSColor.systemYellow

    static let leftClickColor = NSColor.systemRed
    static let rightClickColor = NSColor.systemBlue
    static let rippleDuration: TimeInterval = 0.7

    static let spotlightRadiusDefault: CGFloat = 360   // changeable from the menu
    static let spotlightDim: CGFloat = 0.65

    // Annotate mode (keys 1-5 pick the colour)
    static let palette: [NSColor] = [.systemRed, .systemYellow, .systemGreen, .systemBlue, .white]
    static let textSize: CGFloat = 30

    // Magnifier: a rectangle (points) centred on the cursor; Option+scroll scales it
    static let lensWidth: CGFloat = 760
    static let lensHeight: CGFloat = 440
    static let lensScaleMin: CGFloat = 0.5
    static let lensScaleMax: CGFloat = 1.6
    static let zoomDefault: CGFloat = 3
    static let zoomMin: CGFloat = 1.5
    static let zoomMax: CGFloat = 10
}

// MARK: - Models

struct Ripple {
    let center: NSPoint
    let start: Date
    let color: NSColor
}

struct RectAnno {
    var a: NSPoint
    var b: NSPoint
    var rect: NSRect {
        NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

enum Tool { case pen, rect, text }

/// Persistent annotation (annotate mode). Points are in global screen coordinates.
enum Item {
    case stroke(points: [NSPoint], color: NSColor, width: CGFloat)
    case rect(a: NSPoint, b: NSPoint, color: NSColor, width: CGFloat)
    case text(pos: NSPoint, string: String, color: NSColor, size: CGFloat)
}

func displayID(of screen: NSScreen) -> CGDirectDisplayID {
    let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    return n?.uint32Value ?? 0
}

func screenUnderCursor() -> NSScreen? {
    let p = NSEvent.mouseLocation
    return NSScreen.screens.first(where: { $0.frame.contains(p) }) ?? NSScreen.main
}

// MARK: - Shared state

final class State {
    static let shared = State()

    var windows: [NSWindow] = []

    // --- transient drawing (hold Fn+Shift) ---
    var strokes: [[NSPoint]] = []
    var rects: [RectAnno] = []
    var ripples: [Ripple] = []
    var held = false
    var rectMode = false
    var alpha: CGFloat = 1
    var releasedAt: Date?
    var animTimer: Timer?
    private enum Drag { case none, stroke, rect }
    private var drag: Drag = .none

    // --- spotlight ---
    var spotlight = false
    var onSpotlightChange: (() -> Void)?
    var spotlightRadius: CGFloat = {
        let v = UserDefaults.standard.double(forKey: "spotlightRadius")
        return v > 0 ? CGFloat(v) : Config.spotlightRadiusDefault
    }() {
        didSet { UserDefaults.standard.set(Double(spotlightRadius), forKey: "spotlightRadius") }
    }

    // --- click ripples (setting is remembered) ---
    var ripplesEnabled: Bool = (UserDefaults.standard.object(forKey: "ripplesEnabled") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(ripplesEnabled, forKey: "ripplesEnabled") }
    }

    // --- magnifier (hold Fn+Control) ---
    var magnifying = false
    var zoom: CGFloat = Config.zoomDefault
    var lensScale: CGFloat = 1
    let live = LiveCapture()

    // --- annotate mode ---
    var annotating = false
    var frozen = false
    var capturing = false
    var tool: Tool = .pen
    var colorIndex = 0
    var sizeScale: CGFloat = 1
    var items: [Item] = []
    var editingIndex: Int?
    var marked = ""
    var backdrops: [CGDirectDisplayID: CGImage] = [:]
    private var dragging = false
    private var previousApp: NSRunningApplication?

    private static let numberRowKeyCodes: [UInt16] = [18, 19, 20, 21, 23]   // keys 1-5, layout independent

    private init() {
        live.onFrame = { [weak self] in self?.refresh() }
        live.onError = { [weak self] error in
            self?.setMagnify(false)
            Capture.reportError(error)
        }
    }

    var color: NSColor { Config.palette[colorIndex % Config.palette.count] }
    var capturesMouse: Bool { held || magnifying || annotating }

    func refresh() { windows.forEach { $0.contentView?.needsDisplay = true } }

    func updateCursors() {
        for w in windows {
            if let v = w.contentView { w.invalidateCursorRects(for: v) }
        }
    }

    /// Overlays are click-through unless we need the mouse (drawing, magnifier, annotate).
    func updateMouseCapture() {
        let capture = capturesMouse
        windows.forEach { $0.ignoresMouseEvents = !capture }
        updateCursors()
    }

    // MARK: hold-to-draw

    func setHeld(_ on: Bool) {
        guard on != held else { return }
        if on && annotating { return }
        held = on
        updateMouseCapture()
        if on {
            releasedAt = nil
            alpha = 1
            strokes.removeAll()
            rects.removeAll()
        } else {
            drag = .none
            if !strokes.isEmpty || !rects.isEmpty {
                releasedAt = Date()
                startAnim()
            }
        }
        refresh()
    }

    // MARK: ripples + spotlight

    func addRipple(_ p: NSPoint, _ color: NSColor) {
        ripples.append(Ripple(center: p, start: Date(), color: color))
        startAnim()
    }

    func toggleSpotlight() {
        spotlight.toggle()
        onSpotlightChange?()
        refresh()
    }

    func startAnim() {
        guard animTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        animTimer = t
    }

    func tick() {
        let now = Date()
        ripples.removeAll { now.timeIntervalSince($0.start) > Config.rippleDuration + 0.2 }
        if let t0 = releasedAt {
            let t = now.timeIntervalSince(t0)
            if t > Config.fadeDelay {
                alpha = max(0, 1 - CGFloat((t - Config.fadeDelay) / Config.fadeDuration))
            }
            if alpha <= 0 {
                strokes.removeAll()
                rects.removeAll()
                alpha = 1
                releasedAt = nil
            }
        }
        if ripples.isEmpty && releasedAt == nil {
            animTimer?.invalidate()
            animTimer = nil
        }
        refresh()
    }

    // MARK: magnifier

    func setMagnify(_ on: Bool) {
        guard on != magnifying else { return }
        if on && (held || annotating) { return }
        magnifying = on
        updateMouseCapture()
        if on {
            if let s = screenUnderCursor() {
                live.start(displayID: displayID(of: s), pixelScale: s.backingScaleFactor)
            }
        } else {
            live.stop()
        }
        refresh()
    }

    private func retargetLive() {
        guard let s = screenUnderCursor() else { return }
        let id = displayID(of: s)
        if id != live.displayID { live.start(displayID: id, pixelScale: s.backingScaleFactor) }
    }

    // MARK: annotate mode

    /// Toggle annotate mode. With `frozen` the screen is captured first and shown as a still image.
    func toggleAnnotate(frozen wantFrozen: Bool) {
        if annotating { endAnnotate(); return }
        guard !capturing else { return }
        if wantFrozen {
            capturing = true
            let screens = NSScreen.screens
            Task { @MainActor in
                var shots: [CGDirectDisplayID: CGImage] = [:]
                do {
                    for s in screens {
                        let id = displayID(of: s)
                        shots[id] = try await Capture.snapshot(displayID: id, pixelScale: s.backingScaleFactor)
                    }
                } catch {
                    self.capturing = false
                    Capture.reportError(error)
                    return
                }
                self.capturing = false
                self.backdrops = shots
                self.beginAnnotate(frozen: true)
            }
        } else {
            beginAnnotate(frozen: false)
        }
    }

    private func beginAnnotate(frozen isFrozen: Bool) {
        guard !annotating else { return }
        setHeld(false)
        setMagnify(false)
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = (front?.processIdentifier == ProcessInfo.processInfo.processIdentifier) ? nil : front
        annotating = true
        frozen = isFrozen
        items.removeAll()
        editingIndex = nil
        marked = ""
        tool = .pen
        windows.forEach { ($0 as? Overlay)?.allowKey = true }
        updateMouseCapture()
        NSApp.activate(ignoringOtherApps: true)
        let target = windows.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? windows.first
        target?.makeKeyAndOrderFront(nil)
        for w in windows {
            if let v = w.contentView { w.makeFirstResponder(v) }
        }
        refresh()
    }

    func endAnnotate(restoreFocus: Bool = true) {
        guard annotating else { return }
        commitEditing()
        annotating = false
        frozen = false
        dragging = false
        items.removeAll()
        backdrops.removeAll()
        windows.forEach { ($0 as? Overlay)?.allowKey = false }
        updateMouseCapture()
        if restoreFocus { previousApp?.activate(options: []) }
        previousApp = nil
        refresh()
    }

    func commitEditing() {
        guard let i = editingIndex else { return }
        editingIndex = nil
        marked = ""
        if i < items.count, case .text(_, let s, _, _) = items[i],
           s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.remove(at: i)
        }
    }

    func appendText(_ s: String) {
        guard let i = editingIndex, i < items.count,
              case .text(let pos, let str, let c, let sz) = items[i] else { return }
        items[i] = .text(pos: pos, string: str + s, color: c, size: sz)
        marked = ""
        refresh()
    }

    func backspace() {
        guard let i = editingIndex, i < items.count,
              case .text(let pos, let str, let c, let sz) = items[i] else { return }
        if !marked.isEmpty {
            marked = ""
        } else {
            items[i] = .text(pos: pos, string: String(str.dropLast()), color: c, size: sz)
        }
        refresh()
    }

    private func undo() {
        if !items.isEmpty { items.removeLast() }
    }

    // MARK: event handling

    /// Returns true when the event was consumed (the local monitor then swallows it).
    @discardableResult
    func handle(_ e: NSEvent) -> Bool {
        if annotating { return handleAnnotate(e) }

        let p = NSEvent.mouseLocation
        switch e.type {
        case .flagsChanged:
            let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            rectMode = f.contains(Config.rectExtraFlag)
            let h = f.isSuperset(of: Config.holdFlags)
            setHeld(h)
            setMagnify(!h && f.isSuperset(of: Config.magnifyFlags))

        case .leftMouseDown:
            if held {
                if rectMode {
                    rects.append(RectAnno(a: p, b: p))
                    drag = .rect
                } else {
                    strokes.append([p])
                    drag = .stroke
                }
            } else if ripplesEnabled && !magnifying {
                addRipple(p, Config.leftClickColor)
            }

        case .rightMouseDown:
            if ripplesEnabled && !held && !magnifying { addRipple(p, Config.rightClickColor) }

        case .leftMouseDragged:
            if held {
                switch drag {
                case .stroke:
                    if !strokes.isEmpty { strokes[strokes.count - 1].append(p) }
                case .rect:
                    if !rects.isEmpty { rects[rects.count - 1].b = p }
                case .none:
                    break
                }
            }

        case .leftMouseUp:
            drag = .none

        case .mouseMoved:
            if magnifying { retargetLive() }

        case .scrollWheel:
            if magnifying {
                let d = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY * 0.02 : e.scrollingDeltaY * 0.25
                if e.modifierFlags.contains(.option) {
                    lensScale = min(max(lensScale + d * 0.3, Config.lensScaleMin), Config.lensScaleMax)
                } else {
                    zoom = min(max(zoom + d, Config.zoomMin), Config.zoomMax)
                }
                refresh()
                return true
            }

        default:
            break
        }
        refresh()
        return false
    }

    private func handleAnnotate(_ e: NSEvent) -> Bool {
        let p = NSEvent.mouseLocation
        switch e.type {
        case .leftMouseDown:
            let col = color
            switch tool {
            case .pen:
                items.append(.stroke(points: [p], color: col, width: Config.penWidth * sizeScale))
                dragging = true
            case .rect:
                items.append(.rect(a: p, b: p, color: col, width: 3 * sizeScale))
                dragging = true
            case .text:
                commitEditing()
                items.append(.text(pos: p, string: "", color: col, size: Config.textSize * sizeScale))
                editingIndex = items.count - 1
            }

        case .leftMouseDragged:
            guard dragging, let last = items.indices.last else { break }
            switch items[last] {
            case .stroke(var pts, let c, let w):
                pts.append(p)
                items[last] = .stroke(points: pts, color: c, width: w)
            case .rect(let a, _, let c, let w):
                items[last] = .rect(a: a, b: p, color: c, width: w)
            default:
                break
            }

        case .leftMouseUp:
            dragging = false

        case .keyDown:
            let consumed = handleAnnotateKey(e)
            refresh()
            return consumed

        default:
            break
        }
        refresh()
        return false
    }

    private func handleAnnotateKey(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        let ch = e.charactersIgnoringModifiers?.lowercased() ?? ""

        // Typing text: Return finishes, Shift/Option+Return = new line, everything else goes to the
        // text input system (so dead keys and accents work).
        if editingIndex != nil {
            switch e.keyCode {
            case 53:
                commitEditing()
                return true
            case 36, 76:
                if mods.contains(.shift) || mods.contains(.option) { appendText("\n") } else { commitEditing() }
                return true
            default:
                return false
            }
        }

        switch e.keyCode {
        case 53:                         // Esc
            endAnnotate()
            return true
        case 51:                         // Backspace = undo
            undo()
            return true
        case 126:                        // Up = bigger
            sizeScale = min(sizeScale + 0.25, 3)
            return true
        case 125:                        // Down = smaller
            sizeScale = max(sizeScale - 0.25, 0.5)
            return true
        default:
            break
        }

        if let idx = State.numberRowKeyCodes.firstIndex(of: e.keyCode) {
            colorIndex = idx
            return true
        }
        if mods == .command && ch == "z" {
            undo()
            return true
        }
        if mods.isEmpty || mods == .shift {
            switch ch {
            case "p": tool = .pen; updateCursors()
            case "r": tool = .rect; updateCursors()
            case "t": tool = .text; updateCursors()
            case "x": items.removeAll()
            default: break
            }
        }
        return true   // swallow everything else while annotating (no system beeps)
    }
}
