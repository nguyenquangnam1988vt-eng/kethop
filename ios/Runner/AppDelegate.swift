import UIKit
import Flutter

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    
    // --- KHỞI TẠO VÀ CẤU HÌNH CHANNELS ---
    
    guard let controller = window?.rootViewController as? FlutterViewController else {
        fatalError("rootViewController is not FlutterViewController")
    }
    
    // 1. Khởi tạo UnlockMonitor (không dùng .shared)
    let monitor = UnlockMonitor()
    
    // 2. Cấu hình MethodChannel
    let methodChannel = FlutterMethodChannel(name: methodChannelName, binaryMessenger: controller.binaryMessenger)
    methodChannel.setMethodCallHandler { (call: FlutterMethodCall, result: @escaping FlutterResult) in
        if call.method == "startBackgroundService" {
            monitor.startMonitoring()
            result(nil)
        } else if call.method == "stopBackgroundService" {
            monitor.stopMonitoring()
            result(nil)
        } else {
            result(FlutterMethodNotImplemented)
        }
    }
    
    // 3. Cấu hình EventChannel
    let eventChannel = FlutterEventChannel(name: eventChannelName, binaryMessenger: controller.binaryMessenger)
    eventChannel.setStreamHandler(monitor) // Đặt monitor làm handler cho stream
    
    // ----------------------------------------

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}