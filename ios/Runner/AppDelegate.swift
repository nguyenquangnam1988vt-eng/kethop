import UIKit
import Flutter
import CoreLocation 
import CoreMotion 

@UIApplicationMain
class AppDelegate: FlutterAppDelegate {
    
    // Sử dụng Singleton đã được khởi tạo
    private let monitor = UnlockMonitor.shared
    
    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        
        // BƯỚC 1: Đăng ký các plugin của Flutter
        GeneratedPluginRegistrant.register(with: self)
        
        // BƯỚC 2: Khởi tạo và Thiết lập Kênh Truyền thông cho UnlockMonitor
        if let controller = window?.rootViewController as? FlutterViewController {
            // Đã sửa lỗi: Tên phương thức phải là setupEventChannel
            monitor.setupEventChannel(binaryMessenger: controller.binaryMessenger)
        }
        
        // BƯỚC 3: Loại bỏ monitor.startMonitoring()
        // Việc giám sát (monitoring) sẽ tự động bắt đầu khi Flutter gọi monitor.onListen()
        
        // BƯỚC 4: Trả về kết quả
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
}