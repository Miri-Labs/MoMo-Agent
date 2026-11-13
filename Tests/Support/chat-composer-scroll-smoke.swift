// Real WebKit test: swift Tests/Support/chat-composer-scroll-smoke.swift
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
        func settle() async throws { try await Task.sleep(for: .milliseconds(180)) }
        func check(_ expression: String) async throws {
            guard try await web.evaluateJavaScript(expression) as? Bool == true else {
                throw NSError(domain: expression, code: 1)
            }
        }
        for attempt in 0..<100 {
            if (try? await web.evaluateJavaScript("typeof window.MoMoChat === 'object'")) as? Bool == true { break }
            if attempt == 99 { throw NSError(domain: "RendererLoadTimeout", code: 1) }
            try await Task.sleep(for: .milliseconds(50))
        }
        _ = try await web.evaluateJavaScript(#"""
        window.fixture = {sessionID:'scroll',locale:'zh-Hans',messages:Array.from({length:40},(_,i) => ({
          id:'m'+i,turnID:'r'+i,role:i%2?'assistant':'user',state:'complete',
          blocks:[{id:'b'+i,type:'text',text:'消息 '+i+'，用于验证输入时回到最新消息。'}]})),
          busy:false,stopped:false,canRegenerate:false,contextState:'idle',
          appearance:{dark:false,reduceMotion:true,scale:1}};
        MoMoChat.render(fixture);
        window.atBottom = () => Math.abs(scrollY + innerHeight - document.documentElement.scrollHeight) < 2;
        true;
        """#)
        try await settle()
        _ = try await web.evaluateJavaScript("window.scrollTo(0,100)")
        try await settle()
        _ = try await web.evaluateJavaScript("MoMoChat.render(fixture)")
        try await settle()
        try await check("scrollY === 100")
        _ = try await web.evaluateJavaScript("MoMoChat.scrollToBottom()")
        try await settle()
        try await check("atBottom()")
        _ = try await web.evaluateJavaScript("window.lastBubble=document.querySelector('.turn:last-child'); for(let i=0;i<20;i++)MoMoChat.scrollToBottom()")
        try await settle()
        try await check("atBottom() && lastBubble===document.querySelector('.turn:last-child')")
        window.setContentSize(NSSize(width: 640, height: 350))
        try await settle()
        try await check("atBottom()")
        _ = try await web.evaluateJavaScript("window.scrollTo(0,100)")
        try await settle()
        window.setContentSize(NSSize(width: 640, height: 450))
        try await settle()
        try await check("scrollY === 100")
        // Capture actual viewport offsets after clicking the same button the user sees.
        func clickJump(reduceMotion: Bool, onFirstMovement: String = "") async throws -> Int {
            _ = try await web.evaluateJavaScript("fixture.appearance.reduceMotion = \(reduceMotion); MoMoChat.render(fixture)")
            try await settle()
            _ = try await web.evaluateJavaScript("window.scrollTo(0,100)")
            try await settle()
            try await check("scrollY === 100 && !document.querySelector('#jump').hidden")
            let samples = try await web.callAsyncJavaScript("""
            const start = scrollY, end = document.documentElement.scrollHeight - innerHeight;
            const intermediate = new Set();
            document.querySelector('#jump').click();
            const deadline = performance.now() + 1000;
            return await new Promise(resolve => {
              function sample(now) {
                if (scrollY > start + 2 && scrollY < end - 2) {
                  const first = intermediate.size === 0;
                  intermediate.add(scrollY);
                  if (first) { \(onFirstMovement) }
                }
                if (atBottom() || now >= deadline) resolve(intermediate.size);
                else requestAnimationFrame(sample);
              }
              requestAnimationFrame(sample);
            });
            """, arguments: [:], in: nil, contentWorld: .page)
            return (samples as? NSNumber)?.intValue ?? -1
        }
        let systemReducesMotion = try await web.evaluateJavaScript("matchMedia('(prefers-reduced-motion: reduce)').matches") as? Bool == true
        if systemReducesMotion {
            let moved = try await clickJump(reduceMotion: false)
            guard moved == 0 else { throw NSError(domain: "System reduced-motion jump animated", code: 1) }
            try await check("atBottom()")
        } else {
            let moved = try await clickJump(reduceMotion: false, onFirstMovement: """
            fixture.busy = true;
            const reply = fixture.messages.at(-1);
            reply.state = 'streaming';
            reply.blocks[0].text += ' 新收到的内容。'.repeat(300);
            MoMoChat.render(fixture);
            """)
            guard moved >= 2 else { throw NSError(domain: "Expected animated jump, observed \(moved) intermediate offsets", code: 1) }
            try await check("fixture.busy && atBottom() && document.querySelector('#jump').hidden")
            _ = try await clickJump(reduceMotion: false, onFirstMovement: """
            window.dispatchEvent(new WheelEvent('wheel', { deltaY:-80 }));
            window.scrollTo(0,80);
            MoMoChat.render(fixture);
            """)
            try await check("scrollY === 80 && !document.querySelector('#jump').hidden")
            print("PASS real WebKit: \(moved) intermediate offsets while reply grew; wheel interrupted the jump")
        }
        let reduced = try await clickJump(reduceMotion: true)
        guard reduced == 0 else { throw NSError(domain: "Reduced-motion jump had \(reduced) intermediate offsets", code: 1) }
        try await check("atBottom()")
        print("PASS real WebKit: reduced motion, composing, viewport resizing and history reading")
        application.terminate(nil)
    } catch { print("FAIL \(error)"); exit(1) }
}
application.run()
