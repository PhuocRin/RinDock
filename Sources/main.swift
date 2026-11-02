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
        case .minimizeAll:     return L("Thu nhỏ tất cả cửa sổ của app", "Minimize all of the app's windows")
        case .minimizeFocused: return L("Chỉ thu nhỏ cửa sổ đang dùng", "Minimize only the active window")
        case .hide:            return L("Ẩn app (nhanh, không hiệu ứng)", "Hide the app (fast, no animation)")
        }
    }
}

// MARK: - Ngôn ngữ

enum AppLanguage: String, CaseIterable {
    case system, vi, en

    var title: String {
        switch self {
        case .system: return L("Theo ngôn ngữ của máy", "Same as system")
        case .vi:     return "Tiếng Việt"
        case .en:     return "English"
        }
    }

    /// Ngôn ngữ thực sự dùng (Theo máy → tiếng Việt nếu máy để tiếng Việt, còn lại tiếng Anh).
    static var resolved: AppLanguage {
        switch Prefs.language {
        case .vi: return .vi
        case .en: return .en
        case .system:
            let first = Locale.preferredLanguages.first ?? "en"
            return first.hasPrefix("vi") ? .vi : .en
        }
    }
}

/// Chọn chữ theo ngôn ngữ đang dùng.
func L(_ vi: String, _ en: String) -> String {
    AppLanguage.resolved == .vi ? vi : en
}

enum UpdateFrequency: String, CaseIterable {
    case daily, weekly, off

    var title: String {
        switch self {
        case .daily:  return L("Mỗi ngày", "Daily")
        case .weekly: return L("Mỗi tuần", "Weekly")
        case .off:    return L("Tắt", "Off")
        }
    }

    /// Khoảng cách tối thiểu giữa hai lần tự kiểm tra.
    var interval: TimeInterval? {
        switch self {
        case .daily:  return 20 * 3600
        case .weekly: return 6.5 * 24 * 3600
        case .off:    return nil
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

    /// Tần suất tự hỏi GitHub có bản mới không. Mặc định mỗi ngày.
    static var language: AppLanguage {
        get { AppLanguage(rawValue: d.string(forKey: "language") ?? "") ?? .system }
        set { d.set(newValue.rawValue, forKey: "language") }
    }

    static var updateFrequency: UpdateFrequency {
        get { UpdateFrequency(rawValue: d.string(forKey: "updateFrequency") ?? "") ?? .daily }
        set { d.set(newValue.rawValue, forKey: "updateFrequency") }
    }

    /// Chuyển cài đặt cũ (bật/tắt) sang tần suất.
    static func migrate() {
        if d.string(forKey: "updateFrequency") == nil {
            let oldOn = d.object(forKey: "autoUpdate") as? Bool ?? true
            updateFrequency = oldOn ? .daily : .off
        }
        d.removeObject(forKey: "autoUpdate")
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
    static let facebookURL = URL(string: "https://www.facebook.com/phuocrinrin")!
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
            + L("Chế độ", "Mode") + ": \(Prefs.mode.title)\n"
            + L("Đang bật", "Enabled") + ": \(Prefs.enabled ? L("Có", "Yes") : L("Không", "No")) · "
            + L("Quyền Accessibility", "Accessibility permission") + ": \(AXIsProcessTrusted() ? L("Có", "Yes") : L("Chưa", "Not yet"))"
    }
}

// MARK: - Liquid Glass dùng chung

/// Nền cửa sổ: gradient xanh tím cùng tông icon app, để lớp kính có màu mà khúc xạ.
struct PanelBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.36, green: 0.55, blue: 1.0),
                                    Color(red: 0.48, green: 0.36, blue: 1.0),
                                    Color(red: 0.69, green: 0.36, blue: 1.0)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle()
                .fill(Color(red: 0.45, green: 0.90, blue: 0.95).opacity(0.55))
                .frame(width: 260, height: 260)
                .blur(radius: 70)
                .offset(x: 140, y: 260)
            Circle()
                .fill(Color(red: 1.0, green: 0.55, blue: 0.80).opacity(0.45))
                .frame(width: 240, height: 240)
                .blur(radius: 70)
                .offset(x: -150, y: -200)
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// Khung chung cho mọi cửa sổ: nền gradient, chữ sáng.
    func panelStyle(width: CGFloat = 340) -> some View {
        self
            .padding(.horizontal, 26)
            .padding(.top, 40)
            .padding(.bottom, 26)
            .frame(width: width)
            .background { PanelBackdrop() }
            .environment(\.colorScheme, .dark)
    }

    /// Khối nội dung mờ trong suốt (không phải kính, để nút kính đặt bên trong không bị kính chồng kính).
    func softCard(cornerRadius: CGFloat = 18) -> some View {
        self
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(0.14))
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.28), lineWidth: 1)
            }
    }

    /// Nút Liquid Glass thật trên macOS 26, nút thường ở bản thấp hơn.
    func glassButton(prominent: Bool = false) -> some View {
        modifier(GlassButton(prominent: prominent))
    }

    /// Chữ ghi chú nhỏ trên nền gradient.
    func noteText() -> some View {
        self
            .font(.system(size: 11))
            .foregroundStyle(Color.white.opacity(0.78))
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct GlassButton: ViewModifier {
    let prominent: Bool
    private let deep = Color(red: 0.16, green: 0.12, blue: 0.48)

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            if prominent {
                content.buttonStyle(.glassProminent).tint(deep)
            } else {
                content.buttonStyle(.glass)
            }
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    @ViewBuilder
    private func fallback(_ content: Content) -> some View {
        if prominent {
            content.buttonStyle(.borderedProminent).tint(deep)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

/// Gom các nút kính đứng gần nhau vào một GlassEffectContainer (macOS 26).
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 10
    @ViewBuilder var content: Content

    @ViewBuilder
    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

struct AppIconView: View {
    var size: CGFloat = 88
    @ViewBuilder
    var body: some View {
        if let icon = NSImage(named: NSImage.applicationIconName) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: size, height: size)
                .shadow(color: Color.black.opacity(0.25), radius: 14, y: 6)
        }
    }
}

@MainActor
final class Panel {
    private var window: NSWindow?
    private let content: () -> AnyView

    init(_ content: @escaping () -> AnyView) {
        self.content = content
    }

    func reloadIfVisible() {
        if window?.isVisible == true { show() }
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
            w.appearance = NSAppearance(named: .darkAqua)
            w.standardWindowButton(.miniaturizeButton)?.isHidden = true
            w.standardWindowButton(.zoomButton)?.isHidden = true
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
    private let qr = Support.qrImage

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "heart.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: Color.pink.opacity(0.6), radius: 12)

            Text(L("Ủng hộ tác giả", "Support the author"))
                .font(.system(size: 22, weight: .bold, design: .rounded))

            Text(qr != nil
                 ? L("RinDock miễn phí. Nếu app giúp ích cho bạn, bạn có thể ủng hộ Phước Rin bằng 1 trong 2 cách bên dưới.",
                     "RinDock is free. If it helps you, you can support Phước Rin in one of the two ways below.")
                 : L("RinDock miễn phí. Nếu app giúp ích cho bạn, bạn có thể ủng hộ Phước Rin qua PayPal.",
                     "RinDock is free. If it helps you, you can support Phước Rin via PayPal."))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let qr {
                VStack(alignment: .leading, spacing: 10) {
                    Label(L("Cách 1 · Chuyển khoản ngân hàng", "Option 1 · Bank transfer (Vietnam)"), systemImage: "building.columns.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text(L("Dành cho bạn ở Việt Nam. Mở app ngân hàng bất kỳ, quét mã này.", "For users in Vietnam. Open any banking app and scan this code."))
                        .noteText()
                    Image(nsImage: qr)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 176, height: 176)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 2)
                    Text(L("App ngân hàng sẽ hiện tên chủ tài khoản, bạn kiểm tra đúng tên trước khi chuyển nha.", "Your banking app will show the account holder's name. Please check it before sending."))
                        .noteText()
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .softCard()
            }

            VStack(alignment: .leading, spacing: 10) {
                Label(qr != nil ? L("Cách 2 · PayPal", "Option 2 · PayPal") : "PayPal", systemImage: "globe")
                    .font(.system(size: 13, weight: .semibold))
                Text(L("Dành cho bạn ở nước ngoài hoặc có tài khoản PayPal.", "For users outside Vietnam, or anyone with a PayPal account."))
                    .noteText()
                Button {
                    NSWorkspace.shared.open(Support.paypalURL)
                } label: {
                    Label(L("Ủng hộ qua PayPal", "Support via PayPal"), systemImage: "arrow.up.right")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .glassButton(prominent: true)
                .controlSize(.large)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .softCard()

            Text(L("Cảm ơn bạn đã dùng RinDock 💙", "Thanks for using RinDock 💙"))
                .noteText()
        }
        .panelStyle(width: 360)
    }
}

// MARK: - Giới thiệu

struct AboutView: View {
    var body: some View {
        VStack(spacing: 12) {
            AppIconView(size: 96)

            Text("RinDock")
                .font(.system(size: 26, weight: .bold, design: .rounded))

            Text(L("Phiên bản", "Version") + " \(AppInfo.version)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            Text(L("Bấm icon app trên Dock để thu nhỏ, bấm lại để hiện lên, giống taskbar trên Windows.", "Click an app's Dock icon to minimize it, click again to bring it back, just like the Windows taskbar."))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 12) {
                Text(L("Làm bởi Phước Rin", "Made by Phước Rin"))
                    .font(.system(size: 13, weight: .semibold))

                GlassGroup(spacing: 10) {
                    Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                        GridRow {
                            link("YouTube", "play.rectangle.fill", AppInfo.youtubeURL)
                            link("Facebook", "f.square.fill", AppInfo.facebookURL)
                        }
                        GridRow {
                            link("TikTok", "music.note", AppInfo.tiktokURL)
                            link("GitHub", "chevron.left.forwardslash.chevron.right", AppInfo.repoURL)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .softCard()
            .padding(.top, 6)

            Text(L("Miễn phí · Mã nguồn mở (MIT)", "Free · Open source (MIT)"))
                .noteText()
                .padding(.top, 2)
        }
        .panelStyle()
    }

    private func link(_ title: String, _ symbol: String, _ url: URL) -> some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity)
        }
        .glassButton()
        .controlSize(.large)
    }
}

// MARK: - Báo lỗi

enum BugReport {
    static var template: String {
        L("Mô tả lỗi:", "What happened:") + "\n\n\n"
            + L("Các bước để gặp lỗi:", "Steps to reproduce:") + "\n1. \n2. \n\n"
            + L("App bị ảnh hưởng (nếu có):", "Affected app (if any):") + "\n\n"
            + "---\n" + AppInfo.diagnostics
    }

    static var emailURL: URL? {
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = AppInfo.email
        c.queryItems = [
            URLQueryItem(name: "subject", value: "[RinDock \(AppInfo.version)] " + L("Báo lỗi", "Bug report")),
            URLQueryItem(name: "body", value: template),
        ]
        return c.url
    }

    static var githubURL: URL? {
        var c = URLComponents(string: "https://github.com/PhuocRin/RinDock/issues/new")
        c?.queryItems = [
            URLQueryItem(name: "title", value: L("Báo lỗi: ", "Bug: ")),
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
                .foregroundStyle(.white)
                .shadow(color: Color.orange.opacity(0.6), radius: 12)

            Text(L("Báo lỗi", "Report a bug"))
                .font(.system(size: 22, weight: .bold, design: .rounded))

            Text(L("Gặp lỗi, hay có app không thu nhỏ được? Bạn mô tả giúp mình nha, mình sẽ sửa ở bản sau.", "Found a bug, or an app that won't minimize? Tell me what happened and I'll fix it in the next version."))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text(L("Thông tin gửi kèm", "Info included"))
                    .font(.system(size: 11, weight: .semibold))
                Text(info)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L("Chỉ gồm phiên bản app, macOS và loại chip. Không có thông tin cá nhân.", "Only the app version, macOS version and chip. No personal information."))
                    .noteText()
                    .padding(.top, 2)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .softCard(cornerRadius: 16)

            GlassGroup(spacing: 10) {
                VStack(spacing: 10) {
                    Button {
                        if let url = BugReport.emailURL { NSWorkspace.shared.open(url) }
                    } label: {
                        Label(L("Gửi qua email", "Send by email"), systemImage: "envelope.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .glassButton(prominent: true)
                    .controlSize(.large)

                    HStack(spacing: 10) {
                        Button {
                            if let url = BugReport.githubURL { NSWorkspace.shared.open(url) }
                        } label: {
                            Text(L("Báo trên GitHub", "Report on GitHub")).frame(maxWidth: .infinity)
                        }
                        .glassButton()

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(info, forType: .string)
                            copied = true
                        } label: {
                            Text(copied ? L("Đã sao chép", "Copied") : L("Sao chép thông tin", "Copy info")).frame(maxWidth: .infinity)
                        }
                        .glassButton()
                    }
                    .font(.system(size: 12))
                    .controlSize(.large)
                }
            }
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

    /// Kiểm tra nền theo tần suất người dùng chọn (mỗi ngày / mỗi tuần / tắt).
    func checkIfDue() {
        guard let interval = Prefs.updateFrequency.interval else { return }
        if let last = Prefs.lastUpdateCheck, Date().timeIntervalSince(last) < interval { return }
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
    @AppStorage("updateFrequency") private var frequency: UpdateFrequency = .daily

    var body: some View {
        VStack(spacing: 14) {
            AppIconView(size: 76)

            switch updater.state {
            case .idle, .checking:
                ProgressView()
                    .controlSize(.small)
                Text(L("Đang kiểm tra bản mới…", "Checking for updates…"))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

            case .upToDate:
                Text(L("Bạn đang dùng bản mới nhất", "You're on the latest version"))
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                Text("RinDock \(AppInfo.version)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

            case .failed:
                Text(L("Chưa kiểm tra được", "Couldn't check"))
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                Text(L("Bạn kiểm tra kết nối mạng rồi thử lại nha.", "Check your internet connection and try again."))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Button(L("Thử lại", "Try again")) { updater.check() }
                    .glassButton()
                    .controlSize(.large)

            case let .available(version, url, notes):
                Text(L("Có bản mới RinDock \(version)", "RinDock \(version) is available"))
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                Text(L("Bạn đang dùng bản \(AppInfo.version)", "You're on version \(AppInfo.version)"))
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
                    .padding(14)
                    .softCard(cornerRadius: 16)
                }

                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label(L("Tải bản mới", "Download update"), systemImage: "arrow.down.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .glassButton(prominent: true)
                .controlSize(.large)

                Text(L("Tải file .dmg, mở ra và kéo RinDock vào Applications để thay bản cũ.", "Download the .dmg, open it and drag RinDock into Applications to replace the old version."))
                    .noteText()
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 8) {
                Text(L("Tự kiểm tra cập nhật", "Check for updates automatically"))
                    .font(.system(size: 12, weight: .semibold))
                Picker(L("Tự kiểm tra cập nhật", "Check for updates automatically"), selection: $frequency) {
                    ForEach(UpdateFrequency.allCases, id: \.self) { f in
                        Text(f.title).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(frequency == .off
                     ? L("Đã tắt. Bạn vẫn kiểm tra được bất cứ lúc nào bằng Kiểm tra cập nhật… trong menu.",
                         "Off. You can still check anytime with Check for Updates… in the menu.")
                     : L("RinDock chỉ hỏi GitHub có bản mới không, không gửi thông tin gì của bạn.",
                         "RinDock only asks GitHub whether a new version exists. Nothing about you is sent."))
                    .noteText()
                    .multilineTextAlignment(.center)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .softCard(cornerRadius: 16)
            .padding(.top, 4)
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

        Prefs.migrate()
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
            menu.addItem(item(L("⬆︎ Có bản mới \(a.version), tải về…", "⬆︎ RinDock \(a.version) is available, download…"), #selector(openUpdate)))
            menu.addItem(.separator())
        }

        if AXIsProcessTrusted() {
            menu.addItem(label(Prefs.enabled ? L("RinDock đang chạy", "RinDock is running") : L("RinDock đang tắt", "RinDock is off")))
        } else {
            menu.addItem(item(L("⚠️ Cần cấp quyền Accessibility…", "⚠️ Accessibility permission needed…"), #selector(openAccessibility)))
        }
        menu.addItem(.separator())

        let toggle = item(L("Bật", "Enabled"), #selector(toggleEnabled))
        toggle.state = Prefs.enabled ? .on : .off
        menu.addItem(toggle)
        menu.addItem(.separator())

        menu.addItem(label(L("Bấm icon app đang dùng trên Dock để:", "Clicking the active app's Dock icon:")))
        for mode in ClickMode.allCases {
            let it = item(mode.title, #selector(chooseMode(_:)))
            it.representedObject = mode.rawValue
            it.state = Prefs.mode == mode ? .on : .off
            it.indentationLevel = 1
            menu.addItem(it)
        }
        menu.addItem(.separator())

        let login = item(L("Mở cùng máy", "Open at login"), #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())

        menu.addItem(item(L("Kiểm tra cập nhật…", "Check for Updates…"), #selector(checkForUpdates)))
        let auto = NSMenuItem(title: L("Tự kiểm tra cập nhật", "Check for updates automatically"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for f in UpdateFrequency.allCases {
            let it = item(f.title, #selector(chooseUpdateFrequency(_:)))
            it.representedObject = f.rawValue
            it.state = Prefs.updateFrequency == f ? .on : .off
            sub.addItem(it)
        }
        auto.submenu = sub
        menu.addItem(auto)
        menu.addItem(.separator())

        let langItem = NSMenuItem(title: "Ngôn ngữ · Language", action: nil, keyEquivalent: "")
        let langMenu = NSMenu()
        for lang in AppLanguage.allCases {
            let it = item(lang.title, #selector(chooseLanguage(_:)))
            it.representedObject = lang.rawValue
            it.state = Prefs.language == lang ? .on : .off
            langMenu.addItem(it)
        }
        langItem.submenu = langMenu
        menu.addItem(langItem)
        menu.addItem(.separator())

        menu.addItem(item(L("Giới thiệu RinDock", "About RinDock"), #selector(openAbout)))
        menu.addItem(item(L("Báo lỗi…", "Report a Bug…"), #selector(openBugReport)))
        menu.addItem(item(L("♥ Ủng hộ tác giả…", "♥ Support the Author…"), #selector(openSupport)))
        menu.addItem(.separator())

        menu.addItem(item(L("Thoát RinDock", "Quit RinDock"), #selector(quit)))
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
        let name = hasUpdate ? "MenuBarIconUpdate" : "MenuBarIcon"
        let image = Bundle.main.image(forResource: name)
            ?? NSImage(systemSymbolName: hasUpdate ? "dock.arrow.down.rectangle" : "dock.rectangle",
                       accessibilityDescription: "RinDock")
        image?.size = NSSize(width: 18, height: 18)
        image?.isTemplate = true
        image?.accessibilityDescription = "RinDock"
        statusItem.button?.image = image
        if let a = updater.available {
            statusItem.button?.toolTip = L("RinDock: có bản mới \(a.version)", "RinDock: version \(a.version) is available")
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
            alert.messageText = L("Chưa bật được Mở cùng máy", "Couldn't turn on Open at login")
            alert.informativeText = L("Bạn thêm tay: System Settings → General → Login Items → bấm + → chọn RinDock.", "Add it manually: System Settings → General → Login Items → click + → choose RinDock.") + "\n\n(\(error.localizedDescription))"
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

    @objc private func chooseUpdateFrequency(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let f = UpdateFrequency(rawValue: raw) {
            Prefs.updateFrequency = f
            updater.checkIfDue()
        }
    }

    @objc private func chooseLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let lang = AppLanguage(rawValue: raw) else { return }
        Prefs.language = lang
        // Cửa sổ nào đang mở thì vẽ lại ngay bằng ngôn ngữ mới.
        for panel in [supportPanel, aboutPanel, bugPanel, updatePanel] {
            panel.reloadIfVisible()
        }
        updateIcon()
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
