// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BibimbapCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "BibimbapCore", targets: ["BibimbapFeatures", "BibimbapUI"]),
    ],
    targets: [
        .target(name: "BibimbapLocalization"),
        .target(name: "PulsarHID", dependencies: ["BibimbapLocalization"]),
        .target(name: "PulsarCatalog", resources: [.process("Resources")]),
        .target(
            name: "PulsarProtocol",
            dependencies: ["BibimbapLocalization", "PulsarHID", "PulsarCatalog"]
        ),
        .target(name: "PulsarSimulator", dependencies: ["PulsarHID", "PulsarProtocol", "PulsarCatalog"]),
        .target(
            name: "BibimbapFeatures",
            dependencies: [
                "BibimbapLocalization", "PulsarHID", "PulsarProtocol",
                "PulsarCatalog", "PulsarSimulator",
            ]
        ),
        .target(
            name: "BibimbapUI",
            dependencies: ["BibimbapLocalization", "BibimbapFeatures"],
            resources: [.process("Resources")]
        ),

        // Rendu hors écran des vues, pour inspecter le résultat sans capture d'écran.
        .executableTarget(name: "bibimbap-render", dependencies: ["BibimbapUI"]),

        // Sonde de diagnostic en lecture seule, pour valider le protocole sur matériel réel.
        .executableTarget(name: "pulsar-probe", dependencies: ["PulsarHID", "PulsarProtocol", "PulsarCatalog"]),

        // Essai d'écriture minimal, réversible, à lancer explicitement.
        .executableTarget(name: "pulsar-writetest", dependencies: ["PulsarHID", "PulsarProtocol", "PulsarCatalog"]),

        .testTarget(
            name: "PulsarProtocolTests",
            dependencies: ["PulsarProtocol"],
            resources: [.process("Fixtures")]
        ),
        .testTarget(name: "PulsarCatalogTests", dependencies: ["PulsarCatalog"]),
        .testTarget(name: "PulsarSimulatorTests", dependencies: ["PulsarSimulator"]),
        .testTarget(name: "BibimbapFeaturesTests", dependencies: ["BibimbapFeatures"]),
    ]
)
