import AppKit

struct FakeSelectionAccess: SelectionAccess {
    var focus: Int? = 1
    var hits=[1,1]
    var parents=[Int:Int]()
    var values=[Int:String]()
    var secured=Set<Int>()
    var foreign=Set<Int>()
    var boundaries=Set<Int>()
    var covered=Set<Int>()
    func focused() -> Int? { focus }
    func hit(_ point: CGPoint) -> Int? { point.x<10 ? hits.first:hits.last }
    func parent(_ e:Int) -> Int? { parents[e] }
    func same(_ a:Int,_ b:Int) -> Bool { a==b }
    func belongs(_ e:Int) -> Bool { !foreign.contains(e) }
    func boundary(_ e:Int) -> Bool { boundaries.contains(e) }
    func secure(_ e:Int) -> Bool { secured.contains(e) }
    func contains(_ e:Int,_ p:CGPoint) -> Bool { covered.contains(e) }
    func selected(_ e:Int) -> String? { values[e] }
}

@main struct GlobalVerification {
    static let lines=["Vision-language models adapt to new tasks.","The model compares two images."]
    @MainActor static func main() async throws {
        let suite="TranslateGPT-global-tests-"+UUID().uuidString
        let defaults=UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let settings=SelectionSettings(defaults:defaults)
        let unknown=SourceApplication(pid:98765,key:"/tmp/synthetic-unbundled-app",name:"Synthetic")
        precondition(settings.enabled && settings.permits(unknown))
        settings.enabled=false
        precondition(!SelectionSettings(defaults:defaults).enabled && !settings.permits(unknown))
        precondition(settings.permits(unknown,manual:true))
        settings.enabled=true;settings.exclude(unknown)
        precondition(!SelectionSettings(defaults:defaults).permits(unknown) && !settings.permits(unknown,manual:true))
        settings.include(unknown.key);precondition(settings.permits(unknown))
        settings.screenPermissionRequested=true;precondition(SelectionSettings(defaults:defaults).screenPermissionRequested)
        defaults.set("0.0.0/0",forKey:"TranslateGPT.ocrPermissionRequestedBuild");precondition(!settings.screenPermissionRequested)
        defaults.set(true,forKey:"TranslateGPT.ocrPermissionRequested");precondition(!settings.screenPermissionRequested)
        precondition(!settings.permits(.init(pid:getpid(),key:"own",name:"Own")))
        precondition(!settings.permits(.init(pid:98765,key:"com.xw.quickselecttranslate",name:"Own")))
        print("PASS settings: global default, restart persistence, exclusions, manual OCR, unbundled process and own-app rejection")
        let fakeApps=FileManager.default.temporaryDirectory.appendingPathComponent("TranslateGPT-electron-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:fakeApps) }
        let electron=fakeApps.appendingPathComponent("Chat.app"), native=fakeApps.appendingPathComponent("Notes.app")
        try? FileManager.default.createDirectory(at:electron.appendingPathComponent("Contents/Frameworks/Electron Framework.framework"),withIntermediateDirectories:true)
        try? FileManager.default.createDirectory(at:native.appendingPathComponent("Contents/MacOS"),withIntermediateDirectories:true)
        precondition(ElectronAccessibilityPolicy.eligible(bundleID:"com.example.chat",bundleURL:electron))
        precondition(!ElectronAccessibilityPolicy.eligible(bundleID:"com.microsoft.VSCode",bundleURL:electron))
        precondition(!ElectronAccessibilityPolicy.eligible(bundleID:"com.example.notes",bundleURL:native) && !ElectronAccessibilityPolicy.eligible(bundleID:nil,bundleURL:nil))
        precondition(SelectedContent.none.diagnosticKind=="none" && SelectedContent.text("x").diagnosticKind=="text")
        print("PASS Electron selection access: Electron apps eligible once readable text is missing; code editors and native apps excluded")
        precondition(settings.copyFallback);settings.copyFallback=false;precondition(!SelectionSettings(defaults:defaults).copyFallback);settings.copyFallback=true
        precondition(CopyFallbackPolicy.allowed(bundleID:"com.example.reader",startRole:"AXGroup",secureInput:false,nearTitleBar:false))
        precondition(!CopyFallbackPolicy.allowed(bundleID:"com.example.reader",startRole:"AXGroup",secureInput:true,nearTitleBar:false))
        precondition(!CopyFallbackPolicy.allowed(bundleID:"com.example.reader",startRole:"AXGroup",secureInput:false,nearTitleBar:true))
        precondition(!CopyFallbackPolicy.allowed(bundleID:"com.apple.finder",startRole:"AXGroup",secureInput:false,nearTitleBar:false))
        precondition(!CopyFallbackPolicy.allowed(bundleID:"com.1password.1password",startRole:nil,secureInput:false,nearTitleBar:false))
        precondition(!CopyFallbackPolicy.allowed(bundleID:"com.example.reader",startRole:"AXScrollBar",secureInput:false,nearTitleBar:false))
        precondition(CopyFallbackPolicy.acceptsCopiedTypes(["public.utf8-plain-text","public.rtf"]))
        precondition(!CopyFallbackPolicy.acceptsCopiedTypes(["public.utf8-plain-text","public.file-url"]) && !CopyFallbackPolicy.acceptsCopiedTypes(["public.png"]))
        let board=NSPasteboard(name:NSPasteboard.Name("TranslateGPT-test-"+UUID().uuidString)), empty=NSPasteboard(name:NSPasteboard.Name("TranslateGPT-test-"+UUID().uuidString))
        defer { board.releaseGlobally(); empty.releaseGlobally() }
        board.clearContents()
        let original=NSPasteboardItem();original.setString("user clipboard",forType:.string);original.setData(Data([1,2,3]),forType:NSPasteboard.PasteboardType("com.example.private"))
        board.writeObjects([original]);let saved=PasteboardSnapshot(board)
        board.clearContents();board.setString("copied selection",forType:.string)
        saved.restore(to:board);precondition(PasteboardSnapshot(board)==saved && board.string(forType:.string)=="user clipboard")
        empty.clearContents();let nothing=PasteboardSnapshot(empty);empty.setString("x",forType:.string);nothing.restore(to:empty);precondition(PasteboardSnapshot(empty).items.isEmpty)
        print("PASS copy fallback: on by default with opt-out; refuses secure input, title bars, controls, Finder and password managers; text-only copies; exact clipboard restore")

        let start=CGPoint(x:0,y:0),end=CGPoint(x:20,y:0)
        func read(_ access:FakeSelectionAccess) -> SelectedContent { SelectionExtractor(access:access).read(start:start,end:end) }
        var access=FakeSelectionAccess();access.values=[1:lines[0]]
        precondition(read(access) == .text(lines[0]))
        access.hits=[2,3];access.parents=[2:1,3:1]
        precondition(read(access) == .text(lines[0]))
        access.values[2]=lines[1];precondition(read(access) == .ambiguous)
        access.values.removeValue(forKey:2);access.secured=[1];precondition(read(access) == .secure)
        access.secured=[];access.hits=[8,9];access.parents=[8:10,9:10];access.boundaries=[10]
        precondition(read(access) == .none) // old focused selection in another pane
        access.foreign=[8,9];precondition(read(access) == .unavailable)
        access.foreign=[];access.covered=[1];precondition(read(access) == .text(lines[0]))
        access=FakeSelectionAccess();access.values=[1:String(repeating:"A",count:12001)]
        precondition(read(access) == .unavailable)
        access=FakeSelectionAccess();access.parents=[1:2,2:1];access.values=[1:lines[0]]
        precondition(read(access) == .text(lines[0]))
        precondition(!SelectionPolicy.isSelectionGesture(start:start,end:CGPoint(x:1,y:1),clicks:1))
        precondition(!SelectionPolicy.isSelectionGesture(start:nil,end:end,clicks:2))
        precondition(SelectionPolicy.isSelectionGesture(start:start,end:start,clicks:2))
        precondition(SelectionPolicy.isSelectionGesture(start:start,end:end,clicks:1))
        precondition(SelectionPolicy.accepts(lines[0]) && !SelectionPolicy.accepts("sender@example.invalid"))
        precondition(!SelectionPolicy.accepts("https://example.invalid") && !SelectionPolicy.accepts("10.1.2.3"))
        print("PASS extraction: selected text, touched ancestors, ambiguous and stale-pane rejection, secure ancestors, foreign process, cycles, lengths and ordinary clicks")

        precondition(ScreenCoordinates.quartz(CGRect(x:100,y:100,width:300,height:200),primaryHeight:900)==CGRect(x:100,y:600,width:300,height:200))
        precondition(ScreenCoordinates.quartz(CGRect(x:-1200,y:1000,width:400,height:200),primaryHeight:900)==CGRect(x:-1200,y:-300,width:400,height:200))
        let order=LocalOCR.ordered([.init(text:"second",bounds:.init(x:0,y:0.2,width:0.5,height:0.1)),.init(text:"right",bounds:.init(x:0.5,y:0.8,width:0.4,height:0.1)),.init(text:"first",bounds:.init(x:0,y:0.8,width:0.4,height:0.1))])
        precondition(order=="first right\nsecond")
        print("PASS coordinates and OCR line order: primary, negative origins and display above primary (point coordinates, independent of pixel scale)")

        if CommandLine.arguments.contains("--vision-check") {
        let bitmap=CGContext(data:nil,width:1600,height:260,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        bitmap.setFillColor(NSColor.white.cgColor);bitmap.fill(CGRect(x:0,y:0,width:1600,height:260))
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:bitmap,flipped:false)
        for (index,line) in lines.enumerated() {
            (line as NSString).draw(at:CGPoint(x:40,y:180-index*85),withAttributes:[.font:NSFont.systemFont(ofSize:48),.foregroundColor:NSColor.black])
        }
        NSGraphicsContext.restoreGraphicsState()
        let image=bitmap.makeImage()!
        let recognized=try LocalOCR.recognize(image)
        precondition(recognized.contains("Vision-language models adapt to new tasks.") && recognized.contains("The model compares two images."))
        let blank=CGContext(data:nil,width:100,height:100,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        blank.setFillColor(NSColor.white.cgColor);blank.fill(CGRect(x:0,y:0,width:100,height:100))
        do { _ = try LocalOCR.recognize(blank.makeImage()!);fatalError("blank OCR was accepted") } catch OCRFailure.empty { }
        print("PASS actual local Vision OCR: exact synthetic multiline recognition and blank-image refusal; no screen capture or network")
        }
    }
}
