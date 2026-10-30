import Foundation
@main struct SDPCheck {
    static func main() throws {
        let sdp = "v=0\r\na=group:BUNDLE 0 1\r\na=fingerprint:sha-256 fixture\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\nc=IN IP4 192.168.1.2\r\na=rtcp-mux\r\na=candidate:1 1 udp 1 192.168.1.2 12345 typ host\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\na=candidate:2 1 udp 2 10.0.0.1 4567 typ host\r\n"
        let routed = try DesktopSDP.route(sdp, through: "100.64.0.2:2000")
        let endpoint = try DesktopSDP.endpoint(routed)
        precondition(endpoint == "100.64.0.2:2000")
        precondition(!routed.contains("192.168.") && !routed.contains("10.0.0.1"))
        precondition(routed.components(separatedBy: "a=candidate:").count == 3)
        for invalid in [sdp + "m=audio 9 UDP/TLS/RTP/SAVPF 96\r\n", String(repeating: "a", count: 131073), sdp.replacingOccurrences(of:"a=rtcp-mux",with:""), sdp.replacingOccurrences(of:"a=group:BUNDLE",with:"a=group:OTHER")] {
            do { _ = try DesktopSDP.route(invalid, through:"100.64.0.2:2000"); fatalError("invalid offer accepted") } catch {}
        }
        for endpoint in ["example.com:443", "127.0.0.1:0", "999.1.1.1:1", "127.0.0.1:65536"] {
            do { _ = try DesktopSDP.route(sdp, through:endpoint); fatalError("bad endpoint accepted") } catch {}
        }
        print("PASS SDP candidate isolation, size, media and endpoint validation")
    }
}
