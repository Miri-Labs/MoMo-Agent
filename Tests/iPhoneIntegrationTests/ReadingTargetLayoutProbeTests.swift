import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import MoMoAgent

/// An isolated layout comparison, not recording/archive/playback acceptance.
@MainActor
final class ReadingTargetLayoutProbeTests: XCTestCase {
    func testFlatLazyStackRestoresSampledTargetOnce() async throws {
        try await probe(.flat, fixedTarget: false)
    }

    func testPinnedSectionRestoresSampledTargetOnce() async throws {
        try await probe(.pinnedSection, fixedTarget: false)
    }

    func testFlatLazyStackRestoresFixedDeepTargetOnce() async throws {
        try await probe(.flat, fixedTarget: true)
    }

    func testPinnedSectionRestoresFixedDeepTargetOnce() async throws {
        try await probe(.pinnedSection, fixedTarget: true)
    }

    func testFlatLazyStackRestoresAfterDocumentAdmissionOnce() async throws {
        try await probe(.flat, fixedTarget: true, deferredAdmission: true)
    }

    func testPinnedSectionRestoresAfterDocumentAdmissionOnce() async throws {
        try await probe(.pinnedSection, fixedTarget: true, deferredAdmission: true)
    }

    func testPinnedSectionRestoresAfterConditionalDocumentAdmissionOnce() async throws {
        try await probe(.pinnedSection, fixedTarget: true, deferredAdmission: true, conditionalParagraphs: true)
    }

    func testPinnedSectionRestoresAfterBottomBarAdmissionOnce() async throws {
        try await probe(.pinnedSection, fixedTarget: true, deferredAdmission: true, deferredFooter: true)
    }

    private func probe(_ layout: ProbeLayout, fixedTarget: Bool, deferredAdmission: Bool = false,
                       conditionalParagraphs: Bool = false, deferredFooter: Bool = false) async throws {
        let rows = (0..<20).map { index in
            ProbeRow(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!,
                text: "第\(index + 1)段。" + String(repeating: "这是用于长文阅读位置验证的合成文字，没有调用语音识别或外部模型。",
                                          count: 12 + index % 3))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let lifetime = ProbeLifetime()
        addTeardownBlock { @MainActor in
            let deadline = ContinuousClock.now + .seconds(10)
            while lifetime.controllers.contains(where: { $0.value != nil }), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(lifetime.controllers.allSatisfy { $0.value == nil }, "A destroyed probe still owns its hosting controller.")
        }
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        var trace = ["layout=\(layout.rawValue) mode=\(fixedTarget ? "fixed-index-13" : "native-2400-sampled") deferred-admission=\(deferredAdmission) conditional-rows=\(conditionalParagraphs) deferred-footer=\(deferredFooter) rows=20"]
        var frames: [UUID: CGRect] = [:]
        var visible: [UUID] = []
        var viewportHeight: CGFloat = 0
        var headerFrame: CGRect?
        var issueCount = 0
        var incarnation = 0
        var admission: ProbeAdmission?
        defer {
            let attachment = XCTAttachment(string: trace.joined(separator: "\n"))
            attachment.name = "reading-target-layout-probe-\(layout.rawValue)-\(fixedTarget ? "fixed" : "sampled")"
            attachment.lifetime = .keepAlways; add(attachment)
        }
        func show(target: UUID?, deferDocument: Bool = false) {
            incarnation += 1
            let current = incarnation
            let currentAdmission = ProbeAdmission(ready: !deferDocument)
            admission = currentAdmission
            frames = [:]; visible = []; viewportHeight = 0; headerFrame = nil; issueCount = 0
            let controller = UIHostingController(rootView: NavigationStack {
                ProbeAdmittedContainerView(rows: rows, layout: layout, restoreTarget: target,
                    admission: currentAdmission, conditionalParagraphs: conditionalParagraphs,
                    deferredFooter: deferredFooter) { [weak window] event in
                    guard current == incarnation else { return }
                    if event.kind == "viewport" { visible = event.visible; viewportHeight = event.viewportHeight }
                    if event.kind == "row", let id = event.id, let frame = event.frame { frames[id] = frame }
                    if event.kind == "disappear", let id = event.id { frames[id] = nil }
                    if event.kind == "header" { headerFrame = event.frame }
                    if event.kind == "issue" { issueCount += 1 }
                    if trace.count < 600 {
                        let scroll = window.flatMap { self.scrollView(in: $0) }
                        trace.append("view=\(current) event=\(event.kind) index=\(String(describing: event.id.flatMap { id in rows.firstIndex { $0.id == id } })) visible=\(visible.compactMap { id in rows.firstIndex { $0.id == id } }) frame=\(String(describing: event.frame)) V=\(viewportHeight) H=\(String(describing: event.headerHeight)) header=\(String(describing: headerFrame)) anchor=\(String(describing: event.anchor)) offset=\(String(describing: scroll?.contentOffset)) content=\(String(describing: scroll?.contentSize)) inset=\(String(describing: scroll?.adjustedContentInset))")
                    }
                }
            }.environment(\.dynamicTypeSize, .large))
            lifetime.controllers.append(WeakProbeController(controller))
            window.rootViewController = controller
            window.makeKeyAndVisible()
        }
        func readableHeight(_ frame: CGRect) -> CGFloat {
            let top: CGFloat
            if layout == .pinnedSection, let headerFrame, headerFrame.minY <= 0, headerFrame.maxY > 0 {
                top = min(viewportHeight, headerFrame.maxY)
            } else { top = 0 }
            return min(frame.maxY, viewportHeight) - max(frame.minY, top)
        }

        show(target: nil)
        try await wait(in: window, stage: "initial") {
            window.layoutIfNeeded()
            return self.scrollView(in: window) != nil && viewportHeight > 0 && frames[rows[0].id] != nil
        }
        let target: UUID
        if fixedTarget {
            // Keep this control independent of the native-2400 sampling path. Both
            // layouts recreate with exactly the same predetermined deep paragraph.
            target = rows[13].id
            trace.append("restore-target=\(target) fixed-index=13 sampling-not-required")
        } else {
            let initial = try XCTUnwrap(scrollView(in: window))
            initial.setContentOffset(CGPoint(x: 0, y: 2400), animated: false)
            try await wait(in: window, stage: "sample-readable") {
                window.layoutIfNeeded()
                guard let first = visible.first, let index = rows.firstIndex(where: { $0.id == first }),
                      let frame = frames[first] else { return false }
                return initial.contentOffset.y > 2000 && index > 2 && index < rows.count - 3 && readableHeight(frame) > 44
            }
            target = try XCTUnwrap(visible.first)
            trace.append("saved-sample=\(target) restore-target=\(target) fixed=false")
        }
        screenshot(window, name: "probe-\(layout.rawValue)-before-recreation")
        window.rootViewController = UIViewController()
        show(target: target, deferDocument: deferredAdmission)
        if deferredAdmission {
            try await wait(in: window, stage: "empty-before-document-admission") {
                window.layoutIfNeeded()
                return viewportHeight > 0 && frames.isEmpty && issueCount == 0
            }
            trace.append("admitting-document-after-empty-viewport")
            admission?.ready = true
        }
        var stableFrame: CGRect?
        var stableChecks = 0
        func restoredTargetIsStable() -> Bool {
            window.layoutIfNeeded()
            guard issueCount == 1, visible.first == target, let frame = frames[target], readableHeight(frame) > 44 else {
                stableFrame = nil; stableChecks = 0
                return false
            }
            if let previous = stableFrame, abs(previous.minX - frame.minX) <= 0.25,
               abs(previous.minY - frame.minY) <= 0.25, abs(previous.width - frame.width) <= 0.25,
               abs(previous.height - frame.height) <= 0.25 {
                stableChecks = min(3, stableChecks + 1)
            } else { stableFrame = frame; stableChecks = 1 }
            return stableChecks == 3
        }
        try await wait(in: window, stage: "restored-target", restoredTargetIsStable)
        trace.append("before-screenshot target=\(target) frame=\(String(describing: frames[target])) stable-checks=\(stableChecks)")
        screenshot(window, name: "probe-\(layout.rawValue)-after-restore")
        // drawHierarchy can flush a deferred native layout correction. The verified
        // result must come from the stable geometry after that flush, not its old frame.
        stableFrame = nil; stableChecks = 0
        try await wait(in: window, stage: "restored-target-after-screenshot", restoredTargetIsStable)
        XCTAssertEqual(issueCount, 1, "The probe must not retry scrollTo to make a layout pass.")
        XCTAssertEqual(visible.first, target)
        let restored = try XCTUnwrap(frames[target])
        XCTAssertGreaterThan(readableHeight(restored), 44)
        trace.append("verified-after-screenshot target=\(target) frame=\(restored) stable-checks=\(stableChecks) issued=\(issueCount)")
        window.rootViewController = nil
    }

    private func wait(in window: UIWindow, stage: String, _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let passed = condition()
        if !passed { screenshot(window, name: "probe-failed-\(stage)") }
        XCTAssertTrue(passed, "Actual native reading target did not settle: \(stage)")
        if !passed { throw ProbeFailure.unsettled(stage) }
    }

    private func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView, scroll.bounds.height > 200,
           scroll.contentSize.height > scroll.bounds.height * 3 { return scroll }
        for child in view.subviews { if let result = scrollView(in: child) { return result } }
        return nil
    }

    private func screenshot(_ window: UIWindow, name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private enum ProbeFailure: Error { case unsettled(String) }
    private final class WeakProbeController {
        weak var value: UIViewController?
        init(_ value: UIViewController) { self.value = value }
    }
    private final class ProbeLifetime { var controllers: [WeakProbeController] = [] }
}

@MainActor @Observable
private final class ProbeAdmission {
    var ready: Bool
    init(ready: Bool) { self.ready = ready }
}

private struct ProbeAdmittedContainerView: View {
    let rows: [ProbeRow]
    let layout: ProbeLayout
    let restoreTarget: UUID?
    let admission: ProbeAdmission
    let conditionalParagraphs: Bool
    let deferredFooter: Bool
    let observe: @MainActor (ProbeEvent) -> Void

    var body: some View {
        ReadingTargetProbeView(rows: admission.ready ? rows : [], layout: layout,
            restoreTarget: admission.ready ? restoreTarget : nil,
            conditionalParagraphs: conditionalParagraphs, deferredFooter: deferredFooter, observe: observe)
    }
}

private nonisolated enum ProbeLayout: String, Sendable { case flat, pinnedSection }
private nonisolated struct ProbeRow: Identifiable, Sendable { let id: UUID; let text: String }
private nonisolated struct ProbeEvent: Sendable {
    let kind: String
    var id: UUID? = nil
    var frame: CGRect? = nil
    var visible: [UUID] = []
    var viewportHeight: CGFloat = 0
    var headerHeight: CGFloat? = nil
    var anchor: UnitPoint? = nil
}

private struct ReadingTargetProbeView: View {
    let rows: [ProbeRow]
    let layout: ProbeLayout
    let restoreTarget: UUID?
    let conditionalParagraphs: Bool
    let deferredFooter: Bool
    let observe: @MainActor (ProbeEvent) -> Void
    @State private var position = ScrollPosition(idType: UUID.self)
    @State private var issued = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24, pinnedViews: layout == .pinnedSection ? [.sectionHeaders] : []) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("2026年10月16日").phoneText(.title)
                    Text("独立布局对照 · 合成长段落").phoneText(.history)
                }.padding(.bottom, 14)
                if layout == .pinnedSection {
                    Section { paragraphContent } header: { player.readingViewportHeader() }
                } else {
                    player
                    paragraphContent
                }
            }
            .scrollTargetLayout()
            .frame(maxWidth: .infinity, alignment: .leading).padding(24)
        }
        .coordinateSpace(name: "reading-target-probe")
        .scrollPosition($position, anchor: .top)
        .onReadingViewportChange(identity: restoreTarget, hasHeader: layout == .pinnedSection) { selection in
            observe(ProbeEvent(kind: "viewport", visible: rows.filter { selection.ids.contains($0.id) }.map(\.id),
                viewportHeight: selection.viewportHeight, headerHeight: selection.headerHeight))
            if let restoreTarget, !issued, let anchor = selection.restorationAnchor {
                issued = true
                observe(ProbeEvent(kind: "issue", id: restoreTarget, viewportHeight: selection.viewportHeight,
                    headerHeight: selection.headerHeight, anchor: anchor))
                position.scrollTo(id: restoreTarget, anchor: anchor)
            }
        }
        .navigationTitle("阅读目标对照").navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if !deferredFooter || !rows.isEmpty {
                Text("仅测试布局，不执行录音或模型请求").phoneText(.body)
                    .frame(maxWidth: .infinity, minHeight: 52).padding(.horizontal, 24).padding(.vertical, 12)
                    .background(.background)
            }
        }
    }

    @ViewBuilder
    private var paragraphContent: some View {
        if conditionalParagraphs {
            if rows.isEmpty { ContentUnavailableView("等待转写", systemImage: "waveform") }
            else { paragraphs }
        } else { paragraphs }
    }

    private var paragraphs: some View {
        ForEach(rows) { row in
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("10:00:00").phoneText(.metadata).monospacedDigit()
                    Spacer()
                    Button("回听", systemImage: "play") { }
                        .phoneText(.history).frame(minHeight: 44)
                }
                Text(row.text).phoneText(.transcript).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, row.id == rows.last?.id ? 0 : 8)
            .id(row.id).readingParagraphBounds(row.id)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("reading-target-probe")) } action: { frame in
                observe(ProbeEvent(kind: "row", id: row.id, frame: frame))
            }
            .onDisappear { observe(ProbeEvent(kind: "disappear", id: row.id)) }
        }
    }

    private var player: some View {
        HStack(spacing: 16) {
            Image(systemName: "play.fill").frame(width: 52, height: 52)
            VStack(alignment: .leading) {
                Text("播放器布局占位").phoneText(.metadata)
                Text("00:00                       00:20").phoneText(.caption).monospacedDigit()
            }
            Spacer()
        }
        .padding(.horizontal, 12).frame(height: 88)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 22))
        .padding(.vertical, 8).background(.background)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("reading-target-probe")) } action: { frame in
            observe(ProbeEvent(kind: "header", frame: frame))
        }
    }
}
