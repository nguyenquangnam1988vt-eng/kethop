import UIKit
import Flutter
import CoreMotion
import CoreLocation

// MARK: - Flutter Channel Constants
// Khai báo các hằng số kênh tại đây VÀ CHỈ TẠI ĐÂY để tránh lỗi redeclaration.
let eventChannelName = "com.example.app/monitor_events"
let methodChannelName = "com.example.app/background_service"

@main
class AppDelegate: FlutterAppDelegate {
    
    // Cấu hình UnlockMonitor
    private var unlockMonitor: UnlockMonitor?

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        
        // Setup Flutter View Controller
        guard let controller = window?.rootViewController as? FlutterViewController else {
            // Ghi log lỗi nếu không tìm thấy controller
            print("Lỗi: Không thể tìm thấy FlutterViewController làm root.")
            return super.application(application, didFinishLaunchingWithOptions: launchOptions)
        }
        
        // Khởi tạo Monitor
        unlockMonitor = UnlockMonitor()

        // Setup Method Channel: Gọi các hàm điều khiển từ Flutter (start/stop)
        let methodChannel = FlutterMethodChannel(name: methodChannelName, binaryMessenger: controller.binaryMessenger)
        methodChannel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
            guard let self = self, let monitor = self.unlockMonitor else {
                result(FlutterError(code: "UNAVAILABLE", message: "Monitor service not ready", details: nil))
                return
            }
            
            switch call.method {
            case "startMonitoring":
                monitor.startMonitoring()
                result(nil)
            case "stopMonitoring":
                monitor.stopMonitoring()
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        }

        // Setup Event Channel: Gửi sự kiện từ Native (Lock/Unlock/Alarm/Tilt) về Flutter
        let eventChannel = FlutterEventChannel(name: eventChannelName, binaryMessenger: controller.binaryMessenger)
        eventChannel.setStreamHandler(unlockMonitor)

        GeneratedPluginRegistrant.register(with: self)
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
}