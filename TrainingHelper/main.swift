// TrainingHelper - screen overlay tools for online training
// Copyright (C) 2026 Matej Forman
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify it under the terms of the
// GNU General Public License as published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version. It is distributed in the hope that it will be
// useful, but WITHOUT ANY WARRANTY. See <https://www.gnu.org/licenses/>.

import Cocoa

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
