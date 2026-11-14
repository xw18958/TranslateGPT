import AppKit
import SwiftUI
import ApplicationServices
import Combine

enum BackendError: LocalizedError {
    case unavailable
    var errorDescription: String? {
        "The ChatGPT translation backend is unavailable. No text was sent."
    }
}

protocol TranslationBackend {
    func translate(_ text: String) async throws -> String
}

protocol ProgressiveTranslationBackend: TranslationBackend {
    func translate(_ text: String, onProgress: @escaping @MainActor (String) -> Void) async throws -> String
}

struct UnavailableBackend: TranslationBackend {
    func translate(_ text: String) async throws -> String {
        throw BackendError.unavailable
    }
}

@MainActor
final class TranslateModel: ObservableObject {
    @Published var source = ""
    @Published var output = ""
    @Published var active = false
    @Published var hasTranslation = false
    @Published var isLoading = false
    private var requestID = UUID()
    private var task: Task<Void, Never>?
    private var cache: [String: String] = [:]
    private var cacheOrder: [String] = []

    func invalidate() {
        requestID = UUID()
        task?.cancel()
        task = nil
        output = ""
        hasTranslation = false
        isLoading = false
    }
    func message(_ text: String, loading: Bool = false) {
        invalidate(); output=text; isLoading=loading
    }
    private let backend: any TranslationBackend
    init(backend: (any TranslationBackend)? = nil) {
        self.backend = backend ?? SafariDOMBackend(bridge: {
            guard let url = Bundle.main.url(forResource: "SafariDOMBridge", withExtension: "js") else { return "" }
            return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }())
    }

    func warmBackend() {if let browser=backend as? SafariDOMBackend {Task {await browser.warmWorker()}}}

    func translate(_ input: String) {
        let normalized = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        invalidate()
        let currentID = requestID
        source = normalized
        output = ""
        hasTranslation = false
        isLoading = true
        let cached=StageProfiler.measure("cache_lookup") {cache[normalized]}
        if let cached {
            if CommandLine.arguments.contains("--diagnostics") { print("TranslateGPT phase=cache_hit uptime=\(ProcessInfo.processInfo.systemUptime)"); fflush(stdout) }
            output = cached
            hasTranslation = true
            isLoading = false
            return
        }
        task = Task {
            do {
                let result: String
                if let progressive=backend as? any ProgressiveTranslationBackend {
                    result=try await progressive.translate(normalized) { [weak self] partial in
                        guard let self,self.requestID==currentID,!Task.isCancelled else { return }
                        let assignmentStart=StageProfiler.now
                        if self.output.isEmpty,CommandLine.arguments.contains("--diagnostics") { print("TranslateGPT phase=first_display uptime=\(ProcessInfo.processInfo.systemUptime)");fflush(stdout) }
                        self.output=partial
                        StageProfiler.finish("model_partial_assignment",assignmentStart)
                    }
                } else { result=try await backend.translate(normalized) }
                guard !Task.isCancelled, requestID == currentID else { return }
                let assignmentStart=StageProfiler.now
                cache[normalized] = result
                cacheOrder.removeAll { $0 == normalized }
                cacheOrder.append(normalized)
                if cacheOrder.count > 50 { cache.removeValue(forKey: cacheOrder.removeFirst()) }
                output = result
                hasTranslation = true
                isLoading = false
                StageProfiler.finish("model_final_assignment_and_cache",assignmentStart)
            } catch {
                guard !Task.isCancelled, requestID == currentID else { return }
                output = error.localizedDescription
                isLoading = false
                if CommandLine.arguments.contains("--diagnostics") { print("TranslateGPT phase=failure uptime=\(ProcessInfo.processInfo.systemUptime)"); fflush(stdout) }
            }
        }
    }
}

struct TranslationPopup: View {
    @ObservedObject var model: TranslateModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "character.book.closed.fill")
                    .foregroundStyle(.blue)
                Text("TranslateGPT")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("EN → Simplified Chinese")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button {
                    NSApplication.shared.windows.first(where: { $0 is NSPanel })?.orderOut(nil)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if model.isLoading && model.output.isEmpty {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text("Translating…")
                        }
                        .foregroundStyle(.secondary)
                    } else {
                        Text(model.output)
                            .font(.system(size: 15))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if model.isLoading { ProgressView().controlSize(.small).accessibilityLabel("Receiving translation") }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            HStack {
                Text("ChatGPT · Translation Engine")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Copy translation") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.output, forType: .string)
                }
                .buttonStyle(.borderless)
                .disabled(!model.hasTranslation)
            }
        }
        .padding(15)
        .frame(width: 430, height: 250)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))
    }
}

struct TranslationControls: View {
    @ObservedObject var model: TranslateModel
    let toggle: () -> Void
    let quit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "character.book.closed.fill")
                    .font(.system(size: 30)).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text("TranslateGPT").font(.title2.bold())
                    Text("English → Simplified Chinese").foregroundStyle(.secondary)
                }
            }
            Divider()
            Label(model.active ? "Automatic translation is ON" : "Automatic translation is OFF",
                  systemImage: model.active ? "checkmark.circle.fill" : "pause.circle.fill")
                .font(.headline)
                .foregroundStyle(model.active ? Color.green : Color.secondary)
            Text("Select English text in another app to translate it. For images or inaccessible text, use Control–Option–Command–T.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(model.active ? "Turn Off" : "Turn On", action: toggle)
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .accessibilityIdentifier("automaticTranslationButton")
                Spacer()
                Button("Quit TranslateGPT", action: quit)
            }
            Text("Closing this window keeps the app running. Click its Dock icon to reopen these controls.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: 420)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = TranslateModel()
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var controlWindow: NSWindow!
    private var monitors: [Any] = []
    private var downPoint: NSPoint?
    private var selectionEpoch = 0
    private let settings = SelectionSettings()
    private var selectionApp: SourceApplication?
    private var selectionWindow: AXUIElement?
    private var lastExternalApp: SourceApplication?
    private var extractionTask: Task<Void,Never>?
    private var ocrTask: Task<Void,Never>?
    private var ocrRecognizing=false
    private let regionSelector=RegionSelector()
    private let hotKey=OCRHotKey()
    private var hotKeyAvailable=false
    private var activationObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 250),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.title = "TranslateGPT"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: TranslationPopup(model: model))
        panel = window

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "character.book.closed.fill", accessibilityDescription: "TranslateGPT")
        let menu = NSMenu()
        menu.delegate=self
        lastExternalApp=currentExternalApp()
        hotKey.action={ [weak self] in self?.beginOCR() }
        hotKeyAvailable=hotKey.register()
        model.active=settings.enabled
        if settings.enabled {model.warmBackend()}
        let automatic=NSMenuItem(title:"Automatic translation (all apps)",action:#selector(toggleActive(_:)),keyEquivalent:"")
        automatic.target=self;automatic.state=settings.enabled ? .on:.off;menu.addItem(automatic)
        let exclude=NSMenuItem(title:"Exclude current app",action:#selector(excludeCurrentApp),keyEquivalent:"")
        exclude.target=self;exclude.tag=101;menu.addItem(exclude)
        let exclusions=NSMenuItem(title:"Excluded apps",action:nil,keyEquivalent:"")
        exclusions.submenu=NSMenu();exclusions.tag=102;menu.addItem(exclusions)
        let ocr=NSMenuItem(title:hotKeyAvailable ? "Translate screen region":"Translate screen region (shortcut unavailable)",action:#selector(beginOCR),keyEquivalent:"t")
        ocr.target=self;ocr.keyEquivalentModifierMask=[.control,.option,.command];menu.addItem(ocr)
        menu.addItem(.separator())
        let preview = NSMenuItem(title: "Preview panel (local example)", action: #selector(showPreview), keyEquivalent: "")
        preview.target = self
        menu.addItem(preview)
        let reset = NSMenuItem(title: "Reset request protection…", action: #selector(resetBackendSafety), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
        let permission = NSMenuItem(title: "Open Accessibility settings…", action: #selector(openPermissions), keyEquivalent: "")
        permission.target = self
        menu.addItem(permission)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit TranslateGPT", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu

        let appMenu=NSMenu()
        let appRoot=NSMenuItem();appRoot.submenu=appMenu
        let mainMenu=NSMenu();mainMenu.addItem(appRoot)
        let show=NSMenuItem(title:"Show TranslateGPT",action:#selector(showControls),keyEquivalent:"")
        show.target=self;appMenu.addItem(show)
        appMenu.addItem(.separator())
        let appQuit=NSMenuItem(title:"Quit TranslateGPT",action:#selector(quitApp),keyEquivalent:"q")
        appQuit.target=self;appMenu.addItem(appQuit)
        NSApp.mainMenu=mainMenu

        controlWindow=NSWindow(contentRect:NSRect(x:0,y:0,width:420,height:320),
                               styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
        controlWindow.title="TranslateGPT"
        controlWindow.isReleasedWhenClosed=false
        let controls=NSHostingView(rootView:TranslationControls(model:model,
            toggle:{ [weak self] in self?.setAutomaticTranslation(!(self?.settings.enabled ?? false)) },
            quit:{ [weak self] in self?.quitApp() }))
        controlWindow.contentView=controls
        controlWindow.setContentSize(controls.fittingSize)
        controlWindow.center()
        showControls()

        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard let self = self, !self.regionSelector.active else { return }
            self.invalidateSelection(cancelTranslation:false)
            self.selectionApp = self.currentExternalApp()
            self.selectionWindow=self.selectionApp.flatMap { AXSelectionAccess(pid:$0.pid).focusedWindow() }
            self.downPoint = NSEvent.mouseLocation
        } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            guard let self = self,
                  !self.regionSelector.active,
                  let app = self.currentExternalApp(),
                  self.settings.permits(app), app.pid == self.selectionApp?.pid,
                  let window=self.selectionWindow,self.sameWindow(window,app:app) else { return }
            let location = NSEvent.mouseLocation
            let start = self.downPoint
            self.downPoint = nil
            guard SelectionPolicy.isSelectionGesture(start:start,end:location,clicks:event.clickCount), let start else { return }
            let moved=hypot(start.x-location.x,start.y-location.y)>3
            if CommandLine.arguments.contains("--diagnostics") { print("TranslateGPT phase=mouse_up uptime=\(ProcessInfo.processInfo.systemUptime)"); fflush(stdout) }
            self.selectionEpoch += 1
            let epoch = self.selectionEpoch
            let dispatchStart=StageProfiler.now
            DispatchQueue.main.asyncAfter(deadline: .now() + (moved ? 0.09 : 0.14)) {
                guard epoch == self.selectionEpoch else { return }
                StageProfiler.finish("mouse_up_to_extraction_dispatch",dispatchStart)
                self.translateSelection(from:start,near:location,app:app,window:window,epoch:epoch)
            }
        } as Any)

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.regionSelector.active,NSWorkspace.shared.frontmostApplication?.processIdentifier==ProcessInfo.processInfo.processIdentifier { return }
                // Stop delayed extraction after an app switch. A submitted request
                // remains tied to its source and can finish displaying its result.
                if self.ocrRecognizing { self.invalidateSelection() }
                else { self.selectionEpoch += 1;self.extractionTask?.cancel() }
                if let app=self.currentExternalApp() { self.lastExternalApp=app }
                if self.regionSelector.active { self.regionSelector.cancel() }
            }
        }
        if CommandLine.arguments.contains("--verify-panel") {
            DispatchQueue.main.async { self.showPreview() }
        }
        if CommandLine.arguments.contains("--verify-translation") || CommandLine.arguments.contains("--verify-word") {
            DispatchQueue.main.async {
                self.model.translate(CommandLine.arguments.contains("--verify-word") ? "generalisation" : "Synthetic verification: The model compares two images.")
                self.display(near: NSEvent.mouseLocation)
            }
        }
        if CommandLine.arguments.contains("--verify-overlap") {
            DispatchQueue.main.async {
                self.model.translate("Synthetic overlap test: A neural network processes medical images.")
                self.display(near:NSEvent.mouseLocation)
                Task {
                    for _ in 0..<200 {
                        try? await Task.sleep(nanoseconds:50_000_000)
                        if self.model.isLoading && UserDefaults.standard.bool(forKey:"TranslateGPT.domRequestUncertain") {
                            if CommandLine.arguments.contains("--diagnostics") { print("TranslateGPT phase=overlap_replacement uptime=\(ProcessInfo.processInfo.systemUptime)");fflush(stdout) }
                            self.model.translate("Synthetic overlap test: The model compares two images.")
                            self.display(near:NSEvent.mouseLocation)
                            return
                        }
                        if !self.model.isLoading { return }
                    }
                }
            }
        }

        if CommandLine.arguments.contains("--diagnostics") { print("TranslateGPT accessibilityTrusted=\(AXIsProcessTrusted())"); fflush(stdout) }
        if !AXIsProcessTrusted() { askForAccessibility() }
    }

    private func askForAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    private func currentExternalApp() -> SourceApplication? {
        guard let app=NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return SourceApplication(running:app)
    }

    private func invalidateSelection(cancelTranslation:Bool=true) {
        selectionEpoch += 1
        extractionTask?.cancel(); ocrTask?.cancel()
        ocrRecognizing=false
        if cancelTranslation {model.invalidate()}
        panel.orderOut(nil)
    }

    private func sameWindow(_ window: AXUIElement, app: SourceApplication) -> Bool {
        guard let current=AXSelectionAccess(pid:app.pid).focusedWindow() else { return false }
        return CFEqual(window,current)
    }

    private func translateSelection(from start: NSPoint, near point: NSPoint, app: SourceApplication, window: AXUIElement, epoch: Int) {
        guard AXIsProcessTrusted(), epoch == selectionEpoch,
              currentExternalApp()?.pid==app.pid, sameWindow(window,app:app), settings.permits(app) else { return }
        let from=ScreenCoordinates.quartz(start), end=ScreenCoordinates.quartz(point)
        extractionTask=Task {
            let result=await Task.detached(priority:.userInitiated) {
                StageProfiler.measure("selected_text_extraction") {
                    SelectionExtractor(access:AXSelectionAccess(pid:app.pid)).read(start:from,end:end)
                }
            }.value
            guard !Task.isCancelled, epoch==self.selectionEpoch,
                  self.currentExternalApp()?.pid==app.pid,self.sameWindow(window,app:app),self.settings.permits(app) else { return }
            if case .text(let text)=result {
                if CommandLine.arguments.contains("--diagnostics") { print("TranslateGPT phase=extracted uptime=\(ProcessInfo.processInfo.systemUptime)");fflush(stdout) }
                self.accept(text,near:point)
            }
        }
    }

    private func accept(_ text: String, near point: NSPoint) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SelectionPolicy.accepts(trimmed) else { return }
        model.translate(trimmed)
        display(near: point)
    }

    private func display(near point: NSPoint) {
        let displayStart=StageProfiler.now
        defer {StageProfiler.finish("panel_position_and_orderFront",displayStart)}
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        let w: CGFloat = 430, h: CGFloat = 250
        let x = min(max(point.x + 12, area.minX + 8), area.maxX - w - 8)
        let y = (point.y - h - 14 > area.minY) ? point.y - h - 14 : point.y + 20
        panel.setFrameOrigin(NSPoint(x: x, y: min(max(y, area.minY + 8), area.maxY - h - 8)))
        panel.orderFrontRegardless()
        if CommandLine.arguments.contains("--diagnostics") { print("TranslateGPT phase=popup uptime=\(ProcessInfo.processInfo.systemUptime)"); fflush(stdout) }
    }

    @objc private func toggleActive(_ item: NSMenuItem) {
        setAutomaticTranslation(!settings.enabled)
    }

    private func setAutomaticTranslation(_ enabled:Bool) {
        settings.enabled=enabled
        statusItem.menu?.items.first?.state=enabled ? .on:.off
        model.active=settings.enabled;invalidateSelection();regionSelector.cancel()
        if enabled {model.warmBackend()}
    }

    @objc private func showControls() {
        guard let controlWindow else { return }
        controlWindow.deminiaturize(nil)
        controlWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true)
    }

    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool) -> Bool {
        showControls();return true
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let app=currentExternalApp() ?? lastExternalApp
        let exclude=menu.item(withTag:101)
        exclude?.title=app.map{"Exclude \($0.name)"} ?? "Exclude current app"
        exclude?.representedObject=app
        exclude?.isEnabled=app.map{settings.exclusions[$0.key]==nil} ?? false
        if let submenu=menu.item(withTag:102)?.submenu {
            submenu.removeAllItems()
            for (key,name) in settings.exclusions.sorted(by:{$0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending}) {
                let item=NSMenuItem(title:"Allow "+name,action:#selector(includeApplication(_:)),keyEquivalent:"")
                item.target=self;item.representedObject=key;submenu.addItem(item)
            }
            if submenu.items.isEmpty { let empty=NSMenuItem(title:"None",action:nil,keyEquivalent:"");empty.isEnabled=false;submenu.addItem(empty) }
        }
    }
    @objc private func excludeCurrentApp(_ item: NSMenuItem) {
        guard let app=item.representedObject as? SourceApplication else { return }
        settings.exclude(app);invalidateSelection();regionSelector.cancel()
    }
    @objc private func includeApplication(_ item: NSMenuItem) { if let key=item.representedObject as? String { settings.include(key) } }

    @objc private func beginOCR() {
        guard !regionSelector.active else { return }
        guard let app=currentExternalApp() ?? lastExternalApp,settings.permits(app,manual:true) else { return }
        invalidateSelection(cancelTranslation:false)
        let point=NSEvent.mouseLocation
        guard #available(macOS 15.2, *) else { model.message(OCRFailure.unsupported.localizedDescription);display(near:point);return }
        if AXIsProcessTrusted(),AXSelectionAccess(pid:app.pid).hasSecureFocus() { model.message(OCRFailure.secure.localizedDescription);display(near:point);return }
        guard CGPreflightScreenCaptureAccess() else {
            // Never prompt on launch or for ordinary selections, and never loop.
            if !settings.screenPermissionRequested {
                settings.screenPermissionRequested=true
                _ = CGRequestScreenCaptureAccess()
            }
            model.message(OCRFailure.permission.localizedDescription);display(near:point);return
        }
        let epoch=selectionEpoch
        regionSelector.begin { [weak self] rect in
            guard let self,let rect,epoch==self.selectionEpoch else { return }
            let quartz=ScreenCoordinates.quartz(rect,primaryHeight:ScreenCoordinates.primaryHeight)
            self.ocrTask=Task {
                self.ocrRecognizing=true
                defer { if epoch==self.selectionEpoch { self.ocrRecognizing=false } }
                do {
                    if CommandLine.arguments.contains("--diagnostics") { print("TranslateGPT phase=ocr_start uptime=\(ProcessInfo.processInfo.systemUptime)");fflush(stdout) }
                    let image=try await LocalOCR.capture(quartz)
                    if CommandLine.arguments.contains("--diagnostics") { print("TranslateGPT phase=ocr_captured uptime=\(ProcessInfo.processInfo.systemUptime)");fflush(stdout) }
                    try Task.checkCancellation()
                    // The translation panel appears only after capture, so it
                    // cannot obscure the chosen image region.
                    guard epoch==self.selectionEpoch else { return }
                    // Keep an existing GPT request until OCR yields accepted text.
                    // Recognition is on demand and never warms up in advance.
                    let text=try await Task.detached(priority:.userInitiated) { try LocalOCR.recognize(image) }.value
                    if CommandLine.arguments.contains("--diagnostics") { print("TranslateGPT phase=ocr_recognized uptime=\(ProcessInfo.processInfo.systemUptime)");fflush(stdout) }
                    try Task.checkCancellation()
                    guard epoch==self.selectionEpoch,self.settings.permits(app,manual:true) else { return }
                    self.ocrRecognizing=false
                    self.accept(text,near:rect.origin)
                } catch {
                    guard !Task.isCancelled,epoch==self.selectionEpoch else { return }
                    self.model.message(error.localizedDescription);self.display(near:rect.origin)
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        regionSelector.cancel();hotKey.stop();extractionTask?.cancel();ocrTask?.cancel()
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }

    @objc private func showPreview() {
        model.invalidate()
        model.source = "Vision-language models adapt to new tasks."
        model.output = "视觉语言模型能够适应新任务。"
        model.isLoading = false
        model.hasTranslation = true
        display(near: NSEvent.mouseLocation)
    }

    @objc private func resetBackendSafety() {
        let alert = NSAlert()
        alert.messageText = "Check Translation Engine first"
        alert.informativeText = "Reset protection only after checking the designated Safari conversation for unfinished requests and drafts."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "I checked; reset protection")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        SafariChatBackend.clearUncertainState()
        SafariDOMBackend.clearUncertainState()
    }

    @objc private func openPermissions() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

#if !TRANSLATEGPT_TESTS
@main
struct TranslateGPTEntry {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--browser-worker") {BrowserWorkerTransport.run();return}
        QuickSelectTranslateApp.main()
    }
}
struct QuickSelectTranslateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene { Settings { EmptyView() } }
}

#endif
