// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "captura_capture",
    platforms: [
        .macOS("14.0")
    ],
    products: [
        .library(name: "captura-capture", targets: ["captura_capture"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "captura_capture",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ]
        )
    ]
)
