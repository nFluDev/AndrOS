// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AndrOS",
    platforms: [.macOS(.v14)],
    targets: [
        // Ses surucusuyle ORTAK bellek yapisi: ayni baslik hem C
        // eklentisinde hem Swift tarafinda kullaniliyor ki iki taraf
        // birbirinden habersiz degismesin.
        .target(name: "AndrOSAudioShim"),
        // Sanal kamera uzantisiyle ORTAK kare tamponu.
        .target(name: "AndrOSCameraShim"),
        .target(name: "AndrOSCore", dependencies: ["AndrOSAudioShim"],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "androsctl", dependencies: ["AndrOSCore"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "AndrOSApp",
                          dependencies: ["AndrOSCore", "AndrOSCameraShim"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
