import Foundation
import TailscaleKit
import MoMoAgentRTC

/// One native peer's datagram route. Closing desktop never closes the chat node.
@MainActor final class DesktopMediaRoute {
    let node: TailscaleNode
    let route: TailscaleNode.MediaRoute
    private var closed = false
    private init(node: TailscaleNode, route: TailscaleNode.MediaRoute) { self.node = node; self.route = route }
    static func open(_ tailnet: EmbeddedTailnet) async throws -> DesktopMediaRoute {
        try await tailnet.start()
        await tailnet.refreshStatus()
        guard tailnet.state == "Running", let node = tailnet.node else { throw TailnetError.unavailable }
        let route = try await node.openMediaRoute()
        guard tailnet.node === node, !Task.isCancelled else { try? await node.closeMediaRoute(route); throw CancellationError() }
        return DesktopMediaRoute(node: node, route: route)
    }
    func advertised(_ sdp: String) throws -> String { try DesktopSDP.route(sdp, through: route.tailnet) }
    func received(_ sdp: String) throws -> String { try DesktopSDP.route(sdp, through: route.local) }
    func bind(local: String, remote: String) async throws {
        guard !closed else { throw DesktopRTCError.closed }
        try await node.configureMediaRoute(route, source: DesktopSDP.endpoint(local), remote: DesktopSDP.endpoint(remote))
    }
    func close() async {
        guard !closed else { return }; closed = true
        try? await node.closeMediaRoute(route)
    }
}
