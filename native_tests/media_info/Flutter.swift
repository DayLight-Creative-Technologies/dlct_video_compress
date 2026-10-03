// [DLCT] A minimal stand-in for the Flutter (iOS) API the plugin uses, so the
// plugin's real Swift sources in ios/Classes compile and run as a
// command-line program on a simulator (see run_ios.sh). Like the real
// module, it re-exports UIKit.
@_exported import UIKit

public typealias FlutterResult = (Any?) -> Void
public let FlutterMethodNotImplemented: NSObject = NSObject()

public class FlutterError: NSObject {
    public let code: String
    public let message: String?
    public let details: Any?

    public init(code: String, message: String?, details: Any?) {
        self.code = code
        self.message = message
        self.details = details
    }
}

public class FlutterMethodCall: NSObject {
    public let method: String
    public let arguments: Any?

    public init(methodName: String, arguments: Any?) {
        self.method = methodName
        self.arguments = arguments
    }
}

public protocol FlutterBinaryMessenger {}

public class FlutterMethodChannel: NSObject {
    public init(name: String, binaryMessenger: FlutterBinaryMessenger) {}
    /// Called with each call the plugin makes to Dart (its progress), so the
    /// tests can see a compress running.
    public var onInvoke: ((String, Any?) -> Void)? = nil
    public func invokeMethod(_ method: String, arguments: Any?) {
        onInvoke?(method, arguments)
    }
}

public protocol FlutterPluginRegistrar {
    func messenger() -> FlutterBinaryMessenger
    func addMethodCallDelegate(_ delegate: FlutterPlugin, channel: FlutterMethodChannel)
}

public protocol FlutterPlugin: NSObjectProtocol {
    static func register(with registrar: FlutterPluginRegistrar)
    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult)
}
