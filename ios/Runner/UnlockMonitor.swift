import Foundation
import CoreMotion
import CoreLocation
import Flutter
import UserNotifications

// Định nghĩa thông báo Darwin Notification cho sự kiện mở khóa thiết bị
let kScreenLockStateNotification = "com.apple.springboard.lockstate"

// --- HẰNG SỐ KIỂM TRA ĐỘ ỔN ĐỊNH VÀ NGHIÊNG (ĐÃ CẬP NHẬT THEO YÊU CẦU) ---
let TILT_THRESHOLD: Double = 1.2217 // 70 degrees in radians (70 * pi/180)
let OSCILLATION_LIMIT: Double = 0.026 // ~1.5 degrees in radians 

let TILT_UPDATE_INTERVAL = 0.02 // 50 Hz (20ms)
let TILT_BUFFER_SIZE = 250 // 250 samples * 0.02s = 5 giây dữ liệu

// --- Mô hình Dữ liệu Sự kiện ---
struct MonitorEvent: Codable {
    let type: String // 'LOCK_EVENT', 'TILT_EVENT', 'UNLOCK_EVENT', 'ALARM_EVENT'
    let message: String
    let location: String?
    let tiltValue: Double? // Giá trị làm mịn 5s (tilt trung bình)
    let oscillationValue: Double? // Giá trị dao động (độ sai lệch Z/Roll)
    let timestamp: Int
    
    var jsonString: String {
        let encoder = JSONEncoder()
        // Đã sửa lỗi: 'Type 'JSONEncoder.OutputFormatting' has no member 'compact''. 
        // Bỏ qua outputFormatting; mặc định đã là compact.
        if let data = try? encoder.encode(self), let json = String(data: data, encoding: .utf8) {
            return json
        }
        return "{}"
    }
}

// --- Lớp Quản lý Logic iOS (Singleton) ---
class UnlockMonitor: NSObject, CLLocationManagerDelegate, FlutterStreamHandler {
    
    static let shared = UnlockMonitor()
    
    // --- Flutter Communication ---
    private var eventSink: FlutterEventSink?
    
    // Core Services
    private let motionManager = CMMotionManager()
    private let locationManager = CLLocationManager()
    
    // State Variables
    private var latestLockState = "UNKNOWN"
    private var isLocationMonitoringActive = false
    private var isTiltMonitoringActive = false

    // --- TRẠNG THÁI TILT MỚI ---
    private var tiltBuffer: [Double] = [] // Buffer lưu Roll Angle
    private var tiltMonitorTimer: Timer?
    private var smoothedRollAngle: Double = 0.0
    private var oscillationValue: Double = 0.0
    
    private override init() {
        super.init()
        locationManager.delegate = self
        
        // Đã sửa lỗi: Cannot find 'kCLLOCATIONAccuracyBestForNavigation' in scope
        // Dùng enum case của Swift thay vì hằng số C
        locationManager.desiredAccuracy = .bestForNavigation 
        
        locationManager.requestAlwaysAuthorization()
        
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            print("Quyền thông báo được cấp: \(granted)")
        }
    }
    
    // --- FlutterStreamHandler Implementation ---
    
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        print("[Monitor] Flutter bắt đầu lắng nghe. Khởi động các bộ theo dõi.")
        startMonitoring()
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        print("[Monitor] Flutter dừng lắng nghe. Dừng các bộ theo dõi.")
        stopMonitoring()
        eventSink = nil
        return nil
    }
    
    // Phương thức này được AppDelegate gọi
    func setupEventChannel(binaryMessenger: FlutterBinaryMessenger) {
        let eventChannel = FlutterEventChannel(name: "com.example.app/monitor_events", binaryMessenger: binaryMessenger)
        eventChannel.setStreamHandler(self)
    }

    func startMonitoring() {
        startDarwinNotificationMonitoring()
        startLocationMonitoring()
        startTiltMonitoring()
    }
    
    func stopMonitoring() {
        stopLocationMonitoring()
        stopTiltMonitoring()
        tiltMonitorTimer?.invalidate()
        tiltMonitorTimer = nil
    }
    
    // --- 1. Darwin Notification (Lock/Unlock State) ---
    private func startDarwinNotificationMonitoring() {
        if latestLockState != "UNKNOWN" { return }
        
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(
            center,
            nil,
            { (_, observer, name, _, _) in
                if let name = name?.rawValue as String?, name == kScreenLockStateNotification {
                    DispatchQueue.main.async {
                        UnlockMonitor.shared.handleLockStateChange()
                    }
                }
            } as CFNotificationCallback,
            kScreenLockStateNotification as CFString,
            nil,
            .deliverImmediately
        )
        print("[LockState] Bắt đầu lắng nghe Darwin Notification.")
        
        // Gọi để kiểm tra trạng thái khóa ban đầu ngay sau khi thiết lập lắng nghe
        handleLockStateChange()
    }
    
    // Hàm xử lý sự kiện Lock/Unlock (Bao gồm logic cảnh báo đã cập nhật)
    private func handleLockStateChange() {
        
        // Đã sửa lỗi: Cannot find 'CFNotificationCenterGetState' in scope
        // Thay thế hàm C private bằng API công khai của Swift để kiểm tra Protected Data
        let isProtectedDataAvailable = UIApplication.shared.isProtectedDataAvailable
        let currentState = isProtectedDataAvailable ? "UNLOCKED" : "LOCKED"
        
        if currentState != latestLockState || latestLockState == "UNKNOWN" {
            latestLockState = currentState
            
            let eventType: String
            var message: String
            
            let rollForCheck = self.smoothedRollAngle // Góc nghiêng TRUNG BÌNH 5s
            let isOscillating = self.oscillationValue > OSCILLATION_LIMIT 
            
            if currentState == "UNLOCKED" {
                // LOGIC CẢNH BÁO MỚI:
                // Kích hoạt khi: Mở Khóa + Góc Nghiêng TRUNG BÌNH > 70° + Ổn Định (Dao động <= 1.5°)
                if abs(rollForCheck) > TILT_THRESHOLD && !isOscillating {
                    // CẢNH BÁO BỊ KÍCH HOẠT!
                    eventType = "ALARM_EVENT"
                    let angleDeg = rollForCheck * 180 / Double.pi
                    let oscillationDeg = oscillationValue * 180 / Double.pi
                    
                    message = "CẢNH BÁO: Mở Khóa + Nghiêng TB 5s > 70° (\(String(format: "%.1f", angleDeg))°) VÀ Ổn định (Dao động: \(String(format: "%.2f", oscillationDeg))° < 1.5°)."
                    
                    self.sendLocalNotification(title: "CẢNH BÁO KHẨN CẤP", body: message)
                    
                } else {
                    // Mở Khóa BÌNH THƯỜNG
                    eventType = "UNLOCK_EVENT"
                    message = "Thiết bị đã Mở Khóa."
                }
            } else {
                // Sự kiện Khóa
                eventType = "LOCK_EVENT"
                message = "Thiết bị đã Khóa."
            }
            
            print("[\(eventType)] Trạng thái mới: \(message)")
            
            // Gửi sự kiện về Flutter
            let event = MonitorEvent(
                type: eventType,
                message: message,
                location: self.getLatestLocationString(), 
                tiltValue: self.smoothedRollAngle, 
                oscillationValue: self.oscillationValue, 
                timestamp: Int(Date().timeIntervalSince1970 * 1000)
            )
            self.eventSink?(event.jsonString)
        }
    }
    
    private func sendLocalNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = UNNotificationSound.default
        content.badge = 1

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Lỗi gửi thông báo: \(error.localizedDescription)")
            }
        }
    }
    
    // --- 2. Core Location ---
    private func startLocationMonitoring() {
        if isLocationMonitoringActive { return }
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.showsBackgroundLocationIndicator = true
        locationManager.startUpdatingLocation()
        isLocationMonitoringActive = true
        print("[Location] Bắt đầu theo dõi vị trí liên tục.")
    }
    
    private func stopLocationMonitoring() {
        if !isLocationMonitoringActive { return }
        locationManager.stopUpdatingLocation()
        isLocationMonitoringActive = false
        print("[Location] Đã dừng theo dõi vị trí.")
    }
    
    private func getLatestLocationString() -> String? {
        guard let location = locationManager.location else { return "Không thể lấy vị trí" }
        let lat = String(format: "%.6f", location.coordinate.latitude)
        let lon = String(format: "%.6f", location.coordinate.longitude)
        let alt = String(format: "%.1f", location.altitude)
        let speed = String(format: "%.1f", location.speed)
        return "Lat: \(lat), Lon: \(lon), Alt: \(alt)m, Speed: \(speed) m/s"
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Chỉ giữ vị trí mới nhất
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("[Location] Lỗi vị trí: \(error.localizedDescription)")
    }

    // --- 3. Core Motion (Theo dõi Nghiêng/Tilt) ---
    private func startTiltMonitoring() {
        if isTiltMonitoringActive { return }
        guard motionManager.isDeviceMotionAvailable else {
            print("[Tilt] Lỗi: Cảm biến chuyển động (Device Motion) không khả dụng.")
            return
        }
        
        motionManager.deviceMotionUpdateInterval = TILT_UPDATE_INTERVAL
        
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] (motion, error) in
            guard let self = self, let attitude = motion?.attitude else { return }
            
            // 1. Cập nhật buffer
            self.tiltBuffer.append(attitude.roll)
            if self.tiltBuffer.count > TILT_BUFFER_SIZE {
                self.tiltBuffer.removeFirst()
            }
        }
        
        // 2. Thiết lập Timer để tính toán Trung bình 5s và Dao động (gửi sự kiện 10 lần/giây)
        tiltMonitorTimer = Timer.scheduledTimer(timeInterval: 0.1, target: self, selector: #selector(processAndSendTiltData), userInfo: nil, repeats: true)
        RunLoop.main.add(tiltMonitorTimer!, forMode: .common)
        
        isTiltMonitoringActive = true
        print("[Tilt] Bắt đầu theo dõi nghiêng và tính trung bình \(TILT_BUFFER_SIZE) mẫu (\(TILT_BUFFER_SIZE * TILT_UPDATE_INTERVAL) giây).")
    }
    
    @objc private func processAndSendTiltData() {
        guard self.eventSink != nil, !tiltBuffer.isEmpty else { return }

        // 1. Tính toán Trung bình 5s (Smoothed Roll - tilt trung bình)
        let sum = tiltBuffer.reduce(0, +)
        self.smoothedRollAngle = sum / Double(tiltBuffer.count)
        
        // 2. Tính toán Độ dao động (Oscillation: Max - Min Roll Angle - độ sai lệch Z)
        if let min = tiltBuffer.min(), let max = tiltBuffer.max() {
            self.oscillationValue = max - min
        } else {
            self.oscillationValue = 0.0
        }
        
        // Gửi dữ liệu nghiêng ĐÃ LÀM MỊN và độ dao động về Flutter
        let event = MonitorEvent(
            type: "TILT_EVENT",
            message: "Roll Angle (5s Avg)",
            location: nil,
            tiltValue: self.smoothedRollAngle,
            oscillationValue: self.oscillationValue,
            timestamp: Int(Date().timeIntervalSince1970 * 1000)
        )
        self.eventSink?(event.jsonString)
    }
    
    private func stopTiltMonitoring() {
        if !isTiltMonitoringActive { return }
        motionManager.stopDeviceMotionUpdates()
        tiltMonitorTimer?.invalidate()
        tiltMonitorTimer = nil
        isTiltMonitoringActive = false
        print("[Tilt] Đã dừng theo dõi nghiêng.")
    }
}