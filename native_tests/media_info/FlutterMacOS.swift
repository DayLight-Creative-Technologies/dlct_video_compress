// [DLCT] A minimal stand-in for the FlutterMacOS API the plugin uses, so the
// plugin's real sources in macos/Classes compile and run as a command-line
// program (see run_macos.sh). Like the real module, it re-exports Cocoa.
@_exported import Cocoa

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
    public func invokeMethod(_ method: String, arguments: Any?) {}
}

public protocol FlutterPluginRegistrar {
    var messenger: FlutterBinaryMessenger { get }
    func addMethodCallDelegate(_ delegate: FlutterPlugin, channel: FlutterMethodChannel)
}

public protocol FlutterPlugin: NSObjectProtocol {
    static func register(with registrar: FlutterPluginRegistrar)
    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult)
}
