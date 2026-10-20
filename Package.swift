// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DockAwakeCore",
    platforms: [.macOS(.v13)],
    products: [],
    targets: [
        .target(
            name: "DockAwakeCore",
            path: "src",
            exclude: [
                "AppDelegate.swift",
                "DashboardViewController.swift",
                "Info.plist",
                "dockawake-pmset.c",
                "main.swift",
                "OverviewView.swift",
                "runcat-safe-remove.c"
            ],
            sources: [
                "CommandRunner.swift",
                "ContainerCollector.swift",
                "DashboardModels.swift",
                "DetailCollectionSession.swift",
                "KeepAwakeController.swift",
                "LaunchAgentCollector.swift",
                "NetworkCollector.swift",
                "PowerAssertionCollector.swift",
                "ProcessCollector.swift",
                "PublicIPClient.swift",
                "Scheduler.swift",
                "DockTileView.swift",
                "SystemSummaryCollector.swift"
            ],
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("IOKit")
            ]
        ),
        .testTarget(
            name: "DockAwakeCoreTests",
            dependencies: ["DockAwakeCore"],
            path: "Tests/DockAwakeCoreTests"
        )
    ]
)
