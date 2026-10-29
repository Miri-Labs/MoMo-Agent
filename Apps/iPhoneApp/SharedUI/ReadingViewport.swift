import SwiftUI

nonisolated struct ReadingRestorationRequest<Identity: Equatable & Sendable>: Equatable, Sendable {
    let identity: Identity
    let spanID: UUID
    let anchor: UnitPoint
}

/// Resolve every mounted paragraph in one viewport coordinate space. A lazy row can
/// stay mounted off screen, so row lifetime or past intersection callbacks are not visibility.
private nonisolated struct ReadingViewportAnchors: Sendable {
    var paragraphs: [UUID: Anchor<CGRect>] = [:]
    var headers: [Anchor<CGRect>] = []
}

private nonisolated struct ReadingParagraphBoundsKey: PreferenceKey {
    static var defaultValue: ReadingViewportAnchors { ReadingViewportAnchors() }

    static func reduce(value: inout ReadingViewportAnchors, nextValue: () -> ReadingViewportAnchors) {
        let next = nextValue()
        value.paragraphs.merge(next.paragraphs, uniquingKeysWith: { _, latest in latest })
        value.headers.append(contentsOf: next.headers)
    }
}

nonisolated struct ReadingViewportSelection<Identity: Equatable & Sendable>: Equatable, Sendable {
    let identity: Identity
    let ids: Set<UUID>
    let viewportHeight: CGFloat
    let headerHeight: CGFloat?

    var restorationAnchor: UnitPoint? {
        guard viewportHeight.isFinite, viewportHeight > 0,
              let headerHeight, headerHeight.isFinite, headerHeight >= 0 else { return nil }
        guard headerHeight > 0 else { return .top }
        // Matching anchors place a row of height R at a*(V-R). With a=H/(V-44),
        // R>=44 and V-H>=44 leave >=44pt below the header, with no preceding row below H.
        // A smaller viewport cannot promise 44pt; align for its actual remaining space once.
        let readableHeight = min(44, max(0, viewportHeight - headerHeight))
        let denominator = viewportHeight - readableHeight
        return UnitPoint(x: 0.5, y: min(1, max(0, headerHeight / denominator)))
    }
}

private struct ReadingViewportModifier<Identity: Equatable & Sendable>: ViewModifier {
    let identity: Identity
    let hasHeader: Bool
    let action: @MainActor (ReadingViewportSelection<Identity>) -> Void

    func body(content: Content) -> some View {
        let identity = identity
        let hasHeader = hasHeader
        content.overlayPreferenceValue(ReadingParagraphBoundsKey.self) { anchors in
            Color.clear.onGeometryChange(for: ReadingViewportSelection<Identity>.self) { geometry in
                let viewport = CGRect(origin: .zero, size: geometry.size)
                let headers = anchors.headers.map { geometry[$0] }
                // A pinned player obscures text without changing the scroll view's bounds.
                // Resolve its actual position here; an unpinned header below the viewport top
                // must not remove otherwise readable space above it.
                let readableTop = headers.reduce(viewport.minY) { top, bounds in
                    guard bounds.minY <= viewport.minY, bounds.maxY > viewport.minY,
                          bounds.maxX > viewport.minX, bounds.minX < viewport.maxX else { return top }
                    return max(top, min(viewport.maxY, bounds.maxY))
                }
                let readableViewport = CGRect(x: viewport.minX, y: readableTop, width: viewport.width,
                                              height: max(0, viewport.maxY - readableTop))
                let ids = Set(anchors.paragraphs.compactMap { id, anchor -> UUID? in
                    let bounds = geometry[anchor]
                    let intersection = readableViewport.intersection(bounds)
                    guard bounds.height > 0, !intersection.isNull, intersection.width > 0,
                          intersection.height >= min(44, bounds.height) else { return nil }
                    return id
                })
                // Resolve inside the geometry observation itself, rather than delivering a
                // GeometryReader body snapshot through another onChange/task observation.
                return ReadingViewportSelection(identity: identity, ids: ids, viewportHeight: viewport.height,
                    headerHeight: hasHeader ? headers.map(\.height).max() : 0)
            } action: { selection in
                action(selection)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

extension View {
    func readingParagraphBounds(_ id: UUID) -> some View {
        anchorPreference(key: ReadingParagraphBoundsKey.self, value: .bounds) {
            ReadingViewportAnchors(paragraphs: [id: $0])
        }
    }

    func readingViewportHeader() -> some View {
        anchorPreference(key: ReadingParagraphBoundsKey.self, value: .bounds) {
            ReadingViewportAnchors(headers: [$0])
        }
    }

    func onReadingViewportChange<Identity: Equatable & Sendable>(
        identity: Identity, hasHeader: Bool,
        _ action: @escaping @MainActor (ReadingViewportSelection<Identity>) -> Void
    ) -> some View {
        modifier(ReadingViewportModifier(identity: identity, hasHeader: hasHeader, action: action))
    }
}
