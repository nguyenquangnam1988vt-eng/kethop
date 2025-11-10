import UIKit
import Flutter

// Khai báo tên kênh (đã được định nghĩa trong UnlockMonitor.swift, nhưng cần có sẵn ở đây)
let eventChannelName = "com.example.app/monitor_events"
let methodChannelName = "com.example.app/background_service"

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Đăng ký các plugin được tạo tự động của Flutter
    GeneratedPluginRegistrant.register(with: self)

    // Lấy FlutterViewController, nơi chứa binaryMessenger (dùng để tạo kênh)
    guard let controller = window?.rootViewController as? FlutterViewController else {
        fatalError("rootViewController is not FlutterViewController")
    }

    // 1. Khởi tạo UnlockMonitor
    // Lớp này chứa logic theo dõi cảm biến, vị trí và xử lý sự kiện stream
    let monitor = UnlockMonitor()

    // 2. Thiết lập MethodChannel (Giao tiếp một chiều: Dart gọi Swift)
    let methodChannel = FlutterMethodChannel(name: methodChannelName, binaryMessenger: controller.binaryMessenger)
    methodChannel.setMethodCallHandler { (call: FlutterMethodCall, result: @escaping FlutterResult) in
        
        // Xử lý các lệnh gọi từ Dart
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

    // 3. Thiết lập EventChannel (Giao tiếp stream: Swift gửi data liên tục về Dart)
    let eventChannel = FlutterEventChannel(name: eventChannelName, binaryMessenger: controller.binaryMessenger)
    
    // Đặt 'monitor' làm handler cho stream. Khi Dart lắng nghe, monitor.onListen sẽ được gọi.
    // Khi Dart dừng lắng nghe, monitor.onCancel sẽ được gọi.
    eventChannel.setStreamHandler(monitor)

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}