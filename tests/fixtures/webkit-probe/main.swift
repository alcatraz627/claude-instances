// Loads a hub page in a real WKWebView (the engine Switchboard shows it in)
// and reports what only WebKit can answer: does the tooltip layer appear on
// hover, and does the engine support view transitions between pages.
// Usage: webkit-probe <url> ; prints one JSON line.
import AppKit
import WebKit

final class Probe: NSObject, WKNavigationDelegate {
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
    var done = false
    func run(_ url: URL) {
        web.navigationDelegate = self
        web.load(URLRequest(url: url))
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // give the page its data and first render, then hover the search button
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            let js = """
            (async () => {
              const b = document.querySelector('#findBtn, #searchBtn');
              if (!b) return JSON.stringify({ error: 'no button' });
              b.dispatchEvent(new PointerEvent('pointerover', { bubbles: true }));
              await new Promise(r => setTimeout(r, 700));
              const t = document.querySelector('.tip');
              return JSON.stringify({
                tip: t && t.classList.contains('on') ? t.textContent : null,
                titleLeft: b.getAttribute('title'),
                viewTransitions: typeof document.startViewTransition === 'function',
                crossDocument: CSS.supports('selector(::view-transition)') && 'onpagereveal' in window,
              });
            })()
            """
            webView.callAsyncJavaScript("return await " + js, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let v): print(v as? String ?? "null")
                case .failure(let e): print("{\"error\": \"\(e.localizedDescription)\"}")
                }
                self.done = true
            }
        }
    }
}

let url = URL(string: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "http://127.0.0.1:6247/")!
let app = NSApplication.shared
let probe = Probe()
probe.run(url)
let deadline = Date().addingTimeInterval(20)
while !probe.done && Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
}
if !probe.done { print("{\"error\": \"timed out\"}") }
