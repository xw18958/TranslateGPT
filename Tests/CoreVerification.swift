import Foundation

final class FakePage {
    var draft=false, changed=false, ready=true, empty=false, failAt=""
    var sends=[String](), prepared=0, cleanups=0
    var progressive=false,polls=0
    var instant=true,modeChanges=0
    var sendWindows=[Int]()
    var preparedReady=false,readyCalls=0,readyAfterCalls=1
    func call(_ target: SafariDOMBackend.Target, _ r:[String:String]) throws -> [String:Any] {
        let action=r["action"] ?? ""
        if action==failAt {throw SafariDOMBackend.Failure(message:"simulated transport failure")}
        switch action {
        case "inspect": return ["state":"ready","draft":draft,"generating":false,"instant":instant,"hidden":true]
        case "ensure_instant": modeChanges+=1;instant=true;return ["state":"instant"]
        case "prepare": prepared+=1;return ["state":"prepared","hidden":true,"readyForSend":preparedReady]
        case "ready": readyCalls+=1;return ["state":ready && readyCalls>=readyAfterCalls ? "ready":"not_ready"]
        case "send": sends.append(r["id"]!);sendWindows.append(target.windowID);return ["state":"send_attempted"]
        case "poll":
            polls+=1
            if progressive { return ["state":"observing","generating":polls<3,"text":["初","初段","完整译文"][min(polls-1,2)]] }
            return ["state":"observing","generating":empty,"text":empty ? "":"译文-"+r["id"]!]
        case "cancel_prepared": cleanups+=1;return ["state":changed ? "preserved":"cancelled"]
        default: fatalError("unexpected test action")
        }
    }
}
actor FakeTranslator: TranslationBackend {
    var calls=[String:Int]()
    func count(_ source:String)->Int {calls[source,default:0]}
    func translate(_ text:String) async throws -> String {
        calls[text,default:0]+=1
        if text=="fail" {throw SafariDOMBackend.Failure(message:"controlled failure")}
        await withCheckedContinuation { c in DispatchQueue.main.asyncAfter(deadline:.now()+(text=="slow" ? 0.08:0.001)) {c.resume()} }
        return "译文:"+text
    }
}
actor FakeProgressTranslator: ProgressiveTranslationBackend {
    func translate(_ text:String) async throws -> String { try await translate(text,onProgress:{ _ in }) }
    func translate(_ text:String,onProgress:@escaping @MainActor (String)->Void) async throws -> String {
        await onProgress("初段:"+text)
        await withCheckedContinuation { c in DispatchQueue.main.asyncAfter(deadline:.now()+(text=="slow" ? 0.08:0.01)) {c.resume()} }
        await onProgress("末段:"+text)
        if text=="failstream" {throw SafariDOMBackend.Failure(message:"controlled streaming failure")}
        return "完成:"+text
    }
}
@main struct Verification {
    @MainActor static func wait(_ predicate:()->Bool) async {
        for _ in 0..<1000 {if predicate(){return};try? await Task.sleep(nanoseconds:1_000_000)}
        fatalError("test did not settle")
    }
    @MainActor static func main() async throws {
        let fake=FakeTranslator(), model=TranslateModel(backend:fake)
        model.translate("slow");try await Task.sleep(nanoseconds:2_000_000);model.translate("fast")
        await wait {model.hasTranslation};try await Task.sleep(nanoseconds:100_000_000)
        precondition(model.source=="fast" && model.output=="译文:fast")
        model.translate("fast");precondition(model.hasTranslation)
        let hitCount=await fake.count("fast");precondition(hitCount==1)
        model.translate("slow");model.invalidate();try await Task.sleep(nanoseconds:100_000_000)
        precondition(!model.hasTranslation && !model.isLoading && model.output.isEmpty)
        model.translate("fail");await wait {!model.isLoading};precondition(!model.hasTranslation && model.output=="controlled failure")
        for i in 0..<51 {model.translate("item\(i)");await wait{model.hasTranslation}}
        model.translate("item0");await wait{model.hasTranslation};let evictedCount=await fake.count("item0");precondition(evictedCount==2)
        print("PASS model: stale-result suppression, invalidation, failure state, cache hit and bounded eviction")
        let streaming=TranslateModel(backend:FakeProgressTranslator())
        streaming.translate("slow");await wait{!streaming.output.isEmpty}
        precondition(streaming.isLoading && !streaming.hasTranslation && streaming.output=="初段:slow")
        streaming.translate("fast");await wait{streaming.hasTranslation}
        try await Task.sleep(nanoseconds:100_000_000)
        precondition(streaming.output=="完成:fast" && !streaming.isLoading)
        streaming.translate("failstream");await wait{!streaming.isLoading}
        precondition(streaming.output=="controlled streaming failure" && !streaming.hasTranslation)
        streaming.message("Recognizing text…",loading:true);streaming.invalidate();precondition(!streaming.isLoading && streaming.output.isEmpty)
        print("PASS streaming: real partial updates before completion, stale partial suppression, failure replacement and recognition cancellation")
        let layout="第一段 **重点**，见 `main.swift`。\n\n- 项目一\n- 项目二\n  1. 子项\n\n```python\nprint(1)\n```\n\n### 小结\n\n> 引用"
        precondition(TranslationFormatting.plain(layout)=="第一段 重点，见 main.swift。\n\n• 项目一\n• 项目二\n  1. 子项\n\nprint(1)\n\n小结\n\n┃ 引用")
        precondition(TranslationFormatting.plain("泛化")=="泛化" && TranslationFormatting.plain("a * b and 2*3")=="a * b and 2*3")
        let cjkBold=TranslationFormatting.attributed("**我的判断：**我会送审，*并*标注 `LLM`。")
        precondition(String(cjkBold.characters)=="我的判断：我会送审，并标注 LLM。")
        precondition(cjkBold.runs.contains { $0.inlinePresentationIntent == .stronglyEmphasized && String(cjkBold[$0.range].characters)=="我的判断：" })
        precondition(cjkBold.runs.contains { $0.inlinePresentationIntent == .emphasized } && cjkBold.runs.contains { $0.inlinePresentationIntent == .code })
        precondition(MathText.readable("r_i = \\frac{\\tilde{z}_i - q_\\ell^{low}}{q_\\ell^{high} - q_\\ell^{low} + \\epsilon}, r_i \\in [0,1]")=="ri = (z̃i − qℓlow)/(qℓhigh − qℓlow + ε), ri ∈ [0,1]")
        let scripted=MathText.attributed("q_\\ell^{high}")
        precondition(scripted.runs.count==3 && scripted.runs.contains { $0[AttributeScopes.SwiftUIAttributes.BaselineOffsetAttribute.self]==6 && String(scripted[$0.range].characters)=="high" })
        print("PASS layout rendering: paragraphs, bullets, numbering, headings, quotes, code blocks, CJK-safe bold, italics and inline code; plain copy keeps line breaks and bullets")

        // Typeset panel: Markdown → escaped HTML; formulas → MathML (Temml) or the sub/superscript fallback.
        let noMath: (String, Bool) -> String? = { _, _ in nil }
        let fakeMath: (String, Bool) -> String? = { (tex: String, display: Bool) -> String? in
            let attribute: String = display ? " display=\"block\"" : ""
            let body: String = TranslationHTML.escape(tex)
            return "<math\(attribute)>\(body)</math>"
        }
        precondition(TranslationHTML.render("a <b> & \"c\" <script>x</script>", math: noMath) == "<p>a &lt;b&gt; &amp; &quot;c&quot; &lt;script&gt;x&lt;/script&gt;</p>")
        precondition(TranslationHTML.render("第一行\n第二行\n\n第二段", math: noMath) == "<p>第一行<br>第二行</p><p>第二段</p>")
        precondition(TranslationHTML.render("- 一\n- 二\n  1. 子\n- 三", math: noMath) == "<ul><li>一</li><li>二<ol><li>子</li></ol></li><li>三</li></ul>")
        precondition(TranslationHTML.render("3. 三\n4. 四", math: noMath) == "<ol start=\"3\"><li>三</li><li>四</li></ol>")
        precondition(TranslationHTML.render("设 $r_i$，见 \\(x^2\\)。\n\n$$\\frac{a}{b}$$\n\n\\[y\\]", math: fakeMath)
            == "<p>设 <math>r_i</math>，见 <math>x^2</math>。</p><p><math display=\"block\">\\frac{a}{b}</math></p><p><math display=\"block\">y</math></p>")
        precondition(TranslationHTML.render("价格 $5 和 $10，\\$6", math: fakeMath) == "<p>价格 $5 和 $10，$6</p>")
        precondition(TranslationHTML.render("`$x$` 和\n```\n$y$ <z>\n```", math: fakeMath) == "<p><code>$x$</code> 和</p><pre><code>$y$ &lt;z&gt;</code></pre>")
        precondition(TranslationHTML.render("### 小结\n**粗体：**后文 *斜*\n\n> 引用\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\n---", math: noMath)
            == "<h4>小结</h4><p><strong>粗体：</strong>后文 <em>斜</em></p><blockquote>引用</blockquote><table><tr><td>a</td><td>b</td></tr><tr><td>1</td><td>2</td></tr></table><hr>")
        precondition(TranslationHTML.render("$q_\\ell^{high}$", math: noMath) == "<p><span class=\"tex\">q<sub>ℓ</sub><sup>high</sup></span></p>")
        precondition(TranslationHTML.render("$a<b$", math: noMath) == "<p><span class=\"tex\">a&lt;b</span></p>")
        print("PASS typeset panel HTML: escaping, line breaks, nested and numbered lists, inline and displayed math (\\( \\), \\[ \\], $, $$), money and escaped dollars stay text, code untouched, headings, quotes, tables, rules, fallback scripts")
        let requireTemml=ProcessInfo.processInfo.environment["TRANSLATEGPT_REQUIRE_TEMML"]=="1"
        if let script=MathRenderer.scriptURL, FileManager.default.fileExists(atPath: script.path) {
            let loadStart=ProcessInfo.processInfo.systemUptime
            precondition(MathRenderer.shared.available, "Temml did not load in JavaScriptCore")
            let loadMs=(ProcessInfo.processInfo.systemUptime-loadStart)*1000
            let user="r_i = \\frac{\\tilde{z}_i - q_\\ell^{low}}{q_\\ell^{high} - q_\\ell^{low} + \\epsilon}"
            guard let ml=MathRenderer.shared.mathML(user, display: false) else { preconditionFailure("Temml did not typeset the formula") }
            for part in ["<mfrac", "<msubsup", "<msub", "ℓ"] { precondition(ml.contains(part), "Temml output lacks \(part)") }
            precondition(!ml.contains("<script"))
            guard let block=MathRenderer.shared.mathML("\\sum_{i=1}^{N} x_i", display: true) else { preconditionFailure("Temml did not typeset the displayed sum") }
            let blockDisplay: Bool = block.contains("display=\"block\"")
            let blockScripts: Bool = block.contains("<munderover") || block.contains("<msubsup")
            precondition(blockDisplay && blockScripts)
            precondition(MathRenderer.shared.mathML("\\frac{a}{", display: false) == nil)
            precondition(MathRenderer.shared.mathML("\\href{https://example.invalid}{x}", display: false).map { !$0.contains("href=\"") } ?? true)
            let html=TranslationHTML.render("其中 $\(user)$。")
            precondition(html.hasPrefix("<p>其中 <math") && html.hasSuffix("</math>。</p>"))
            let formulaStart=ProcessInfo.processInfo.systemUptime
            for k in 0..<50 { precondition(MathRenderer.shared.mathML("x_{\(k)} + \\frac{a_\(k)}{b^{\(k)}}", display: false) != nil) }
            let perFormula=(ProcessInfo.processInfo.systemUptime-formulaStart)*1000/50
            print(String(format:"TIMING temml_load_ms=%.1f temml_new_formula_avg_ms=%.2f", loadMs, perFormula))
            print("PASS math typesetting: Temml MathML for the fraction with sub/superscripts and a displayed sum; invalid TeX falls back; links not trusted")
        } else {
            precondition(!requireTemml, "Temml is required for this build but missing")
            print("SKIP math typesetting: Temml not fetched (python3 scripts/fetch_temml.py)")
        }

        let suite="TranslateGPT-verification-"+UUID().uuidString
        let defaults=UserDefaults(suiteName:suite)!
        defer {defaults.removePersistentDomain(forName:suite)}
        func backend(_ page:FakePage, timeout:Double=0.08)->SafariDOMBackend {
            SafariDOMBackend(bridge:"test",defaults:defaults,targetProvider:{[.init(windowID:1,tabIndex:1)]},requestProvider:page.call,pollInterval:0.002,settleInterval:0.006,responseTimeout:timeout)
        }
        func reset(){defaults.removePersistentDomain(forName:suite)}
        var page=FakePage();page.draft=true
        do {_ = try await backend(page).translate("A");fatalError("draft was accepted")} catch {}
        precondition(page.sends.isEmpty && page.prepared==0)
        page=FakePage();let serialized=backend(page)
        let first=Task {try await serialized.translate("A")};await wait{page.sends.count==1};first.cancel()
        let second=Task {try await serialized.translate("B")};_ = try await first.value;_ = try await second.value
        precondition(page.sends.count==2 && Set(page.sends).count==2)
        precondition(!defaults.bool(forKey:"TranslateGPT.domRequestUncertain"))
        print("PASS backend: existing draft refusal and latest request waits for cancelled submitted request")
        reset();page=FakePage();page.ready=false;let cancelled=backend(page)
        let pending=Task{try await cancelled.translate("A")};await wait{page.prepared==1};pending.cancel()
        do {_ = try await pending.value;fatalError("cancel should fail")}catch{}
        precondition(page.sends.isEmpty && page.cleanups==1)
        reset();page=FakePage();page.failAt="prepare"
        do {_ = try await backend(page).translate("A");fatalError("transport should fail")}catch{}
        precondition(page.sends.isEmpty && !defaults.bool(forKey:"TranslateGPT.domRequestUncertain"))
        reset();page=FakePage();page.empty=true
        do {_ = try await backend(page,timeout:0.015).translate("A");fatalError("timeout should fail")}catch{}
        precondition(page.sends.count==1 && defaults.bool(forKey:"TranslateGPT.domRequestUncertain"))
        let restored=backend(page)
        do {_ = try await restored.translate("B");fatalError("uncertainty should persist")}catch{}
        precondition(page.sends.count==1)
        reset();page=FakePage();page.failAt="poll"
        do {_ = try await backend(page).translate("A");fatalError("poll should fail")}catch{}
        precondition(page.sends.count==1 && defaults.bool(forKey:"TranslateGPT.domRequestUncertain"))
        print("PASS backend: pre-send cancellation cleanup, pre-send failure, timeout, persistent uncertain state, post-send failure; no automatic resend")
        reset();page=FakePage();var snapshots=[String]()
        _ = try await backend(page).translate("A",onProgress:{snapshots.append($0)})
        precondition(snapshots.count==1 && snapshots[0].hasPrefix("译文-"))
        reset();page=FakePage();page.progressive=true;snapshots=[]
        let completed=try await backend(page).translate("A",onProgress:{snapshots.append($0)})
        precondition(completed=="完整译文" && snapshots==["初","初段","完整译文"])
        reset();page=FakePage();page.instant=false
        _ = try await backend(page).translate("A")
        precondition(page.modeChanges==1 && page.sends.count==1)
        reset();page=FakePage()
        let preferredPage=page
        let chooser=SafariDOMBackend(bridge:"test",defaults:defaults,targetProvider:{[.init(windowID:1,tabIndex:1),.init(windowID:2,tabIndex:1)]},requestProvider:{target,request in
            var state=try preferredPage.call(target,request)
            if request["action"]=="inspect" {state["instant"]=target.windowID==2}
            return state
        },pollInterval:0.002,settleInterval:0.006,responseTimeout:0.1)
        _ = try await chooser.translate("A")
        precondition(page.sendWindows==[2] && page.modeChanges==0)
        reset();page=FakePage();page.preparedReady=true
        _ = try await backend(page).translate("Prepared and immediately ready")
        precondition(page.sends.count==1 && page.readyCalls==0)
        reset();page=FakePage()
        _ = try await backend(page).translate("Composer needs its readiness check")
        precondition(page.sends.count==1 && page.readyCalls==1)
        reset();page=FakePage();page.readyAfterCalls=2
        _ = try await backend(page).translate("Composer becomes ready after its next update")
        precondition(page.sends.count==1 && page.readyCalls==2)
        print("PASS preparation fast path: saves one readiness call when confirmed ready; preserves the fallback and one-send behavior")
        reset()
        var startedJobs=0,stopCalls=0,activeID="",jobPolls=0
        let jobs=SafariDOMBackend(bridge:"test",defaults:defaults,targetProvider:{[.init(windowID:1,tabIndex:1)]},requestProvider:{_,r in
            switch r["action"] {
            case "inspect":return ["state":"ready","draft":false,"generating":false,"instant":true]
            case "start":startedJobs+=1;activeID=r["id"]!;jobPolls=0;return ["state":"sent"]
            case "status":jobPolls+=1;return ["state":"responding","text":"译文","generating":startedJobs==1 || jobPolls<2]
            case "stop_owned":precondition(r["id"]==activeID);stopCalls+=1;return ["state":"stopped"]
            case "complete":return ["state":"completed"]
            default:fatalError("unexpected coordinated action")
            }
        },coordinatedJobs:true,pollInterval:0.002,settleInterval:0.006,responseTimeout:0.2)
        let obsolete=Task{try await jobs.translate("obsolete")}
        await wait{startedJobs==1};obsolete.cancel()
        let newest=Task{try await jobs.translate("newest")}
        do{_ = try await obsolete.value;fatalError("obsolete request returned")}catch is CancellationError {}catch{fatalError("unexpected cancellation error")}
        _ = try await newest.value
        precondition(stopCalls==1 && startedJobs==2 && !defaults.bool(forKey:"TranslateGPT.domRequestUncertain"))
        print("PASS coordinated backend: positively confirmed stop before newest start; partial cancelled output not returned")
        reset()
        var interruptedSends=0,loseDocument=true
        let interruption=SafariDOMBackend(bridge:"test",defaults:defaults,targetProvider:{[.init(windowID:1,tabIndex:1)]},requestProvider:{_,r in
            switch r["action"] {
            case "inspect":return ["state":"ready","draft":false,"generating":false,"instant":true]
            case "start":interruptedSends+=1;return ["state":"sent"]
            case "status":return loseDocument ? ["state":"unknown_request"]:["state":"responding","text":"新译文","generating":false]
            case "complete":return ["state":"completed"]
            default:fatalError("unexpected interruption action")
            }
        },coordinatedJobs:true,pollInterval:0.002,settleInterval:0.006,responseTimeout:0.1)
        do{_ = try await interruption.translate("lost request");fatalError("lost document completed")}catch{}
        precondition(interruptedSends==1 && !defaults.bool(forKey:"TranslateGPT.domRequestUncertain"))
        loseDocument=false
        let afterLoss=try await interruption.translate("new explicit request")
        precondition(afterLoss=="新译文" && interruptedSends==2)
        print("PASS lost response document: immediate interruption, no automatic replay, no stuck protection; next explicit request succeeds")
        func ready()->[String:Any] {["state":"ready","draft":false,"generating":false,"instant":true]}
        reset()
        var unansweredStarts=0
        let unanswered=SafariDOMBackend(bridge:"test",defaults:defaults,targetProvider:{[.init(windowID:1,tabIndex:1)]},requestProvider:{_,r in
            switch r["action"] {
            case "inspect":return ready()
            case "start":unansweredStarts+=1;return ["state":"sent"]
            case "status":return unansweredStarts==1 ? ["state":"failed","failure":"no_response","safeUnsent":false,"text":""]:["state":"responding","text":"下一条译文","generating":false]
            case "complete":return ["state":"completed"]
            default:fatalError("unexpected no-response action")
            }
        },coordinatedJobs:true,pollInterval:0.002,settleInterval:0.006,responseTimeout:0.2)
        do{_ = try await unanswered.translate("unanswered request");fatalError("unanswered request completed")}
        catch{precondition(error.localizedDescription.hasPrefix("ChatGPT did not respond to this request. It was not resent."))}
        precondition(unansweredStarts==1 && !defaults.bool(forKey:"TranslateGPT.domRequestUncertain"))
        let afterUnanswered=try await unanswered.translate("next explicit request")
        precondition(afterUnanswered=="下一条译文" && unansweredStarts==2)
        reset()
        defaults.set(true,forKey:"TranslateGPT.domRequestUncertain");defaults.set("earlier-job",forKey:"TranslateGPT.pendingJobID")
        var settledYet=false,earlierActions=[String]()
        let reconciling=SafariDOMBackend(bridge:"test",defaults:defaults,targetProvider:{[.init(windowID:1,tabIndex:1)]},requestProvider:{_,r in
            earlierActions.append(r["action"]!)
            switch r["action"] {
            case "inspect":return ready()
            case "recover_status","stop_owned":precondition(r["id"]=="earlier-job");return settledYet ? ["state":"failed","failure":"no_response","safeUnsent":false]:["state":"sent","text":"","generating":false,"stopReason":"stop_controls_0"]
            case "start":return ["state":"sent"]
            case "status":return ["state":"responding","text":"恢复后译文","generating":false]
            case "complete":return ["state":"completed"]
            default:fatalError("unexpected reconciliation action")
            }
        },coordinatedJobs:true,pollInterval:0.002,settleInterval:0.006,responseTimeout:0.2)
        do{_ = try await reconciling.translate("too early");fatalError("unsettled earlier job was bypassed")}catch{}
        precondition(!earlierActions.contains("start") && defaults.bool(forKey:"TranslateGPT.domRequestUncertain"))
        settledYet=true;earlierActions=[]
        let reconciled=try await reconciling.translate("after earlier job settled")
        precondition(reconciled=="恢复后译文" && earlierActions.filter{$0=="start"}.count==1 && !earlierActions.contains("stop_owned"))
        precondition(!defaults.bool(forKey:"TranslateGPT.domRequestUncertain"))
        reset()
        var idleStarts=0
        let idleCancel=SafariDOMBackend(bridge:"test",defaults:defaults,targetProvider:{[.init(windowID:1,tabIndex:1)]},requestProvider:{_,r in
            switch r["action"] {
            case "inspect":return ready()
            case "start":idleStarts+=1;return ["state":"sent"]
            case "status":return idleStarts==1 ? ["state":"sent","text":"","generating":false]:["state":"responding","text":"最新译文","generating":false]
            case "stop_owned":return ["state":"failed","failure":"no_response","safeUnsent":false]
            case "complete":return ["state":"completed"]
            default:fatalError("unexpected idle-cancel action")
            }
        },coordinatedJobs:true,pollInterval:0.002,settleInterval:0.006,responseTimeout:1)
        let idleObsolete=Task{try await idleCancel.translate("unanswered obsolete")}
        await wait{idleStarts==1};idleObsolete.cancel()
        let idleNewest=Task{try await idleCancel.translate("newest after unanswered")}
        do{_ = try await idleObsolete.value;fatalError("obsolete request returned")}catch is CancellationError {}catch{fatalError("unexpected idle cancellation error: \(error)")}
        let newestAfterIdle=try await idleNewest.value
        precondition(newestAfterIdle=="最新译文" && idleStarts==2 && !defaults.bool(forKey:"TranslateGPT.domRequestUncertain"))
        print("PASS unanswered submitted job: reported once without resend, protection cleared only after page-confirmed end, waits while unsettled, cancellation and next explicit request proceed")
        print("PASS backend progress: observed response emitted immediately without artificial chunks")
        print("PASS Instant selection: higher reasoning mode changed before any submission")
    }
}
