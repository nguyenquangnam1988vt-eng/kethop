import Foundation
import Flutter
import CoreLocation
import CoreMotion
import UIKit

// MARK: - Constants and Structs

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

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        // Gửi trạng thái hiện tại ngay khi kết nối
        sendEvent(type: "LOCK_EVENT", message: isScreenLocked ? "Thiết bị Khóa (Khởi tạo)" : "Thiết bị Mở Khóa (Khởi tạo)")
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    // MARK: - Setup and Lifecycle

    // Cấu hình CLLocationManager
    private func setupLocationManager() {
        locationManager.delegate = self
        // SỬA LỖI: Sử dụng hằng số kCLLocationAccuracyBest
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
    }

    // Thiết lập lắng nghe thông báo Proxy Lock/Unlock
    private func setupNotificationObservers() {

        // Proxy Lock: Ứng dụng đi vào nền
        NotificationCenter.default.addObserver(self,
            selector: #selector(didLock),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )

        // Proxy Unlock: Ứng dụng trở nên hoạt động (Foreground)
        NotificationCenter.default.addObserver(self,
            selector: #selector(didUnlock),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )

    }

    // MARK: - Background Service Control

    // Bắt đầu service nền (được gọi qua MethodChannel)
    @objc func startMonitoring() {
        // Yêu cầu quyền truy cập Vị trí
        locationManager.requestWhenInUseAuthorization()
        locationManager.requestAlwaysAuthorization()

        // Bắt đầu cập nhật vị trí liên tục
        locationManager.startUpdatingLocation()
        startLocationTimer()

        // Bắt đầu theo dõi Nghiêng liên tục
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
        // Logic gửi vị trí nếu cần, hiện tại chỉ cập nhật lastLocation
    }

    // MARK: - Tilt Monitoring (CoreMotion)

    private func startTiltMonitoring() {
        guard !isMonitoringTilt else { return }
        isMonitoringTilt = true

        if motionManager.isDeviceMotionAvailable {
            motionManager.deviceMotionUpdateInterval = 0.05 // 50ms

            // **KHẮC PHỤC LỖI:** Thay thế .xArbitraryZAxis bằng CMAttitudeReferenceFrame.xArbitraryCorrectedZAxis
            motionManager.startDeviceMotionUpdates(
                using: .xArbitraryCorrectedZAxis, 
                to: OperationQueue.main
            ) { [weak self] (motion, error) in
                guard let self = self, let motion = motion else { return }

                let rollAngle = motion.attitude.roll
                self.processTiltData(rollAngle: rollAngle)

                // Vô cùng quan trọng: Luôn kiểm tra cảnh báo sau khi nhận dữ liệu cảm biến mới
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

        // 2. Tính toán giá trị Nghiêng (Trung bình) và Độ Dao Động (Độ lệch chuẩn)
        let averageTilt = tiltHistory.reduce(0, +) / Double(tiltHistory.count)
        let mean = averageTilt
        let sumOfSquaredDifferences = tiltHistory.reduce(0) { $0 + pow($1 - mean, 2) }
        let variance = sumOfSquaredDifferences / Double(tiltHistory.count)
        let oscillation = sqrt(variance)

        lastTiltValue = averageTilt
        lastOscillationValue = oscillation

        // 3. Gửi sự kiện Tilt cứ mỗi 500ms (10 mẫu)
        if tiltHistory.count == tiltHistoryCapacity {
            let message: String = oscillation < OSCILLATION_THRESHOLD ? "Thiết bị Rất Ổn Định." : "Thiết bị Đang Dao Động."

            sendTiltEvent(tiltValue: averageTilt, oscillationValue: oscillation, message: message)
        }
    }

    // MARK: - State Management (Proxy Lock/Unlock)

    @objc private func didLock() {
        guard !isScreenLocked else { return }
        isScreenLocked = true

        isDeviceStable = false

        sendEvent(type: "LOCK_EVENT", message: "Thiết bị đã Khóa (Proxy: Ứng dụng vào nền).", location: lastLocation?.toLocationString())
    }

    @objc private func didUnlock() {
        guard isScreenLocked else { return }
        isScreenLocked = false

        sendEvent(type: "UNLOCK_EVENT", message: "Thiết bị đã Mở Khóa (Proxy: Ứng dụng hoạt động).", location: lastLocation?.toLocationString())
    }

    // MARK: - Alarm Logic (Logic CẢNH BÁO)

    private func checkAlarmConditions() {
        guard isMonitoringTilt else { return }

        // CẢNH BÁO: Kích hoạt khi thiết bị được coi là Mở Khóa (proxy) VÀ nằm Rất Phẳng VÀ Rất Ổn Định (Low Oscillation)
        if !isScreenLocked {
            let tiltLow = abs(lastTiltValue) < TILT_THRESHOLD_RAD * 0.1 // Rất phẳng (ví dụ: < 7 độ)
            let oscillationLow = lastOscillationValue < OSCILLATION_THRESHOLD // Rất ổn định (dao động thấp)

            if tiltLow && oscillationLow {
                // ĐIỀU KIỆN CẢNH BÁO VI PHẠM!
                let alarmMessage = "CẢNH BÁO: MỞ KHÓA & ỔN ĐỊNH VI PHẠM!\n" +
                                   "Roll: \(lastTiltValue.to3Decimal()) rad\n" +
                                   "Oscillation: \(lastOscillationValue.to5Decimal()) rad"

                sendEvent(type: "ALARM_EVENT", message: alarmMessage, location: lastLocation?.toLocationString())
            }
        }
    }

    // MARK: - Event Sending

    // Gửi sự kiện Lock/Unlock/Alarm
    private func sendEvent(type: String, message: String, location: String? = nil) {
        guard let sink = eventSink else { return }

        // Đảm bảo timestamp là Double (mili giây)
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