import Foundation
import Flutter
import CoreLocation
import CoreMotion
import UIKit

// MARK: - Constants and Structs

// Định nghĩa tên kênh Flutter
let eventChannelName = "com.example.app/monitor_events"
let methodChannelName = "com.example.app/background_service"

// Ngưỡng nghiêng (độ) - Khoảng 70 độ.
let TILT_THRESHOLD_DEGREE: Double = 70.0
let TILT_THRESHOLD_RAD: Double = TILT_THRESHOLD_DEGREE * .pi / 180.0

// Ngưỡng dao động (độ ổn định) - Giá trị nhỏ hơn nghĩa là ổn định hơn.
let OSCILLATION_THRESHOLD: Double = 0.005 

// MARK: - Unlock Monitor Class

class UnlockMonitor: NSObject, FlutterStreamHandler, CLLocationManagerDelegate {

    // Flutter Channel
    private var eventSink: FlutterEventSink?
    
    // Core Motion
    private var motionManager = CMMotionManager()
    private var tiltTimer: Timer?
    private var isMonitoringTilt = false
    
    // Core Location
    private var locationManager = CLLocationManager()
    private var lastLocation: CLLocation?
    private var locationTimer: Timer?
    
    // Device State
    private var isScreenLocked = true
    private var isDeviceStable = false

    // Tilt Data Tracking
    private var tiltHistory: [Double] = []
    private let tiltHistoryCapacity = 10 // Lưu 10 mẫu (0.5 giây)
    private var lastTiltValue: Double = 0.0
    private var lastOscillationValue: Double = 0.0

    override init() {
        super.init()
        setupNotificationObservers()
        setupLocationManager()
    }
    
    // MARK: - FlutterStreamHandler Implementation
    
    // Lắng nghe bắt đầu stream (từ Dart)
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        // Gửi trạng thái hiện tại ngay khi kết nối
        sendEvent(type: "LOCK_EVENT", message: isScreenLocked ? "Thiết bị Khóa (Khởi tạo)" : "Thiết bị Mở Khóa (Khởi tạo)")
        return nil
    }
    
    // Lắng nghe hủy stream (từ Dart)
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    // MARK: - Setup and Lifecycle

    // Cấu hình CLLocationManager
    private func setupLocationManager() {
        locationManager.delegate = self
        // FIX LỖI 1: Thay .best bằng hằng số kCLLocationAccuracyBest
        locationManager.desiredAccuracy = kCLLocationAccuracyBest 
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
    }

    // Thiết lập lắng nghe thông báo Lock/Unlock của thiết bị
    private func setupNotificationObservers() {
        NotificationCenter.default.addObserver(self, 
            selector: #selector(didLock), 
            name: UIScreen.didWakeNotification, 
            object: nil
        )
        NotificationCenter.default.addObserver(self, 
            selector: #selector(didUnlock), 
            name: UIScreen.didUnaugmentNotification, // Dùng thay thế cho .unlocked (thường là khi unaugment, hay mở khóa)
            object: nil
        )
        NotificationCenter.default.addObserver(self, 
            selector: #selector(didLock), 
            name: UIApplication.didEnterBackgroundNotification, 
            object: nil
        )
    }
    
    // MARK: - Background Service Control

    // Bắt đầu service nền (được gọi qua MethodChannel)
    @objc func startMonitoring() {
        // Yêu cầu quyền truy cập Vị trí
        locationManager.requestWhenInUseAuthorization()
        locationManager.requestAlwaysAuthorization()

        // Bắt đầu cập nhật vị trí
        locationManager.startUpdatingLocation()
        startLocationTimer()
        
        // Bắt đầu theo dõi Nghiêng
        startTiltMonitoring()
    }
    
    // Dừng service nền (được gọi qua MethodChannel)
    @objc func stopMonitoring() {
        locationManager.stopUpdatingLocation()
        stopLocationTimer()
        stopTiltMonitoring()
    }

    // MARK: - Location Monitoring
    
    private func startLocationTimer() {
        // Cập nhật vị trí mỗi 15 giây
        locationTimer?.invalidate()
        locationTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            self?.sendCurrentLocation()
        }
        locationTimer?.fire()
    }
    
    private func stopLocationTimer() {
        locationTimer?.invalidate()
        locationTimer = nil
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        lastLocation = location
    }
    
    private func sendCurrentLocation() {
        guard let location = lastLocation else { return }

        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        let locationString = "Lat: \(lat.to6Decimal()), Lon: \(lon.to6Decimal())"
        
        // Gửi sự kiện vị trí nếu có sự kiện lock/unlock xảy ra
        // Ở đây chỉ lưu trữ, việc gửi gắn liền với Lock/Unlock
    }
    
    // MARK: - Tilt Monitoring (CoreMotion)
    
    private func startTiltMonitoring() {
        guard !isMonitoringTilt else { return }
        isMonitoringTilt = true
        
        if motionManager.isDeviceMotionAvailable {
            motionManager.deviceMotionUpdateInterval = 0.05 // 50ms
            motionManager.startDeviceMotionUpdates(using: .xArbitraryZAxisAttitude) { [weak self] (motion, error) in
                guard let self = self, let motion = motion else { return }
                
                // Roll (nghiêng quanh trục X) là góc nghiêng phổ biến nhất
                let rollAngle = motion.attitude.roll 
                self.processTiltData(rollAngle: rollAngle)
                
                // Luôn kiểm tra cảnh báo sau khi nhận dữ liệu nghiêng mới
                self.checkAlarmConditions()
            }
        } else {
            print("Device Motion not available.")
        }
    }
    
    private func stopTiltMonitoring() {
        motionManager.stopDeviceMotionUpdates()
        isMonitoringTilt = false
    }
    
    private func processTiltData(rollAngle: Double) {
        // 1. Cập nhật lịch sử nghiêng
        tiltHistory.append(rollAngle)
        if tiltHistory.count > tiltHistoryCapacity {
            tiltHistory.removeFirst()
        }
        
        // 2. Tính toán giá trị Nghiêng (Trung bình 500ms)
        let averageTilt = tiltHistory.reduce(0, +) / Double(tiltHistory.count)
        
        // 3. Tính toán Độ Dao Động (Ổn định) - Độ lệch chuẩn
        let mean = averageTilt
        let sumOfSquaredDifferences = tiltHistory.reduce(0) { $0 + pow($1 - mean, 2) }
        let variance = sumOfSquaredDifferences / Double(tiltHistory.count)
        let oscillation = sqrt(variance) // Độ lệch chuẩn là độ dao động

        lastTiltValue = averageTilt
        lastOscillationValue = oscillation

        // 4. Gửi sự kiện Tilt cứ mỗi 500ms (10 mẫu)
        if tiltHistory.count == tiltHistoryCapacity {
            let message: String
            if abs(averageTilt) < TILT_THRESHOLD_RAD * 0.1 {
                 message = "Thiết bị rất Phẳng và Ổn Định."
            } else if abs(averageTilt) < TILT_THRESHOLD_RAD {
                message = "Thiết bị đang Nghiêng nhẹ."
            } else {
                message = "Thiết bị Nghiêng quá Ngưỡng!"
            }
            
            sendTiltEvent(tiltValue: averageTilt, oscillationValue: oscillation, message: message)
        }
    }

    // MARK: - State Management

    @objc private func didLock() {
        guard !isScreenLocked else { return }
        isScreenLocked = true
        
        // Đảm bảo không gửi ALARM ngay lập tức khi Lock
        // Dừng theo dõi nghiêng tạm thời hoặc reset trạng thái cảnh báo
        isDeviceStable = false
        
        sendEvent(type: "LOCK_EVENT", message: "Thiết bị đã Khóa.", location: lastLocation?.toLocationString())
    }

    @objc private func didUnlock() {
        guard isScreenLocked else { return }
        isScreenLocked = false
        
        sendEvent(type: "UNLOCK_EVENT", message: "Thiết bị đã Mở Khóa.", location: lastLocation?.toLocationString())
        
        // Việc mở khóa là điều kiện tiên quyết cho ALARM, không phải ALARM.
        // Cảnh báo sẽ được kiểm tra sau khi có dữ liệu nghiêng mới.
    }
    
    // MARK: - Alarm Logic

    private func checkAlarmConditions() {
        guard isMonitoringTilt else { return }

        // Điều kiện BẤT THƯỜNG (ALARM):
        // 1. Thiết bị đang ở trạng thái MỞ KHÓA
        // 2. Thiết bị RẤT PHẲNG (góc nghiêng thấp)
        // 3. Thiết bị RẤT ỔN ĐỊNH (dao động thấp)
        
        if !isScreenLocked {
            let tiltLow = abs(lastTiltValue) < TILT_THRESHOLD_RAD * 0.1 // Rất phẳng (dưới 7 độ)
            let oscillationLow = lastOscillationValue < OSCILLATION_THRESHOLD // Rất ổn định (độ dao động thấp)

            if tiltLow && oscillationLow {
                // VI PHẠM: Thiết bị mở khóa, phẳng và ổn định.
                let alarmMessage = "MỞ KHÓA & ỔN ĐỊNH VI PHẠM!\n" +
                                   "Roll: \(lastTiltValue.to3Decimal()) rad\n" +
                                   "Oscillation: \(lastOscillationValue.to5Decimal()) rad"
                                   
                sendEvent(type: "ALARM_EVENT", message: alarmMessage, location: lastLocation?.toLocationString())
            } 
        }
        // Ghi chú: Nếu màn hình Khóa, không bao giờ phát ALARM.
    }

    // MARK: - Event Sending

    // Gửi sự kiện Lock/Unlock/Alarm
    private func sendEvent(type: String, message: String, location: String? = nil) {
        guard let sink = eventSink else { return }
        
        // FIX LỖI 2: Đảm bảo timestamp là Double (mili giây)
        let timestamp = Date().timeIntervalSince1970 * 1000.0

        let eventData: [String: Any] = [
            "type": type,
            "message": message,
            "location": location as Any,
            "timestamp": timestamp // Double
        ]
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: eventData, options: [])
            let jsonString = String(data: jsonData, encoding: .utf8)
            sink(jsonString)
        } catch {
            print("Error serializing JSON for event: \(error)")
        }
    }
    
    // Gửi sự kiện Tilt
    private func sendTiltEvent(tiltValue: Double, oscillationValue: Double, message: String) {
        guard let sink = eventSink else { return }

        let timestamp = Date().timeIntervalSince1970 * 1000.0

        let eventData: [String: Any] = [
            "type": "TILT_EVENT",
            "message": message,
            "tiltValue": tiltValue,
            "oscillationValue": oscillationValue,
            "timestamp": timestamp
        ]
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: eventData, options: [])
            let jsonString = String(data: jsonData, encoding: .utf8)
            sink(jsonString)
        } catch {
            print("Error serializing JSON for tilt event: \(error)")
        }
    }
}

// MARK: - Extensions

extension CLLocation {
    func toLocationString() -> String {
        let lat = self.coordinate.latitude.to6Decimal()
        let lon = self.coordinate.longitude.to6Decimal()
        return "Lat: \(lat), Lon: \(lon)"
    }
}

extension Double {
    func to3Decimal() -> String {
        return String(format: "%.3f", self)
    }
    func to5Decimal() -> String {
        return String(format: "%.5f", self)
    }
    func to6Decimal() -> String {
        return String(format: "%.6f", self)
    }
}