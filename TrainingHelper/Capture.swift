// TrainingHelper - screen overlay tools for online training
// Copyright (C) 2026 Matej Forman
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify it under the terms of the
// GNU General Public License as published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version. It is distributed in the hope that it will be
// useful, but WITHOUT ANY WARRANTY. See <https://www.gnu.org/licenses/>.

import Cocoa
import ScreenCaptureKit
import CoreImage
import CoreMedia
import CoreVideo

enum CaptureError: Error { case noDisplay }

/// Screen capture helpers (ScreenCaptureKit, macOS 14+). Needs the Screen Recording permission.
/// Our own windows (overlays, timer) are excluded from every capture.
enum Capture {
    private static var alertShown = false

    static func filter(for displayID: CGDirectDisplayID) async throws -> (SCContentFilter, SCDisplay) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.noDisplay
        }
        let me = ProcessInfo.processInfo.processIdentifier
        let mine = content.applications.filter { $0.processID == me }
        return (SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: []), display)
    }

    static func configuration(for display: SCDisplay, pixelScale: CGFloat) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.width = Int(CGFloat(display.width) * pixelScale)
        c.height = Int(CGFloat(display.height) * pixelScale)
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.showsCursor = false
        return c
    }

    /// One still image of a display (used for "freeze screen").
    static func snapshot(displayID: CGDirectDisplayID, pixelScale: CGFloat) async throws -> CGImage {
        let (f, d) = try await filter(for: displayID)
        return try await SCScreenshotManager.captureImage(contentFilter: f,
                                                          configuration: configuration(for: d, pixelScale: pixelScale))
    }

    static func reportError(_ error: Error) {
        guard !alertShown else { return }
        alertShown = true
        let a = NSAlert()
        a.messageText = "Screen Recording permission needed"
        a.informativeText = "The magnifier and Freeze screen need the Screen Recording permission.\n\n"
            + "System Settings → Privacy & Security → Screen & System Audio Recording → enable TrainingHelper, "
            + "then quit and start the app again.\n\n(\(error.localizedDescription))"
        a.addButton(withTitle: "Open Settings")
        a.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Live capture of one display while the magnifier key is held. Frames arrive on the main queue.
final class LiveCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var generation = 0
    private var latest: CVPixelBuffer?
    private let ciContext = CIContext()

    private(set) var displayID: CGDirectDisplayID = 0
    var onFrame: (() -> Void)?
    var onError: ((Error) -> Void)?

    func start(displayID id: CGDirectDisplayID, pixelScale: CGFloat) {
        stopStream()
        generation += 1
        let gen = generation
        displayID = id
        latest = nil
        Task { @MainActor in
            do {
                let (filter, display) = try await Capture.filter(for: id)
                guard gen == self.generation else { return }
                let cfg = Capture.configuration(for: display, pixelScale: pixelScale)
                cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                cfg.queueDepth = 5
                let s = SCStream(filter: filter, configuration: cfg, delegate: self)
                try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
                try await s.startCapture()
                if gen != self.generation {
                    try? await s.stopCapture()
                    return
                }
                self.stream = s
            } catch {
                if gen == self.generation { self.onError?(error) }
            }
        }
    }

    func stop() {
        generation += 1
        stopStream()
        latest = nil
        displayID = 0
    }

    private func stopStream() {
        guard let s = stream else { return }
        stream = nil
        Task { try? await s.stopCapture() }
    }

    /// The part of the latest frame around `center` (global screen points), `regionWidth` x `regionHeight` points.
    func crop(around center: NSPoint, screenFrame: NSRect, regionWidth: CGFloat, regionHeight: CGFloat) -> CGImage? {
        guard let pb = latest, screenFrame.width > 0, screenFrame.height > 0 else { return nil }
        let pw = CGFloat(CVPixelBufferGetWidth(pb))
        let ph = CGFloat(CVPixelBufferGetHeight(pb))
        let sx = pw / screenFrame.width
        let sy = ph / screenFrame.height
        let rect = CGRect(x: (center.x - screenFrame.minX - regionWidth / 2) * sx,
                          y: (center.y - screenFrame.minY - regionHeight / 2) * sy,
                          width: regionWidth * sx,
                          height: regionHeight * sy).integral
        return ciContext.createCGImage(CIImage(cvPixelBuffer: pb), from: rect)
    }

    // MARK: SCStreamOutput / SCStreamDelegate

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        latest = pb
        onFrame?()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        latest = nil
    }
}
