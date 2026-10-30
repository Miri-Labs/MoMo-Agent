// Run on macOS: swift Tests/Support/chat-system-status-smoke.swift [optional screenshot.png]
import AppKit
import WebKit

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
                      styleMask: [.titled], backing: .buffered, defer: false)
let web = WKWebView(frame: window.contentView!.bounds)
window.contentView = web
window.orderFront(nil)
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let assets = root.appendingPathComponent("Apps/iPhoneApp/Features/Assistant/Rendering/Web")
web.loadFileURL(assets.appendingPathComponent("index.html"), allowingReadAccessTo: assets)

Task { @MainActor in
    do {
        for attempt in 0..<100 {
            if (try? await web.evaluateJavaScript("typeof window.MoMoChat === 'object'")) as? Bool == true { break }
            if attempt == 99 { throw NSError(domain: "RendererLoadTimeout", code: 1) }
            try await Task.sleep(for: .milliseconds(50))
        }
        let passed = try await web.evaluateJavaScript(#"""
        (() => {
          const message = (id,turnID,role,text) => ({id,turnID,role,state:'complete',blocks:[{id:id+':text',type:'text',text}]});
          const before = [message('u1','r1','user','整理这份资料'), message('a1','r1','assistant','我先核对资料。'),
            message('status-r1','r1','system','这次请求未完成。\n资料暂时无法读取。')];
          const render = (messages,dark=false) => MoMoChat.render({sessionID:'synthetic',locale:'zh-Hans',messages,busy:false,
            stopped:false,canRegenerate:false,contextState:'idle',waitingForReply:false,appearance:{dark,reduceMotion:true,scale:1}});
          render(before);
          const status = document.querySelector('.turn.system');
          if (!status || status.querySelector('.actions') || status.getAttribute('aria-label') === '助理') return false;
          const after = [...before,message('u2','r2','user','那先告诉我明天的安排'),message('a2','r2','assistant','明天上午十点有项目讨论。')];
          render(after); render(after,true); render(after);
          return document.querySelector('.turn.system') === status && status.textContent.includes('资料暂时无法读取') &&
            document.querySelectorAll('.turn').length === 5 && document.querySelector('.turn:last-child').textContent.includes('项目讨论') &&
            !status.querySelector('.prose,.actions,.user-bubble') && document.querySelector('#working').hidden;
        })()
        """#)
        guard passed as? Bool == true else { throw NSError(domain: "SystemStatusAssertion", code: 1) }
        if CommandLine.arguments.count > 1 {
            try await Task.sleep(for: .milliseconds(150))
            let image = try await web.takeSnapshot(configuration: nil)
            let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        print("PASS real WebKit: stable failure status survives later success and appearance changes; no assistant actions or typing")
        application.terminate(nil)
    } catch {
        print("FAIL \(error)")
        exit(1)
    }
}
application.run()
