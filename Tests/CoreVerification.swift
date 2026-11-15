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
