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
            dependencies: ["SpiceCodecInterop"]
        ),
        .target(
            name: "SpiceVideoToolbox",
            dependencies: ["SpiceCodecs"]
        ),
        .target(
            name: "SpiceIOSurface"
        ),
        .target(
            name: "SpiceCodecInterop",
            dependencies: ["CTurboJPEG", "CSpiceQUIC", "CZlib"]
        ),
        .systemLibrary(
            name: "CTurboJPEG",
            pkgConfig: "libturbojpeg",
            providers: [
                .brew(["jpeg-turbo"]),
            ]
        ),
        .systemLibrary(
            name: "CSpiceQUIC",
            pkgConfig: "spice-client-glib-2.0",
            providers: [
                .brew(["spice-gtk"]),
            ]
        ),
        .systemLibrary(
            name: "CZlib",
            pkgConfig: "zlib",
            providers: [
                .brew(["zlib"]),
            ]
        ),
        .systemLibrary(
            name: "CUSBRedir",
            pkgConfig: "libusbredirhost",
            providers: [
                .brew(["usbredir"]),
            ]
        ),
        .target(
            name: "CUSBRedirShim",
            dependencies: ["CUSBRedir"]
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
            dependencies: ["SpiceIOSurface", "SpiceProtocol", "SpiceWire"]
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
                "SpiceProtocol",
                "SpiceRenderer",
                "SpiceTransport",
                "SpiceTransportNetwork",
                "SpiceWire",
                "CUSBRedirShim",
            ]
        ),
        .executableTarget(
            name: "SpiceProbe",
            dependencies: ["SwiftSpice"]
        ),
        .executableTarget(
            name: "SpiceViewer",
            dependencies: ["SpiceRenderer", "SwiftSpice"]
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
            dependencies: ["SpiceCodecs", "SpiceVideoToolbox"],
            resources: [.process("Fixtures")]
        ),
        .testTarget(
            name: "SpiceCoreTests",
            dependencies: [
                "SpiceCodecs",
                "SpiceCore",
                "SpiceChannels",
                "SpiceCryptoSecurity",
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
            dependencies: ["SpiceIOSurface", "SpiceRenderer"]
        ),
        .testTarget(
            name: "SwiftSpiceTests",
            dependencies: [
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
