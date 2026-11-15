import AppKit
import Vision
import ScreenCaptureKit
import Carbon.HIToolbox

enum OCRFailure: LocalizedError {
    case permission, unsupported, empty, secure, unavailable, recognition
    var errorDescription: String? {
        switch self {
        case .permission: return "Screen Recording permission is required for region OCR. In System Settings → Privacy & Security → Screen & System Audio Recording, turn on TranslateGPT. If it is already on, select it, click –, add it again with +, then reopen TranslateGPT. Normal selection translation remains available."
        case .unsupported: return "Region OCR requires macOS 15.2 or later. Normal selection translation remains available."
        case .empty: return "No translatable English was recognized. Select a region with clear text."
        case .secure: return "Secure input fields cannot be translated."
        case .unavailable: return "The selected region could not be captured. Protected content may be unavailable."
        case .recognition: return "Text recognition failed. Try a smaller region with clear English text."
        }
    }
}

struct OCRLine { let text: String; let bounds: CGRect }
enum LocalOCR {
    static func ordered(_ lines: [OCRLine]) -> String {
        // Vision uses bottom-left normalized coordinates. Cluster rows first.
        var rows=[[OCRLine]]()
        for line in lines.sorted(by:{$0.bounds.midY>$1.bounds.midY}) {
            if let index=rows.firstIndex(where:{ abs($0[0].bounds.midY-line.bounds.midY) < min($0[0].bounds.height,line.bounds.height)*0.45 }) {
                rows[index].append(line)
            } else { rows.append([line]) }
        }
        return rows.map { $0.sorted{$0.bounds.minX<$1.bounds.minX}.map(\.text).joined(separator:" ") }.joined(separator:"\n")
    }
    static func recognize(_ image: CGImage) throws -> String {
        let setupStart=StageProfiler.now
        let request=VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = true
        StageProfiler.finish("ocr_request_setup",setupStart)
        do { try StageProfiler.measure("vision_recognition") {try VNImageRequestHandler(cgImage:image,options:[:]).perform([request])} }
        catch { throw OCRFailure.recognition }
        let orderStart=StageProfiler.now
        defer {StageProfiler.finish("ocr_line_order_and_filter",orderStart)}
        let text=ordered((request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map { OCRLine(text:$0.string,bounds:observation.boundingBox) }
        })
        guard SelectionPolicy.accepts(text) else { throw OCRFailure.empty }
        return text
    }
    static func capture(_ rect: CGRect) async throws -> CGImage {
        guard #available(macOS 15.2, *) else { throw OCRFailure.unsupported }
        guard CGPreflightScreenCaptureAccess() else { throw OCRFailure.permission }
        let captureStart=StageProfiler.now
        return try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(in:rect) { image,error in
                StageProfiler.finish("region_capture",captureStart)
                if let image { continuation.resume(returning:image) }
                else { continuation.resume(throwing:OCRFailure.unavailable) }
            }
        }
    }
}

@MainActor final class OCRHotKey {
    private var handler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    var action: (() -> Void)?
    func register() -> Bool {
        var type=EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed))
        let status=InstallEventHandler(GetApplicationEventTarget(),{ _,_,context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { Unmanaged<OCRHotKey>.fromOpaque(context).takeUnretainedValue().action?() }
            return noErr
        },1,&type,Unmanaged.passUnretained(self).toOpaque(),&handler)
        guard status==noErr else { return false }
        let result=RegisterEventHotKey(UInt32(kVK_ANSI_T),UInt32(controlKey|optionKey|cmdKey),EventHotKeyID(signature:0x54475054,id:1),GetApplicationEventTarget(),0,&hotKey)
        return result==noErr
    }
    func stop() { if let hotKey { UnregisterEventHotKey(hotKey) }; if let handler { RemoveEventHandler(handler) }; hotKey=nil;handler=nil }
}

@MainActor private final class RegionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor private final class RegionView: NSView {
    var began: CGPoint?
    var current: CGPoint?
    var completed: ((CGRect?) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds,cursor:.crosshair) }
    override func keyDown(with event: NSEvent) { if event.keyCode==53 { completed?(nil) } }
    override func mouseDown(with event: NSEvent) { began=convert(event.locationInWindow,from:nil);current=began;needsDisplay=true }
    override func mouseDragged(with event: NSEvent) { current=convert(event.locationInWindow,from:nil);needsDisplay=true }
    override func mouseUp(with event: NSEvent) {
        guard let began else { completed?(nil);return }
        let end=convert(event.locationInWindow,from:nil)
        let local=CGRect(x:min(began.x,end.x),y:min(began.y,end.y),width:abs(end.x-began.x),height:abs(end.y-began.y)).intersection(bounds)
        guard local.width>=4,local.height>=4,let window else { completed?(nil);return }
        completed?(window.convertToScreen(convert(local,to:nil)))
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.18).setFill();bounds.fill()
        if let began,let current {
            let rect=CGRect(x:min(began.x,current.x),y:min(began.y,current.y),width:abs(current.x-began.x),height:abs(current.y-began.y))
            NSColor.white.withAlphaComponent(0.15).setFill();rect.fill()
            NSColor.systemBlue.setStroke();let path=NSBezierPath(rect:rect);path.lineWidth=2;path.stroke()
        }
        let message="Drag around English text · Esc to cancel"
        (message as NSString).draw(at:CGPoint(x:20,y:bounds.maxY-44),withAttributes:[.font:NSFont.systemFont(ofSize:18,weight:.semibold),.foregroundColor:NSColor.white])
    }
}

@MainActor final class RegionSelector {
    private var windows=[NSPanel]()
    private var completion: ((CGRect?) -> Void)?
    var active: Bool { !windows.isEmpty }
    func begin(completion: @escaping (CGRect?) -> Void) {
        cancel();self.completion=completion
        // A single panel per display avoids huge offscreen surfaces; a region is
        // confined to the display where its drag begins, including negative origins.
        for screen in NSScreen.screens {
            let window=RegionPanel(contentRect:screen.frame,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
            window.level = .screenSaver
            window.isOpaque=false;window.backgroundColor = .clear;window.hasShadow=false
            window.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
            window.isReleasedWhenClosed=false
            let view=RegionView(frame:CGRect(origin:.zero,size:screen.frame.size))
            view.completed={ [weak self] rect in self?.finish(rect) }
            window.contentView=view;window.makeFirstResponder(view);windows.append(window)
            window.orderFrontRegardless()
        }
        let current=NSEvent.mouseLocation
        windows.first(where:{$0.frame.contains(current)})?.makeKey()
        NSCursor.crosshair.push()
    }
    func cancel() { if active { finish(nil) } }
    private func finish(_ rect: CGRect?) {
        guard active else { return }
        let callback=completion;completion=nil
        for window in windows { window.orderOut(nil) }
        windows.removeAll();NSCursor.pop()
        // Capture happens on the next run-loop turn after overlays disappear.
        DispatchQueue.main.async { callback?(rect) }
    }
}
