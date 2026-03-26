import Flutter
import UIKit

public class FlutterPreviewFilePlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "flutter_preview_file", binaryMessenger: registrar.messenger())
    let instance = FlutterPreviewFilePlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getPlatformVersion":
      result("iOS " + UIDevice.current.systemVersion)
    case "loadDocContent", "convertDocToHtml", "saveDocTextContent", "convertHtmlToPdf":
      result(
        FlutterError(
          code: "unsupported",
          message: "Legacy .doc native conversion is currently supported on Android only.",
          details: nil
        )
      )
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
