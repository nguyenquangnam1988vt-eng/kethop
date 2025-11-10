import UIKit
import Flutter
import CoreLocation // Cần thiết cho Core Location Manager trong UnlockMonitor
import CoreMotion // Cần thiết cho Core Motion trong UnlockMonitor

@UIApplicationMain
class AppDelegate: FlutterAppDelegate {
    
    // Sử dụng class UnlockMonitor mới
    private let monitor = UnlockMonitor.shared
    
    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        
        // BƯỚC 1: Đăng ký các plugin của Flutter
        GeneratedPluginRegistrant.register(with: self)
        
        // BƯỚC 2: Khởi tạo và Thiết lập Kênh Truyền thông cho UnlockMonitor
        if let controller = window?.rootViewController as? FlutterViewController {
            // Thiết lập kênh truyền thông
            monitor.setupFlutterChannel(binaryMessenger: controller.binaryMessenger)
        }
        
        // BƯỚC 3: Bắt đầu theo dõi (monitor sẽ bắt đầu cả Unlock và Tilt)
        monitor.startMonitoring()
        
        // BƯỚC 4: Trả về kết quả
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
}