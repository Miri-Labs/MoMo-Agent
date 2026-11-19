import SwiftUI
import MoMoAgentClient
#if os(iOS)
import UIKit
typealias PlatformIllustrationImage = UIImage
#else
import AppKit
typealias PlatformIllustrationImage = NSImage
#endif

final class LifeIllustrationImageCache: @unchecked Sendable {
    static let shared = LifeIllustrationImageCache()
    private let cache: NSCache<NSURL, PlatformIllustrationImage> = {
        let store = NSCache<NSURL, PlatformIllustrationImage>()
        store.countLimit = 96
        store.totalCostLimit = 96 * 1024 * 1024
        return store
    }()

    func cached(_ url: URL) -> PlatformIllustrationImage? {
        cache.object(forKey: url as NSURL)
    }

    func swiftUIImage(_ url: URL) -> Image? {
        guard let img = cached(url) else { return nil }
        #if os(iOS)
        return Image(uiImage: img)
        #else
        return Image(nsImage: img)
        #endif
    }

    func load(_ url: URL) async -> PlatformIllustrationImage? {
        if let hit = cached(url) { return hit }
        let decoded: PlatformIllustrationImage? = await Task.detached(priority: .userInitiated) {
            #if os(iOS)
            guard let raw = UIImage(contentsOfFile: url.path) else { return nil }
            return await raw.byPreparingForDisplay() ?? raw
            #else
            guard let data = try? Data(contentsOf: url), let raw = NSImage(data: data) else { return nil }
            return raw
            #endif
        }.value
        if let decoded {
            #if os(iOS)
            let cost = Int(decoded.size.width * decoded.size.height * decoded.scale * decoded.scale * 4)
            #else
            let cost = Int(decoded.size.width * decoded.size.height * 4)
            #endif
            cache.setObject(decoded, forKey: url as NSURL, cost: max(1, cost))
        }
        return decoded
    }

    #if os(macOS)
    private let artworkCache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 24
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

    /// Frame transparent artwork for display; the original remains untouched for sharing.
    func loadArtwork(_ url: URL) async -> NSImage? {
        if let cached = artworkCache.object(forKey: url as NSURL) { return cached }
        guard let original = await load(url) else { return nil }
        let framed = await Task.detached(priority: .userInitiated) {
            guard let image = original.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  image.alphaInfo != .none, image.alphaInfo != .noneSkipFirst,
                  image.alphaInfo != .noneSkipLast else { return original }
            let width = image.width, height = image.height
            var rgba = [UInt8](repeating: 0, count: width * height * 4)
            let bounds: CGRect? = rgba.withUnsafeMutableBytes { bytes in
                guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                let pixels = bytes.bindMemory(to: UInt8.self)
                var left = width, top = height, right = -1, bottom = -1
                for y in 0..<height {
                    for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 0 {
                        left = min(left, x); right = max(right, x)
                        top = min(top, y); bottom = max(bottom, y)
                    }
                }
                guard right >= left, bottom >= top else { return nil }
                let padding = CGFloat(max(right - left + 1, bottom - top + 1)) * 0.04
                return CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
                    .insetBy(dx: -padding, dy: -padding)
                    .intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
            }
            guard let bounds, let cropped = image.cropping(to: bounds) else { return original }
            return NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
        }.value
        artworkCache.setObject(framed, forKey: url as NSURL, cost: Int(framed.size.width * framed.size.height * 4))
        return framed
    }
    #endif
}

extension LifeIllustration {
    var caption: String {
        let zone = TimeZone(identifier: timezone) ?? .current
        var clock = Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
        clock.timeZone = zone
        let range = Date(timeIntervalSince1970: windowStart).formatted(clock)
            + "–" + Date(timeIntervalSince1970: windowEnd).formatted(clock)
        return place.flatMap { $0.isEmpty ? nil : range + " · " + $0 } ?? range
    }

    var dateCaption: String { primaryDay + " · " + caption + (crossesMidnight ? " · " + String(localized: "跨午夜") : "") }
}

struct LifeIllustrationImageView: View {
    let url: URL
    var contentMode: ContentMode = .fit
    @State private var loaded: Image?
    @State private var loadedURL: URL?

    private var currentImage: Image? {
        if loadedURL == url, let loaded { return loaded }
        return LifeIllustrationImageCache.shared.swiftUIImage(url)
    }

    var body: some View {
        Color.clear.aspectRatio(1, contentMode: .fit)
            .overlay {
                if let img = currentImage {
                    img.resizable().aspectRatio(contentMode: contentMode)
                }
            }
            .clipped()
            .task(id: url) {
                if let hit = LifeIllustrationImageCache.shared.swiftUIImage(url) {
                    loadedURL = url
                    loaded = hit
                    return
                }
                guard let platform = await LifeIllustrationImageCache.shared.load(url), !Task.isCancelled else { return }
                loadedURL = url
                #if os(iOS)
                loaded = Image(uiImage: platform)
                #else
                loaded = Image(nsImage: platform)
                #endif
            }
    }
}

struct LifeIllustrationPlate: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(LifeIllustrationPaper.fill(for: colorScheme))
            .clipShape(Rectangle())
            .overlay {
                ZStack {
                    Rectangle().strokeBorder(MoMoPalette.line, lineWidth: 0.6)
                    Rectangle().inset(by: 5).strokeBorder(MoMoPalette.line.opacity(0.65), lineWidth: 0.5)
                }
                .allowsHitTesting(false)
            }
    }
}

struct LifeIllustrationMetadata: View {
    let illustration: LifeIllustration
    let position: Int
    let count: Int

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 9) {
                Text(illustration.primaryDay)
                    .font(.system(.caption2, design: .monospaced))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(MoMoPalette.surface, in: Capsule())
                    .accessibilityHidden(true)
                Text(illustration.caption).font(.system(.caption, design: .monospaced))
                    .accessibilityLabel(illustration.dateCaption)
                    .accessibilityIdentifier("lifeIllustration.viewer.caption")
            }
            Spacer(minLength: 0)
            if count > 1 {
                Text(String(format: "%02d / %02d", position, count))
                    .font(.system(.caption2, design: .monospaced))
                    .contentTransition(.numericText())
                    .fixedSize()
                    .accessibilityIdentifier("lifeIllustration.viewer.page")
            }
        }
        .foregroundStyle(MoMoPalette.muted)
    }
}

extension LifeIllustrationStore {
    var settingsRowStatus: String {
        if settings.supported { return String(localized: "Codex 订阅可用") }
        if settings.provider == "anthropic" { return String(localized: "Claude 订阅暂不支持") }
        if !isConfigured { return String(localized: "连接 Mac 后可用") }
        if !hasLoadedSettings { return isRefreshing ? String(localized: "正在同步…") : String(localized: "连接 Mac 后同步") }
        if settings.serviceStatus == "unavailable" { return String(localized: "暂不可用") }
        return String(localized: "需要 Codex 订阅")
    }

    var settingsDetailStatus: String {
        if settings.supported { return String(localized: "Codex 订阅可用") }
        if settings.provider == "anthropic" {
            return String(localized: "Claude 订阅暂不支持，切换为 Codex 订阅后可用。")
        }
        if !isConfigured { return String(localized: "连接 Mac 后可用") }
        if !hasLoadedSettings { return isRefreshing ? String(localized: "正在同步…") : String(localized: "连接 Mac 后同步") }
        if settings.serviceStatus == "unavailable" { return String(localized: "暂不可用") }
        return String(localized: "登录 Codex 订阅后可用。")
    }
}

struct LifeIllustrationSettingsControls: View {
    let store: LifeIllustrationStore
    @State private var saving = false
    @State private var failure: String?

    var body: some View {
        Toggle("生活插画", isOn: Binding(get: { store.settings.enabled }, set: {
            save(enabled: $0, interval: store.settings.intervalHours)
        }))
        .disabled(!store.settings.supported || saving)
        .accessibilityIdentifier("lifeIllustration.settings.enabled")
        Text("对话结束约 10 分钟、转录完成后自动生成。已保存的插画会保留。")
            .font(.footnote).foregroundStyle(.secondary)
        Text(store.settingsDetailStatus).font(.footnote).foregroundStyle(.secondary)
            .accessibilityIdentifier("lifeIllustration.settings.subscription")
            .task { await store.refresh() }
        if store.settings.pendingCount > 0 {
            Text("后台排队待生成：\(store.settings.pendingCount) 张")
                .font(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier("lifeIllustration.settings.pendingCount")
        }
        if store.settings.retryableCount > 0 {
            HStack {
                Text("未完成的历史时段：\(store.settings.retryableCount) 张")
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button("重新入队生成") { retry() }
                    .font(.footnote)
                    .disabled(!store.settings.supported || !store.settings.enabled || saving)
                    .accessibilityIdentifier("lifeIllustration.settings.retry")
            }
        }
        if let failure = failure ?? store.error {
            Text(failure).font(.footnote).foregroundStyle(MoMoPalette.failure)
        }
    }

    private func save(enabled: Bool, interval: Int) {
        saving = true
        Task {
            defer { saving = false }
            do { try await store.updateSettings(enabled: enabled, intervalHours: interval); failure = nil }
            catch { failure = error.localizedDescription }
        }
    }

    private func retry() {
        saving = true
        Task {
            defer { saving = false }
            do { try await store.retryIncomplete(); failure = nil }
            catch { failure = error.localizedDescription }
        }
    }
}

struct LifeIllustrationSettingsView: View {
    let store: LifeIllustrationStore
    var body: some View {
        Form { Section { LifeIllustrationSettingsControls(store: store) } }
            .navigationTitle("生活插画")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
    }
}

#if os(iOS)
struct LifeIllustrationViewer: View {
    let store: LifeIllustrationStore
    let initialID: String
    var referenceDay: String? = nil
    let showSource: (LifeIllustration) -> Void
    @State private var selection: String
    @State private var zoomed = false
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    init(store: LifeIllustrationStore, initialID: String, referenceDay: String? = nil, showSource: @escaping (LifeIllustration) -> Void) {
        self.store = store
        self.initialID = initialID
        self.referenceDay = referenceDay
        self.showSource = showSource
        _selection = State(initialValue: initialID)
    }

    private var items: [LifeIllustration] {
        let day = referenceDay ?? store.items.first { $0.id == initialID }?.primaryDay
        return store.items.filter { $0.belongs(to: day ?? "") && store.imageURL(for: $0, thumbnail: false) != nil }
            .sorted { $0.windowStart < $1.windowStart }
    }
    private var selected: LifeIllustration? { items.first { $0.id == selection } }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let side = max(0, min(geometry.size.width - 48, geometry.size.height * 0.50))
                ScrollView {
                    VStack(spacing: 14) {
                        if let selected {
                            LifeIllustrationMetadata(
                                illustration: selected,
                                position: (items.firstIndex(where: { $0.id == selection }) ?? 0) + 1,
                                count: items.count
                            )
                            .frame(width: side)
                            .animation(.snappy(duration: 0.2), value: selection)
                        }
                        TabView(selection: $selection) {
                            ForEach(items) { item in
                                Group {
                                    if let url = store.imageURL(for: item, thumbnail: false) {
                                        LifeIllustrationZoomView(
                                            url: url,
                                            isSelected: selection == item.id,
                                            zoomed: Binding(
                                                get: { selection == item.id && zoomed },
                                                set: { if selection == item.id { zoomed = $0 } }
                                            )
                                        )
                                        .frame(width: side, height: side)
                                        .modifier(LifeIllustrationPlate())
                                    }
                                }
                                .tag(item.id)
                                .contextMenu {
                                    Button("查看依据", systemImage: "text.alignleft") { dismiss(); showSource(item) }
                                    Button("删除", systemImage: "trash", role: .destructive) {
                                        Task {
                                            do { try await store.delete(item); if items.isEmpty { dismiss() } }
                                            catch { failure = error.localizedDescription }
                                        }
                                    }
                                }
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .never))
                        .frame(height: side)
                        .accessibilityIdentifier("lifeIllustration.viewer.image")

                        if items.count > 1 {
                            stickerSwitcherBar(width: side)
                        }

                        if let selected {
                            let index = items.firstIndex { $0.id == selected.id } ?? 0
                            LifeIllustrationDetailView(illustration: selected, previous: index > 0 ? items[index - 1] : nil) {
                                dismiss(); showSource(selected)
                            }
                            .padding(.horizontal, 24)
                            .animation(.snappy(duration: 0.2), value: selection)
                        }
                    }
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
                }
                .background {
                    VerticalPullDismissInstaller(enabled: !zoomed) { dismiss() }
                }
            }
            .background(MoMoPalette.canvas)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
                        .accessibilityIdentifier("lifeIllustration.viewer.close")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let selected, let url = store.imageURL(for: selected, thumbnail: false) {
                        ShareLink(item: url) { Label("分享", systemImage: "square.and.arrow.up") }.labelStyle(.iconOnly)
                            .accessibilityIdentifier("lifeIllustration.viewer.share")
                    }
                }
            }
        }
        .task(id: items.map(\.id)) {
            // Pre-decode all full-size stickers of this day off the main thread so swiping is 120Hz-smooth.
            for item in items {
                if Task.isCancelled { return }
                if let url = store.imageURL(for: item, thumbnail: false) {
                    _ = await LifeIllustrationImageCache.shared.load(url)
                }
            }
        }
        .onChange(of: selection) { zoomed = false }
        .onChange(of: items.map(\.id)) { _, ids in
            if ids.isEmpty { dismiss() }
            else if !ids.contains(selection), let first = ids.first { selection = first }
        }
        .alert("操作未完成", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("好", role: .cancel) { failure = nil }
        } message: { Text(failure ?? "") }
    }

    private func stickerSwitcherBar(width: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(items) { item in
                        let active = item.id == selection
                        Button {
                            withAnimation(.snappy(duration: 0.22)) {
                                selection = item.id
                            }
                        } label: {
                            if let thumb = store.imageURL(for: item) {
                                LifeIllustrationImageView(url: thumb)
                                    .frame(width: 40, height: 40)
                                    .padding(4)
                                    .background(LifeIllustrationPaper.fill(for: colorScheme), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .strokeBorder(
                                                active ? MoMoPalette.ink.opacity(0.65) : MoMoPalette.line,
                                                lineWidth: active ? 1.2 : 0.6
                                            )
                                    }
                                    .scaleEffect(active ? 1.0 : 0.94)
                                    .opacity(active ? 1.0 : 0.68)
                            }
                        }
                        .buttonStyle(.plain)
                        .id(item.id)
                        .accessibilityLabel(item.dateCaption)
                        .accessibilityIdentifier("lifeIllustration.viewer.thumb.\(item.id)")
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
            .frame(width: width)
            .onChange(of: selection) { _, newID in
                withAnimation(.snappy(duration: 0.22)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
        }
    }
}

// Strictly vertical downward pan recognizer so horizontal TabView swipes never contend with SwiftUI DragGesture.
private struct VerticalPullDismissInstaller: UIViewRepresentable {
    let enabled: Bool
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(enabled: enabled, onDismiss: onDismiss) }

    func makeUIView(context: Context) -> PassthroughInstallerView {
        let view = PassthroughInstallerView()
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: PassthroughInstallerView, context: Context) {
        context.coordinator.enabled = enabled
        context.coordinator.onDismiss = onDismiss
        uiView.attachIfNeeded()
    }

    final class PassthroughInstallerView: UIView {
        weak var coordinator: Coordinator?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            attachIfNeeded()
        }
        func attachIfNeeded() {
            guard let coordinator, let host = superview?.superview else { return }
            if coordinator.recognizer.view !== host {
                coordinator.recognizer.view?.removeGestureRecognizer(coordinator.recognizer)
                host.addGestureRecognizer(coordinator.recognizer)
            }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var enabled: Bool
        var onDismiss: () -> Void
        lazy var recognizer: UIPanGestureRecognizer = {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
            pan.cancelsTouchesInView = false
            pan.delegate = self
            return pan
        }()

        init(enabled: Bool, onDismiss: @escaping () -> Void) {
            self.enabled = enabled
            self.onDismiss = onDismiss
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard enabled, let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let v = pan.velocity(in: pan.view)
            return v.y > 0 && abs(v.y) > abs(v.x) * 1.6
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        @objc private func handle(_ pan: UIPanGestureRecognizer) {
            guard enabled, pan.state == .ended else { return }
            let t = pan.translation(in: pan.view)
            if t.y > 95 && abs(t.y) > abs(t.x) * 1.5 {
                onDismiss()
            }
        }
    }
}

// UIScrollView keeps pinch zoom and image panning native, without tearing down pages during horizontal swipes.
struct LifeIllustrationZoomView: UIViewRepresentable {
    let url: URL
    var isSelected: Bool = true
    @Binding var zoomed: Bool

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> ImageScrollView {
        let scroll = ImageScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 5
        scroll.panGestureRecognizer.isEnabled = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.imageView.contentMode = .scaleAspectFit
        scroll.addSubview(scroll.imageView)
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        context.coordinator.loadImage(into: scroll, url: url)
        return scroll
    }

    func updateUIView(_ scroll: ImageScrollView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.url != url {
            context.coordinator.url = url
            scroll.setZoomScale(1, animated: false)
            scroll.panGestureRecognizer.isEnabled = false
            context.coordinator.loadImage(into: scroll, url: url)
        } else if !isSelected, scroll.zoomScale > 1.001 {
            scroll.setZoomScale(1, animated: false)
            scroll.panGestureRecognizer.isEnabled = false
        }
    }

    final class ImageScrollView: UIScrollView {
        let imageView = UIImageView()
        override func layoutSubviews() {
            super.layoutSubviews()
            if zoomScale == 1 { imageView.frame = bounds; contentSize = bounds.size }
        }
    }

    @MainActor final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: LifeIllustrationZoomView
        var url: URL
        private var loadTask: Task<Void, Never>?

        init(parent: LifeIllustrationZoomView) { self.parent = parent; url = parent.url }

        func loadImage(into scroll: ImageScrollView, url: URL) {
            loadTask?.cancel()
            if let hit = LifeIllustrationImageCache.shared.cached(url) {
                scroll.imageView.image = hit
                return
            }
            loadTask = Task { [weak scroll] in
                guard let decoded = await LifeIllustrationImageCache.shared.load(url),
                      !Task.isCancelled, let scroll else { return }
                scroll.imageView.image = decoded
            }
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { (scrollView as? ImageScrollView)?.imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            let zoomed = scrollView.zoomScale > 1.01
            scrollView.panGestureRecognizer.isEnabled = zoomed
            parent.zoomed = zoomed
        }

        @objc func doubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scroll = gesture.view as? ImageScrollView else { return }
            if scroll.zoomScale > 1.01 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let center = gesture.location(in: scroll.imageView)
                let size = CGSize(width: scroll.bounds.width / 2.5, height: scroll.bounds.height / 2.5)
                scroll.zoom(to: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                                      width: size.width, height: size.height), animated: true)
            }
        }
    }
}
#elseif os(macOS)
struct LifeIllustrationViewer: View {
    let store: LifeIllustrationStore
    let initialID: String
    let referenceDay: String?
    var close: (() -> Void)?
    let showSource: (LifeIllustration) -> Void
    @State private var selection: String
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale

    init(store: LifeIllustrationStore, initialID: String, referenceDay: String? = nil,
         close: (() -> Void)? = nil, showSource: @escaping (LifeIllustration) -> Void) {
        self.store = store
        self.initialID = initialID
        self.referenceDay = referenceDay
        self.close = close
        self.showSource = showSource
        _selection = State(initialValue: initialID)
    }

    private var items: [LifeIllustration] {
        let day = referenceDay ?? store.items.first { $0.id == initialID }?.primaryDay
        return store.items.filter { $0.belongs(to: day ?? "") }.sorted { $0.windowStart < $1.windowStart }
    }

    private var selected: LifeIllustration? { items.first { $0.id == selection } ?? items.first }
    private var selectedIndex: Int { items.firstIndex { $0.id == selected?.id } ?? 0 }

    private var dayTitle: String {
        let day = referenceDay ?? selected?.primaryDay ?? ""
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let date = Calendar.current.date(from:
            DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)) else { return day }
        return date.formatted(.dateTime.locale(locale).month().day().weekday())
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button("返回", systemImage: "chevron.left", action: closeViewer)
                    .labelStyle(.iconOnly).keyboardShortcut(.cancelAction)
                    .help("返回").accessibilityIdentifier("lifeIllustration.viewer.close")
                Text(dayTitle).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(MoMoPalette.muted)
                Spacer(minLength: 8)
                if let selected {
                    if let url = store.imageURL(for: selected, thumbnail: false) {
                        ShareLink(item: url) { Label("分享", systemImage: "square.and.arrow.up") }
                            .labelStyle(.iconOnly).help("分享贴纸")
                            .accessibilityIdentifier("lifeIllustration.viewer.share")
                    }
                    Menu {
                        Button("删除", systemImage: "trash", role: .destructive) { delete(selected) }
                    } label: { Label("更多", systemImage: "ellipsis") }
                    .labelStyle(.iconOnly).menuIndicator(.hidden)
                    .accessibilityIdentifier("lifeIllustration.viewer.more")
                }
            }
            .buttonStyle(.borderless).controlSize(.regular)
            .padding(.horizontal, 24).frame(height: 52)

            if let selected {
                MacLifeIllustrationPage(illustration: selected, url: store.imageURL(for: selected, thumbnail: false)) {
                    closeViewer()
                    showSource(selected)
                }
            } else {
                ContentUnavailableView("暂无贴纸", systemImage: "photo")
            }

            if items.count > 1 { filmstrip }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LifeIllustrationPaper.fill(for: colorScheme))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lifeIllustration.viewer")
        .onChange(of: initialID) { _, id in selection = id }
        .onChange(of: items.map(\.id)) { _, ids in
            if ids.isEmpty { closeViewer() }
            else if !ids.contains(selection), let first = ids.first { selection = first }
        }
        .alert("操作未完成", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("好", role: .cancel) { failure = nil }
        } message: { Text(failure ?? "") }
    }

    private var filmstrip: some View {
        HStack(spacing: 12) {
            Button("上一幅", systemImage: "chevron.left") { move(-1) }
                .labelStyle(.iconOnly).disabled(selectedIndex == 0)
                .keyboardShortcut(.leftArrow, modifiers: [])
                .accessibilityIdentifier("lifeIllustration.viewer.previous")
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(items) { item in
                            Button { selection = item.id } label: {
                                Group {
                                    if let url = store.imageURL(for: item) {
                                        LifeIllustrationImageView(url: url)
                                    } else { Image(systemName: "photo").foregroundStyle(MoMoPalette.muted) }
                                }
                                .frame(width: 52, height: 52).padding(4)
                                .background(selected?.id == item.id ? MoMoPalette.paper : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 8))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8).strokeBorder(
                                        selected?.id == item.id ? MoMoPalette.muted : .clear, lineWidth: 1)
                                }
                            }
                            .buttonStyle(.plain).id(item.id)
                            .accessibilityLabel(item.dateCaption)
                            .accessibilityAddTraits(selected?.id == item.id ? [.isSelected] : [])
                            .accessibilityIdentifier("lifeIllustration.viewer.thumb.\(item.id)")
                        }
                    }.padding(2)
                }
                .onChange(of: selection, initial: true) { _, id in proxy.scrollTo(id, anchor: .center) }
            }
            .frame(maxWidth: CGFloat(items.count) * 68)
            Button("下一幅", systemImage: "chevron.right") { move(1) }
                .labelStyle(.iconOnly).disabled(selectedIndex == items.count - 1)
                .keyboardShortcut(.rightArrow, modifiers: [])
                .accessibilityIdentifier("lifeIllustration.viewer.next")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 24).padding(.bottom, 20).padding(.top, 8)
        .frame(maxWidth: 660)
    }

    private func move(_ delta: Int) {
        let index = selectedIndex + delta
        guard items.indices.contains(index) else { return }
        selection = items[index].id
    }

    private func closeViewer() {
        if let close { close() } else { dismiss() }
    }

    private func delete(_ item: LifeIllustration) {
        Task {
            do { try await store.delete(item) }
            catch { failure = error.localizedDescription }
        }
    }
}

struct MacLifeIllustrationPage: View {
    let illustration: LifeIllustration
    let url: URL?
    let showSource: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let available = CGSize(width: max(160, min(560, geometry.size.width - 48)),
                                   height: max(180, geometry.size.height - 200))
            ScrollView {
                VStack(spacing: 22) {
                    Group {
                        if let url {
                            LifeIllustrationZoomView(url: url, available: available)
                                .accessibilityLabel(illustration.summary ?? String(localized: "生活贴纸"))
                        } else {
                            ContentUnavailableView("图片暂不可用", systemImage: "photo")
                                .frame(width: available.width, height: available.height)
                        }
                    }
                    .accessibilityIdentifier("lifeIllustration.viewer.image")

                    VStack(spacing: 12) {
                        Text(illustration.caption).font(.system(.caption, design: .monospaced))
                            .foregroundStyle(MoMoPalette.muted)
                            .accessibilityIdentifier("lifeIllustration.viewer.caption")
                        if let summary = illustration.summary, !summary.isEmpty {
                            Text(summary).font(.system(size: 16)).lineSpacing(5)
                                .foregroundStyle(MoMoPalette.ink)
                                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("lifeIllustration.viewer.summary")
                        }
                        Button("查看转录", systemImage: "text.alignleft", action: showSource)
                            .buttonStyle(.borderless).font(.system(size: 12))
                            .padding(.top, 4)
                            .accessibilityIdentifier("lifeIllustration.viewer.source")
                    }
                    .frame(maxWidth: 440).padding(.horizontal, 24)
                }
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
    }
}

struct LifeIllustrationZoomView: View {
    let url: URL
    let available: CGSize
    @State private var image: NSImage?
    @State private var loadedURL: URL?
    @State private var failed = false

    var body: some View {
        Group {
            if loadedURL == url, let image {
                let scale = min(available.width / max(1, image.size.width), available.height / max(1, image.size.height))
                MacLifeIllustrationZoomSurface(image: image, url: url)
                    .frame(width: image.size.width * scale, height: image.size.height * scale)
            } else if failed {
                ContentUnavailableView("图片暂不可用", systemImage: "photo")
            } else { ProgressView().controlSize(.small) }
        }
        .task(id: url) {
            failed = false
            let decoded = await LifeIllustrationImageCache.shared.loadArtwork(url)
            guard !Task.isCancelled else { return }
            image = decoded
            loadedURL = url
            failed = decoded == nil
        }
    }
}

private struct MacLifeIllustrationZoomSurface: NSViewRepresentable {
    let image: NSImage
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ImageScrollView {
        let scroll = ImageScrollView()
        scroll.drawsBackground = false
        scroll.allowsMagnification = true
        scroll.minMagnification = 1
        scroll.maxMagnification = 5
        scroll.imageView.image = image
        scroll.imageView.imageScaling = .scaleProportionallyUpOrDown
        scroll.documentView = scroll.imageView
        let doubleClick = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleClick(_:)))
        doubleClick.numberOfClicksRequired = 2
        scroll.addGestureRecognizer(doubleClick)
        return scroll
    }

    func updateNSView(_ scroll: ImageScrollView, context: Context) {
        if context.coordinator.url != url {
            scroll.magnification = 1
            scroll.imageView.image = image
            context.coordinator.url = url
        }
    }

    final class ImageScrollView: NSScrollView {
        let imageView = NSImageView()
        override func layout() {
            super.layout()
            if magnification == 1 { imageView.frame = CGRect(origin: .zero, size: contentView.bounds.size) }
        }
    }

    @MainActor final class Coordinator: NSObject {
        var url: URL?
        @objc func doubleClick(_ gesture: NSClickGestureRecognizer) {
            guard let scroll = gesture.view as? ImageScrollView else { return }
            scroll.setMagnification(scroll.magnification > 1.01 ? 1 : 2.5, centeredAt: gesture.location(in: scroll.imageView))
        }
    }
}
#endif

struct LifeIllustrationDetailView: View {
    let illustration: LifeIllustration
    let previous: LifeIllustration?
    let showSource: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                if let place = illustration.place, !place.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(place).font(.headline).foregroundStyle(MoMoPalette.ink)
                        if illustration.placeStart != nil {
                            Text(illustration.stayCaption).font(.system(.caption, design: .monospaced))
                        }
                    }
                }
                if let previous, let departure = previous.placeEnd, let arrival = illustration.placeStart,
                   arrival >= departure, let place = previous.place, !place.isEmpty, place != illustration.place {
                    Text("\(place) \(previous.clock(departure)) → \(illustration.clock(arrival))")
                        .font(.system(.caption, design: .monospaced)).fixedSize(horizontal: false, vertical: true)
                }
            }
            .foregroundStyle(MoMoPalette.muted)
            if let summary = illustration.summary, !summary.isEmpty {
                Text(summary).font(.system(size: 14)).lineSpacing(5)
                    .foregroundStyle(MoMoPalette.ink).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("lifeIllustration.viewer.summary")
            }
            Button("查看转录", systemImage: "text.alignleft", action: showSource)
                .font(.caption).foregroundStyle(MoMoPalette.ink)
                .frame(minHeight: 44).buttonStyle(.plain)
                .accessibilityIdentifier("lifeIllustration.viewer.source")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lifeIllustration.viewer.detail")
    }
}
