import Foundation
import Flutter
import CoreLocation
import CoreMotion
import UIKit

// MARK: - Constants and Structs

// Flutter Channel names
let eventChannelName = "com.example.app/monitor_events"
let methodChannelName = "com.example.app/background_service"

// Tilt threshold in radians (approx 70 degrees).
let TILT_THRESHOLD_DEGREE: Double = 70.0
let TILT_THRESHOLD_RAD: Double = TILT_THRESHOLD_DEGREE * .pi / 180.0

// Oscillation threshold (stability) - Lower value means more stable.
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
    private let tiltHistoryCapacity = 10 // Store 10 samples (0.5 seconds)
    private var lastTiltValue: Double = 0.0
    private var lastOscillationValue: Double = 0.0

    override init() {
        super.init()
        setupNotificationObservers()
        setupLocationManager()
    }

    // MARK: - FlutterStreamHandler Implementation

    // Listens for stream start (from Dart)
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        // Send current state upon connection
        sendEvent(type: "LOCK_EVENT", message: isScreenLocked ? "Thiết bị Khóa (Khởi tạo)" : "Thiết bị Mở Khóa (Khởi tạo)")
        return nil
    }

    // Listens for stream cancellation (from Dart)
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    // MARK: - Setup and Lifecycle

    // Configure CLLocationManager
    private func setupLocationManager() {
        locationManager.delegate = self
        // FIX: Use kCLLocationAccuracyBest constant
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
    }

    // Set up Lock/Unlock/Active notification observers
    private func setupNotificationObservers() {

        // FIX LỖI: Using UIApplication lifecycle notifications as reliable substitutes
        // Assumption: Device is considered "locked" or unsupervised when the app enters the background
        NotificationCenter.default.addObserver(self,
            selector: #selector(didLock),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )

        // Assumption: Device is considered "unlocked" when the app becomes active/foreground
        NotificationCenter.default.addObserver(self,
            selector: #selector(didUnlock),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )

    }

    // MARK: - Background Service Control

    // Start background service (called via MethodChannel)
    @objc func startMonitoring() {
        // Request Location authorization
        locationManager.requestWhenInUseAuthorization()
        locationManager.requestAlwaysAuthorization()

        // Start location updates
        locationManager.startUpdatingLocation()
        startLocationTimer()

        // Start Tilt monitoring
        startTiltMonitoring()
    }

    // Stop background service (called via MethodChannel)
    @objc func stopMonitoring() {
        locationManager.stopUpdatingLocation()
        stopLocationTimer()
        stopTiltMonitoring()
    }

    // MARK: - Location Monitoring

    private func startLocationTimer() {
        // Update location every 15 seconds
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

        // The location data is primarily sent when a Lock/Unlock/Alarm event occurs
        // This function ensures 'lastLocation' is always up-to-date
    }

    // MARK: - Tilt Monitoring (CoreMotion)

    private func startTiltMonitoring() {
        guard !isMonitoringTilt else { return }
        isMonitoringTilt = true

        if motionManager.isDeviceMotionAvailable {
            motionManager.deviceMotionUpdateInterval = 0.05 // 50ms

            // FIX LỖI: Use correct CMAttitudeReferenceFrame and provide OperationQueue
            motionManager.startDeviceMotionUpdates(
                using: .xArbitraryZAxis, // Correct Reference Frame
                to: OperationQueue.main // OperationQueue is MANDATORY
            ) { [weak self] (motion, error) in
                guard let self = self, let motion = motion else { return }

                // Roll (rotation around X-axis) is the most common tilt angle
                let rollAngle = motion.attitude.roll
                self.processTiltData(rollAngle: rollAngle)

                // Always check alarm after receiving new tilt data
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
        // 1. Update tilt history
        tiltHistory.append(rollAngle)
        if tiltHistory.count > tiltHistoryCapacity {
            tiltHistory.removeFirst()
        }

        // 2. Calculate Tilt Value (500ms Average)
        let averageTilt = tiltHistory.reduce(0, +) / Double(tiltHistory.count)

        // 3. Calculate Oscillation (Stability) - Standard Deviation
        let mean = averageTilt
        let sumOfSquaredDifferences = tiltHistory.reduce(0) { $0 + pow($1 - mean, 2) }
        let variance = sumOfSquaredDifferences / Double(tiltHistory.count)
        let oscillation = sqrt(variance) // Standard deviation is oscillation

        lastTiltValue = averageTilt
        lastOscillationValue = oscillation

        // 4. Send Tilt event every 500ms (10 samples)
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

        // Reset stability upon locking
        isDeviceStable = false

        sendEvent(type: "LOCK_EVENT", message: "Thiết bị đã Khóa (Ứng dụng vào nền).", location: lastLocation?.toLocationString())
    }

    @objc private func didUnlock() {
        guard isScreenLocked else { return }
        isScreenLocked = false

        sendEvent(type: "UNLOCK_EVENT", message: "Thiết bị đã Mở Khóa (Ứng dụng hoạt động).", location: lastLocation?.toLocationString())
    }

    // MARK: - Alarm Logic

    private func checkAlarmConditions() {
        guard isMonitoringTilt else { return }

        // ALARM Condition:
        // 1. Device is UNLOCKED
        // 2. Device is VERY FLAT (low tilt angle)
        // 3. Device is VERY STABLE (low oscillation)

        if !isScreenLocked {
            let tiltLow = abs(lastTiltValue) < TILT_THRESHOLD_RAD * 0.1 // Very flat (e.g., < 7 degrees)
            let oscillationLow = lastOscillationValue < OSCILLATION_THRESHOLD // Very stable (low noise)

            if tiltLow && oscillationLow {
                // VIOLATION: Device is unlocked, flat, and stable.
                let alarmMessage = "MỞ KHÓA & ỔN ĐỊNH VI PHẠM!\n" +
                                   "Roll: \(lastTiltValue.to3Decimal()) rad\n" +
                                   "Oscillation: \(lastOscillationValue.to5Decimal()) rad"

                sendEvent(type: "ALARM_EVENT", message: alarmMessage, location: lastLocation?.toLocationString())
            }
        }
    }

    // MARK: - Event Sending

    // Send Lock/Unlock/Alarm events
    private func sendEvent(type: String, message: String, location: String? = nil) {
        guard let sink = eventSink else { return }

        // Ensure timestamp is Double (milliseconds)
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

    // Send Tilt events
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