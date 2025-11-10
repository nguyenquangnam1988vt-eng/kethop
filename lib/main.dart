// lib/main.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'dart:convert';

// Định nghĩa EventChannel để nhận luồng dữ liệu từ iOS
const EventChannel _eventChannel = EventChannel('com.example.app/monitor_events');
// Định nghĩa MethodChannel để gửi lệnh đến iOS (ví dụ: bắt đầu/dừng service nền)
const MethodChannel _methodChannel = MethodChannel('com.example.app/background_service');

void main() {
  runApp(const MyApp());
}

// --- Mô hình Dữ liệu ---
class MonitorEvent {
  final String type; // 'LOCK_EVENT' hoặc 'TILT_EVENT'
  final String message;
  final String? location;
  final double? tiltValue;
  final DateTime timestamp;

  MonitorEvent({
    required this.type,
    required this.message,
    this.location,
    this.tiltValue,
    required this.timestamp,
  });

  factory MonitorEvent.fromJson(Map<String, dynamic> json) {
    return MonitorEvent(
      type: json['type'] as String,
      message: json['message'] as String,
      location: json['location'] as String?,
      // FIX LỖI: Xử lý an toàn cho tiltValue (num -> double)
      tiltValue: (json['tiltValue'] as num?)?.toDouble(),
      timestamp: DateTime.fromMillisecondsSinceEpoch(json['timestamp'] as int),
    );
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Unlock & Tilt Monitor',
      theme: ThemeData(
        // Thiết lập chủ đề tối (Dark Theme) làm mặc định
        brightness: Brightness.dark,
        primarySwatch: Colors.blue,
        scaffoldBackgroundColor: const Color(0xFF121212), // Màu nền tối
        cardColor: const Color(0xFF1E1E1E), // Màu nền thẻ
        
        // FIX LỖI: Thay thế Typography.white bằng ThemeData.dark().textTheme
        // Đảm bảo tương thích trên mọi nền tảng
        textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'Roboto'),
        
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF1F1F1F),
          foregroundColor: Colors.white,
        ),
        colorScheme: ColorScheme.fromSwatch(
          primarySwatch: Colors.blue,
          brightness: Brightness.dark,
        ).copyWith(secondary: Colors.blueAccent),
      ),
      home: const MonitorScreen(),
    );
  }
}

class MonitorScreen extends StatefulWidget {
  const MonitorScreen({super.key});

  @override
  State<MonitorScreen> createState() => _MonitorScreenState();
}

class _MonitorScreenState extends State<MonitorScreen> {
  // State variables
  List<MonitorEvent> _historyEvents = [];
  MonitorEvent? _latestTiltEvent;
  String _connectionStatus = "Đang chờ kết nối...";
  
  // --- BIẾN MỚI ---
  bool _isMonitoringActive = false; // Trạng thái Bắt đầu/Dừng theo dõi
  bool _isScreenLocked = true; // Mặc định là Khóa (Locked)
  String? _warningStatus; // Cảnh báo vi phạm (null nếu không có)
  StreamSubscription? _eventSubscription;

  @override
  void initState() {
    super.initState();
    // Bắt đầu lắng nghe sự kiện khi ứng dụng chạy lần đầu
    _toggleMonitoring(); 
  }

  // --- LOGIC CHẠY ỨNG DỤNG DƯỚI NỀN (MethodChannel) ---
  Future<void> _toggleMonitoring() async {
    setState(() {
      _isMonitoringActive = !_isMonitoringActive;
    });

    if (_isMonitoringActive) {
      // 1. Gửi lệnh BẮT ĐẦU SERVICE NỀN đến Native (iOS)
      try {
        await _methodChannel.invokeMethod('startBackgroundService');
        _startListeningToEvents();
        setState(() => _connectionStatus = "Đã bắt đầu theo dõi và kết nối.");
      } on PlatformException catch (e) {
        setState(() {
          _isMonitoringActive = false; // Thất bại thì dừng lại
          _connectionStatus = "Lỗi khi bắt đầu dịch vụ nền: ${e.message}";
        });
      }
    } else {
      // 2. Gửi lệnh DỪNG SERVICE NỀN đến Native (iOS)
      try {
        await _methodChannel.invokeMethod('stopBackgroundService');
        _stopListeningToEvents();
        setState(() => _connectionStatus = "Đã dừng theo dõi.");
      } on PlatformException catch (e) {
        setState(() => _connectionStatus = "Lỗi khi dừng dịch vụ nền: ${e.message}");
      }
    }
  }

  void _startListeningToEvents() {
    // Ngăn chặn việc đăng ký lắng nghe nhiều lần
    _eventSubscription?.cancel();

    _eventSubscription = _eventChannel.receiveBroadcastStream().listen(
      _onEvent,
      onError: _onError,
      onDone: _onDone,
    );
  }

  void _stopListeningToEvents() {
    _eventSubscription?.cancel();
    _eventSubscription = null;
  }

  // --- LOGIC XỬ LÝ SỰ KIỆN VÀ CẢNH BÁO ---
  void _checkAndSetWarning() {
    // Điều kiện CẢNH BÁO (VI PHẠM):
    // 1. Theo dõi đang BẬT (_isMonitoringActive)
    // 2. Màn hình đang MỞ (!_isScreenLocked)
    // 3. Góc nghiêng (tiltValue) < 70% (khoảng 0.7 radians)
    // 4. Góc nghiêng (tiltValue) < 1.5 (dao động thấp, tức là thiết bị ổn định)
    
    if (_isMonitoringActive && !_isScreenLocked) {
      final double currentTilt = (_latestTiltEvent?.tiltValue ?? 0.0).abs();
      
      // Giả sử 70% tilt value là 0.7 radians (do góc nghiêng thường đo bằng radians)
      const double TILT_THRESHOLD = 0.7; 
      const double Z_FLUCTUATION_THRESHOLD = 1.5; // Giả sử đây là ngưỡng ổn định
      
      if (currentTilt < TILT_THRESHOLD && currentTilt < Z_FLUCTUATION_THRESHOLD) {
        // Nếu thiết bị được MỞ KHÓA và đang ở trạng thái KHÁ PHẲNG/ỔN ĐỊNH
        _warningStatus = 'CẢNH BÁO VI PHẠM: Thiết bị mở khóa & Ổn Định (${currentTilt.toStringAsFixed(3)} rad)';
      } else {
        _warningStatus = null;
      }
    } else {
      _warningStatus = null;
    }
  }

  void _onEvent(dynamic event) {
    setState(() {
      _connectionStatus = "Đã kết nối";
      try {
        final Map<String, dynamic> data = jsonDecode(event as String);
        final monitorEvent = MonitorEvent.fromJson(data);

        if (monitorEvent.type == 'TILT_EVENT') {
          _latestTiltEvent = monitorEvent;
        } else {
          _historyEvents.insert(0, monitorEvent);
          // CẬP NHẬT TRẠNG THÁI KHÓA MÀN HÌNH
          _isScreenLocked = !monitorEvent.message.contains('Mở Khóa');
        }
        
        // KIỂM TRA CẢNH BÁO sau khi cập nhật dữ liệu mới
        _checkAndSetWarning();

      } catch (e) {
        _connectionStatus = "Lỗi phân tích JSON: $e";
        print('Error decoding JSON: $e, Raw event: $event');
      }
    });
  }

  void _onError(Object error) {
    setState(() {
      _connectionStatus = "Lỗi kết nối: ${error.toString()}";
      print('EventChannel Error: $error');
    });
  }

  void _onDone() {
    setState(() {
      _connectionStatus = "Kênh truyền tin đã đóng.";
    });
  }

  @override
  void dispose() {
    _stopListeningToEvents();
    // Đảm bảo MethodChannel được gọi để dừng service nếu đang chạy
    if (_isMonitoringActive) {
      _methodChannel.invokeMethod('stopBackgroundService').catchError((e) {
        print('Error stopping background service on dispose: $e');
      });
    }
    super.dispose();
  }

  // --- WIDGET: THẺ CẢNH BÁO VI PHẠM ---
  Widget _buildWarningCard() {
    if (_warningStatus == null) return Container();

    return Card(
      elevation: 10,
      color: Colors.red.shade900,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 35),
            const SizedBox(width: 15),
            Expanded(
              child: Text(
                _warningStatus!,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --- WIDGET: THẺ TRẠNG THÁI KHÓA MÀN HÌNH ---
  Widget _buildLockStatusCard() {
    final bool isLocked = _isScreenLocked;
    final String statusText = isLocked ? 'MÀN HÌNH ĐANG KHÓA' : 'MÀN HÌNH ĐANG MỞ';
    final Color statusColor = isLocked ? Colors.red.shade600 : Colors.green.shade600;
    final IconData statusIcon = isLocked ? Icons.lock_outline : Icons.lock_open_rounded;

    return Card(
      elevation: 8,
      color: isLocked ? const Color(0xFF300000) : const Color(0xFF003000), 
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(statusIcon, color: statusColor, size: 40),
            const SizedBox(width: 15),
            Text(
              statusText,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w900,
                color: statusColor,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Tạo thẻ hiển thị dữ liệu Tilt mới nhất
  Widget _buildTiltMonitorCard() {
    final double tiltValue = _latestTiltEvent?.tiltValue ?? 0.0;
    final String tiltMessage = _latestTiltEvent?.message ?? 'Chờ dữ liệu...';
    
    // Tính toán màu sắc dựa trên giá trị nghiêng
    Color tiltColor = Colors.grey;
    if (tiltValue.abs() > 0.05) {
      tiltColor = Colors.yellow.shade700;
    }
    if (tiltValue.abs() > 0.1) {
      tiltColor = Colors.orange.shade700;
    }
    if (tiltValue.abs() > 0.2) {
      tiltColor = Colors.red.shade700;
    }

    return Card(
      elevation: 6,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.screen_rotation, color: tiltColor, size: 30),
                const SizedBox(width: 10),
                // Fix cho TextTheme
                Text(
                  'Cảm Biến Nghiêng (Gia Tốc Kế)',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(color: Colors.white, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const Divider(color: Colors.white10, height: 20),
            Text(
              'Góc Nghiêng Hiện Tại (Z-Axis): ${tiltValue.toStringAsFixed(3)} radians',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: tiltColor),
            ),
            const SizedBox(height: 8),
            Text(
              'Trạng Thái: $tiltMessage',
              style: const TextStyle(fontSize: 14, color: Colors.white70),
            ),
            if (_latestTiltEvent != null)
              Text(
                'Cập nhật: ${_latestTiltEvent!.timestamp.toString().substring(11, 19)}',
                style: const TextStyle(fontSize: 12, color: Colors.white54),
              ),
          ],
        ),
      ),
    );
  }

  // Tạo Tile hiển thị sự kiện Lock/Unlock
  Widget _buildLockUnlockTile(MonitorEvent event) {
    final bool isUnlocked = event.message.contains('Mở Khóa');
    final Color eventColor = isUnlocked ? Colors.green.shade400 : Colors.red.shade400;
    final IconData icon = isUnlocked ? Icons.lock_open : Icons.lock;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4.0),
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: eventColor.withOpacity(0.3), width: 1),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
        leading: Icon(icon, color: eventColor, size: 32),
        title: Text(
          event.message,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: eventColor,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Thời gian: ${event.timestamp.toString().substring(0, 19)}',
              style: const TextStyle(color: Colors.white70),
            ),
            if (event.location != null)
              Text(
                'Vị trí: ${event.location}',
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Sử dụng headline6 (đã bị deprecate) thay bằng titleLarge để tránh cảnh báo, 
    // nhưng giữ nguyên styling tương đương nếu được
    final titleStyle = Theme.of(context).textTheme.titleLarge;
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('Theo Dõi Mở Khóa & Nghiêng Thiết Bị'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(24.0),
          child: Container(
            color: Colors.white12,
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 4.0),
            child: Text(
              'Trạng thái kênh: $_connectionStatus',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Colors.white70),
            ),
          ),
        ),
      ),
      body: CustomScrollView(
        slivers: [
          // Nút BẮT ĐẦU/DỪNG THEO DÕI
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: ElevatedButton.icon(
                onPressed: _toggleMonitoring,
                icon: Icon(
                  _isMonitoringActive ? Icons.pause_circle_filled : Icons.play_circle_fill,
                  size: 30,
                ),
                label: Text(
                  _isMonitoringActive ? 'DỪNG THEO DÕI' : 'BẮT ĐẦU THEO DÕI',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _isMonitoringActive ? Colors.red.shade700 : Colors.green.shade700,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 20),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                  elevation: 8,
                ),
              ),
            ),
          ),

          // THẺ CẢNH BÁO VI PHẠM (nếu có)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12.0),
              child: _buildWarningCard(),
            ),
          ),
          
          // THẺ TRẠNG THÁI KHÓA/MỞ
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: _buildLockStatusCard(),
            ),
          ),
          
          // Dữ liệu Nghiêng (Tilt)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: _buildTiltMonitorCard(),
            ),
          ),
          
          // Tiêu đề Lịch sử Lock/Unlock
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(left: 16.0, right: 16.0, top: 10.0, bottom: 8.0),
              child: Text(
                'Lịch Sử Sự Kiện (Lock/Unlock)',
                style: titleStyle?.copyWith(color: Colors.blueAccent),
              ),
            ),
          ),

          // Danh sách Lịch sử Lock/Unlock
          _historyEvents.isEmpty
              ? SliverToBoxAdapter(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32.0),
                      child: Text(
                        'Chưa có sự kiện Lock/Unlock nào được ghi lại.',
                        style: TextStyle(color: Colors.white70, fontSize: 16),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                )
              : SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12.0),
                        child: _buildLockUnlockTile(_historyEvents[index]),
                      );
                    },
                    childCount: _historyEvents.length,
                  ),
                ),
        ],
      ),
    );
  }
}