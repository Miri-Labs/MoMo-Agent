# /// script
# dependencies = ["playwright==1.62.0"]
# ///
"""Run with uv; install a task-local Chromium with Playwright before running."""
import argparse
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Thread

from playwright.sync_api import sync_playwright


class QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass


def main():
    args = argparse.ArgumentParser()
    args.add_argument("--screenshot", type=Path)
    options = args.parse_args()
    web = Path(__file__).resolve().parents[2] / "Apps/iPhoneApp/Features/Assistant/Rendering/Web"
    server = ThreadingHTTPServer(("127.0.0.1", 0), partial(QuietHandler, directory=str(web)))
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch()
            page = browser.new_page(viewport={"width": 390, "height": 720})
            errors = []
            page.on("pageerror", lambda error: errors.append(str(error)))
            page.goto(f"http://127.0.0.1:{server.server_port}/index.html")
            page.wait_for_function("typeof window.MoMoChat === 'object'")
            messages = [
                {"id": "u1", "turnID": "u1", "role": "user", "state": "complete",
                 "blocks": [{"id": "b1", "type": "text", "text": "刚才说好去杭州，住宿还没订。"}]},
                {"id": "a1", "turnID": "u1", "role": "assistant", "state": "complete",
                 "blocks": [{"id": "b2", "type": "text", "text": "记得，接着安排住宿。"}]},
                {"id": "u2", "turnID": "u2", "role": "user", "state": "complete",
                 "blocks": [{"id": "b3", "type": "text", "text": "继续刚才的对话"}]},
            ]

            def render(state, busy=True, stopped=False):
                page.evaluate("snapshot => window.MoMoChat.render(snapshot)", {
                    "sessionID": "fixture", "messages": messages, "busy": busy,
                    "stopped": stopped, "contextState": state,
                    "appearance": {"dark": False, "reduceMotion": False, "scale": 1},
                })

            def check(expression):
                page.wait_for_function(expression, timeout=5000)

            render("compacting")
            check("document.querySelector('#working').dataset.phase === 'compacting' && !document.querySelector('#working').hidden")
            check("document.querySelector('#working').textContent.includes('整理较早的对话')")
            check("document.querySelector('#transcript').textContent.includes('刚才说好去杭州')")
            check("document.querySelector('#announcer').textContent.includes('整理较早的对话')")
            page.evaluate("window.oldTurn = document.querySelector('#transcript').firstElementChild")
            if options.screenshot:
                page.screenshot(path=str(options.screenshot))
            render("compacted")
            check("document.querySelector('#working').dataset.phase === 'compacted' && document.querySelector('#working').textContent.includes('正在继续回复')")
            messages.append({"id": "a2", "turnID": "u2", "role": "assistant", "state": "streaming",
                             "blocks": [{"id": "b4", "type": "text", "text": "The full answer continues. 我们继续安排杭州的住宿。"}]})
            render("compacted")
            check("document.querySelector('#working').hidden && document.querySelector('#working').dataset.phase === 'writing'")
            check("document.querySelector('#transcript').textContent.includes('The full answer continues.')")
            check("window.oldTurn === document.querySelector('#transcript').firstElementChild")
            render("failed", busy=False)
            check("!document.querySelector('#working').hidden && document.querySelector('#working').textContent.includes('聊天记录已保留')")
            check("document.querySelector('#working').dataset.animating === 'false'")
            render("compacting", busy=True, stopped=True)
            check("document.querySelector('#working').hidden")
            assert not errors, errors
            browser.close()
            print("PASS: compaction, completion, full streamed answer, retained DOM, failure, cancellation, accessibility announcement")
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


if __name__ == "__main__":
    main()
