import AppKit
import SwiftUI

/// 讓選單列的 Popover 視窗永遠貼著選單列下緣，高度剛好等於內容。
///
/// `MenuBarExtra(.window)` 的視窗在內容高度改變時處理得不好：內容變矮時視窗不會跟著縮，
/// 上方會留下一塊透明的空白；內容變高時則是往上長。這裡自己接手視窗的大小與位置：
/// 記住視窗打開時的上緣，之後不論內容怎麼變，都把視窗設成「上緣不動、高度等於內容」，
/// 所以新增的內容（例如錯誤訊息）會把下面的東西往下推。
struct PopoverWindowAnchor: NSViewRepresentable {
    /// 內容實際需要的高度。
    var contentHeight: CGFloat

    func makeNSView(context: Context) -> AnchorView {
        AnchorView()
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.contentHeight = contentHeight
        view.apply()
    }

    final class AnchorView: NSView {
        var contentHeight: CGFloat = 0
        private var anchorTop: CGFloat?
        private var observers: [NSObjectProtocol] = []
        private var isApplying = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            anchorTop = nil
            guard let window else { return }

            let center = NotificationCenter.default
            // 每次打開時系統會把視窗擺到選單列圖示下方，這時的上緣就是我們要固定住的位置。
            observers.append(center.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                self?.captureAnchor()
                self?.apply()
            })
            // SwiftUI 自己調整視窗大小之後，再把它修正回來。
            observers.append(center.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: .main
            ) { [weak self] _ in
                self?.apply()
            })

            if window.isVisible {
                captureAnchor()
                apply()
            }
        }

        private func captureAnchor() {
            guard let window else { return }
            var top = window.frame.maxY
            // 不能超過選單列的下緣。
            if let screen = window.screen {
                top = min(top, screen.visibleFrame.maxY)
            }
            anchorTop = top
        }

        func apply() {
            // 開發用的預覽視窗是一般視窗，大小由 NSHostingView 自己決定，這裡再去改會互相打架。
            guard !DebugFlags.preview else { return }
            guard !isApplying, let window, let anchorTop, contentHeight > 1 else { return }
            let current = window.frame
            let target = NSRect(
                x: current.minX, y: anchorTop - contentHeight,
                width: current.width, height: contentHeight
            )
            guard abs(current.minY - target.minY) > 0.5 || abs(current.height - target.height) > 0.5 else { return }
            isApplying = true
            window.setFrame(target, display: true)
            isApplying = false
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}
