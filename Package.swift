// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BarGrup",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "BarGrup",
            path: "Sources/BarGrup",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
