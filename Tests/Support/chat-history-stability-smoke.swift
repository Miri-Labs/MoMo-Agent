// Real WebKit regression: swift Tests/Support/chat-history-stability-smoke.swift
import AppKit
import WebKit

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 393, height: 740),
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
            if (try? await web.evaluateJavaScript("typeof MoMoChat === 'object'")) as? Bool == true { break }
            if attempt == 99 { throw NSError(domain: "RendererLoadTimeout", code: 1) }
            try await Task.sleep(for: .milliseconds(50))
        }
        _ = try await web.evaluateJavaScript(#"""
        const message = (id, run, role, text) => ({id,turnID:run,role,state:'complete',blocks:[{id:id+':text',type:'text',text}]});
        window.fixture = {sessionID:'history',locale:'zh-Hans',messages:[],busy:false,stopped:false,canRegenerate:false,contextState:'idle',
          appearance:{dark:false,reduceMotion:false,scale:1}};
        for(let i=0;i<7;i++) fixture.messages.push(message('user'+i,'run'+i,'user','请求 '+i),message('ack'+i,'run'+i,'assistant','我来处理 '+i));
        MoMoChat.render(fixture);
        for(let i=0;i<7;i++) {
          fixture.messages.push(message('final'+i,'run'+i,'assistant','完成结果 '+i));
          MoMoChat.render(fixture);
        }
        window.doc = document.documentElement;
        window.rows = [...document.querySelector('#transcript').children];
        window.prose = [...document.querySelectorAll('.prose')];
        window.mutations = 0; window.animations = 0;
        new MutationObserver(records => { mutations += records.filter(r=>r.type==='childList').length; })
          .observe(document.querySelector('#transcript'),{childList:true,subtree:true});
        true;
        """#)
        try await Task.sleep(for: .milliseconds(450))
        _ = try await web.evaluateJavaScript("document.querySelector('#transcript').addEventListener('animationstart',()=>animations++); mutations=0; true")
        for _ in 0..<20 {
            _ = try await web.evaluateJavaScript("MoMoChat.render(fixture); true")
            try await Task.sleep(for: .milliseconds(30))
        }
        let result = try await web.evaluateJavaScript(#"""
        JSON.stringify({rows:document.querySelectorAll('.turn').length,expected:fixture.messages.length,mutations,animations,
          sameDocument:doc===document.documentElement,
          sameRows:rows.every((row,i)=>row===document.querySelector('#transcript').children[i]),
          sameProse:prose.every((p,i)=>p===document.querySelectorAll('.prose')[i]),
          allContent:fixture.messages.every(m=>[...document.querySelectorAll('.turn')].some(row=>row.textContent.includes(m.blocks[0].text)))})
        """#)
        print(result ?? "No result")
        guard try await web.evaluateJavaScript("document.querySelectorAll('.turn').length===fixture.messages.length && mutations===0 && animations===0 && rows.every((row,i)=>row===document.querySelector('#transcript').children[i]) && prose.every((p,i)=>p===document.querySelectorAll('.prose')[i])") as? Bool == true else {
            throw NSError(domain: "History was removed, moved, or animated during an unchanged refresh", code: 1)
        }
        print("PASS: interleaved task acknowledgements and completions retain all rows; 20 refreshes cause zero DOM removals/moves and zero entrance animations")
        application.terminate(nil)
    } catch { print("FAIL \(error)"); exit(1) }
}
application.run()
