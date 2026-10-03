// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AppleSiliconDDC",
    platforms: [.macOS(.v13)],
    products: [.library(name: "AppleSiliconDDC", targets: ["AppleSiliconDDC"])],
    targets: [
        .target(
            name: "AppleSiliconDDCObjC",
            path: "Sources/AppleSiliconDDCObjC",
            publicHeadersPath: "."
        ),
        .target(
            name: "AppleSiliconDDC",
            dependencies: ["AppleSiliconDDCObjC"],
            path: "Sources/AppleSiliconDDC",
            linkerSettings: [.linkedFramework("CoreDisplay")]
        )
    ]
)
