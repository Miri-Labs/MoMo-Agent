// Real WebKit regression: swift Tests/Support/chat-source-links-smoke.swift [screenshot-directory]
import AppKit
import WebKit

@MainActor final class LinkReceiver: NSObject, WKScriptMessageHandler {
    var opened: String?
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let value = message.body as? [String: Any], value["type"] as? String == "link" else { return }
        opened = value["value"] as? String
    }
}
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let receiver = MainActor.assumeIsolated { LinkReceiver() }
let configuration = WKWebViewConfiguration()
configuration.websiteDataStore = .nonPersistent()
configuration.userContentController.add(receiver, name: "chat")
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 393, height: 600),
    styleMask: [.titled], backing: .buffered, defer: false)
let web = WKWebView(frame: window.contentView!.bounds, configuration: configuration)
window.contentView = web
window.orderFront(nil)
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let assets = root.appendingPathComponent("Apps/iPhoneApp/Features/Assistant/Rendering/Web")
web.loadFileURL(assets.appendingPathComponent("index.html"), allowingReadAccessTo: assets)

Task { @MainActor in
    do {
        func wait(_ predicate: String) async throws {
            for _ in 0..<100 {
                if (try? await web.evaluateJavaScript(predicate)) as? Bool == true { return }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw NSError(domain: "SourceLinks timeout: \(predicate)", code: 1)
        }
        func check(_ predicate: String) async throws {
            guard try await web.evaluateJavaScript(predicate) as? Bool == true else {
                throw NSError(domain: "SourceLinks assertion: \(predicate)", code: 2)
            }
        }
        try await wait("typeof MoMoChat === 'object'")
        _ = try await web.evaluateJavaScript(#"""
        window.citation = 'momoagent://source/d64b7800-be32-49ed-b6f1-7530ebf8c1be/6b1b8ca7-8855-3eb4-756b-05400adf5599?version=78&generation=0';
        window.text = '14:24—14:40，讨论了访谈流程。来源：'+citation+'。\n\n[讨论原文]('+citation+')\n\n<'+citation+'>\n\n原文示例：`'+citation+'`';
        window.fixture = {sessionID:'source-links',locale:'zh-Hans',busy:false,stopped:false,canRegenerate:false,
          contextState:'idle',waitingForReply:false,appearance:{dark:false,reduceMotion:true,scale:1},
          messages:[{id:'u',turnID:'u',role:'user',state:'complete',blocks:[{id:'input',type:'text',text:'回顾刚才的讨论'}]},
            {id:'a',turnID:'u',role:'assistant',state:'complete',blocks:[{id:'body',type:'text',text}]}]};
        MoMoChat.render(structuredClone(fixture));
        true;
        """#)
        try await wait("document.querySelectorAll('a.recording-source').length === 3")
        try await check("[...document.querySelectorAll('a')].every(a=>a.getAttribute('href')===citation)")
        try await check("document.querySelector('code').textContent===citation")
        _ = try await web.evaluateJavaScript("window.link=document.querySelector('a'); window.bubble=document.querySelector('.prose'); link.click(); true")
        for _ in 0..<100 {
            if receiver.opened != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard receiver.opened == "momoagent://source/d64b7800-be32-49ed-b6f1-7530ebf8c1be/6b1b8ca7-8855-3eb4-756b-05400adf5599?version=78&generation=0" else {
            throw NSError(domain: "SourceLinks click did not preserve the exact citation", code: 3)
        }
        _ = try await web.evaluateJavaScript("for(let i=0;i<20;i++) MoMoChat.render(structuredClone(fixture)); true")
        try await check("link===document.querySelector('a') && bubble===document.querySelector('.prose')")
        for mode in ["light", "dark", "english"] {
            let dark = mode == "dark", english = mode == "english"
            _ = try await web.evaluateJavaScript("fixture.locale='\(english ? "en" : "zh-Hans")'; fixture.appearance.dark=\(dark); MoMoChat.render(structuredClone(fixture)); true")
            try await wait("document.querySelector('a.recording-source').textContent === '\(english ? "View recording" : "查看录音")'")
            if CommandLine.arguments.count > 1 {
                try await wait("document.fonts.status === 'loaded'")
                try await Task.sleep(for: .milliseconds(100))
                let snapshot = try await web.takeSnapshot(configuration: nil)
                guard let tiff = snapshot.tiffRepresentation,
                    let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                    throw NSError(domain: "SourceLinks screenshot failed", code: 4)
                }
                try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("source-links-\(mode).png"))
            }
            print("PASS \(mode): compact citations; literal code preserved")
        }
        print("PASS: exact native click callback; 20 history refreshes retain link and bubble identity")
        web.configuration.userContentController.removeScriptMessageHandler(forName: "chat")
        application.terminate(nil)
    } catch { print("FAIL \(error)"); exit(1) }
}
application.run()
