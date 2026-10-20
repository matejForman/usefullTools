// TrainingHelper - screen overlay tools for online training
// Copyright (C) 2026 Matej Forman
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify it under the terms of the
// GNU General Public License as published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version. It is distributed in the hope that it will be
// useful, but WITHOUT ANY WARRANTY. See <https://www.gnu.org/licenses/>.

import Cocoa
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var spotlightItem: NSMenuItem!
    var rippleItem: NSMenuItem!
    var sizeItems: [NSMenuItem] = []
    let timer = FluidTimerController()

    func applicationDidFinishLaunching(_ n: Notification) {
        // Ask for the permission needed to see global key presses (Fn+Shift etc.)
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)

        rebuildWindows()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.rebuildWindows()
        }
        // Switching to another app (Cmd+Tab) leaves annotate mode.
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                               object: nil, queue: .main) { _ in
            State.shared.endAnnotate(restoreFocus: false)
        }

        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp,
                                           .rightMouseDown, .flagsChanged, .keyDown, .scrollWheel]
        NSEvent.addGlobalMonitorForEvents(matching: mask) { _ = State.shared.handle($0) }
        NSEvent.addLocalMonitorForEvents(matching: mask) { State.shared.handle($0) ? nil : $0 }

        buildMenu()
        State.shared.onSpotlightChange = { [weak self] in
            self?.spotlightItem.state = State.shared.spotlight ? .on : .off
        }
        registerHotKeys()
    }

    /// Control+Option + S / A / F, system-wide, independent of the keyboard layout.
    func registerHotKeys() {
        let mods = controlKey | optionKey
        var failed: [String] = []
        if !HotKeys.register(keyCode: kVK_ANSI_S, modifiers: mods, id: 1, action: { State.shared.toggleSpotlight() }) {
            failed.append("⌃⌥S")
        }
        if !HotKeys.register(keyCode: kVK_ANSI_A, modifiers: mods, id: 2, action: { State.shared.toggleAnnotate(frozen: false) }) {
            failed.append("⌃⌥A")
        }
        if !HotKeys.register(keyCode: kVK_ANSI_F, modifiers: mods, id: 3, action: { State.shared.toggleAnnotate(frozen: true) }) {
            failed.append("⌃⌥F")
        }
        if !failed.isEmpty {
            let a = NSAlert()
            a.messageText = "Shortcut not available"
            a.informativeText = failed.joined(separator: ", ") + " could not be registered (another app probably uses it). The menu items still work."
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
        }
    }

    // One transparent overlay per display; rebuilt when displays change.
    func rebuildWindows() {
        State.shared.windows.forEach { $0.orderOut(nil) }
        State.shared.windows.removeAll()
        for screen in NSScreen.screens {
            let w = Overlay(contentRect: screen.frame, styleMask: .borderless,
                            backing: .buffered, defer: false, screen: screen)
            w.isReleasedWhenClosed = false
            w.setFrame(screen.frame, display: true)
            w.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            w.backgroundColor = .clear
            w.isOpaque = false
            w.hasShadow = false
            w.sharingType = .readOnly
            w.allowKey = State.shared.annotating
            w.ignoresMouseEvents = !State.shared.capturesMouse
            w.acceptsMouseMovedEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.contentView = DrawView(frame: NSRect(origin: .zero, size: screen.frame.size))
            w.orderFrontRegardless()
            State.shared.windows.append(w)
        }
    }

    func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "✎"

        let menu = NSMenu()

        rippleItem = NSMenuItem(title: "Click ripples", action: #selector(toggleRipples), keyEquivalent: "")
        rippleItem.target = self
        rippleItem.state = State.shared.ripplesEnabled ? .on : .off
        menu.addItem(rippleItem)

        spotlightItem = NSMenuItem(title: "Spotlight (⌃⌥S)", action: #selector(toggleSpotlight), keyEquivalent: "")
        spotlightItem.target = self
        menu.addItem(spotlightItem)

        let sizeMenu = NSMenu()
        for (title, radius) in [("Small", 220), ("Medium", 360), ("Large", 520), ("Huge", 760)] {
            let it = NSMenuItem(title: title, action: #selector(setSpotlightSize(_:)), keyEquivalent: "")
            it.tag = radius
            it.target = self
            it.state = Int(State.shared.spotlightRadius) == radius ? .on : .off
            sizeMenu.addItem(it)
            sizeItems.append(it)
        }
        let sizeParent = NSMenuItem(title: "Spotlight size", action: nil, keyEquivalent: "")
        sizeParent.submenu = sizeMenu
        menu.addItem(sizeParent)

        menu.addItem(.separator())

        let annotate = NSMenuItem(title: "Annotate screen (⌃⌥A)", action: #selector(annotateLive), keyEquivalent: "")
        annotate.target = self
        menu.addItem(annotate)

        let freeze = NSMenuItem(title: "Freeze screen & annotate (⌃⌥F)", action: #selector(annotateFrozen), keyEquivalent: "")
        freeze.target = self
        menu.addItem(freeze)

        menu.addItem(.separator())

        let sub = NSMenu()
        for m in [1, 5, 10, 15, 20] {
            let it = NSMenuItem(title: "\(m) min", action: #selector(startTimer(_:)), keyEquivalent: "")
            it.tag = m
            it.target = self
            sub.addItem(it)
        }
        let custom = NSMenuItem(title: "Custom…", action: #selector(customTimer), keyEquivalent: "")
        custom.target = self
        sub.addItem(custom)
        let parent = NSMenuItem(title: "Break timer", action: nil, keyEquivalent: "")
        parent.submenu = sub
        menu.addItem(parent)

        let stop = NSMenuItem(title: "Stop timer", action: #selector(stopTimer), keyEquivalent: "")
        stop.target = self
        menu.addItem(stop)

        menu.addItem(.separator())

        // Cheat sheet (items without an action are shown greyed out)
        let help = NSMenu()
        let lines = [
            "Hold Fn+Shift: draw (fades out)",
            "Hold Fn+Shift+Option: rectangle",
            "Hold Fn+Control: magnifier, scroll = zoom",
            "   + Option while scrolling = lens size",
            "⌃⌥S: spotlight",
            "⌃⌥A: annotate   ⌃⌥F: freeze + annotate",
            "In annotate: P pen · R rectangle · T text",
            "1–5 colour · ↑↓ size · ⌫ undo · X clear · Esc exit",
            "Text: Return = done, ⇧Return = new line"
        ]
        for l in lines { help.addItem(NSMenuItem(title: l, action: nil, keyEquivalent: "")) }
        let helpItem = NSMenuItem(title: "Shortcuts", action: nil, keyEquivalent: "")
        helpItem.submenu = help
        menu.addItem(helpItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc func toggleRipples() {
        State.shared.ripplesEnabled.toggle()
        rippleItem.state = State.shared.ripplesEnabled ? .on : .off
    }

    @objc func toggleSpotlight() { State.shared.toggleSpotlight() }

    @objc func setSpotlightSize(_ sender: NSMenuItem) {
        State.shared.spotlightRadius = CGFloat(sender.tag)
        for it in sizeItems { it.state = (it.tag == sender.tag) ? .on : .off }
        State.shared.refresh()
    }

    // Short delay so the status-bar menu is gone before the screen is captured.
    @objc func annotateLive() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { State.shared.toggleAnnotate(frozen: false) }
    }

    @objc func annotateFrozen() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { State.shared.toggleAnnotate(frozen: true) }
    }

    @objc func startTimer(_ sender: NSMenuItem) { timer.start(minutes: Double(sender.tag)) }
    @objc func stopTimer() { timer.stop() }

    @objc func customTimer() {
        let alert = NSAlert()
        alert.messageText = "Break timer"
        alert.informativeText = "Minutes:"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        field.stringValue = "10"
        alert.accessoryView = field
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let txt = field.stringValue.replacingOccurrences(of: ",", with: ".")
            if let m = Double(txt), m > 0 { timer.start(minutes: m) }
        }
    }
}
