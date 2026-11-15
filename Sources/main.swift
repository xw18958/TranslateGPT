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
    @Published var accessibilityTrusted = true
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

// Turns common LaTeX into readable Unicode math: \alpha_{\min} → α_min, r_i → rᵢ, \frac{a}{b} → a/b.
enum MathText {
    static let symbols:[String:String]=["alpha":"α","beta":"β","gamma":"γ","delta":"δ","epsilon":"ε","varepsilon":"ε","zeta":"ζ","eta":"η","theta":"θ","lambda":"λ","mu":"μ","nu":"ν","xi":"ξ","pi":"π","rho":"ρ","sigma":"σ","tau":"τ","phi":"φ","varphi":"φ","chi":"χ","psi":"ψ","omega":"ω",
        "Gamma":"Γ","Delta":"Δ","Theta":"Θ","Lambda":"Λ","Pi":"Π","Sigma":"Σ","Phi":"Φ","Psi":"Ψ","Omega":"Ω","le":"≤","leq":"≤","ge":"≥","geq":"≥","neq":"≠","ne":"≠","approx":"≈","times":"×","cdot":"·","pm":"±",
        "in":"∈","sum":"∑","prod":"∏","int":"∫","infty":"∞","partial":"∂","nabla":"∇","to":"→","rightarrow":"→","leftarrow":"←","sim":"∼","propto":"∝","odot":"⊙","otimes":"⊗","oplus":"⊕","ldots":"…","cdots":"⋯",
        "min":"min","max":"max","log":"log","exp":"exp","arg":"arg","sqrt":"√","quad":" ","qquad":"  ","left":"","right":"",",":" ",";":" "]
    static let sub:[Character:Character]=["0":"₀","1":"₁","2":"₂","3":"₃","4":"₄","5":"₅","6":"₆","7":"₇","8":"₈","9":"₉","i":"ᵢ","j":"ⱼ","k":"ₖ","n":"ₙ","t":"ₜ","+":"₊","-":"₋","a":"ₐ","e":"ₑ","o":"ₒ","x":"ₓ","m":"ₘ","l":"ₗ","s":"ₛ","p":"ₚ","r":"ᵣ","u":"ᵤ","v":"ᵥ","h":"ₕ"]
    static let sup:[Character:Character]=["0":"⁰","1":"¹","2":"²","3":"³","4":"⁴","5":"⁵","6":"⁶","7":"⁷","8":"⁸","9":"⁹","+":"⁺","-":"⁻","n":"ⁿ","i":"ⁱ","T":"ᵀ","t":"ᵗ","k":"ᵏ"]
    // Symbols, fractions and accents become Unicode; _ and ^ stay as markers for attributed().
    static func normalized(_ tex: String) -> String {
        var s=tex
        for (name,mark) in [("tilde","\u{303}"),("widetilde","\u{303}"),("hat","\u{302}"),("widehat","\u{302}"),("bar","\u{304}"),("overline","\u{305}"),("dot","\u{307}"),("vec","\u{20D7}")] {
            s=s.replacingOccurrences(of:"\\\\"+name+#"\{(\\?[A-Za-z]+)\}"#,with:"$1"+mark,options:.regularExpression)
            s=s.replacingOccurrences(of:"\\\\"+name+#" ?([A-Za-z])"#,with:"$1"+mark,options:.regularExpression)
        }
        s=s.replacingOccurrences(of:#"\\(?:mathrm|text|mathbf|mathit|operatorname|boldsymbol|mathcal|mathbb)\{([^{}]*)\}"#,with:"$1",options:.regularExpression)
        for _ in 0..<3 { s=s.replacingOccurrences(of:#"\\(?:frac|dfrac|tfrac)\{((?:[^{}]|\{[^{}]*\})*)\}\{((?:[^{}]|\{[^{}]*\})*)\}"#,with:"($1)/($2)",options:.regularExpression) }
        s=s.replacingOccurrences(of:#"\\([A-Za-z]+|[,;!])"#,with:"\u{1}$1\u{2}",options:.regularExpression)
        for (name,value) in symbols { s=s.replacingOccurrences(of:"\u{1}"+name+"\u{2}",with:value) }
        s=s.replacingOccurrences(of:"\u{1}ell\u{2}",with:"ℓ").replacingOccurrences(of:"\u{1}!\u{2}",with:"")
        s=s.replacingOccurrences(of:#"\x{1}([A-Za-z]+)\x{2}"#,with:"$1",options:.regularExpression)
        s=s.replacingOccurrences(of:#"(?<![_^])\(([A-Za-z0-9α-ωℓ]+)\)/\(([A-Za-z0-9α-ωℓ]+)\)"#,with:"$1/$2",options:.regularExpression)
        return s.replacingOccurrences(of:"-",with:"−")
    }
    static func readable(_ tex: String) -> String { String(attributed(tex).characters) }
    // Real subscripts and superscripts (any letters, e.g. q with "low" below and "high" above) via smaller, shifted text.
    static func attributed(_ tex: String) -> AttributedString {
        let s=Array(normalized(tex)); var out=AttributedString(), plain="", i=0
        func flush() { if !plain.isEmpty { out.append(AttributedString(plain.replacingOccurrences(of:"{",with:"").replacingOccurrences(of:"}",with:""))); plain="" } }
        while i<s.count {
            let c=s[i]
            guard (c=="_" || c=="^"), i+1<s.count else { plain.append(c); i+=1; continue }
            var body="", j=i+1
            if s[j]=="{" { var depth=0; while j<s.count { if s[j]=="{" { depth+=1; if depth==1 { j+=1; continue } } else if s[j]=="}" { depth-=1; if depth==0 { j+=1; break } }; body.append(s[j]); j+=1 } }
            else { body=String(s[j]); j+=1 }
            flush()
            var piece=AttributedString(body.replacingOccurrences(of:"{",with:"").replacingOccurrences(of:"}",with:"").replacingOccurrences(of:"_",with:"").replacingOccurrences(of:"^",with:""))
            piece[AttributeScopes.SwiftUIAttributes.FontAttribute.self]=Font.system(size:10)
            piece[AttributeScopes.SwiftUIAttributes.BaselineOffsetAttribute.self]=c=="_" ? -4:6
            out.append(piece); i=j
        }
        flush(); return out
    }
    // x_{ab} → x with Unicode subscripts when every character has one, else x_ab.
    static func script(_ s:String,_ mark:Character,_ table:[Character:Character]) -> String {
        var out="",i=s.startIndex
        while i<s.endIndex {
            guard s[i]==mark, s.index(after:i)<s.endIndex else { out.append(s[i]); i=s.index(after:i); continue }
            var j=s.index(after:i), body=""
            if s[j]=="{", let close=s[j...].firstIndex(of:"}") { body=String(s[s.index(after:j)..<close]); j=s.index(after:close) }
            else { body=String(s[j]); j=s.index(after:j) }
            let mapped=body.compactMap { table[$0] }
            out += mapped.count==body.count && !body.isEmpty ? String(mapped) : String(mark)+body
            i=j
        }
        return out
    }
}

// Renders the Markdown subset the page agent produces: paragraphs, lists, headings, quotes, emphasis and code.
// Inline emphasis is parsed here rather than with CommonMark, whose flanking rules leave `**粗体：**后文` unbolded.
enum TranslationFormatting {
    static func attributed(_ markdown: String) -> AttributedString {
        var out=AttributedString(), inCode=false, first=true
        for raw in markdown.components(separatedBy:"\n") {
            if raw.trimmingCharacters(in:.whitespaces).hasPrefix("```") { inCode.toggle(); continue }
            var line: AttributedString
            if inCode { line=AttributedString(raw); line.inlinePresentationIntent = .code }
            else {
                let (prefix,body,heading)=parts(raw)
                line=AttributedString(prefix)
                var rest=inline(body)
                if heading { rest.inlinePresentationIntent = .stronglyEmphasized }
                line.append(rest)
            }
            if !first { out.append(AttributedString("\n")) }
            out.append(line); first=false
        }
        return out
    }
    static func plain(_ markdown: String) -> String { String(attributed(markdown).characters) }
    // List markers become bullets, heading hashes are removed, quotes get a bar.
    static func parts(_ line: String) -> (String,String,Bool) {
        let indent=String(line.prefix { $0==" " }), rest=line.dropFirst(indent.count)
        if let m=rest.range(of:#"^[-*+] "#,options:.regularExpression) { return (indent+"• ",String(rest[m.upperBound...]),false) }
        if let m=rest.range(of:#"^\d{1,3}[.)] "#,options:.regularExpression) { return (indent+String(rest[m]),String(rest[m.upperBound...]),false) }
        if let m=rest.range(of:#"^#{1,6} "#,options:.regularExpression) { return (indent,String(rest[m.upperBound...]),true) }
        if let m=rest.range(of:#"^> ?"#,options:.regularExpression) { return (indent+"┃ ",String(rest[m.upperBound...]),false) }
        return (indent,String(rest),false)
    }
    static func inline(_ text: String) -> AttributedString {
        var out=AttributedString(), plain="", i=text.startIndex
        func flush() { if !plain.isEmpty { out.append(AttributedString(plain)); plain="" } }
        while i<text.endIndex {
            let after=text.index(after:i)
            if text[i]=="$" {
                let double=text[i...].hasPrefix("$$"), start=text.index(i,offsetBy:double ? 2:1)
                if start<=text.endIndex, let close=text[start...].range(of:double ? "$$":"$"), close.lowerBound>start {
                    flush(); let math=MathText.attributed(String(text[start..<close.lowerBound]))
                    out.append(math); i=close.upperBound; continue
                }
            }
            if text[i]=="`", after<text.endIndex, let close=text[after...].firstIndex(of:"`") {
                flush(); var code=AttributedString(String(text[after..<close])); code.inlinePresentationIntent = .code
                out.append(code); i=text.index(after:close); continue
            }
            if text[i...].hasPrefix("**"), let close=text[text.index(i,offsetBy:2)...].range(of:"**"), close.lowerBound>text.index(i,offsetBy:2) {
                flush(); var bold=inline(String(text[text.index(i,offsetBy:2)..<close.lowerBound])); bold.inlinePresentationIntent = .stronglyEmphasized
                out.append(bold); i=close.upperBound; continue
            }
            if text[i]=="*", after<text.endIndex, !text[after].isWhitespace, text[after] != "*",
               let close=text[after...].firstIndex(of:"*"), close>after, !text[text.index(before:close)].isWhitespace {
                flush(); var italic=inline(String(text[after..<close])); italic.inlinePresentationIntent = .emphasized
                out.append(italic); i=text.index(after:close); continue
            }
            plain.append(text[i]); i=after
        }
        flush(); return out
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
                        // Translations are formatted; English status and error messages stay plain.
                        Text(model.hasTranslation || model.isLoading ? TranslationFormatting.attributed(model.output) : AttributedString(model.output))
                            .font(.system(size: 15))
                            .lineSpacing(2)
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
                    // Plain text keeps line breaks and bullets; Markdown-aware apps also get the formatting.
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(TranslationFormatting.plain(model.output), forType: .string)
                    NSPasteboard.general.setString(model.output, forType: NSPasteboard.PasteboardType("net.daringfireball.markdown"))
                }
                .buttonStyle(.borderless)
                .disabled(!model.hasTranslation)
            }
        }
        .padding(15)
        .frame(minWidth: 300, maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))
    }
}

struct TranslationControls: View {
    @ObservedObject var model: TranslateModel
    let toggle: () -> Void
    let quit: () -> Void
    let openAccessibility: () -> Void

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
            if !model.accessibilityTrusted {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Accessibility permission is not in effect, so selected text cannot be read.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.semibold)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    Text("Turn on TranslateGPT in System Settings → Privacy & Security → Accessibility. If it is already on, select it, click –, add it again with +, then reopen TranslateGPT.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Open Accessibility Settings", action: openAccessibility)
                }
            }
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
    private var trustTimer: Timer?
    private var outputObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 250),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .resizable],
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
        let popup = NSHostingView(rootView: TranslationPopup(model: model))
        popup.sizingOptions = [] // the panel size is set by fitPanel or by the user, not by SwiftUI's ideal size
        window.contentView = popup
        window.minSize = NSSize(width: 300, height: 200)
        panel = window
        outputObserver = model.$output.receive(on: DispatchQueue.main).sink { [weak self] text in
            MainActor.assumeIsolated { guard let self else { return }; self.fitPanel(to: text) }
        }

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
        let copyFallback=NSMenuItem(title:"Copy fallback when selection is unreadable",action:#selector(toggleCopyFallback(_:)),keyEquivalent:"")
        copyFallback.target=self;copyFallback.state=settings.copyFallback ? .on:.off;copyFallback.toolTip="Only when Accessibility cannot read a selection: press ⌘C, translate the copied text, then restore your clipboard.";menu.addItem(copyFallback)
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
            quit:{ [weak self] in self?.quitApp() },
            openAccessibility:{ [weak self] in self?.openPermissions() }))
        model.accessibilityTrusted=AXIsProcessTrusted()
        controlWindow.contentView=controls
        controlWindow.setContentSize(controls.fittingSize)
        // Permission can be granted or lose effect while running; the check is a cheap local call.
        trustTimer=Timer.scheduledTimer(withTimeInterval:2,repeats:true) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; self.refreshAccessibilityTrust() }
        }
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

        if CommandLine.arguments.contains("--diagnostics") { print("TranslateGPT accessibilityTrusted=\(AXIsProcessTrusted()) screenCaptureAllowed=\(CGPreflightScreenCaptureAccess())"); fflush(stdout) }
        if !AXIsProcessTrusted() { askForAccessibility() }
    }

    private func refreshAccessibilityTrust() {
        let trusted=AXIsProcessTrusted()
        guard trusted != model.accessibilityTrusted else { return }
        model.accessibilityTrusted=trusted
        DispatchQueue.main.async { [weak self] in
            guard let self, let content=self.controlWindow?.contentView else { return }
            self.controlWindow.setContentSize(content.fittingSize)
        }
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
            func extract() async -> SelectedContent {
                await Task.detached(priority:.userInitiated) {
                    StageProfiler.measure("selected_text_extraction") {
                        SelectionExtractor(access:AXSelectionAccess(pid:app.pid)).read(start:from,end:end)
                    }
                }.value
            }
            @MainActor func current() -> Bool {
                guard !Task.isCancelled, epoch==self.selectionEpoch else { return false }
                guard self.currentExternalApp()?.pid==app.pid, self.sameWindow(window,app:app) else { return false }
                return self.settings.permits(app)
            }
            var result=await extract()
            guard current() else { return }
            // Electron apps publish page text only after an assistive client asks; ask once, then reread this selection.
            if result == .none || result == .unavailable, ElectronAccessibility.enableIfNeeded(pid:app.pid) {
                if CommandLine.arguments.contains("--diagnostics") { print("TranslateGPT phase=electron_accessibility_enabled");fflush(stdout) }
                try? await Task.sleep(nanoseconds:450_000_000)
                guard current() else { return }
                result=await extract()
                guard current() else { return }
            }
            let diagnostics=CommandLine.arguments.contains("--diagnostics")
            if diagnostics, CommandLine.arguments.contains("--force-copy-fallback") { result = .none } // live test of the fallback path
            if diagnostics, result.diagnosticKind != "text" {
                print("TranslateGPT phase=extraction_without_text kind=\(result.diagnosticKind)");fflush(stdout)
            }
            // Last resort for apps that expose no readable selection: copy it, then restore the clipboard.
            // Also when Accessibility reports two different selections: the app's own copy names the current one.
            if result == .none || result == .unavailable || result == .ambiguous, self.settings.copyFallback {
                let access=AXSelectionAccess(pid:app.pid)
                let top=access.frame(window).map { from.y-$0.minY < 30 } ?? true
                if CopyFallbackPolicy.allowed(bundleID:NSRunningApplication(processIdentifier:app.pid)?.bundleIdentifier,
                                              startRole:access.role(at:from),secureInput:CopyFallbackPolicy.secureInputActive(),nearTitleBar:top) {
                    let copy=await CopyFallback.copySelection()
                    if diagnostics { print("TranslateGPT phase=copy_fallback outcome=\(copy.outcome) restored=\(copy.restored)");fflush(stdout) }
                    guard current() else { return }
                    if let text=copy.text { result = .text(text) }
                } else if diagnostics { print("TranslateGPT phase=copy_fallback outcome=skipped");fflush(stdout) }
            }
            if case .text(let text)=result {
                if CommandLine.arguments.contains("--diagnostics") { print("TranslateGPT phase=extracted uptime=\(ProcessInfo.processInfo.systemUptime)");fflush(stdout) }
                self.accept(text,near:point)
            }
        }
    }

    private func accept(_ text: String, near point: NSPoint) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let reason=SelectionPolicy.rejection(trimmed) {
            if CommandLine.arguments.contains("--diagnostics") { print("TranslateGPT phase=selection_skipped reason=\(reason)");fflush(stdout) }
            return
        }
        model.translate(trimmed)
        display(near: point)
    }

    // Grows the panel (never shrinks it mid-reply) so longer translations fit, up to 70% of the screen; beyond that it scrolls.
    private func fitPanel(to text: String) {
        guard let panel, panel.isVisible, !text.isEmpty, let area=(panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        let plain=model.hasTranslation || model.isLoading ? TranslationFormatting.plain(text) : text
        let width: CGFloat = plain.count > 450 || (plain.contains("\n") && plain.count > 220) ? 560 : 430
        let measured=NSAttributedString(string:plain,attributes:[.font:NSFont.systemFont(ofSize:15)])
            .boundingRect(with:NSSize(width:width-36,height:.greatestFiniteMagnitude),options:[.usesLineFragmentOrigin,.usesFontLeading]).height
        let height=min(max(250,ceil(measured*1.12)+120),area.height*0.7)
        var frame=panel.frame
        let targetW=max(frame.width,width), targetH=max(frame.height,height)
        guard targetW>frame.width || targetH>frame.height else { return }
        let top=frame.maxY
        frame.size=NSSize(width:targetW,height:targetH)
        frame.origin.y=max(top-targetH,area.minY+8)
        frame.origin.x=max(area.minX+8,min(frame.origin.x,area.maxX-targetW-8))
        panel.setFrame(frame,display:true)
    }

    private func display(near point: NSPoint) {
        let displayStart=StageProfiler.now
        defer {StageProfiler.finish("panel_position_and_orderFront",displayStart)}
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        let w: CGFloat = 430, h: CGFloat = 250
        let x = min(max(point.x + 12, area.minX + 8), area.maxX - w - 8)
        let y = (point.y - h - 14 > area.minY) ? point.y - h - 14 : point.y + 20
        // Each new translation starts at the base size; fitPanel grows it to the reply.
        panel.setFrame(NSRect(x: x, y: min(max(y, area.minY + 8), area.maxY - h - 8), width: w, height: h), display: true)
        panel.orderFrontRegardless()
        fitPanel(to: model.output)
        if CommandLine.arguments.contains("--diagnostics") { print("TranslateGPT phase=popup uptime=\(ProcessInfo.processInfo.systemUptime)"); fflush(stdout) }
    }

    @objc private func toggleCopyFallback(_ item: NSMenuItem) {
        settings.copyFallback.toggle(); item.state=settings.copyFallback ? .on:.off
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
        regionSelector.cancel();hotKey.stop();extractionTask?.cancel();ocrTask?.cancel();trustTimer?.invalidate()
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
