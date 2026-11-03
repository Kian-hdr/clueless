// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "InterviewAssistant",
    platforms: [.macOS(.v14)],
    products: [.library(name: "InterviewCore", targets: ["InterviewCore"]), .executable(name: "InterviewAssistant", targets: ["InterviewAssistant"]), .executable(name: "CluelessFastAnswer", targets: ["CluelessFastAnswer"])],
    targets: [
        .target(name: "InterviewCore"),
        .executableTarget(name: "InterviewAssistant", dependencies: ["InterviewCore"]),
        .executableTarget(name: "CluelessFastAnswer", dependencies: ["InterviewCore"]),
        .testTarget(name: "InterviewCoreTests", dependencies: ["InterviewCore"]),
        .testTarget(name: "InterviewSessionTests", dependencies: ["InterviewCore", "InterviewAssistant"])
    ],
    swiftLanguageModes: [.v5]
)
