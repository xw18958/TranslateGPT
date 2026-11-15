import AppKit
import JavaScriptCore
import WebKit

// Typeset translations: Markdown subset → HTML, LaTeX → MathML (Temml), shown in a locked-down web view.

/// LaTeX → MathML with the bundled Temml library (MIT) inside JavaScriptCore. No web page, no network.
@MainActor final class MathRenderer {
    static let shared = MathRenderer()
    private var context: JSContext?
    private var renderFunction: JSValue?
    private var loadFailed = false
    private var cache = [String: String]()

    static var scriptURL: URL? {
        #if TRANSLATEGPT_TESTS
        if let path = ProcessInfo.processInfo.environment["TRANSLATEGPT_TEMML_PATH"] { return URL(fileURLWithPath: path) }
        #endif
        return Bundle.main.url(forResource: "temml.min", withExtension: "js")
    }
    var available: Bool { loadIfNeeded() != nil }
    var loaded: Bool { renderFunction != nil }
    /// Loads Temml ahead of the first formula so the first translation with math is not slowed down.
    func warm() { _ = loadIfNeeded() }

    private func loadIfNeeded() -> JSValue? {
        if let renderFunction { return renderFunction }
        guard !loadFailed, let url = Self.scriptURL, let source = try? String(contentsOf: url, encoding: .utf8),
              let ctx = JSContext() as JSContext? else { loadFailed = true; return nil }
        let start = StageProfiler.now
        // Temml ships as a browser/CommonJS bundle; give it the globals it may look for.
        _ = ctx.evaluateScript("var module={exports:{}};var exports=module.exports;var self=this;")
        _ = ctx.evaluateScript(source)
        _ = ctx.evaluateScript("""
        var __tgptTemml=(typeof temml!=='undefined'&&temml)||module.exports.default||module.exports;
        function __tgptRender(tex,display){try{return __tgptTemml.renderToString(tex,{displayMode:display,throwOnError:true,trust:false,annotate:false});}catch(e){return null;}}
        """)
        guard ctx.exception == nil, let render = ctx.objectForKeyedSubscript("__tgptRender") as JSValue?, render.isObject,
              let probe = render.call(withArguments: ["x", false]) as JSValue?, probe.isString else { loadFailed = true; return nil }
        StageProfiler.finish("temml_load", start)
        context = ctx; renderFunction = render
        return render
    }

    /// MathML for one formula, or nil when Temml is unavailable or cannot parse it.
    func mathML(_ tex: String, display: Bool) -> String? {
        let key = (display ? "D:" : "I:") + tex
        if let hit = cache[key] { return hit }
        guard let render = loadIfNeeded() else { return nil }
        let start = StageProfiler.now
        let value = render.call(withArguments: [tex, display]) as JSValue?
        StageProfiler.finish("temml_render", start)
        guard let value, value.isString, let markup = value.toString() as String?, markup.contains("<math") else { return nil }
        if cache.count > 300 { cache.removeAll() }
        cache[key] = markup
        return markup
    }
}

extension MathText {
    /// Fallback when Temml cannot typeset a formula: Unicode symbols with HTML sub/superscripts.
    static func html(_ tex: String) -> String {
        let s = Array(normalized(tex)); var out = "", plain = "", i = 0
        func clean(_ t: String) -> String { TranslationHTML.escape(t.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")) }
        func flush() { out += clean(plain); plain = "" }
        while i < s.count {
            let c = s[i]
            guard c == "_" || c == "^", i + 1 < s.count else { plain.append(c); i += 1; continue }
            var body = "", j = i + 1
            if s[j] == "{" {
                var depth = 0
                while j < s.count {
                    if s[j] == "{" { depth += 1; if depth == 1 { j += 1; continue } }
                    else if s[j] == "}" { depth -= 1; if depth == 0 { j += 1; break } }
                    body.append(s[j]); j += 1
                }
            } else { body = String(s[j]); j += 1 }
            flush()
            let tag = c == "_" ? "sub" : "sup"
            let inner: String = clean(body.replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "^", with: ""))
            out += "<\(tag)>\(inner)</\(tag)>"
            i = j
        }
        flush()
        return out
    }
}

/// Converts the Markdown subset produced by the page agent (and plain ChatGPT text) to HTML.
/// All text is escaped; the only markup is what this renderer emits plus MathML from Temml.
enum TranslationHTML {
    private static let mathOpen: Character = "\u{E000}", mathClose: Character = "\u{E001}"
    private static let codeOpen: Character = "\u{E002}", codeClose: Character = "\u{E003}"

    @MainActor static func render(_ markdown: String) -> String {
        render(markdown) { MathRenderer.shared.mathML($0, display: $1) }
    }

    static func render(_ markdown: String, math: (String, Bool) -> String?) -> String {
        var formulas = [(tex: String, display: Bool)](), code = [String]()
        let text = extractMath(extractCode(markdown, into: &code), into: &formulas)
        var html = blocks(text, code: code)
        for (index, formula) in formulas.enumerated() {
            let token = placeholder(mathOpen, index, mathClose)
            let fallback: String = MathText.html(formula.tex)
            let wrapperClass: String = formula.display ? "tex tex-display" : "tex"
            let markup: String = math(formula.tex, formula.display) ?? "<span class=\"\(wrapperClass)\">\(fallback)</span>"
            html = html.replacingOccurrences(of: token, with: markup)
        }
        return html
    }

    private static func placeholder(_ open: Character, _ index: Int, _ close: Character) -> String { "\(open)\(index)\(close)" }

    static func escape(_ text: String) -> String {
        var out = ""
        for c in text {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(c)
            }
        }
        return out
    }

    // Fenced code blocks become single placeholder lines so nothing inside them is treated as Markdown or math.
    private static func extractCode(_ markdown: String, into code: inout [String]) -> String {
        var lines = [String](), current: [String]? = nil
        for line in markdown.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if let block = current { code.append(block.joined(separator: "\n")); lines.append(placeholder(codeOpen, code.count - 1, codeClose)); current = nil }
                else { current = [] }
                continue
            }
            if current != nil { current!.append(line) } else { lines.append(line) }
        }
        if let block = current { code.append(block.joined(separator: "\n")); lines.append(placeholder(codeOpen, code.count - 1, codeClose)) }
        return lines.joined(separator: "\n")
    }

    // \[…\] and $$…$$ are display math; \(…\) and $…$ inline. A lone $ (money) is left alone.
    private static func extractMath(_ text: String, into formulas: inout [(tex: String, display: Bool)]) -> String {
        let chars = Array(text); var out = "", i = 0
        func find(_ needle: [Character], from start: Int) -> Int? {
            guard needle.count <= chars.count else { return nil }
            var k = start
            while k + needle.count <= chars.count {
                if Array(chars[k..<k + needle.count]) == needle { return k }
                k += 1
            }
            return nil
        }
        func token(_ tex: String, _ display: Bool) -> String {
            formulas.append((tex.trimmingCharacters(in: .whitespacesAndNewlines), display))
            return placeholder(mathOpen, formulas.count - 1, mathClose)
        }
        while i < chars.count {
            let c = chars[i], next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            if c == "`", let close = chars[(i + 1)...].firstIndex(where: { $0 == "`" || $0 == "\n" }), chars[close] == "`" {
                out += String(chars[i...close]); i = close + 1; continue   // inline code stays literal
            }
            if c == "\\", next == "$" { out += "$"; i += 2; continue }   // escaped dollar is text
            if c == "\\", next == "[", let close = find(["\\", "]"], from: i + 2) { out += token(String(chars[(i + 2)..<close]), true); i = close + 2; continue }
            if c == "\\", next == "(", let close = find(["\\", ")"], from: i + 2) { out += token(String(chars[(i + 2)..<close]), false); i = close + 2; continue }
            if c == "$", next == "$", let close = find(["$", "$"], from: i + 2), close > i + 2 { out += token(String(chars[(i + 2)..<close]), true); i = close + 2; continue }
            if c == "$", let n = next, !n.isWhitespace, n != "$" {
                var k = i + 1, closeAt: Int? = nil
                while k < chars.count, chars[k] != "\n" {
                    if chars[k] == "$", !chars[k - 1].isWhitespace, chars[k - 1] != "\\",
                       !(k + 1 < chars.count && chars[k + 1].isNumber) { closeAt = k; break }
                    k += 1
                }
                if let close = closeAt, close > i + 1 { out += token(String(chars[(i + 1)..<close]), false); i = close + 1; continue }
            }
            out.append(c); i += 1
        }
        return out
    }

    private struct ListItem { let indent: Int; let ordered: Bool; let start: Int; let text: String }

    private static func listItem(_ line: String) -> ListItem? {
        guard let match = line.range(of: #"^ *([-*+•]|\d{1,3}[.)]) +"#, options: .regularExpression) else { return nil }
        let marker = line[match].trimmingCharacters(in: .whitespaces)
        let indent = line.prefix { $0 == " " }.count
        let number = Int(marker.dropLast())
        return ListItem(indent: indent, ordered: number != nil, start: number ?? 1, text: String(line[match.upperBound...]))
    }

    private static func blocks(_ text: String, code: [String]) -> String {
        var out = "", paragraph = [String](), quote = [String](), table = [[String]]()
        var lists = [(indent: Int, ordered: Bool)]()
        func joinedLines(_ lines: [String]) -> String {
            let rendered: [String] = lines.map { (line: String) -> String in inline(line) }
            return rendered.joined(separator: "<br>")
        }
        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let body: String = joinedLines(paragraph)
            out += "<p>"; out += body; out += "</p>"
            paragraph = []
        }
        func flushQuote() {
            guard !quote.isEmpty else { return }
            let body: String = joinedLines(quote)
            out += "<blockquote>"; out += body; out += "</blockquote>"
            quote = []
        }
        func flushTable() {
            guard !table.isEmpty else { return }
            out += "<table>"
            for row in table {
                out += "<tr>"
                for cell in row { let content: String = inline(cell); out += "<td>"; out += content; out += "</td>" }
                out += "</tr>"
            }
            out += "</table>"
            table = []
        }
        func closeList(_ ordered: Bool) { out += ordered ? "</li></ol>" : "</li></ul>" }
        func closeLists(deeperThan indent: Int) {
            while let top = lists.last, top.indent > indent { closeList(top.ordered); lists.removeLast() }
        }
        func flushAll() { flushParagraph(); flushQuote(); flushTable(); closeLists(deeperThan: -1) }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { flushParagraph(); flushQuote(); flushTable(); continue }
            if trimmed.first == codeOpen, trimmed.last == codeClose, let index = Int(trimmed.dropFirst().dropLast()), index < code.count {
                flushAll()
                let body: String = escape(code[index])
                out += "<pre><code>"; out += body; out += "</code></pre>"
                continue
            }
            if let heading = trimmed.range(of: #"^#{1,6} +"#, options: .regularExpression) {
                flushAll()
                let body: String = inline(String(trimmed[heading.upperBound...]))
                out += "<h4>"; out += body; out += "</h4>"
                continue
            }
            if trimmed.range(of: #"^(-{3,}|\*{3,}|_{3,})$"#, options: .regularExpression) != nil { flushAll(); out += "<hr>"; continue }
            if trimmed.hasPrefix(">") {
                flushParagraph(); flushTable(); closeLists(deeperThan: -1)
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)); continue
            }
            if trimmed.count > 1, trimmed.hasPrefix("|"), trimmed.hasSuffix("|") {
                flushParagraph(); flushQuote(); closeLists(deeperThan: -1)
                let cells = trimmed.dropFirst().dropLast().components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                if !cells.allSatisfy({ $0.range(of: #"^:?-{2,}:?$"#, options: .regularExpression) != nil }) { table.append(cells) }
                continue
            }
            if let item = listItem(line) {
                flushParagraph(); flushQuote(); flushTable()
                closeLists(deeperThan: item.indent)
                let body: String = inline(item.text)
                if let top = lists.last, top.indent == item.indent {
                    if top.ordered == item.ordered { out += "</li><li>"; out += body; continue }
                    closeList(top.ordered); lists.removeLast()
                }
                let open: String
                if !item.ordered { open = "<ul>" } else if item.start == 1 { open = "<ol>" } else { open = "<ol start=\"\(item.start)\">" }
                out += open; out += "<li>"; out += body
                lists.append((indent: item.indent, ordered: item.ordered)); continue
            }
            let lineIndent: Int = line.prefix(while: { $0 == " " }).count
            if let top = lists.last, lineIndent > top.indent, paragraph.isEmpty {
                let body: String = inline(trimmed)
                out += "<br>"; out += body; continue   // continuation line of a list item
            }
            closeLists(deeperThan: -1); flushQuote(); flushTable()
            paragraph.append(trimmed)
        }
        flushAll()
        return out
    }

    // Bold, italics and inline code; everything else escaped. Same rules as the panel's earlier renderer.
    static func inline(_ text: String) -> String {
        var out = "", i = text.startIndex
        while i < text.endIndex {
            let after = text.index(after: i)
            if text[i] == "`", after < text.endIndex, let close = text[after...].firstIndex(of: "`") {
                let body: String = escape(String(text[after..<close]))
                out += "<code>"; out += body; out += "</code>"; i = text.index(after: close); continue
            }
            if text[i...].hasPrefix("**"), let close = text[text.index(i, offsetBy: 2)...].range(of: "**"), close.lowerBound > text.index(i, offsetBy: 2) {
                let body: String = inline(String(text[text.index(i, offsetBy: 2)..<close.lowerBound]))
                out += "<strong>"; out += body; out += "</strong>"; i = close.upperBound; continue
            }
            if text[i] == "*", after < text.endIndex, !text[after].isWhitespace, text[after] != "*",
               let close = text[after...].firstIndex(of: "*"), close > after, !text[text.index(before: close)].isWhitespace {
                let body: String = inline(String(text[after..<close]))
                out += "<em>"; out += body; out += "</em>"; i = text.index(after: close); continue
            }
            out += escape(String(text[i])); i = after
        }
        return out
    }
}

/// The panel's translation view: a WKWebView created once at launch and reused.
/// Page JavaScript is off and nothing can be loaded; the app updates content with its own script calls.
@MainActor final class TranslationWebView: NSObject, WKNavigationDelegate {
    let view: WKWebView
    var onHeight: (@MainActor (CGFloat) -> Void)?
    private var loaded = false, pending: String?, shown: String?
    private static let heightScript = "Math.ceil(document.getElementById('c').getBoundingClientRect().height)"

    override init() {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        view = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 160), configuration: config)
        super.init()
        view.setValue(false, forKey: "drawsBackground")
        view.underPageBackgroundColor = .clear
        view.allowsMagnification = false
        view.navigationDelegate = self
        view.unregisterDraggedTypes()   // nothing can be dropped into the panel
        view.loadHTMLString(Self.shell(), baseURL: nil)
    }

    func show(_ html: String) {
        guard html != shown else { return }
        shown = html
        if loaded { apply(html) } else { pending = html }
    }

    private func apply(_ html: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: html, options: [.fragmentsAllowed]),
              let literal = String(data: data, encoding: .utf8) else { return }
        let start = StageProfiler.now
        let script = "(function(){var c=document.getElementById('c');c.innerHTML=\(literal);return Math.ceil(c.getBoundingClientRect().height);})()"
        run(script) { [weak self] height in
            StageProfiler.finish("panel_html_update", start)
            self?.onHeight?(height)
        }
    }

    /// Reports the content height again, e.g. after the panel was reset to its base size.
    func remeasure() {
        guard loaded, shown?.isEmpty == false else { return }
        run(Self.heightScript) { [weak self] height in self?.onHeight?(height) }
    }

    // App scripts run in the app's own script world, which page settings cannot disable; it shares the page's DOM.
    private func run(_ script: String, height: @escaping @MainActor (CGFloat) -> Void) {
        view.evaluateJavaScript(script, in: nil, in: .defaultClient) { result in
            MainActor.assumeIsolated {
                if case .success(let value) = result, let number = value as? NSNumber { height(CGFloat(number.doubleValue)) }
                else if StageProfiler.enabled { print("TranslateGPT phase=panel_script_failed"); fflush(stdout) }
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        if let pending { self.pending = nil; apply(pending) }
    }

    // Only the initial empty page loads; drops, links and redirects are refused.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        !loaded && navigationAction.navigationType == .other ? .allow : .cancel
    }

    // Temml's own stylesheet for system math fonts, when bundled, then the panel's styles.
    static func shell() -> String {
        let temmlCSS = Bundle.main.url(forResource: "Temml-Local", withExtension: "css").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return shellHTML.replacingOccurrences(of: "/*TEMML*/", with: temmlCSS.replacingOccurrences(of: "</", with: "<\\/"))
    }

    static let shellHTML = """
    <!doctype html><html><head><meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
    <style>/*TEMML*/</style><style>
    :root{color-scheme:light dark}
    html,body{margin:0;padding:0;background:transparent}
    body{font:15px/1.55 -apple-system,"PingFang SC",sans-serif;color:CanvasText;color:-apple-system-label;-webkit-user-select:text;overflow-wrap:anywhere}
    #c{padding:0 2px 4px 0}
    p{margin:0 0 .6em} ul,ol{margin:0 0 .6em;padding-left:1.4em} li{margin:.15em 0} li>ul,li>ol{margin:.15em 0}
    h4{font-size:1em;font-weight:600;margin:.5em 0 .3em}
    code{font:13px ui-monospace,Menlo,monospace;background:rgba(127,127,127,.16);border-radius:4px;padding:0 .25em}
    pre{background:rgba(127,127,127,.13);border-radius:6px;padding:.5em .7em;overflow-x:auto;margin:0 0 .6em} pre code{background:none;padding:0}
    blockquote{margin:0 0 .6em;padding-left:.8em;border-left:3px solid rgba(127,127,127,.45);color:-apple-system-secondary-label}
    table{border-collapse:collapse;margin:0 0 .6em} td{border:1px solid rgba(127,127,127,.35);padding:.2em .5em}
    hr{border:none;border-top:1px solid rgba(127,127,127,.35);margin:.6em 0}
    math{font-family:"STIX Two Math",math;font-size:1.1em}
    math[display="block"]{display:block math;margin:.45em 0;overflow-x:auto;overflow-y:hidden}
    .tex{font-family:"STIX Two Math","Times New Roman",serif} .tex-display{display:block;text-align:center;margin:.45em 0}
    sub,sup{font-size:.72em}
    </style></head><body><div id="c"></div></body></html>
    """
}
