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

    /// Tự hỏi GitHub có bản mới không (tối đa mỗi ngày một lần). Mặc định bật.
    static var autoUpdate: Bool {
        get { d.object(forKey: "autoUpdate") as? Bool ?? true }
        set { d.set(newValue, forKey: "autoUpdate") }
    }

    static var lastUpdateCheck: Date? {
        get { d.object(forKey: "lastUpdateCheck") as? Date }
        set { d.set(newValue, forKey: "lastUpdateCheck") }
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

// MARK: - Thông tin app

enum AppInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
    static let repoURL = URL(string: "https://github.com/PhuocRin/RinDock")!
    static let apiLatestRelease = URL(string: "https://api.github.com/repos/PhuocRin/RinDock/releases/latest")!
    static let youtubeURL = URL(string: "https://youtube.com/@phuocrin")!
    static let tiktokURL = URL(string: "https://www.tiktok.com/@phuocrinrin")!
    static let email = "phuocrinrin@gmail.com"

    static var macOS: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    static var chip: String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "?" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    /// Thông tin gửi kèm khi báo lỗi. Không có gì cá nhân.
    static var diagnostics: String {
        "RinDock \(version) · \(macOS) · \(chip)\n"
            + "Chế độ: \(Prefs.mode.title)\n"
            + "Đang bật: \(Prefs.enabled ? "Có" : "Không") · Quyền Accessibility: \(AXIsProcessTrusted() ? "Có" : "Chưa")"
    }
}

// MARK: - Cửa sổ kính dùng chung

extension View {
    func panelStyle(width: CGFloat = 340) -> some View {
        self
            .padding(.horizontal, 28)
            .padding(.top, 36)
            .padding(.bottom, 24)
            .frame(width: width)
            .background(.ultraThinMaterial)
    }
}

@MainActor
final class Panel {
    private var window: NSWindow?
    private let content: () -> AnyView

    init(_ content: @escaping () -> AnyView) {
        self.content = content
    }

    func show() {
        let controller = NSHostingController(rootView: content())
        controller.sizingOptions = .preferredContentSize   // cửa sổ tự co giãn theo nội dung

        if let w = window {
            w.contentViewController = controller
        } else {
            let w = NSWindow(contentViewController: controller)
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            window = w
        }
        if let w = window, !w.isVisible { w.center() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Ủng hộ tác giả

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
        .panelStyle()
    }
}

// MARK: - Giới thiệu

struct AboutView: View {
    var body: some View {
        VStack(spacing: 12) {
            if let icon = NSImage(named: NSImage.applicationIconName) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 96, height: 96)
            }

            Text("RinDock")
                .font(.system(size: 24, weight: .bold, design: .rounded))

            Text("Phiên bản \(AppInfo.version)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            Text("Bấm icon app trên Dock để thu nhỏ, bấm lại để hiện lên, giống taskbar trên Windows.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 4)

            Text("Làm bởi Phước Rin")
                .font(.system(size: 13, weight: .semibold))

            HStack(spacing: 8) {
                link("YouTube", "play.rectangle.fill", AppInfo.youtubeURL)
                link("TikTok", "music.note", AppInfo.tiktokURL)
                link("GitHub", "chevron.left.forwardslash.chevron.right", AppInfo.repoURL)
            }

            Text("Miễn phí · Mã nguồn mở (MIT)")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .panelStyle()
    }

    private func link(_ title: String, _ symbol: String, _ url: URL) -> some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.bordered)
    }
}

// MARK: - Báo lỗi

enum BugReport {
    static var template: String {
        "Mô tả lỗi:\n\n\n"
            + "Các bước để gặp lỗi:\n1. \n2. \n\n"
            + "App bị ảnh hưởng (nếu có):\n\n"
            + "---\n" + AppInfo.diagnostics
    }

    static var emailURL: URL? {
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = AppInfo.email
        c.queryItems = [
            URLQueryItem(name: "subject", value: "[RinDock \(AppInfo.version)] Báo lỗi"),
            URLQueryItem(name: "body", value: template),
        ]
        return c.url
    }

    static var githubURL: URL? {
        var c = URLComponents(string: "https://github.com/PhuocRin/RinDock/issues/new")
        c?.queryItems = [
            URLQueryItem(name: "title", value: "Báo lỗi: "),
            URLQueryItem(name: "body", value: template),
        ]
        return c?.url
    }
}

struct BugReportView: View {
    private let info = AppInfo.diagnostics
    @State private var copied = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "ladybug.fill")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(colors: [.orange, .red], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .padding(.top, 8)

            Text("Báo lỗi")
                .font(.system(size: 22, weight: .bold, design: .rounded))

            Text("Gặp lỗi, hay có app không thu nhỏ được? Bạn mô tả giúp mình nha, mình sẽ sửa ở bản sau.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Thông tin gửi kèm")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(info)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.06)))

            Text("Chỉ gồm phiên bản app, macOS và loại chip. Không có thông tin cá nhân.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                if let url = BugReport.emailURL { NSWorkspace.shared.open(url) }
            } label: {
                Label("Gửi qua email", systemImage: "envelope.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            HStack(spacing: 8) {
                Button("Báo trên GitHub") {
                    if let url = BugReport.githubURL { NSWorkspace.shared.open(url) }
                }
                Button(copied ? "Đã sao chép" : "Sao chép thông tin") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(info, forType: .string)
                    copied = true
                }
            }
            .buttonStyle(.bordered)
            .font(.system(size: 12))
        }
        .panelStyle()
    }
}

// MARK: - Cập nhật

@MainActor
final class Updater: ObservableObject {
    enum State: Equatable {
        case idle, checking, upToDate, failed
        case available(version: String, url: URL, notes: String)
    }

    struct Release: Decodable {
        let tag_name: String
        let html_url: URL
        let body: String?
    }

    @Published private(set) var state: State = .idle
    var onChange: (@MainActor () -> Void)?

    var available: (version: String, url: URL)? {
        if case let .available(v, u, _) = state { return (v, u) }
        return nil
    }

    /// Kiểm tra nền: chỉ khi đang bật và lần trước đã quá 20 tiếng.
    func checkIfDue() {
        guard Prefs.autoUpdate else { return }
        if let last = Prefs.lastUpdateCheck, Date().timeIntervalSince(last) < 20 * 3600 { return }
        check()
    }

    func check() {
        if state == .checking { return }
        state = .checking
        Task { await run() }
    }

    private func run() async {
        var req = URLRequest(url: AppInfo.apiLatestRelease, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("RinDock/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let rel = try JSONDecoder().decode(Release.self, from: data)
            Prefs.lastUpdateCheck = Date()
            let latest = rel.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            if Updater.isNewer(latest, than: AppInfo.version) {
                state = .available(version: latest, url: rel.html_url, notes: rel.body ?? "")
            } else {
                state = .upToDate
            }
        } catch {
            state = .failed
        }
        onChange?()
    }

    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

struct UpdateView: View {
    @ObservedObject var updater: Updater
    @AppStorage("autoUpdate") private var autoUpdate = true

    var body: some View {
        VStack(spacing: 14) {
            if let icon = NSImage(named: NSImage.applicationIconName) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 72, height: 72)
            }

            switch updater.state {
            case .idle, .checking:
                ProgressView()
                    .controlSize(.small)
                Text("Đang kiểm tra bản mới…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

            case .upToDate:
                Text("Bạn đang dùng bản mới nhất")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Text("RinDock \(AppInfo.version)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

            case .failed:
                Text("Chưa kiểm tra được")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Text("Bạn kiểm tra kết nối mạng rồi thử lại nha.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Button("Thử lại") { updater.check() }
                    .buttonStyle(.bordered)

            case let .available(version, url, notes):
                Text("Có bản mới RinDock \(version)")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Text("Bạn đang dùng bản \(AppInfo.version)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                if !notes.isEmpty {
                    ScrollView {
                        Text(notes)
                            .font(.system(size: 12))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 150)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.06)))
                }

                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Tải bản mới", systemImage: "arrow.down.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Text("Tải file .dmg, mở ra và kéo RinDock vào Applications để thay bản cũ.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().padding(.vertical, 2)

            Toggle("Tự kiểm tra cập nhật mỗi ngày", isOn: $autoUpdate)
                .font(.system(size: 12))
            Text("RinDock chỉ hỏi GitHub có bản mới không, không gửi thông tin gì của bạn.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .panelStyle()
    }
}

// MARK: - Thanh menu

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let clicker = DockClicker()
    private let updater = Updater()
    private var trustTimer: Timer?
    private var updateTimer: Timer?

    private let supportPanel = Panel { AnyView(SupportView()) }
    private let aboutPanel = Panel { AnyView(AboutView()) }
    private let bugPanel = Panel { AnyView(BugReportView()) }
    private lazy var updatePanel: Panel = {
        let u = updater
        return Panel { AnyView(UpdateView(updater: u)) }
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

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

        updater.onChange = { [weak self] in self?.updateIcon() }
        updater.checkIfDue()
        updateTimer = Timer.scheduledTimer(timeInterval: 6 * 3600, target: self,
                                           selector: #selector(periodicUpdateCheck(_:)),
                                           userInfo: nil, repeats: true)
        updateIcon()
    }

    @objc private func checkTrust(_ timer: Timer) {
        if AXIsProcessTrusted() {
            timer.invalidate()
            trustTimer = nil
            updateIcon()
        }
    }

    @objc private func periodicUpdateCheck(_ timer: Timer) {
        updater.checkIfDue()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if let a = updater.available {
            menu.addItem(item("⬆︎ Có bản mới \(a.version), tải về…", #selector(openUpdate)))
            menu.addItem(.separator())
        }

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

        menu.addItem(item("Kiểm tra cập nhật…", #selector(checkForUpdates)))
        let auto = item("Tự kiểm tra cập nhật", #selector(toggleAutoUpdate))
        auto.state = Prefs.autoUpdate ? .on : .off
        menu.addItem(auto)
        menu.addItem(.separator())

        menu.addItem(item("Giới thiệu RinDock", #selector(openAbout)))
        menu.addItem(item("Báo lỗi…", #selector(openBugReport)))
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
        let hasUpdate = updater.available != nil
        let symbol = hasUpdate ? "dock.arrow.down.rectangle" : "dock.rectangle"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "RinDock")
            ?? NSImage(systemSymbolName: "rectangle.bottomthird.inset.filled", accessibilityDescription: "RinDock")
        image?.isTemplate = true
        statusItem.button?.image = image
        if let a = updater.available {
            statusItem.button?.toolTip = "RinDock: có bản mới \(a.version)"
        } else {
            statusItem.button?.toolTip = "RinDock"
        }
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
            alert.informativeText = "Bạn thêm tay: System Settings → General → Login Items → bấm + → chọn RinDock.\n\n(\(error.localizedDescription))"
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func checkForUpdates() {
        updater.check()
        updatePanel.show()
    }

    @objc private func openUpdate() {
        updatePanel.show()
    }

    @objc private func toggleAutoUpdate() {
        Prefs.autoUpdate.toggle()
        if Prefs.autoUpdate { updater.checkIfDue() }
    }

    @objc private func openAbout() {
        aboutPanel.show()
    }

    @objc private func openBugReport() {
        bugPanel.show()
    }

    @objc private func openSupport() {
        supportPanel.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - Khởi chạy

@main
struct RinDockApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let appDelegate = AppDelegate()
        application.delegate = appDelegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(appDelegate) {
            application.run()
        }
    }
}
