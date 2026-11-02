// RinDock — bấm icon app trên Dock để thu nhỏ / hiện lại, giống taskbar Windows.
// Chạy trên thanh menu, cần quyền Accessibility.

import Cocoa
import ApplicationServices
import ServiceManagement
import SwiftUI

// MARK: - Cài đặt

enum ClickMode: String, CaseIterable {
    case minimizeAll, minimizeFocused, hide

    var title: String {
        switch self {
        case .minimizeAll:     return "Thu nhỏ tất cả cửa sổ của app"
        case .minimizeFocused: return "Chỉ thu nhỏ cửa sổ đang dùng"
        case .hide:            return "Ẩn app (nhanh, không hiệu ứng)"
        }
    }
}

enum Prefs {
    private static let d = UserDefaults.standard

    static var enabled: Bool {
        get { d.object(forKey: "enabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "enabled") }
    }

    static var mode: ClickMode {
        get { ClickMode(rawValue: d.string(forKey: "mode") ?? "") ?? .minimizeAll }
        set { d.set(newValue.rawValue, forKey: "mode") }
    }
}

// MARK: - Accessibility helpers

enum AX {
    static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v
    }

    static func string(_ el: AXUIElement, _ name: String) -> String? {
        attr(el, name) as? String
    }

    static func bool(_ el: AXUIElement, _ name: String) -> Bool? {
        (attr(el, name) as? NSNumber)?.boolValue
    }

    static func element(_ el: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = attr(el, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(v, to: AXUIElement.self)
    }

    static func pid(_ el: AXUIElement) -> pid_t {
        var p: pid_t = 0
        AXUIElementGetPid(el, &p)
        return p
    }

    /// Cửa sổ thật của app (bỏ qua popover, tooltip, panel lạ).
    static func windows(of pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let list = attr(app, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        return list.filter {
            let sub = string($0, kAXSubroleAttribute)
            return sub == kAXStandardWindowSubrole || sub == kAXDialogSubrole
        }
    }

    static func isMinimized(_ w: AXUIElement) -> Bool {
        bool(w, kAXMinimizedAttribute) ?? false
    }

    static func setMinimized(_ w: AXUIElement, _ value: Bool) {
        let v: CFBoolean = value ? kCFBooleanTrue : kCFBooleanFalse
        AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, v)
    }
}

// MARK: - Tìm icon Dock dưới con trỏ

struct DockHit {
    let appPath: String?
    let title: String?
}

enum DockHitTest {
    static func item(at point: CGPoint) -> DockHit? {
        guard let dockPid = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
        else { return nil }

        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.3)
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &found) == .success,
              var el = found,
              AX.pid(el) == dockPid
        else { return nil }

        // Phần tử trúng có thể là con của icon, đi ngược lên vài cấp.
        for _ in 0..<4 {
            if AX.string(el, kAXRoleAttribute) == "AXDockItem" {
                guard AX.string(el, kAXSubroleAttribute) == "AXApplicationDockItem" else { return nil }
                var path: String?
                if let url = AX.attr(el, kAXURLAttribute) as? URL {
                    path = url.resolvingSymlinksInPath().path
                }
                return DockHit(appPath: path, title: AX.string(el, kAXTitleAttribute))
            }
            guard let parent = AX.element(el, kAXParentAttribute) else { break }
            el = parent
        }
        return nil
    }

    static func runningApp(for hit: DockHit) -> NSRunningApplication? {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        if let path = hit.appPath,
           let app = apps.first(where: { $0.bundleURL?.resolvingSymlinksInPath().path == path }) {
            return app
        }
        if let title = hit.title {
            return apps.first { $0.localizedName == title }
        }
        return nil
    }
}

// MARK: - Bắt cú bấm trên Dock

final class DockClicker {
    private struct Press {
        let point: CGPoint
        let time: Date
        let app: NSRunningApplication
        let wasFrontmost: Bool
        let wasHidden: Bool
        let visible: [AXUIElement]
        let minimized: [AXUIElement]
        let focused: AXUIElement?
    }

    private var downMonitor: Any?
    private var upMonitor: Any?
    private var press: Press?
    private var lastAction = Date.distantPast

    func start() {
        downMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in
            self?.handleDown(e)
        }
        upMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] e in
            self?.handleUp(e)
        }
    }

    // Chụp lại trạng thái TRƯỚC khi Dock xử lý cú bấm (Dock xử lý lúc nhả chuột).
    private func handleDown(_ e: NSEvent) {
        press = nil
        guard Prefs.enabled, AXIsProcessTrusted() else { return }

        // Giữ Command/Option/Control/Shift khi bấm: để Dock làm như bình thường.
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        guard mods.isEmpty, let point = e.cgEvent?.location else { return }

        guard let hit = DockHitTest.item(at: point),
              let app = DockHitTest.runningApp(for: hit) else { return }

        let pid = app.processIdentifier
        let wins = AX.windows(of: pid)
        var focused = AX.element(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute)
        if let f = focused, AX.isMinimized(f) { focused = nil }

        press = Press(
            point: point,
            time: Date(),
            app: app,
            wasFrontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
            wasHidden: app.isHidden,
            visible: wins.filter { !AX.isMinimized($0) },
            minimized: wins.filter { AX.isMinimized($0) },
            focused: focused
        )
    }

    private func handleUp(_ e: NSEvent) {
        guard let p = press else { return }
        press = nil

        // Kéo icon để sắp xếp hoặc nhấn giữ để mở menu: bỏ qua.
        guard let up = e.cgEvent?.location,
              hypot(up.x - p.point.x, up.y - p.point.y) < 6,
              Date().timeIntervalSince(p.time) < 0.6 else { return }

        // Chống bấm đúp làm thu nhỏ rồi hiện lại liền.
        guard Date().timeIntervalSince(lastAction) > 0.35 else { return }

        // Đợi Dock làm xong phần của nó rồi mới ra tay.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.act(on: p)
        }
    }

    private func act(on p: Press) {
        // App đang bị ẩn: Dock tự hiện lại, không cần làm gì.
        if p.wasHidden { return }

        if p.wasFrontmost && !p.visible.isEmpty {
            // App đang dùng, có cửa sổ đang hiện → thu nhỏ / ẩn.
            switch Prefs.mode {
            case .hide:
                p.app.hide()
            case .minimizeAll:
                p.visible.forEach { AX.setMinimized($0, true) }
            case .minimizeFocused:
                AX.setMinimized(p.focused ?? p.visible[0], true)
            }
            lastAction = Date()
        } else if p.visible.isEmpty && !p.minimized.isEmpty {
            // Mọi cửa sổ đang thu nhỏ → hiện lại hết (Dock mặc định chỉ hiện một cái).
            p.minimized.forEach { AX.setMinimized($0, false) }
            if let last = p.minimized.last {
                AXUIElementPerformAction(last, kAXRaiseAction as CFString)
            }
            p.app.activate(options: [.activateAllWindows])
            lastAction = Date()
        }
        // Các trường hợp khác: để Dock làm như bình thường.
    }
}

// MARK: - Cửa sổ Ủng hộ tác giả

enum Support {
    static let paypalURL = URL(string: "https://paypal.me/phuocrin")!
    /// Ảnh QR ủng hộ, đóng gói trong app (Contents/Resources/donate-qr.png).
    static var qrImage: NSImage? { Bundle.main.image(forResource: "donate-qr") }
}

struct SupportView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "heart.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(colors: [.pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .padding(.top, 8)

            Text("Ủng hộ tác giả")
                .font(.system(size: 22, weight: .bold, design: .rounded))

            Text("RinDock miễn phí. Nếu app giúp ích cho bạn, bạn có thể ủng hộ Phước Rin để mình có thêm động lực làm app và video.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let qr = Support.qrImage {
                VStack(spacing: 8) {
                    Image(nsImage: qr)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 200, height: 200)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white))
                        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                    Text("Quét bằng app ngân hàng")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("App ngân hàng sẽ hiện tên chủ tài khoản, bạn kiểm tra đúng tên trước khi chuyển nha.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }

            Button {
                NSWorkspace.shared.open(Support.paypalURL)
            } label: {
                Label("Ủng hộ qua PayPal", systemImage: "creditcard")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Text("Cảm ơn bạn đã dùng RinDock 💙")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 28)
        .padding(.top, 36)
        .padding(.bottom, 24)
        .frame(width: 340)
        .background(.ultraThinMaterial)
    }
}

@MainActor
final class SupportWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingView(rootView: SupportView())
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                             styleMask: [.titled, .closable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.contentView = hosting
            w.setContentSize(hosting.fittingSize)
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Thanh menu

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let clicker = DockClicker()
    private let supportWindow = SupportWindowController()
    private var trustTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let image = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: "RinDock")
            ?? NSImage(systemSymbolName: "rectangle.bottomthird.inset.filled", accessibilityDescription: "RinDock")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = "RinDock"

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        clicker.start()

        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        if !AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary) {
            trustTimer = Timer.scheduledTimer(timeInterval: 2, target: self,
                                              selector: #selector(checkTrust(_:)),
                                              userInfo: nil, repeats: true)
        }
        updateIcon()
    }

    @objc private func checkTrust(_ timer: Timer) {
        if AXIsProcessTrusted() {
            timer.invalidate()
            trustTimer = nil
            updateIcon()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if AXIsProcessTrusted() {
            menu.addItem(label(Prefs.enabled ? "RinDock đang chạy" : "RinDock đang tắt"))
        } else {
            menu.addItem(item("⚠️ Cần cấp quyền Accessibility…", #selector(openAccessibility)))
        }
        menu.addItem(.separator())

        let toggle = item("Bật", #selector(toggleEnabled))
        toggle.state = Prefs.enabled ? .on : .off
        menu.addItem(toggle)
        menu.addItem(.separator())

        menu.addItem(label("Bấm icon app đang dùng trên Dock để:"))
        for mode in ClickMode.allCases {
            let it = item(mode.title, #selector(chooseMode(_:)))
            it.representedObject = mode.rawValue
            it.state = Prefs.mode == mode ? .on : .off
            it.indentationLevel = 1
            menu.addItem(it)
        }
        menu.addItem(.separator())

        let login = item("Mở cùng máy", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())

        menu.addItem(item("♥ Ủng hộ tác giả…", #selector(openSupport)))
        menu.addItem(.separator())

        menu.addItem(item("Thoát RinDock", #selector(quit)))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    private func label(_ title: String) -> NSMenuItem {
        NSMenuItem(title: title, action: nil, keyEquivalent: "")
    }

    private func updateIcon() {
        statusItem.button?.appearsDisabled = !(Prefs.enabled && AXIsProcessTrusted())
    }

    @objc private func toggleEnabled() {
        Prefs.enabled.toggle()
        updateIcon()
    }

    @objc private func chooseMode(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let mode = ClickMode(rawValue: raw) {
            Prefs.mode = mode
        }
    }

    @objc private func openAccessibility() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Chưa bật được Mở cùng máy"
            alert.informativeText = "Ní thêm tay: System Settings → General → Login Items → bấm + → chọn RinDock.\n\n(\(error.localizedDescription))"
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func openSupport() {
        supportWindow.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - Khởi chạy

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.accessory)
application.run()
