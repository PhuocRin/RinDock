// RinDock — bấm icon app trên Dock để thu nhỏ / hiện lại, giống taskbar Windows.
// Chạy trên thanh menu, cần quyền Accessibility.

import Cocoa
import ApplicationServices
import ServiceManagement
import SwiftUI
import CryptoKit
import Combine
import Security

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

enum UpdateMode: String, CaseIterable {
    case auto, ask, notify

    var title: String {
        switch self {
        case .auto:   return L("Tự cập nhật", "Install automatically")
        case .ask:    return L("Hỏi trước khi cập nhật", "Ask before installing")
        case .notify: return L("Chỉ báo cho tôi", "Just notify me")
        }
    }

    var shortTitle: String {
        switch self {
        case .auto:   return L("Tự cập nhật", "Auto")
        case .ask:    return L("Hỏi trước", "Ask")
        case .notify: return L("Chỉ báo", "Notify")
        }
    }
}

enum GlassLook: String, CaseIterable {
    case system, clear, tinted

    var title: String {
        switch self {
        case .system: return L("Theo hệ thống", "System")
        case .clear:  return L("Trong", "Clear")
        case .tinted: return L("Mờ", "Tinted")
        }
    }

    var note: String {
        switch self {
        case .system: return L("Theo cài đặt Liquid Glass của macOS (System Settings → Appearance). Đổi ở đó là RinDock đổi theo.",
                               "Follows macOS's Liquid Glass setting (System Settings → Appearance).")
        case .clear:  return L("Kính trong hơn, thấy rõ nền phía sau.", "Clearer glass that shows more of what's behind it.")
        case .tinted: return L("Kính đục hơn, chữ trên nút dễ đọc hơn.", "More opaque glass with easier-to-read buttons.")
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

    static var language: AppLanguage {
        get { AppLanguage(rawValue: d.string(forKey: "language") ?? "") ?? .system }
        set { d.set(newValue.rawValue, forKey: "language") }
    }

    /// Tần suất tự hỏi GitHub có bản mới không. Mặc định mỗi ngày.
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

    /// Đã xem cửa sổ hướng dẫn lần đầu chưa.
    static var onboarded: Bool {
        get { d.bool(forKey: "onboarded") }
        set { d.set(newValue, forKey: "onboarded") }
    }

    /// Có bản mới thì làm gì. Mặc định hỏi trước.
    static var updateMode: UpdateMode {
        get { UpdateMode(rawValue: d.string(forKey: "updateMode") ?? "") ?? .ask }
        set { d.set(newValue.rawValue, forKey: "updateMode") }
    }

    /// Phiên bản trước khi tự cập nhật (để báo "đã cập nhật" sau khi mở lại).
    static var justUpdatedFrom: String? {
        get { d.string(forKey: "justUpdatedFrom") }
        set { d.set(newValue, forKey: "justUpdatedFrom") }
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

// MARK: - App nào đang ở trên cùng

/// Ghi lại lịch sử app được đưa lên trước, để biết đúng app nào đang dùng
/// tại THỜI ĐIỂM nhấn chuột (Dock có thể đã kịp đổi app trước khi RinDock xử lý).
final class FrontmostTracker {
    private var history: [(time: TimeInterval, pid: pid_t)] = []
    private var observer: NSObjectProtocol?

    init() {
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            history.append((0, pid))
        }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.record(app.processIdentifier)
        }
    }

    private func record(_ pid: pid_t) {
        history.append((ProcessInfo.processInfo.systemUptime, pid))
        if history.count > 20 { history.removeFirst(history.count - 20) }
    }

    /// App đang ở trên cùng tại thời điểm `t` (giây kể từ lúc bật máy, cùng thang với NSEvent.timestamp).
    func frontmost(at t: TimeInterval) -> pid_t? {
        history.last(where: { $0.time <= t })?.pid
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
    }
}

/// Đọc thứ tự cửa sổ trên màn hình (từ trên xuống), không cần quyền ghi màn hình.
enum WindowStack {
    /// Cửa sổ trên cùng của app có đang bị cửa sổ THƯỜNG của một app THƯỜNG khác đè quá nửa không.
    /// Bỏ qua cửa sổ nổi, lớp phủ trong suốt của app thanh menu, Dock, thông báo…
    static func isCovered(pid: pid_t) -> Bool {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return false }
        let regular = Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map { $0.processIdentifier })
        var above: [CGRect] = []

        for w in list {
            guard (w[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let owner = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict as CFDictionary),
                  rect.width > 100, rect.height > 100 else { continue }
            let alpha = (w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            if alpha < 0.5 { continue }

            if owner == pid {
                let area = rect.width * rect.height
                for r in above {
                    let overlap = rect.intersection(r)
                    if !overlap.isNull, overlap.width * overlap.height > area * 0.5 { return true }
                }
                return false
            }
            if regular.contains(owner) { above.append(rect) }
        }
        return false
    }
}

/// Nhật ký 30 lần bấm Dock gần nhất (chỉ trong bộ nhớ, mất khi thoát app). Dùng khi báo lỗi.
enum DockLog {
    private(set) static var lines: [String] = []
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func add(_ text: String) {
        lines.append(fmt.string(from: Date()) + " " + text)
        if lines.count > 30 { lines.removeFirst(lines.count - 30) }
    }

    static var text: String {
        lines.isEmpty ? L("(chưa có lần bấm nào)", "(no clicks yet)") : lines.joined(separator: "\n")
    }
}

// MARK: - Bắt cú bấm trên Dock

final class DockClicker {
    private struct Press {
        let point: CGPoint
        let time: Date
        let app: NSRunningApplication
        let wasActive: Bool
        let wasHidden: Bool
        let visible: [AXUIElement]
        let minimized: [AXUIElement]
        let focused: AXUIElement?
    }

    private var downMonitor: Any?
    private var upMonitor: Any?
    private var press: Press?
    private var lastAction = Date.distantPast
    private let tracker = FrontmostTracker()

    func start() {
        downMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in
            self?.handleDown(e)
        }
        upMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] e in
            self?.handleUp(e)
        }
    }

    // Chụp lại trạng thái lúc nhấn chuột, trước khi Dock xử lý cú bấm.
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

        // "Đang dùng" = là app trên cùng ĐÚNG lúc nhấn chuột, và cửa sổ không bị app khác đè lên.
        let frontAtPress = tracker.frontmost(at: e.timestamp) == pid
        let covered = frontAtPress && WindowStack.isCovered(pid: pid)
        let active = frontAtPress && !covered
        let visibleCount = wins.filter { !AX.isMinimized($0) }.count
        DockLog.add("\(app.localizedName ?? "?") front=\(frontAtPress) covered=\(covered) "
                    + "visible=\(visibleCount) min=\(wins.count - visibleCount) hidden=\(app.isHidden)")

        press = Press(
            point: point,
            time: Date(),
            app: app,
            wasActive: active,
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
        guard Date().timeIntervalSince(lastAction) > 0.35 else {
            DockLog.add("  → bỏ qua (bấm quá nhanh)")
            return
        }

        // Đợi Dock làm xong phần của nó rồi mới ra tay.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.act(on: p)
        }
    }

    private func act(on p: Press) {
        // App đang bị ẩn: Dock tự hiện lại, không cần làm gì.
        if p.wasHidden { DockLog.add("  → để Dock hiện app"); return }

        if p.wasActive && !p.visible.isEmpty {
            DockLog.add("  → thu nhỏ (\(Prefs.mode.rawValue))")
            // App đang dùng, nằm trên cùng → thu nhỏ / ẩn.
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
            DockLog.add("  → hiện lại \(p.minimized.count) cửa sổ")
            p.minimized.forEach { AX.setMinimized($0, false) }
            if let last = p.minimized.last {
                AXUIElementPerformAction(last, kAXRaiseAction as CFString)
            }
            p.app.activate(options: [.activateAllWindows])
            lastAction = Date()
        } else if !p.visible.isEmpty {
            // App nằm dưới app khác → đưa cửa sổ của nó lên trên (giống Windows), không thu nhỏ.
            DockLog.add("  → đưa lên trên")
            if let top = p.focused ?? p.visible.first {
                AXUIElementPerformAction(top, kAXRaiseAction as CFString)
            }
            p.app.activate(options: [.activateAllWindows])
        }
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

/// Lớp làm mờ màn hình phía sau cửa sổ.
struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Nền cửa sổ: màn hình phía sau được làm mờ + lớp gradient, độ đậm chỉnh trong Giao diện kính.
struct PanelBackground: View {
    @AppStorage("backdropOpacity") private var opacity: Double = 0.85
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            BehindWindowBlur()
            PanelBackdrop()
                .opacity(reduceTransparency ? 1 : opacity)
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
            .background { PanelBackground() }
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
    @AppStorage("glassLook") private var look: GlassLook = .system
    private let deep = Color(red: 0.16, green: 0.12, blue: 0.48)

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            if prominent {
                content.buttonStyle(.glassProminent).tint(deep)
            } else {
                styled(content)
            }
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    #if compiler(>=6.2)
    /// Kiểu kính Trong / Mờ cần macOS 26.1; "Theo hệ thống" dùng kính mặc định để macOS tự áp cài đặt của người dùng.
    @available(macOS 26.0, *)
    @ViewBuilder
    private func styled(_ content: Content) -> some View {
        if #available(macOS 26.1, *) {
            switch look {
            case .system: content.buttonStyle(.glass)
            case .clear:  content.buttonStyle(.glass(.clear))
            case .tinted: content.buttonStyle(.glass(.regular.tint(Color.white.opacity(0.22))))
            }
        } else {
            content.buttonStyle(.glass)
        }
    }
    #endif

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

    func close() {
        window?.close()
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
            w.isOpaque = false
            w.backgroundColor = .clear
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
            + "\n\n" + L("Nhật ký bấm Dock:", "Dock click log:") + "\n" + DockLog.text
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
                Text(L("Gồm phiên bản app, macOS, loại chip và nhật ký 30 lần bấm Dock gần nhất (tên app được bấm). Không có thông tin cá nhân nào khác.",
                       "App version, macOS version, chip and a log of the last 30 Dock clicks (names of clicked apps). No other personal information."))
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
                            NSPasteboard.general.setString(info + "\n\n" + DockLog.text, forType: .string)
                            copied = true
                        } label: {
                            Text(copied ? L("Đã sao chép", "Copied") : L("Sao chép kèm nhật ký", "Copy with log")).frame(maxWidth: .infinity)
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

// MARK: - Giao diện kính

struct AppearanceView: View {
    @AppStorage("glassLook") private var look: GlassLook = .system
    @AppStorage("backdropOpacity") private var opacity: Double = 0.85
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var supportsGlassStyles: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0))
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "drop.halffull")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: Color.cyan.opacity(0.6), radius: 12)

            Text(L("Giao diện kính", "Glass appearance"))
                .font(.system(size: 22, weight: .bold, design: .rounded))

            Text(L("Áp dụng cho các cửa sổ của RinDock, đổi là thấy ngay.", "Applies to RinDock's windows and updates instantly."))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 8) {
                Text(L("Kiểu kính", "Glass style"))
                    .font(.system(size: 12, weight: .semibold))
                Picker(L("Kiểu kính", "Glass style"), selection: $look) {
                    ForEach(GlassLook.allCases, id: \.self) { g in
                        Text(g.title).tag(g)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(!supportsGlassStyles)
                Text(supportsGlassStyles ? look.note
                     : L("Cần macOS 26.1 trở lên để đổi kiểu kính.", "Changing the glass style needs macOS 26.1 or later."))
                    .noteText()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .softCard(cornerRadius: 16)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L("Độ đậm của nền", "Background tint"))
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text("\(Int((opacity * 100).rounded()))%")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $opacity, in: 0.3...1.0) {
                    Text(L("Độ đậm của nền", "Background tint"))
                } minimumValueLabel: {
                    Text(L("Trong", "Clear")).font(.system(size: 11))
                } maximumValueLabel: {
                    Text(L("Đậm", "Solid")).font(.system(size: 11))
                }
                .labelsHidden()
                .disabled(reduceTransparency)
                Text(reduceTransparency
                     ? L("Máy đang bật Giảm độ trong suốt (Reduce Transparency) nên nền luôn đậm.",
                         "Reduce Transparency is on, so the background stays solid.")
                     : L("Kéo về Trong để nhìn xuyên ra màn hình phía sau.", "Drag toward Clear to see more of the screen behind."))
                    .noteText()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .softCard(cornerRadius: 16)

            GlassGroup(spacing: 10) {
                HStack(spacing: 10) {
                    Button {
                        look = .system
                        opacity = 0.85
                    } label: {
                        Text(L("Đặt lại", "Reset")).frame(maxWidth: .infinity)
                    }
                    .glassButton()

                    Button {
                        NSApp.keyWindow?.close()
                    } label: {
                        Text(L("Xong", "Done")).frame(maxWidth: .infinity)
                    }
                    .glassButton(prominent: true)
                }
                .font(.system(size: 13, weight: .semibold))
                .controlSize(.large)
            }
        }
        .panelStyle(width: 360)
    }
}

// MARK: - Hướng dẫn lần đầu

struct OnboardingView: View {
    var onDone: @MainActor () -> Void = {}
    @State private var trusted = AXIsProcessTrusted()
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 14) {
            AppIconView(size: 84)

            Text(L("Chào mừng tới RinDock", "Welcome to RinDock"))
                .font(.system(size: 22, weight: .bold, design: .rounded))

            Text(L("Làm 2 bước dưới đây là dùng được ngay.", "Two quick steps and you're ready."))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            // Bước 1: quyền
            VStack(alignment: .leading, spacing: 10) {
                stepHeader(1, L("Cấp quyền Accessibility", "Allow Accessibility"), done: trusted)
                Text(L("RinDock cần quyền này để biết bạn bấm icon nào trên Dock và thu nhỏ cửa sổ. Không chụp màn hình, không ghi phím.",
                       "RinDock needs this to see which Dock icon you click and minimize windows. No screen recording, no keylogging."))
                    .noteText()
                if trusted {
                    Label(L("Đã cấp quyền", "Permission granted"), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(red: 0.55, green: 1.0, blue: 0.7))
                } else {
                    Text(L("Bấm nút dưới → bật công tắc cạnh RinDock trong danh sách.",
                           "Click below → turn on the switch next to RinDock."))
                        .font(.system(size: 12, weight: .medium))
                    Button {
                        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label(L("Mở cài đặt Accessibility", "Open Accessibility settings"), systemImage: "lock.open.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .glassButton(prominent: true)
                    .controlSize(.large)
                    Text(L("Đã bật mà vẫn báo chưa có quyền? Chọn RinDock trong danh sách, bấm nút − để xoá, rồi bấm lại nút trên.",
                           "Turned it on but still not granted? Select RinDock in the list, click − to remove it, then click the button above again."))
                        .noteText()
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .softCard(cornerRadius: 16)

            // Bước 2: mở cùng máy
            VStack(alignment: .leading, spacing: 10) {
                stepHeader(2, L("Mở cùng máy (nên bật)", "Open at login (recommended)"), done: openAtLogin)
                Toggle(L("Tự mở RinDock khi bật máy", "Start RinDock when you log in"), isOn: $openAtLogin)
                    .font(.system(size: 12, weight: .medium))
                    .onChange(of: openAtLogin) { on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            openAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .softCard(cornerRadius: 16)

            // Cách dùng
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Cách dùng", "How it works"))
                    .font(.system(size: 12, weight: .semibold))
                bullet("dock.rectangle", L("Bấm icon app đang dùng trên Dock → thu nhỏ. Bấm lại → hiện lên.",
                                           "Click the active app's Dock icon to minimize it. Click again to bring it back."))
                bullet("menubar.rectangle", L("Cài đặt nằm ở icon RinDock trên thanh menu, góc trên bên phải màn hình.",
                                              "Settings live in the RinDock icon in the menu bar, top right of your screen."))
                bullet("command", L("Giữ ⌘ ⌥ ⌃ hoặc ⇧ khi bấm để Dock làm như bình thường.",
                                    "Hold ⌘ ⌥ ⌃ or ⇧ while clicking for the normal Dock behavior."))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .softCard(cornerRadius: 16)

            Button {
                onDone()
            } label: {
                Text(trusted ? L("Bắt đầu dùng", "Get started") : L("Để sau", "Later"))
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .glassButton(prominent: trusted)
            .controlSize(.large)
        }
        .panelStyle(width: 380)
        .onReceive(tick) { _ in
            trusted = AXIsProcessTrusted()
        }
    }

    private func stepHeader(_ n: Int, _ title: String, done: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(n).circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(done ? Color(red: 0.55, green: 1.0, blue: 0.7) : Color.white)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
        }
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 18)
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Cập nhật

/// Kiểm tra gói cập nhật có đúng do Phước Rin phát hành không.
enum UpdateSecurity {
    /// Khoá công khai ed25519. Khoá bí mật tương ứng nằm trong secret RINDOCK_SIGNING trên GitHub.
    static let publicKeyBase64 = "cp4+XU5KBpctbtgRelU5WVsCOlPVuVl2X71we0GpjW0="

    static func verify(_ data: Data, signature: Data) -> Bool {
        guard let raw = Data(base64Encoded: publicKeyBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return false }
        return key.isValidSignature(signature, for: data)
    }

    /// Yêu cầu chữ ký của chính app đang chạy (nil nếu không đọc được).
    static func currentRequirement() -> SecRequirement? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var req: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &req) == errSecSuccess else { return nil }
        return req
    }

    /// App đang chạy là bản ký ad-hoc (bản thử cũ) hay bản ký bằng chứng chỉ.
    static var currentIsAdHoc: Bool {
        guard let req = currentRequirement() else { return true }
        var text: CFString?
        SecRequirementCopyString(req, [], &text)
        return (text as String?)?.contains("cdhash") ?? true
    }

    /// Chữ ký Developer ID của Apple (dùng khi sau này chuyển từ chứng chỉ tự tạo sang chứng chỉ Apple).
    static let developerIDRequirement: SecRequirement? = {
        let text = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists "
            + "and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        var req: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &req) == errSecSuccess else { return nil }
        return req
    }()

    /// App mới phải còn nguyên chữ ký, và phải cùng chứng chỉ với app đang chạy
    /// HOẶC được ký bằng Developer ID của Apple. (Gói chứa nó đã qua kiểm tra chữ ký ed25519 của tác giả.)
    static func newAppIsTrusted(_ url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        if currentIsAdHoc {
            return SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess
        }
        if let same = currentRequirement(), SecStaticCodeCheckValidity(code, flags, same) == errSecSuccess {
            return true
        }
        if let devID = developerIDRequirement, SecStaticCodeCheckValidity(code, flags, devID) == errSecSuccess {
            return true
        }
        return false
    }
}

enum UpdateError: Error {
    case missingPackage, badSignature, badApp, notWritable, failed(String)

    var message: String {
        switch self {
        case .missingPackage:
            return L("Bản này chưa có gói tự cập nhật. Bạn tải thủ công giúp mình nha.",
                     "This version has no auto-update package. Please download it manually.")
        case .badSignature:
            return L("Gói tải về không đúng chữ ký của Phước Rin nên RinDock không cài.",
                     "The downloaded package isn't signed by Phước Rin, so RinDock won't install it.")
        case .badApp:
            return L("App trong gói cập nhật không hợp lệ nên RinDock không cài.",
                     "The app inside the update package isn't valid, so RinDock won't install it.")
        case .notWritable:
            return L("RinDock chỉ tự cập nhật được khi nằm trong thư mục Applications. Bạn kéo RinDock vào Applications rồi thử lại nha.",
                     "RinDock can only update itself from the Applications folder. Move it there and try again.")
        case .failed(let detail):
            return L("Có lỗi khi cập nhật: ", "Update failed: ") + detail
        }
    }
}

@MainActor
final class Updater: ObservableObject {
    struct Asset: Decodable, Equatable {
        let name: String
        let browser_download_url: URL
    }

    struct Release: Decodable, Equatable {
        let tag_name: String
        let html_url: URL
        let body: String?
        let assets: [Asset]

        var version: String { tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")) }
        var notes: String { body ?? "" }
        var zipURL: URL? { assets.first { $0.name.hasSuffix(".zip") }?.browser_download_url }
        var sigURL: URL? { assets.first { $0.name.hasSuffix(".zip.sig") }?.browser_download_url }
        var canAutoInstall: Bool { zipURL != nil && sigURL != nil }
    }

    enum State: Equatable {
        case idle, checking, upToDate, failed
        case available(Release)
        case downloading(Release)
        case installing(Release)
        case installFailed(Release, String)
        case updated(from: String)
    }

    @Published private(set) var state: State = .idle
    var onChange: (@MainActor () -> Void)?
    /// Gọi khi kiểm tra nền thấy bản mới (AppDelegate quyết định làm gì theo cài đặt).
    var onFoundInBackground: (@MainActor (Release) -> Void)?

    var available: Release? {
        if case let .available(r) = state { return r }
        return nil
    }

    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    /// Vừa tự cập nhật xong và mở lại: hiện "đã cập nhật".
    func noteJustUpdated() -> Bool {
        guard let from = Prefs.justUpdatedFrom else { return false }
        Prefs.justUpdatedFrom = nil
        guard from != AppInfo.version else { return false }
        state = .updated(from: from)
        return true
    }

    /// Kiểm tra nền theo tần suất người dùng chọn (mỗi ngày / mỗi tuần / tắt).
    func checkIfDue() {
        guard let interval = Prefs.updateFrequency.interval else { return }
        if let last = Prefs.lastUpdateCheck, Date().timeIntervalSince(last) < interval { return }
        check(background: true)
    }

    func check(background: Bool = false) {
        if isBusy { return }
        state = .checking
        Task { await run(background: background) }
    }

    private func run(background: Bool) async {
        var req = URLRequest(url: AppInfo.apiLatestRelease, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("RinDock/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let rel = try JSONDecoder().decode(Release.self, from: data)
            Prefs.lastUpdateCheck = Date()
            if Updater.isNewer(rel.version, than: AppInfo.version) {
                state = .available(rel)
                onChange?()
                if background { onFoundInBackground?(rel) }
                return
            }
            state = .upToDate
        } catch {
            state = background ? .idle : .failed
        }
        onChange?()
    }

    func install(_ rel: Release) {
        switch state {
        case .downloading, .installing: return
        default: break
        }
        Task { await performInstall(rel) }
    }

    private func performInstall(_ rel: Release) async {
        do {
            guard let zipURL = rel.zipURL, let sigURL = rel.sigURL else { throw UpdateError.missingPackage }
            state = .downloading(rel)
            onChange?()

            let (zipData, zipResp) = try await URLSession.shared.data(from: zipURL)
            let (sigData, sigResp) = try await URLSession.shared.data(from: sigURL)
            guard (zipResp as? HTTPURLResponse)?.statusCode == 200,
                  (sigResp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let sigText = String(decoding: sigData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let signature = Data(base64Encoded: sigText),
                  UpdateSecurity.verify(zipData, signature: signature) else { throw UpdateError.badSignature }

            state = .installing(rel)
            let newApp = try await Task.detached { () throws -> URL in
                try Installer.unpack(zipData)
            }.value
            guard Installer.bundleID(of: newApp) == Bundle.main.bundleIdentifier,
                  UpdateSecurity.newAppIsTrusted(newApp) else { throw UpdateError.badApp }

            try Installer.replaceAndRelaunch(with: newApp)
        } catch let e as UpdateError {
            state = .installFailed(rel, e.message)
        } catch {
            state = .installFailed(rel, UpdateError.failed(error.localizedDescription).message)
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

enum Installer {
    /// Giải nén gói .zip vào thư mục tạm, trả về đường dẫn RinDock.app mới.
    static func unpack(_ zipData: Data) throws -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("RinDockUpdate-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let zip = dir.appendingPathComponent("update.zip")
        try zipData.write(to: zip)
        let out = dir.appendingPathComponent("unpacked")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, out.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError.failed("ditto \(p.terminationStatus)") }
        let app = out.appendingPathComponent("RinDock.app")
        guard fm.fileExists(atPath: app.path) else { throw UpdateError.badApp }
        return app
    }

    static func bundleID(of app: URL) -> String? {
        Bundle(url: app)?.bundleIdentifier
    }

    /// Thoát RinDock, thay app cũ bằng app mới, rồi mở lại.
    @MainActor
    static func replaceAndRelaunch(with newApp: URL) throws {
        let fm = FileManager.default
        let current = Bundle.main.bundleURL
        let parent = current.deletingLastPathComponent()
        // App chạy từ ổ .dmg hoặc bị macOS "dời chỗ" tạm (App Translocation) thì không ghi được.
        guard !current.path.contains("/AppTranslocation/"),
              fm.isWritableFile(atPath: parent.path),
              fm.isWritableFile(atPath: current.path) else { throw UpdateError.notWritable }

        Prefs.justUpdatedFrom = AppInfo.version
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done
        /bin/rm -rf "$1.old"
        if /bin/mv "$1" "$1.old"; then
          if /bin/mv "$2" "$1"; then /bin/rm -rf "$1.old"; else /bin/mv "$1.old" "$1"; fi
        fi
        /usr/bin/xattr -dr com.apple.quarantine "$1" 2>/dev/null
        /usr/bin/open "$1"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "rindock-update", current.path, newApp.path]
        do {
            try p.run()
        } catch {
            Prefs.justUpdatedFrom = nil
            throw UpdateError.failed(error.localizedDescription)
        }
        NSApp.terminate(nil)
    }
}

struct UpdateView: View {
    @ObservedObject var updater: Updater
    @AppStorage("updateFrequency") private var frequency: UpdateFrequency = .daily
    @AppStorage("updateMode") private var mode: UpdateMode = .ask

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
                title(L("Bạn đang dùng bản mới nhất", "You're on the latest version"))
                Text("RinDock \(AppInfo.version)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

            case .failed:
                title(L("Chưa kiểm tra được", "Couldn't check"))
                Text(L("Bạn kiểm tra kết nối mạng rồi thử lại nha.", "Check your internet connection and try again."))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button(L("Thử lại", "Try again")) { updater.check() }
                    .glassButton()
                    .controlSize(.large)

            case let .available(rel):
                title(L("Có bản mới RinDock \(rel.version)", "RinDock \(rel.version) is available"))
                Text(L("Bạn đang dùng bản \(AppInfo.version)", "You're on version \(AppInfo.version)"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                notesBox(rel.notes)
                actions(for: rel)

            case let .downloading(rel):
                ProgressView()
                    .controlSize(.small)
                title(L("Đang tải RinDock \(rel.version)…", "Downloading RinDock \(rel.version)…"))

            case let .installing(rel):
                ProgressView()
                    .controlSize(.small)
                title(L("Đang cài RinDock \(rel.version)…", "Installing RinDock \(rel.version)…"))
                Text(L("RinDock sẽ tự đóng và mở lại trong vài giây.", "RinDock will quit and reopen in a few seconds."))
                    .noteText()
                    .multilineTextAlignment(.center)

            case let .installFailed(rel, reason):
                title(L("Chưa cập nhật được", "Couldn't update"))
                Text(reason)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                actions(for: rel)

            case let .updated(from):
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                title(L("Đã cập nhật lên RinDock \(AppInfo.version)", "Updated to RinDock \(AppInfo.version)"))
                Text(L("Từ bản \(from)", "From version \(from)"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            settings
        }
        .panelStyle(width: 360)
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 19, weight: .bold, design: .rounded))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func notesBox(_ notes: String) -> some View {
        if !notes.isEmpty {
            ScrollView {
                Text(notes)
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 140)
            .padding(14)
            .softCard(cornerRadius: 16)
        }
    }

    @ViewBuilder
    private func actions(for rel: Updater.Release) -> some View {
        GlassGroup(spacing: 10) {
            VStack(spacing: 10) {
                if rel.canAutoInstall {
                    Button {
                        updater.install(rel)
                    } label: {
                        Label(L("Cập nhật ngay", "Update now"), systemImage: "arrow.down.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .glassButton(prominent: true)
                    .controlSize(.large)

                    Button {
                        NSWorkspace.shared.open(rel.html_url)
                    } label: {
                        Text(L("Tải thủ công", "Download manually"))
                            .font(.system(size: 12))
                            .frame(maxWidth: .infinity)
                    }
                    .glassButton()
                    .controlSize(.large)
                } else {
                    Button {
                        NSWorkspace.shared.open(rel.html_url)
                    } label: {
                        Label(L("Tải bản mới", "Download update"), systemImage: "arrow.down.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .glassButton(prominent: true)
                    .controlSize(.large)
                }
            }
        }
        if UpdateSecurity.currentIsAdHoc && rel.canAutoInstall {
            Text(L("Lần cập nhật này bạn sẽ phải cấp lại quyền Accessibility một lần. Từ bản sau thì không cần nữa.",
                   "After this update you'll need to grant Accessibility permission once more. Future updates won't need it."))
                .noteText()
                .multilineTextAlignment(.center)
        }
    }

    private var settings: some View {
        VStack(spacing: 10) {
            VStack(spacing: 6) {
                Text(L("Tự kiểm tra cập nhật", "Check for updates"))
                    .font(.system(size: 12, weight: .semibold))
                Picker(L("Tự kiểm tra cập nhật", "Check for updates"), selection: $frequency) {
                    ForEach(UpdateFrequency.allCases, id: \.self) { f in
                        Text(f.title).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(spacing: 6) {
                Text(L("Khi có bản mới", "When an update is available"))
                    .font(.system(size: 12, weight: .semibold))
                Picker(L("Khi có bản mới", "When an update is available"), selection: $mode) {
                    ForEach(UpdateMode.allCases, id: \.self) { m in
                        Text(m.shortTitle).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(frequency == .off)
            }

            Text(settingsNote)
                .noteText()
                .multilineTextAlignment(.center)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .softCard(cornerRadius: 16)
        .padding(.top, 4)
    }

    private var settingsNote: String {
        if frequency == .off {
            return L("Đã tắt tự kiểm tra. Bạn vẫn kiểm tra được bất cứ lúc nào bằng Kiểm tra cập nhật… trong menu.",
                     "Automatic checks are off. You can still check anytime with Check for Updates… in the menu.")
        }
        switch mode {
        case .auto:
            return L("Có bản mới là RinDock tự tải, kiểm tra chữ ký rồi cài và mở lại. Chỉ hỏi GitHub, không gửi thông tin gì của bạn.",
                     "RinDock downloads, verifies and installs new versions on its own, then reopens. It only asks GitHub; nothing about you is sent.")
        case .ask:
            return L("Có bản mới là RinDock hỏi bạn trước, bấm một nút là xong. Chỉ hỏi GitHub, không gửi thông tin gì của bạn.",
                     "RinDock asks you first; one click installs it. It only asks GitHub; nothing about you is sent.")
        case .notify:
            return L("Có bản mới thì icon trên thanh menu đổi dấu, bạn tự cập nhật khi muốn. Chỉ hỏi GitHub, không gửi thông tin gì của bạn.",
                     "The menu bar icon changes when an update is out; you update when you like. It only asks GitHub; nothing about you is sent.")
        }
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
    private let appearancePanel = Panel { AnyView(AppearanceView()) }
    private lazy var onboardingPanel: Panel = {
        Panel { [weak self] in
            AnyView(OnboardingView(onDone: { self?.finishOnboarding() }))
        }
    }()
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

        // Lần đầu mở, hoặc chưa có quyền: hiện cửa sổ hướng dẫn thay cho hộp thoại hệ thống.
        if !AXIsProcessTrusted() {
            trustTimer = Timer.scheduledTimer(timeInterval: 2, target: self,
                                              selector: #selector(checkTrust(_:)),
                                              userInfo: nil, repeats: true)
        }
        if !Prefs.onboarded || !AXIsProcessTrusted() {
            onboardingPanel.show()
        }

        Prefs.migrate()
        updater.onChange = { [weak self] in self?.updateIcon() }
        updater.onFoundInBackground = { [weak self] rel in self?.handleFoundUpdate(rel) }
        if updater.noteJustUpdated() {
            updatePanel.show()
        }
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

    private func finishOnboarding() {
        Prefs.onboarded = true
        onboardingPanel.close()
        updateIcon()
    }

    @objc private func openOnboarding() {
        onboardingPanel.show()
    }

    @objc private func openAppearance() {
        appearancePanel.show()
    }

    @objc private func periodicUpdateCheck(_ timer: Timer) {
        updater.checkIfDue()
    }

    private func handleFoundUpdate(_ rel: Updater.Release) {
        switch Prefs.updateMode {
        case .auto:
            if rel.canAutoInstall { updater.install(rel) }
        case .ask:
            updatePanel.show()
        case .notify:
            break
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if let a = updater.available {
            menu.addItem(item(L("⬆︎ Có bản mới \(a.version), cập nhật…", "⬆︎ RinDock \(a.version) is available, update…"), #selector(openUpdate)))
            menu.addItem(.separator())
        }

        if AXIsProcessTrusted() {
            menu.addItem(label(Prefs.enabled ? L("RinDock đang chạy", "RinDock is running") : L("RinDock đang tắt", "RinDock is off")))
        } else {
            menu.addItem(item(L("⚠️ Cần cấp quyền Accessibility…", "⚠️ Accessibility permission needed…"), #selector(openOnboarding)))
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

        let whenItem = NSMenuItem(title: L("Khi có bản mới", "When an update is available"), action: nil, keyEquivalent: "")
        let whenMenu = NSMenu()
        for m in UpdateMode.allCases {
            let it = item(m.title, #selector(chooseUpdateMode(_:)))
            it.representedObject = m.rawValue
            it.state = Prefs.updateMode == m ? .on : .off
            whenMenu.addItem(it)
        }
        whenItem.submenu = whenMenu
        menu.addItem(whenItem)
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
        menu.addItem(item(L("Giao diện kính…", "Glass Appearance…"), #selector(openAppearance)))
        menu.addItem(.separator())

        menu.addItem(item(L("Giới thiệu RinDock", "About RinDock"), #selector(openAbout)))
        menu.addItem(item(L("Hướng dẫn sử dụng", "Getting Started"), #selector(openOnboarding)))
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

    @objc private func chooseUpdateMode(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let m = UpdateMode(rawValue: raw) {
            Prefs.updateMode = m
        }
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
        for panel in [supportPanel, aboutPanel, bugPanel, updatePanel, appearancePanel, onboardingPanel] {
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
