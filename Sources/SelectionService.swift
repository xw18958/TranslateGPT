import AppKit
import ApplicationServices

struct SourceApplication: Equatable {
    let pid: pid_t
    let key: String
    let name: String
    init?(running app: NSRunningApplication) {
        guard app.processIdentifier > 0 else { return nil }
        pid = app.processIdentifier
        key = app.bundleIdentifier ?? app.executableURL?.standardizedFileURL.path ?? "pid:\(pid)"
        name = app.localizedName ?? app.executableURL?.lastPathComponent ?? "App"
    }
    init(pid: pid_t, key: String, name: String) { self.pid=pid; self.key=key; self.name=name }
}

final class SelectionSettings {
    private let defaults: UserDefaults
    private let enabledKey = "TranslateGPT.globalAutomaticEnabled"
    private let exclusionsKey = "TranslateGPT.excludedApplications"
    init(defaults: UserDefaults = .standard) { self.defaults=defaults }
    var enabled: Bool {
        get { defaults.object(forKey: enabledKey) == nil ? true : defaults.bool(forKey: enabledKey) }
        set { defaults.set(newValue, forKey: enabledKey) }
    }
    var exclusions: [String:String] { defaults.dictionary(forKey: exclusionsKey) as? [String:String] ?? [:] }
    // Asked at most once per installed build: an update can change the app's code identity,
    // after which macOS needs a fresh request before it lists the new build.
    static var currentBuild: String {
        let info=Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "")/\(info["CFBundleVersion"] as? String ?? "")"
    }
    var screenPermissionRequested: Bool {
        get { defaults.string(forKey:"TranslateGPT.ocrPermissionRequestedBuild") == Self.currentBuild }
        set { if newValue { defaults.set(Self.currentBuild,forKey:"TranslateGPT.ocrPermissionRequestedBuild") } else { defaults.removeObject(forKey:"TranslateGPT.ocrPermissionRequestedBuild") } }
    }
    func exclude(_ app: SourceApplication) { var items=exclusions; items[app.key]=app.name; defaults.set(items, forKey:exclusionsKey) }
    func include(_ key: String) { var items=exclusions; items.removeValue(forKey:key); defaults.set(items, forKey:exclusionsKey) }
    func permits(_ app: SourceApplication, ownPID: pid_t = ProcessInfo.processInfo.processIdentifier, manual: Bool = false) -> Bool {
        (manual || enabled) && app.pid != ownPID && app.key != "com.xw.quickselecttranslate" && exclusions[app.key] == nil
    }
}

enum SelectionPolicy {
    static func accepts(_ text: String) -> Bool {
        let value=text.trimmingCharacters(in:.whitespacesAndNewlines)
        guard (1...12000).contains(value.count), value.range(of:"[a-zA-Z]",options:.regularExpression) != nil else { return false }
        let patterns = [
            #"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#,
            #"(?i)\b(?:https?://|www\.)\S+"#,
            #"(?i)\b(?:[A-Z0-9-]+\.)+[A-Z]{2,}(?:/[^\s]*)?\b"#,
            #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#
        ]
        return !patterns.contains { value.range(of:$0,options:.regularExpression) != nil }
    }
    static func isSelectionGesture(start: CGPoint?, end: CGPoint, clicks: Int) -> Bool {
        guard let start else { return false }
        return hypot(start.x-end.x,start.y-end.y)>3 || clicks>=2
    }
}

enum SelectedContent: Equatable {
    case text(String), none, secure, ambiguous, unavailable
    // Source-free label for diagnostics.
    var diagnosticKind: String {
        switch self { case .text: return "text"; case .none: return "none"; case .secure: return "secure"; case .ambiguous: return "ambiguous"; case .unavailable: return "unavailable" }
    }
}

// Electron apps expose web content to Accessibility only after an assistive client sets AXManualAccessibility.
// Turned on at most once per process, only after a selection there could not be read. Code editors are excluded
// because they switch to screen-reader mode when accessibility support turns on.
enum ElectronAccessibilityPolicy {
    static let excludedBundles:Set<String>=["com.microsoft.VSCode","com.microsoft.VSCodeInsiders","com.visualstudio.code.oss",
        "com.vscodium","com.todesktop.230313mzl4w4u92","com.exafunction.windsurf","cc.arduino.IDE2"]
    static func eligible(bundleID: String?, bundleURL: URL?) -> Bool {
        guard let bundleURL, !excludedBundles.contains(bundleID ?? "") else { return false }
        return FileManager.default.fileExists(atPath:bundleURL.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
    }
}
@MainActor enum ElectronAccessibility {
    private static var requested=Set<pid_t>()
    /// True only when this call turned accessibility on, so the caller may read the selection once more.
    static func enableIfNeeded(pid: pid_t) -> Bool {
        guard !requested.contains(pid), let app=NSRunningApplication(processIdentifier:pid),
              ElectronAccessibilityPolicy.eligible(bundleID:app.bundleIdentifier,bundleURL:app.bundleURL) else { return false }
        requested.insert(pid)
        return AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid),"AXManualAccessibility" as CFString,kCFBooleanTrue) == .success
    }
}

// Small adapter makes traversal testable without touching other applications.
protocol SelectionAccess {
    associatedtype Element
    func focused() -> Element?
    func hit(_ point: CGPoint) -> Element?
    func parent(_ element: Element) -> Element?
    func same(_ a: Element, _ b: Element) -> Bool
    func belongs(_ element: Element) -> Bool
    func boundary(_ element: Element) -> Bool
    func secure(_ element: Element) -> Bool
    func contains(_ element: Element, _ point: CGPoint) -> Bool
    func selected(_ element: Element) -> String?
}

struct SelectionExtractor<Access: SelectionAccess> {
    let access: Access
    func read(start: CGPoint, end: CGPoint) -> SelectedContent {
        let deadline=ProcessInfo.processInfo.systemUptime+0.6
        func chain(_ first: Access.Element?) -> [Access.Element] {
            var result=[Access.Element](), node=first
            for _ in 0..<8 {
                guard ProcessInfo.processInfo.systemUptime<deadline, let current=node,
                      access.belongs(current), !access.boundary(current),
                      !result.contains(where:{access.same($0,current)}) else { break }
                result.append(current); node=access.parent(current)
            }
            return result
        }
        let focused=chain(access.focused())
        let touched=chain(access.hit(start))+chain(access.hit(end))
        if focused.contains(where:access.secure) || touched.contains(where:access.secure) { return .secure }
        // Never search an entire window: a different pane can retain an old selection.
        let related = focused.contains { f in touched.contains { access.same(f,$0) } }
            || focused.first.map { access.contains($0,start) && access.contains($0,end) } == true
        var nodes=[Access.Element]()
        for node in touched+(related ? focused:[]) where !nodes.contains(where:{access.same($0,node)}) { nodes.append(node) }
        guard !nodes.isEmpty else { return .unavailable }
        var texts=Set<String>()
        for node in nodes {
            guard ProcessInfo.processInfo.systemUptime<deadline else { return .unavailable }
            if let selected=access.selected(node)?.trimmingCharacters(in:.whitespacesAndNewlines), !selected.isEmpty {
                guard selected.count<=12000 else { return .unavailable }
                texts.insert(selected)
                if texts.count>1 { return .ambiguous }
            }
        }
        return texts.first.map(SelectedContent.text) ?? .none
    }
}

struct AXSelectionAccess: SelectionAccess {
    let pid: pid_t
    private let root: AXUIElement
    init(pid: pid_t) { self.pid=pid; root=AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(root,0.08) }
    private func value(_ e: AXUIElement, _ attribute: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(e,0.05)
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(e,attribute as CFString,&result) == .success ? result:nil
    }
    private func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value)==AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    func focused() -> AXUIElement? { element(value(root,kAXFocusedUIElementAttribute as String)) }
    func focusedWindow() -> AXUIElement? { element(value(root,kAXFocusedWindowAttribute as String)) }
    func hit(_ point: CGPoint) -> AXUIElement? {
        var result: AXUIElement?
        AXUIElementCopyElementAtPosition(root,Float(point.x),Float(point.y),&result)
        if let result { AXUIElementSetMessagingTimeout(result,0.08) }
        return result
    }
    func parent(_ e: AXUIElement) -> AXUIElement? { element(value(e,kAXParentAttribute as String)) }
    func same(_ a: AXUIElement, _ b: AXUIElement) -> Bool { CFEqual(a,b) }
    func belongs(_ e: AXUIElement) -> Bool { var owner:pid_t=0; return AXUIElementGetPid(e,&owner) == .success && owner==pid }
    func boundary(_ e: AXUIElement) -> Bool { ["AXApplication","AXWindow"].contains(value(e,kAXRoleAttribute as String) as? String ?? "") }
    func secure(_ e: AXUIElement) -> Bool {
        [kAXRoleAttribute as String,kAXSubroleAttribute as String].contains {
            let role=value(e,$0) as? String ?? ""
            return role=="AXSecureTextField" || role=="AXPasswordField"
        }
    }
    func contains(_ e: AXUIElement, _ point: CGPoint) -> Bool {
        guard let p=value(e,kAXPositionAttribute as String),CFGetTypeID(p)==AXValueGetTypeID(),
              let s=value(e,kAXSizeAttribute as String),CFGetTypeID(s)==AXValueGetTypeID() else { return false }
        var origin=CGPoint.zero,size=CGSize.zero
        guard AXValueGetValue(p as! AXValue,.cgPoint,&origin),AXValueGetValue(s as! AXValue,.cgSize,&size),size.width>0,size.height>0 else { return false }
        return CGRect(origin:origin,size:size).contains(point)
    }
    func selected(_ e: AXUIElement) -> String? {
        if let text=value(e,kAXSelectedTextAttribute as String) as? String, !text.isEmpty { return text }
        if let range=value(e,"AXSelectedTextMarkerRange") {
            var text:CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(e,"AXStringForTextMarkerRange" as CFString,range,&text) == .success,
               let text=text as? String, !text.isEmpty { return text }
        }
        if let range=value(e,kAXSelectedTextRangeAttribute as String), CFGetTypeID(range)==AXValueGetTypeID() {
            let axRange=range as! AXValue
            var selected=CFRange()
            guard AXValueGetType(axRange) == .cfRange, AXValueGetValue(axRange,.cfRange,&selected),
                  selected.location>=0, selected.length>0, selected.length<=24000 else { return nil }
            var text:CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(e,kAXStringForRangeParameterizedAttribute as CFString,range,&text) == .success { return text as? String }
        }
        return nil
    }
    func hasSecureFocus() -> Bool {
        var node=focused()
        for _ in 0..<8 {
            guard let e=node, belongs(e), !boundary(e) else { return false }
            if secure(e) { return true }
            node=parent(e)
        }
        return false
    }
}

enum ScreenCoordinates {
    static func quartz(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x:rect.minX,y:primaryHeight-rect.maxY,width:rect.width,height:rect.height)
    }
    static var primaryHeight: CGFloat { CGFloat(CGDisplayBounds(CGMainDisplayID()).height) }
    static func quartz(_ point: CGPoint) -> CGPoint { CGPoint(x:point.x,y:primaryHeight-point.y) }
}
