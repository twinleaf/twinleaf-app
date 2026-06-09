// swift-tools-version: 6.2
// SPDX-License-Identifier: Apache-2.0

import PackageDescription

let package = Package(
    name: "Twinleaf",
    platforms: [
        .macOS(.v26),
        .iOS(.v26)
    ],
    products: [
        .executable(name: "Twinleaf", targets: ["Twinleaf"])
    ],
    targets: [
        .executableTarget(
            name: "Twinleaf",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker",
                    "-sectcreate",
                    "-Xlinker",
                    "__TEXT",
                    "-Xlinker",
                    "__info_plist",
                    "-Xlinker",
                    "Packaging/Twinleaf-Info.plist"
                ])
            ]
        )
    ]
)
