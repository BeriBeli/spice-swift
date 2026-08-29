// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "SwiftSpice",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(name: "SwiftSpice", targets: ["SwiftSpice"]),
        .executable(name: "spice-probe", targets: ["SpiceProbe"]),
        .executable(name: "spice-viewer", targets: ["SpiceViewer"]),
        .executable(name: "spice-live-interaction", targets: ["SpiceLiveInteraction"]),
    ],
    targets: [
        .target(
            name: "SpiceWire"
        ),
        .target(
            name: "SpiceProtocol",
            dependencies: ["SpiceWire"]
        ),
        .target(
            name: "SpiceTransport"
        ),
        .target(
            name: "SpiceTransportNetwork",
            dependencies: ["SpiceTransport"]
        ),
        .target(
            name: "SpiceCore",
            dependencies: ["SpiceProtocol", "SpiceTransport", "SpiceWire"]
        ),
        .target(
            name: "SpiceCodecs",
            dependencies: ["CSpicePixelOps", "SpiceCodecInterop"]
        ),
        .target(
            name: "CSpicePixelOps"
        ),
        .target(
            name: "SpiceVideoToolbox",
            dependencies: ["SpiceCodecs"]
        ),
        .target(
            name: "SpiceIOSurface"
        ),
        .target(
            name: "SpiceMetalCompositor",
            dependencies: ["SpiceCodecs", "SpiceIOSurface", "SpiceVideoToolbox"],
            exclude: ["Shaders"],
            plugins: ["CompileMetalShaders"]
        ),
        .target(
            name: "SpiceCodecInterop",
            dependencies: ["CTurboJPEG", "CSpiceQUIC", "CZlib"]
        ),
        .binaryTarget(
            name: "CTurboJPEG",
            path: "Artifacts/CTurboJPEG.xcframework"
        ),
        .binaryTarget(
            name: "CSpiceQUIC",
            path: "Artifacts/CSpiceQUIC.xcframework"
        ),
        .systemLibrary(
            name: "CZlib"
        ),
        .binaryTarget(
            name: "CUSBRedir",
            path: "Artifacts/CUSBRedir.xcframework"
        ),
        .target(
            name: "CUSBRedirShim",
            dependencies: ["CUSBRedir"],
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("IOKit"),
                .linkedFramework("Security"),
            ]
        ),
        .target(
            name: "SpiceChannels",
            dependencies: [
                "SpiceCodecs",
                "SpiceCore",
                "SpiceProtocol",
                "SpiceRenderer",
                "SpiceVideoToolbox",
                "SpiceWire",
            ]
        ),
        .target(
            name: "SpiceCryptoSecurity",
            dependencies: ["SpiceCore"]
        ),
        .target(
            name: "SpiceRenderer",
            dependencies: [
                "CSpicePixelOps",
                "SpiceCodecs",
                "SpiceIOSurface",
                "SpiceMetalCompositor",
                "SpiceProtocol",
                "SpiceWire",
            ]
        ),
        .target(
            name: "SpiceTestSupport",
            dependencies: ["SpiceProtocol", "SpiceTransport", "SpiceWire"]
        ),
        .target(
            name: "SwiftSpice",
            dependencies: [
                "SpiceCore",
                "SpiceChannels",
                "SpiceCodecs",
                "SpiceCryptoSecurity",
                "SpiceIOSurface",
                "SpiceMetalCompositor",
                "SpiceProtocol",
                "SpiceRenderer",
                "SpiceTransport",
                "SpiceTransportNetwork",
                "SpiceWire",
                "CUSBRedirShim",
            ],
            exclude: ["Shaders"],
            plugins: ["CompileMetalShaders"]
        ),
        .executableTarget(
            name: "SpiceProbe",
            dependencies: ["SwiftSpice"]
        ),
        .executableTarget(
            name: "SpiceViewer",
            dependencies: ["SpiceRenderer", "SwiftSpice"]
        ),
        .target(
            name: "SpiceLiveInteractionSupport",
            dependencies: ["SwiftSpice"]
        ),
        .executableTarget(
            name: "SpiceLiveInteraction",
            dependencies: ["SpiceLiveInteractionSupport", "SwiftSpice"]
        ),
        .executableTarget(
            name: "SpiceProtocolGenerator"
        ),
        .plugin(
            name: "GenerateSpiceProtocol",
            capability: .command(
                intent: .custom(
                    verb: "generate-spice-protocol",
                    description: "Generate checked-in Swift SPICE protocol messages"
                ),
                permissions: [
                    .writeToPackageDirectory(
                        reason: "Update checked-in protocol sources from the pinned schema"
                    ),
                ]
            ),
            dependencies: ["SpiceProtocolGenerator"]
        ),
        .plugin(
            name: "CompileMetalShaders",
            capability: .buildTool(),
            exclude: ["compile-metal.sh"]
        ),
        .testTarget(
            name: "SpiceWireTests",
            dependencies: ["SpiceWire"]
        ),
        .testTarget(
            name: "SpiceProtocolTests",
            dependencies: ["SpiceProtocol", "SpiceWire"]
        ),
        .testTarget(
            name: "SpiceTransportTests",
            dependencies: ["SpiceTestSupport", "SpiceTransport", "SpiceTransportNetwork"]
        ),
        .testTarget(
            name: "SpiceCodecsTests",
            dependencies: ["SpiceCodecs"],
            resources: [.process("Fixtures")]
        ),
        .testTarget(
            name: "SpiceVideoToolboxTests",
            dependencies: [
                "SpiceCodecs",
                "SpiceMetalCompositor",
                "SpiceVideoToolbox",
            ],
            resources: [.process("Fixtures")]
        ),
        .testTarget(
            name: "SpiceCoreTests",
            dependencies: [
                "SpiceCodecs",
                "SpiceCore",
                "SpiceChannels",
                "SpiceCryptoSecurity",
                "SpiceMetalCompositor",
                "SpiceProtocol",
                "SpiceRenderer",
                "SpiceTestSupport",
                "SpiceTransport",
                "SpiceWire",
            ],
            resources: [.process("Fixtures")]
        ),
        .testTarget(
            name: "SpiceRendererTests",
            dependencies: [
                "CSpicePixelOps",
                "SpiceCodecs",
                "SpiceIOSurface",
                "SpiceRenderer",
                "SpiceVideoToolbox",
            ]
        ),
        .testTarget(
            name: "SpiceMetalCompositorTests",
            dependencies: ["SpiceCodecs", "SpiceMetalCompositor"]
        ),
        .testTarget(
            name: "SwiftSpiceTests",
            dependencies: [
                "SpiceLiveInteractionSupport",
                "SwiftSpice",
                "SpiceChannels",
                "SpiceCore",
                "SpiceIOSurface",
                "SpiceProtocol",
                "SpiceRenderer",
                "SpiceTestSupport",
                "SpiceTransport",
                "SpiceWire",
            ]
        ),
        .testTarget(
            name: "SpiceViewerTests",
            dependencies: ["SpiceViewer", "SwiftSpice"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
