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
        print("PASS real WebKit: composing returns to bottom; repeated typing preserves DOM; viewport shrink follows; history reading remains stable")
        application.terminate(nil)
    } catch { print("FAIL \(error)"); exit(1) }
}
application.run()
