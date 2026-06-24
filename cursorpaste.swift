// cursorpaste — float an image on the cursor; click to paste it into whatever
// app you click, Esc to cancel. Used by screenshot-ai's "Auto-delete" path so
// you can drop a screenshot straight into your AI tool, then it self-deletes.
//
// Build: xcrun swiftc -O -o cursorpaste cursorpaste.swift
// Run:   cursorpaste /path/to/image.png    (exit 0 = pasted, 1 = cancelled)
//
// Needs Accessibility permission (to watch for the click/Esc and to send ⌘V).

import Cocoa
import ApplicationServices

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: cursorpaste <image-path>\n".utf8))
    exit(2)
}
let imagePath = args[1]
guard let image = NSImage(contentsOfFile: imagePath) else {
    FileHandle.standardError.write(Data("cursorpaste: cannot load image \(imagePath)\n".utf8))
    exit(2)
}
let fileURL = URL(fileURLWithPath: imagePath)

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // no Dock icon, don't steal focus

// Prompt for Accessibility on first run. Without it the overlay still follows
// the cursor, but the click/Esc monitors and ⌘V won't work.
let axOpts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
let trusted = AXIsProcessTrustedWithOptions(axOpts)
if !trusted {
    FileHandle.standardError.write(Data("cursorpaste: needs Accessibility permission — grant it in System Settings → Privacy & Security → Accessibility, then try again.\n".utf8))
}

// --- thumbnail floating panel ---------------------------------------------
let maxSide: CGFloat = 220
let sz = image.size
let scale = min(1, maxSide / max(sz.width, sz.height))
let thumb = NSSize(width: max(40, sz.width * scale), height: max(40, sz.height * scale))

let panel = NSPanel(contentRect: NSRect(origin: .zero, size: thumb),
                    styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered, defer: false)
panel.isFloatingPanel = true
panel.level = .screenSaver
panel.backgroundColor = .clear
panel.isOpaque = false
panel.hasShadow = true
panel.ignoresMouseEvents = true // clicks pass through to the app underneath
panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
panel.alphaValue = 0.92

let iv = NSImageView(frame: NSRect(origin: .zero, size: thumb))
iv.image = image
iv.imageScaling = .scaleProportionallyUpOrDown
iv.wantsLayer = true
iv.layer?.cornerRadius = 8
iv.layer?.masksToBounds = true
iv.layer?.borderWidth = 2
iv.layer?.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
panel.contentView = iv
panel.orderFrontRegardless()

// Follow the cursor (offset down-right so the cursor stays visible).
func reposition() {
    let m = NSEvent.mouseLocation
    panel.setFrameOrigin(NSPoint(x: m.x + 14, y: m.y - thumb.height - 14))
}
reposition()
let follow = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { _ in reposition() }
RunLoop.main.add(follow, forMode: .common)

// --- paste + exit ----------------------------------------------------------
func copyToPasteboard() {
    let pb = NSPasteboard.general
    pb.clearContents()
    let item = NSPasteboardItem()
    if let tiff = image.tiffRepresentation,
       let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        item.setData(png, forType: .png)
        item.setData(tiff, forType: .tiff)
    }
    pb.writeObjects([item, fileURL as NSURL]) // image data + the file itself
}

func sendPaste() {
    let src = CGEventSource(stateID: .combinedSessionState)
    let vKey: CGKeyCode = 0x09 // 'v'
    let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
    down?.flags = .maskCommand
    let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
    up?.flags = .maskCommand
    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)
}

var finished = false
func finish(_ code: Int32) {
    if finished { return }
    finished = true
    follow.invalidate()
    panel.orderOut(nil)
    exit(code)
}

// Esc cancels.
NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { ev in
    if ev.keyCode == 53 { finish(1) } // 53 = Escape
}

// A click drops it: the click focuses the target field, then we paste into it.
NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { _ in
    copyToPasteboard()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
        sendPaste()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { finish(0) }
    }
}

app.run()
