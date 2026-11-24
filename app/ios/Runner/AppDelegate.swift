import Flutter
import ImageIO
import UIKit
import Vision

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // Движок создаётся сценой (SceneDelegate), поэтому каналы регистрируются здесь, а не в didFinishLaunching:
  // так они достаются тому движку, который реально показывает приложение.
  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "QasyndaOcr") {
      QasyndaOcr.register(with: registrar)
    }
  }
}

/// Распознавание текста на снимке карты: канал qasynda/ocr, метод recognize({path}) → список строк.
/// Apple Vision, без сети и без сторонних библиотек. Снимок читается с диска; удаляет его приложение.
final class QasyndaOcr: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "qasynda/ocr", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(QasyndaOcr(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "recognize" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard let args = call.arguments as? [String: Any], let path = args["path"] as? String else {
      result(FlutterError(code: "bad_args", message: "path is required", details: nil))
      return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      var lines: [String] = []
      var failure: FlutterError?
      do {
        lines = try QasyndaOcr.recognize(path: path)
      } catch {
        failure = FlutterError(code: "ocr_failed", message: error.localizedDescription, details: nil)
      }
      DispatchQueue.main.async {
        if let failure = failure {
          result(failure)
        } else {
          result(lines)
        }
      }
    }
  }

  private static func recognize(path: String) throws -> [String] {
    let url = URL(fileURLWithPath: path)
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    let handler = VNImageRequestHandler(url: url, orientation: orientation(of: url), options: [:])
    try handler.perform([request])
    guard let observations = request.results else { return [] }
    var lines: [String] = []
    for observation in observations {
      if let candidate = observation.topCandidates(1).first {
        lines.append(candidate.string)
      }
    }
    return lines
  }

  /// Камера пишет JPEG с поворотом в EXIF; Vision нужно сказать его явно.
  private static func orientation(of url: URL) -> CGImagePropertyOrientation {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
          let raw = properties[kCGImagePropertyOrientation as String] as? NSNumber,
          let value = CGImagePropertyOrientation(rawValue: raw.uint32Value)
    else {
      return .up
    }
    return value
  }
}
