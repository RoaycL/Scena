import Foundation

nonisolated enum AppRuntime {
    static var isRunningTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier", "XCInjectBundleInto"]
            .contains { environment[$0] != nil }
            || environment.keys.contains { $0.hasPrefix("XCTest") || $0.hasPrefix("XCInject") }
            || environment["DYLD_INSERT_LIBRARIES"]?.localizedCaseInsensitiveContains("XCTest") == true
            || NSClassFromString("XCTestCase") != nil
            || Bundle.allBundles.contains { $0.bundleURL.pathExtension == "xctest" }
    }
}
