// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MoMoAgentAgentClient",
    platforms: [.macOS(.v14), .iOS(.v18)],
    products: [
        .library(name: "MoMoAgentClient", targets: ["MoMoAgentClient"]),
        .library(name: "MoMoAgentRTC", targets: ["MoMoAgentRTC"]),
        .executable(name: "momo-agent-probe", targets: ["MoMoAgentProbe"]),
        .executable(name: "momo-rtc-probe", targets: ["MoMoRTCProbe"])
    ],
    dependencies: [.package(url: "https://github.com/stasel/WebRTC.git", exact: "155.0.0")],
    targets: [
        .target(name: "MoMoAgentClient"),
        .target(name: "MoMoAgentRTC", dependencies: ["MoMoAgentClient", .product(name: "WebRTC", package: "WebRTC")]),
        .executableTarget(name: "MoMoAgentProbe", dependencies: ["MoMoAgentClient"]),
        .executableTarget(name: "MoMoRTCProbe", dependencies: ["MoMoAgentClient", "MoMoAgentRTC"]),
        .testTarget(name: "MoMoAgentClientTests", dependencies: ["MoMoAgentClient"])
    ]
)
