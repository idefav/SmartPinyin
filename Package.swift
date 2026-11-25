// swift-tools-version: 6.0
import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let homebrewPrefix = ProcessInfo.processInfo.environment["HOMEBREW_PREFIX"] ?? "/opt/homebrew"

let librimeInclude = "Vendor/librime/dist/include"
let librimeLib = "Vendor/librime/dist/lib"
let llamaInclude = "\(homebrewPrefix)/opt/llama.cpp/include"
let ggmlInclude = "\(homebrewPrefix)/opt/ggml/include"
let llamaLib = "\(homebrewPrefix)/opt/llama.cpp/lib"
let ggmlLib = "\(homebrewPrefix)/opt/ggml/lib"

let package = Package(
    name: "SmartPinyin",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "SharedIPC", targets: ["SharedIPC"]),
        .library(name: "PinyinEngineCore", targets: ["PinyinEngineCore"]),
        .library(name: "LocalInferenceCore", targets: ["LocalInferenceCore"]),
        .library(name: "SmartPinyinCore", targets: ["SmartPinyinCore"]),
        .library(name: "SmartPinyinInstallerCore", targets: ["SmartPinyinInstallerCore"]),
        .executable(name: "SmartPinyinBench", targets: ["SmartPinyinBench"])
    ],
    targets: [
        .target(
            name: "SharedIPC",
            path: "Sources/SharedIPC"
        ),
        .target(
            name: "CLibRimeBridge",
            path: "Sources/CLibRimeBridge",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("../../\(librimeInclude)")
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(librimeLib)",
                    "-lrime",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path",
                    "-Xlinker", "-rpath", "-Xlinker", "\(packageRoot)/\(librimeLib)"
                ])
            ]
        ),
        .target(
            name: "PinyinEngineCore",
            dependencies: ["SharedIPC", "CLibRimeBridge"],
            path: "Sources/PinyinEngineCore"
        ),
        .target(
            name: "CLlamaBridge",
            path: "Sources/CLlamaBridge",
            publicHeadersPath: "include",
            cxxSettings: [
                .unsafeFlags([
                    "-std=c++17",
                    "-I\(llamaInclude)",
                    "-I\(ggmlInclude)"
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(llamaLib)",
                    "-L\(ggmlLib)",
                    "-lllama",
                    "-lggml",
                    "-lggml-base",
                    "-Xlinker", "-rpath", "-Xlinker", llamaLib,
                    "-Xlinker", "-rpath", "-Xlinker", ggmlLib
                ])
            ]
        ),
        .target(
            name: "LocalInferenceCore",
            dependencies: ["SharedIPC", "CLlamaBridge"],
            path: "Sources/LocalInferenceCore"
        ),
        .target(
            name: "SmartPinyinCore",
            dependencies: ["SharedIPC", "PinyinEngineCore"],
            path: "Sources/SmartPinyinCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("NaturalLanguage")
            ]
        ),
        .target(
            name: "SmartPinyinInstallerCore",
            dependencies: ["SharedIPC"],
            path: "Sources/SmartPinyinInstallerCore",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "SmartPinyinBench",
            dependencies: [
                "SharedIPC",
                "PinyinEngineCore",
                "LocalInferenceCore",
                "SmartPinyinCore"
            ],
            path: "Sources/SmartPinyinBench",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SmartPinyinCoreTests",
            dependencies: [
                "SharedIPC",
                "PinyinEngineCore",
                "SmartPinyinCore",
                "LocalInferenceCore",
                "SmartPinyinInstallerCore"
            ],
            path: "Tests/SmartPinyinCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
