// swift-tools-version:5.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "DatabaseKit",
    platforms: [
        .iOS(.v11),
        .macOS(.v10_13)
    ],
    products: [
        .library(name: "DatabaseKit", targets: ["DatabaseKit"])
    ],
    targets: [
        .target(name: "DatabaseKit", path: "./DatabaseKit", exclude: ["DatabaseKit.h", "Info.plist"]
        )
    ]
)
