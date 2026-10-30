// Real WebKit, synthetic notification/message payloads. Does not receive APNs or install an app.
import AppKit
import WebKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 393, height: 740), styleMask: [.titled], backing: .buffered, defer: false)
let web = WKWebView(frame: window.contentView!.bounds)
window.contentView = web
window.orderFront(nil)
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let assets = root.appendingPathComponent("Apps/iPhoneApp/Features/Assistant/Rendering/Web")
web.loadFileURL(assets.appendingPathComponent("index.html"), allowingReadAccessTo: assets)

Task { @MainActor in
    do {
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("typeof MoMoChat === 'object'")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        _ = try await web.evaluateJavaScript(#"""
        window.fixture = {sessionID:'notification-conversation',messages:[],busy:false,stopped:false,canRegenerate:false,contextState:'idle',
          appearance:{dark:false,reduceMotion:true,scale:1}, focus:{requestID:'cold-tap',messageID:'m5'}};
        window.msg = (id) => ({id,turnID:id,role:'assistant',state:'complete',blocks:[{id:id+'-text',type:'text',text:'这是一条用于验证定位的完整回复。 '.repeat(8)}]});
        // The cold notification target is not cached until the next replay batch.
        MoMoChat.render(fixture);
        for(let i=0;i<30;i++) fixture.messages.push(msg('m'+i));
        fixture.messages[4].turnID = 'shared-run'; fixture.messages[5].turnID = 'shared-run';
        MoMoChat.render(fixture);
        window.rows = [...document.querySelector('#transcript').children];
        true;
        """#)
        try await Task.sleep(for: .milliseconds(300))
        guard try await web.evaluateJavaScript("Math.abs(document.querySelector('[data-source-message=m5]').getBoundingClientRect().top-16)<3") as? Bool == true else {
            throw NSError(domain: "Cold notification did not locate replayed message", code: 1)
        }
        _ = try await web.evaluateJavaScript("window.scrollTo(0,120); true")
        try await Task.sleep(for: .milliseconds(100))
        _ = try await web.evaluateJavaScript("window.savedTop=scrollY; MoMoChat.render(fixture); true")
        try await Task.sleep(for: .milliseconds(200))
        guard try await web.evaluateJavaScript("Math.abs(scrollY-savedTop)<3 && rows.every((row,i)=>row===document.querySelector('#transcript').children[i])") as? Bool == true else {
            throw NSError(domain: "Duplicate notification stole reading position or rebuilt rows", code: 2)
        }
        _ = try await web.evaluateJavaScript("fixture.focus={requestID:'second-tap',messageID:'m20'}; MoMoChat.render(fixture); true")
        try await Task.sleep(for: .milliseconds(200))
        guard try await web.evaluateJavaScript("Math.abs(document.querySelector('[data-source-message=m20]').getBoundingClientRect().top-16)<3") as? Bool == true else {
            throw NSError(domain: "Second notification did not navigate to its own reply", code: 3)
        }
        print("PASS: cold target after replay; duplicate intent keeps scroll/DOM; second target locates exact reply")
        app.terminate(nil)
    } catch { print("FAIL \(error)"); exit(1) }
}
app.run()
