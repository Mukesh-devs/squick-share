import AppKit
import QuickShareCore
import SwiftUI
import UniformTypeIdentifiers

/// The main window: a sidebar (Send, Receive, History, Settings and a "This Mac" card) next to the
/// chosen page, under a native toolbar whose items follow the page (see WindowCoordinator).
///
/// A plain sidebar next to the page, rather than NavigationSplitView: the window keeps one fixed
/// layout and never resizes itself, which keeps it clear of the SwiftUI window-resizing loops seen on
/// macOS 26 (see WindowCoordinator).
struct MainWindowView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @State private var dropTargeted = false

    var body: some View {
        // The title bar is transparent and the window content runs under it: backgrounds fill that
        // strip, so the sidebar reaches the top under the window buttons, while the content itself
        // stays in the safe area below the toolbar.
        HStack(spacing: 0) {
            Sidebar()
                .frame(width: 220)
                // The welcome sheet hangs off the sidebar, the text sheet off the page: one sheet per view.
                .sheet(isPresented: welcomeShown) {
                    WelcomeSheet().environmentObject(model).environmentObject(settings)
                }
            Rectangle()
                .fill(Theme.separator)
                .frame(width: 1)
                .ignoresSafeArea()
            ContentPane()
                .environment(\.windowDropTargeted, dropTargeted)
                .sheet(isPresented: $model.isComposingText) {
                    ComposeTextSheet().environmentObject(model)
                }
        }
        .frame(minWidth: 760, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
        // Files dropped anywhere in the window go to the send list.
        .onDrop(of: DropLoader.types, isTargeted: $dropTargeted) { providers in
            DropLoader.load(providers) { files, texts in
                if !files.isEmpty { model.addSendFiles(files) }
                texts.forEach { model.addSendText($0) }
                if model.section != .send { model.section = .send }
            }
        }
        .overlay {
            if dropTargeted, model.section != .send {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(6)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
    }

    /// Shown once, the first time the window opens.
    private var welcomeShown: Binding<Bool> {
        Binding(get: { !settings.hasSeenWelcome },
                set: { shown in if !shown, !settings.hasSeenWelcome { settings.hasSeenWelcome = true } })
    }
}

// MARK: - Theme

/// The window's colours, in light and dark mode.
enum Theme {
    /// Set while rendering snapshots: the sidebar is drawn in a solid colour (the translucent material
    /// has nothing behind it) and pages are drawn without their scroll view, which a window snapshot
    /// can't capture. Both look the same as the live window scrolled to the top.
    @MainActor static var snapshotMode = false

    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
    }

    static let page = dynamic(light: rgb(245, 245, 247), dark: rgb(30, 30, 32))
    static let card = dynamic(light: .white, dark: rgb(42, 42, 45))
    static let cardBorder = dynamic(light: rgb(0, 0, 0, 0.06), dark: rgb(255, 255, 255, 0.08))
    static let separator = dynamic(light: rgb(0, 0, 0, 0.09), dark: rgb(0, 0, 0, 0.5))
    static let toolbar = dynamic(light: rgb(251, 251, 253, 0.96), dark: rgb(38, 38, 41, 0.96))
    static let sidebarSolid = dynamic(light: rgb(233, 233, 238), dark: rgb(40, 40, 43))
    static let neutralCircle = dynamic(light: rgb(242, 244, 248), dark: rgb(58, 58, 62))
    static let neutralRing = dynamic(light: rgb(0, 0, 0, 0.06), dark: rgb(255, 255, 255, 0.08))
    static let fill = dynamic(light: rgb(0, 0, 0, 0.06), dark: rgb(255, 255, 255, 0.10))
    static let rowSelection = dynamic(light: rgb(0, 116, 240, 0.10), dark: rgb(48, 150, 255, 0.20))
    static let accentSoft = dynamic(light: rgb(0, 116, 240, 0.12), dark: rgb(48, 150, 255, 0.20))
    static let successText = dynamic(light: rgb(31, 157, 85), dark: rgb(48, 209, 88))
    static let warningText = dynamic(light: rgb(201, 100, 0), dark: rgb(255, 159, 10))
    static let failureText = dynamic(light: rgb(215, 0, 21), dark: rgb(255, 105, 97))

    static let brandTop = Color(red: 28 / 255, green: 160 / 255, blue: 1)
    static let brandMid = Color(red: 10 / 255, green: 116 / 255, blue: 245 / 255)
    static let brandBottom = Color(red: 0, green: 82 / 255, blue: 224 / 255)
    static let success = Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255)

    /// The app icon's blue.
    static var brand: LinearGradient {
        LinearGradient(colors: [brandTop, brandMid, brandBottom], startPoint: UnitPoint(x: 0.25, y: 0), endPoint: UnitPoint(x: 0.75, y: 1))
    }

    /// The gradient behind a coloured settings or welcome icon square.
    static func tile(_ top: Color, _ bottom: Color) -> LinearGradient {
        LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    }
}

/// Whether files are being dragged over the window (the Send page highlights its drop area).
private struct WindowDropTargetedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var windowDropTargeted: Bool {
        get { self[WindowDropTargetedKey.self] }
        set { self[WindowDropTargetedKey.self] = newValue }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            SidebarHeading(title: "Share")
            SidebarRow(section: .send)
            SidebarRow(section: .receive)
            SidebarHeading(title: "Library").padding(.top, 10)
            SidebarRow(section: .history)
            Spacer(minLength: 12)
            SidebarRow(section: .settings)
            ThisMacCard().padding(.top, 8)
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(SidebarBackground().ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sidebar")
    }
}

private struct SidebarHeading: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct SidebarRow: View {
    @EnvironmentObject private var model: AppModel
    let section: MainSection
    @State private var hovering = false

    var body: some View {
        let selected = model.section == section
        let badge = model.badge(for: section)
        Button { if model.section != section { model.section = section } } label: {
            HStack(spacing: 9) {
                Image(systemName: section.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(selected ? Color.white : Color.accentColor)
                    .frame(width: 20)
                Text(section.title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(selected ? Color.white : Color.primary)
                Spacer(minLength: 4)
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(selected ? Color.white : Color.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(selected ? Color.white.opacity(0.25) : Theme.fill))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.accentColor : (hovering ? Theme.fill : Color.clear))
                    .shadow(color: selected ? Color.accentColor.opacity(0.3) : .clear, radius: 4, y: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(section.title)
        .accessibilityValue(badge > 0 ? "\(badge)" : "")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityHint(section == .receive && !model.pendingRequests.isEmpty ? "A request is waiting" : "")
    }
}

/// This Mac's name and whether it can be found. Clicking it opens Receive.
private struct ThisMacCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Button { model.section = .receive } label: {
            HStack(spacing: 10) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.brand))
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.identity.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Circle().fill(model.statusColor).frame(width: 7, height: 7)
                        Text(model.cardStatus)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .card(cornerRadius: 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Who can see this Mac")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("This Mac, \(model.identity.name). \(model.statusLine)")
        .accessibilityAddTraits(.isButton)
    }
}

/// The translucent sidebar material Finder and System Settings use.
private struct SidebarBackground: View {
    var body: some View {
        if Theme.snapshotMode {
            Theme.sidebarSolid
        } else {
            SidebarMaterial()
        }
    }
}

private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

extension AppModel {
    /// Under the Mac's name in the sidebar: "Visible to everyone", "Hidden", "Visible for 9:41".
    var cardStatus: String {
        if localNetworkDenied { return "Local network access is off" }
        if !hasNetwork { return "No network" }
        if case .failed = receiverStatus { return "Can't be discovered" }
        switch settings.visibility {
        case .everyone: return "Visible to everyone"
        case .hidden: return "Hidden"
        case .temporary: return "Visible for \(Format.countdown((settings.temporaryVisibilityUntil ?? now).timeIntervalSince(now)))"
        }
    }

    /// Whether `StatusBanners` has something to show.
    var hasStatusBanner: Bool {
        if case .failed = receiverStatus { return true }
        return localNetworkDenied || !hasNetwork || notice != nil || receivedText != nil
    }
}

// MARK: - Content pane

/// The page, with a bar behind the toolbar items.
private struct ContentPane: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Theme.page.ignoresSafeArea()
                page
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The toolbar area: a light bar, without a line under it.
                Theme.toolbar
                .frame(height: geometry.safeAreaInsets.top)
                .offset(y: -geometry.safeAreaInsets.top)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder private var page: some View {
        switch model.section {
        case .send: SendPage()
        case .receive: ReceivePage()
        case .history: HistoryPage()
        case .settings: SettingsPage()
        }
    }
}

// MARK: - Page building blocks

/// A scrolling page with standard margins.
struct PageScroll<Content: View>: View {
    var spacing: CGFloat = 16
    @ViewBuilder let content: () -> Content

    var body: some View {
        if Theme.snapshotMode {
            stack
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .clipped()
        } else {
            ScrollView { stack }
        }
    }

    private var stack: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content()
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A page's large title and a line about what it is for.
struct PageTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 28, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(.system(size: 13.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 2)
    }
}

/// A section title, with an optional link on the right.
struct SectionHeader: View {
    let title: String
    var linkTitle: String? = nil
    var link: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 17, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let linkTitle, let link {
                Button(linkTitle, action: link)
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.top, 6)
        .padding(.horizontal, 2)
    }
}

/// A white (dark grey in dark mode) rounded card with a hairline and a soft shadow.
struct CardBackground: ViewModifier {
    var cornerRadius: CGFloat = 14
    var highlighted = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Theme.card)
                    .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(highlighted ? Color.accentColor.opacity(0.35) : Theme.cardBorder,
                                  lineWidth: highlighted ? 1.5 : 1)
            }
    }
}

extension View {
    func card(cornerRadius: CGFloat = 14, highlighted: Bool = false) -> some View {
        modifier(CardBackground(cornerRadius: cornerRadius, highlighted: highlighted))
    }
}

/// The blue card at the top of Send and Receive, in the app icon's colours.
struct HeroCard<Content: View>: View {
    var dashed = false
    var lifted = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .foregroundStyle(.white)
            .padding(.horizontal, 26)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                // The gradient takes the card's size; the rings are drawn over it and clipped to it,
                // so they never make the background bigger than the card.
                Theme.brand
                    .overlay {
                        ZStack {
                            // Two faint rings, like ripples.
                            Circle()
                                .strokeBorder(Color.white.opacity(0.13), lineWidth: 1)
                                .frame(width: 420, height: 420)
                                .offset(x: 260)
                            Circle()
                                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                                .frame(width: 560, height: 560)
                                .offset(x: 330)
                        }
                        .allowsHitTesting(false)
                    }
                    .overlay { if lifted { Color.white.opacity(0.10) } }
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: Theme.brandBottom.opacity(0.28), radius: 12, y: 6)
            }
            .overlay {
                if dashed {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(lifted ? 0.95 : 0.65),
                                      style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                        .padding(8)
                }
            }
    }
}

/// The frosted square holding the hero card's symbol.
struct HeroIcon: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 28, weight: .regular))
            .foregroundStyle(.white)
            .frame(width: 72, height: 72)
            .background(RoundedRectangle(cornerRadius: 17, style: .continuous).fill(Color.white.opacity(0.2)))
            .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
            .accessibilityHidden(true)
    }
}

// MARK: - Buttons

/// Buttons drawn by the app, so they look the same in active and inactive windows (the system's
/// prominent style turns white-on-white when the window isn't key).
struct PillButtonStyle: ButtonStyle {
    enum Kind {
        /// Blue, the main action.
        case primary
        /// White with a hairline.
        case secondary
        /// Grey fill.
        case gray
        /// Translucent white, on the blue hero card.
        case glass
    }

    var kind: Kind = .secondary
    var large = false
    /// Rounded rectangle instead of a capsule.
    var rounded = false
    /// Fill the width offered instead of hugging the label.
    var stretch = false

    func makeBody(configuration: Configuration) -> some View {
        PillButton(configuration: configuration, style: self)
    }
}

private struct PillButton: View {
    let configuration: ButtonStyleConfiguration
    let style: PillButtonStyle
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.rounded ? 8 : 100, style: .continuous)
        label
            .font(.system(size: style.large ? 13.5 : 12.5, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, style.large ? 18 : 12)
            .frame(maxWidth: style.stretch ? .infinity : nil)
            .frame(height: style.large ? 34 : 28)
            .foregroundStyle(foreground)
            .background(shape.fill(background))
            .overlay(shape.strokeBorder(border, lineWidth: style.kind == .glass ? 1 : 0.5))
            .shadow(color: shadow, radius: style.kind == .primary ? 4 : 1.5, y: style.kind == .primary ? 2 : 0.5)
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovering = $0 }
    }

    @ViewBuilder private var label: some View {
        if style.stretch {
            configuration.label
        } else {
            configuration.label.fixedSize()
        }
    }

    private var pressed: Bool { configuration.isPressed }

    private var foreground: Color {
        switch style.kind {
        case .primary, .glass: return .white
        case .secondary, .gray: return .primary
        }
    }

    private var background: Color {
        switch style.kind {
        case .primary: return Color.accentColor.opacity(pressed ? 0.8 : (hovering ? 0.92 : 1))
        case .secondary: return pressed ? Theme.fill : Theme.card
        case .gray: return pressed || hovering ? Color.primary.opacity(pressed ? 0.16 : 0.11) : Theme.fill
        case .glass: return Color.white.opacity(pressed ? 0.32 : (hovering ? 0.28 : 0.22))
        }
    }

    private var border: Color {
        switch style.kind {
        case .primary, .gray: return .clear
        case .secondary: return Color.primary.opacity(0.14)
        case .glass: return Color.white.opacity(0.35)
        }
    }

    private var shadow: Color {
        switch style.kind {
        case .primary: return Color.accentColor.opacity(0.3)
        case .secondary: return .black.opacity(0.06)
        case .gray, .glass: return .clear
        }
    }
}

/// A toolbar button: a symbol and a title on a pill (the main action in blue).
struct ToolbarPill: View {
    let title: String
    let symbol: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                Text(title)
            }
        }
        .buttonStyle(PillButtonStyle(kind: prominent ? .primary : .secondary))
        .padding(.horizontal, 2)
        .padding(.vertical, 4)
    }
}

/// All, Received, Sent: the History toolbar's filter.
struct HistoryFilterPicker: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Picker("Show", selection: $model.historyFilter) {
            Text("All").tag(AppModel.HistoryFilter.all)
            Text("Received").tag(AppModel.HistoryFilter.received)
            Text("Sent").tag(AppModel.HistoryFilter.sent)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .padding(.vertical, 4)
    }
}

// MARK: - Banners

/// Problems that stop discovery, and one-off notices.
struct StatusBanners: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.localNetworkDenied {
                Banner(symbol: "exclamationmark.triangle.fill", tint: .orange,
                       text: "Local network access is off, so SQuick Share can't find or be found by nearby devices.") {
                    Button("Open System Settings") { model.openLocalNetworkSettings() }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                }
            } else if !model.hasNetwork {
                Banner(symbol: "wifi.slash", tint: .orange,
                       text: "This Mac isn't connected to a network. Both devices must be on the same Wi-Fi network.") { EmptyView() }
            } else if case .failed(let message) = model.receiverStatus {
                Banner(symbol: "exclamationmark.triangle.fill", tint: .orange,
                       text: "This Mac can't be discovered right now (\(message)). SQuick Share keeps retrying.") { EmptyView() }
            }
            if let item = model.receivedText {
                Banner(symbol: item.webURL != nil ? "link" : "text.bubble", tint: .accentColor,
                       text: "\(item.deviceName) sent \(item.webURL != nil ? "a link" : "text"): \(String(item.text.prefix(300)))") {
                    HStack(spacing: 8) {
                        if item.webURL != nil {
                            Button("Open Link") { model.openReceivedText(item) }
                                .buttonStyle(PillButtonStyle(kind: .primary))
                        }
                        Button("Copy") { model.copyReceivedText(item) }
                            .buttonStyle(PillButtonStyle(kind: .secondary))
                        Button("Dismiss") { model.dismissReceivedText() }
                            .buttonStyle(PillButtonStyle(kind: .gray))
                    }
                }
            }
            if let notice = model.notice {
                Banner(symbol: "info.circle.fill", tint: .accentColor, text: notice) {
                    Button("OK") { model.notice = nil }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                }
            }
        }
    }
}

struct Banner<Actions: View>: View {
    let symbol: String
    let tint: Color
    let text: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(Circle().fill(tint.opacity(0.14)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                actions()
            }
            .padding(.top, 6)
            Spacer(minLength: 0)
        }
        .padding(12)
        .card(cornerRadius: 12)
        .accessibilityElement(children: .contain)
    }
}

/// A request waiting for an answer, shown on pages other than Receive so it is never missed.
struct RequestStrip: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 8) {
            ForEach(model.pendingRequests) { request in
                HStack(spacing: 12) {
                    DeviceGlyph(type: request.device.type, size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(request.device.name) wants to share").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text("\(request.offerSummary) · PIN \(request.pin)")
                            .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Button("Details") { model.section = .receive }
                        .buttonStyle(PillButtonStyle(kind: .gray))
                    Button("Decline") { model.decline(request) }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                    Button("Accept") { model.accept(request, trust: false) }
                        .buttonStyle(PillButtonStyle(kind: .primary))
                }
                .padding(12)
                .card(cornerRadius: 12, highlighted: true)
                .accessibilityElement(children: .contain)
            }
        }
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(Color.accentColor)
                .frame(width: 60, height: 60)
                .background(Circle().fill(Theme.neutralCircle))
                .accessibilityHidden(true)
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(message).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .card()
    }
}

// MARK: - Sheets

/// Shown the first time the window opens.
struct WelcomeSheet: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 88, height: 88)
                .accessibilityHidden(true)
            Text("Welcome to SQuick Share")
                .font(.system(size: 24, weight: .bold))
                .padding(.top, 8)
            Text("Quick Share for your Mac. Share with Android in a tap.")
                .font(.system(size: 13.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 14) {
                WelcomeFeature(symbol: "paperplane.fill", tint: Theme.tile(Theme.brandTop, Theme.brandBottom), title: "Send",
                               text: "Drop files on a nearby phone, tablet or PC.")
                WelcomeFeature(symbol: "arrow.down.to.line", tint: Theme.tile(Color(red: 0.2, green: 0.83, blue: 0.6), Color(red: 0.02, green: 0.59, blue: 0.41)),
                               title: "Receive", text: "Accept photos, videos and files from any Quick Share device.")
                WelcomeFeature(symbol: "lock.fill", tint: Theme.tile(Color(red: 0.65, green: 0.55, blue: 0.98), Color(red: 0.43, green: 0.16, blue: 0.85)),
                               title: "Private and local", text: "Everything stays on your Wi-Fi, encrypted between the two devices. No account.")
            }
            .padding(.top, 22)
            Text("macOS may ask for Local Network, Notifications and Bluetooth access.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 18)
            Button { settings.hasSeenWelcome = true } label: {
                Text("Continue")
            }
            .buttonStyle(PillButtonStyle(kind: .primary, large: true, rounded: true, stretch: true))
            .keyboardShortcut(.defaultAction)
            .padding(.top, 12)
        }
        .padding(.horizontal, 36)
        .padding(.top, 30)
        .padding(.bottom, 28)
        .frame(width: 480)
    }
}

private struct WelcomeFeature: View {
    let symbol: String
    let tint: LinearGradient
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Text(text).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Text or a link to send.
struct ComposeTextSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send Text or a Link").font(.system(size: 15, weight: .semibold))
            Text("It's added to the items to send. Then click a device.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body)
                .frame(height: 120)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.secondary.opacity(0.3)))
                .accessibilityLabel("Text or link to send")
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(PillButtonStyle(kind: .secondary, rounded: true))
                Button("Add") {
                    model.addSendText(text)
                    dismiss()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .help("Add (⌘↩)")
                .buttonStyle(PillButtonStyle(kind: .primary, rounded: true))
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

// MARK: - Drops

/// Loads dropped files, links and text.
enum DropLoader {
    static let types: [UTType] = [.fileURL, .url, .plainText]

    /// Calls `completion` once, on the main queue, with everything that could be loaded.
    @discardableResult
    static func load(_ providers: [NSItemProvider], completion: @escaping @MainActor ([URL], [String]) -> Void) -> Bool {
        let collected = Collected()
        let group = DispatchGroup()
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { collected.add(file: url) }
                    group.leave()
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                handled = true
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { collected.add(text: url.absoluteString) }
                    group.leave()
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                handled = true
                group.enter()
                _ = provider.loadObject(ofClass: String.self) { string, _ in
                    if let string { collected.add(text: string) }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            let (files, texts) = collected.values
            MainActor.assumeIsolated { completion(files, texts) }
        }
        return handled
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var files: [URL] = []
        private var texts: [String] = []

        func add(file: URL) { lock.lock(); files.append(file); lock.unlock() }
        func add(text: String) { lock.lock(); texts.append(text); lock.unlock() }
        var values: ([URL], [String]) { lock.lock(); defer { lock.unlock() }; return (files, texts) }
    }
}
