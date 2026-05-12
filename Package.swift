// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "WeaponShift",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "WeaponShift", targets: ["WeaponShift"])
    ],
    targets: [
        .executableTarget(
            name: "WeaponShift",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("GameController"),
                .linkedFramework("SpriteKit")
            ]
        ),
        .testTarget(
            name: "WeaponShiftTests",
            dependencies: ["WeaponShift"]
        )
    ]
)
