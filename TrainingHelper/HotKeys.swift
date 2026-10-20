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

/// System-wide hotkeys (Carbon). Unlike key monitors they need no extra privacy permission
/// and do not depend on the keyboard layout (they use physical key codes).
enum HotKeys {
    private static var actions: [UInt32: () -> Void] = [:]
    private static var refs: [EventHotKeyRef] = []
    private static var handlerInstalled = false

    /// Returns false when the combination could not be registered (e.g. another app already owns it).
    @discardableResult
    static func register(keyCode: Int, modifiers: Int, id: UInt32, action: @escaping () -> Void) -> Bool {
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x54484C50), id: id)   // 'THLP'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hkID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let r = ref else { return false }
        refs.append(r)
        actions[id] = action
        return true
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            let st = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                       EventParamType(typeEventHotKeyID), nil,
                                       MemoryLayout<EventHotKeyID>.size, nil, &hk)
            if st == noErr {
                let id = hk.id
                DispatchQueue.main.async { HotKeys.actions[id]?() }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
