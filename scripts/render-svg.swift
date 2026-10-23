// Render an SVG to a transparent PNG with WebKit: swift render-svg.swift in.svg out.png SIZE
import AppKit
import WebKit

let args = CommandLine.arguments
guard args.count == 4, let size = Int(args[3]) else { FileHandle.standardError.write(Data("usage: in.svg out.png SIZE\n".utf8)); exit(64) }
let svg = try! String(contentsOfFile: args[1], encoding: .utf8)
let html = "<html><body style='margin:0;background:transparent'><div style='width:\(size)px;height:\(size)px'>"
    + svg.replacingOccurrences(of: "width=\"1024\" height=\"1024\"", with: "width=\"\(size)\" height=\"\(size)\"") + "</div></body></html>"
_ = NSApplication.shared
let web = WKWebView(frame: NSRect(x: 0, y: 0, width: size, height: size))
web.setValue(false, forKey: "drawsBackground")
final class Nav: NSObject, WKNavigationDelegate {
    let size: Int
    init(size: Int) { self.size = size }
    func webView(_ w: WKWebView, didFinish _: WKNavigation!) {
        let size = self.size
        let cfg = WKSnapshotConfiguration()
        cfg.rect = w.bounds
        cfg.snapshotWidth = NSNumber(value: Int(w.bounds.width))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            w.takeSnapshot(with: cfg) { img, err in
                guard let img, let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
                else { print("snapshot failed: \(String(describing: err))"); exit(1) }
                rep.size = NSSize(width: size, height: size)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                NSGraphicsContext.current?.imageInterpolation = .high
                img.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
                NSGraphicsContext.restoreGraphicsState()
                let png = rep.representation(using: .png, properties: [:])!
                try! png.write(to: URL(fileURLWithPath: args[2])); exit(0)
            }
        }
    }
}
let nav = Nav(size: size); web.navigationDelegate = nav
web.loadHTMLString(html, baseURL: nil)
RunLoop.main.run()
