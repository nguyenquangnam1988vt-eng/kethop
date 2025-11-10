// lib/main.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'dart:convert'; // Để xử lý JSON

void main() {
  runApp(const MyApp());
}

// Định nghĩa EventChannel để nhận luồng dữ liệu từ iOS
const EventChannel _eventChannel = EventChannel('com.example.app/monitor_events');

// --- Mô hình Dữ liệu (Dùng cho cả sự kiện Tilt và Lock) ---
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

  // Factory constructor để tạo đối tượng từ JSON (Map)
  factory MonitorEvent.fromJson(Map<String, dynamic> json) {
    return MonitorEvent(
      type: json['type'] as String,
      message: json['message'] as String,
      location: json['location'] as String?,
      // Fix an toàn: Xử lý trường hợp tiltValue là int hoặc double
      tiltValue: (json['tiltValue'] as num?)?.toDouble(), 
      // Chuyển đổi timestamp từ mili giây (iOS gửi) sang DateTime
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
        
        // FIX LỖI: Sử dụng ThemeData.dark().textTheme để tương thích đa nền tảng
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

// --- MonitorScreen: Hiển thị cả 2 loại sự kiện ---
class MonitorScreen extends StatefulWidget {
  const MonitorScreen({super.key});

  @override
  State<MonitorScreen> createState() => _MonitorScreenState();
}

class _MonitorScreenState extends State<MonitorScreen> {
  // Danh sách lưu trữ các sự kiện lịch sử (Lock/Unlock)
  List<MonitorEvent> _historyEvents = [];
  // Sự kiện Tilt (Nghiêng) mới nhất
  MonitorEvent? _latestTiltEvent;
  
  // Trạng thái khóa/mở màn hình hiện tại
  bool _isScreenLocked = true; // Mặc định: màn hình tắt (Locked)

  // Trạng thái kết nối kênh
  String _connectionStatus = "Đang chờ kết nối...";

  @override
  void initState() {
    super.initState();
    _startListeningToEvents();
  }

  void _startListeningToEvents() {
    // Đăng ký lắng nghe EventChannel
    _eventChannel.receiveBroadcastStream().listen(
      _onEvent,
      onError: _onError,
      onDone: _onDone,
    );
  }

  // Hàm xử lý khi nhận được dữ liệu từ iOS
  void _onEvent(dynamic event) {
    setState(() {
      _connectionStatus = "Đã kết nối";
      try {
        // Chuyển chuỗi JSON nhận được thành Map
        final Map<String, dynamic> data = jsonDecode(event as String);
        final monitorEvent = MonitorEvent.fromJson(data);

        if (monitorEvent.type == 'TILT_EVENT') {
          // Cập nhật sự kiện nghiêng mới nhất (không lưu vào lịch sử)
          _latestTiltEvent = monitorEvent;
        } else {
          // Lưu sự kiện Lock/Unlock vào lịch sử
          _historyEvents.insert(0, monitorEvent);

          // CẬP NHẬT TRẠNG THÁI KHÓA MÀN HÌNH
          // Nếu message chứa 'Mở Khóa', tức là màn hình đang Mở (isLocked = false)
          _isScreenLocked = !monitorEvent.message.contains('Mở Khóa');
        }
      } catch (e) {
        _connectionStatus = "Lỗi phân tích JSON: $e";
        print('Error decoding JSON: $e, Raw event: $event');
      }
    });
  }

  // Hàm xử lý lỗi khi kênh truyền tin gặp sự cố
  void _onError(Object error) {
    setState(() {
      _connectionStatus = "Lỗi kết nối: ${error.toString()}";
      print('EventChannel Error: $error');
    });
  }

  // Hàm xử lý khi kênh truyền tin kết thúc (hiếm khi xảy ra)
  void _onDone() {
    setState(() {
      _connectionStatus = "Kênh truyền tin đã đóng.";
    });
  }

  // --- WIDGET: HIỂN THỊ TRẠNG THÁI MỞ/TẮT MÀN HÌNH ---
  Widget _buildLockStatusCard() {
    final bool isLocked = _isScreenLocked;
    // 'Tắt' khi bị khóa, 'Mở' khi mở khóa
    final String statusText = isLocked ? 'MÀN HÌNH ĐANG TẮT' : 'MÀN HÌNH ĐANG MỞ'; 
    final Color statusColor = isLocked ? Colors.red.shade600 : Colors.green.shade600;
    final IconData statusIcon = isLocked ? Icons.lock_outline : Icons.lock_open_rounded;

    return Card(
      elevation: 8,
      // Đổi màu nền card dựa trên trạng thái (tối hơn)
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
          // Hiển thị Trạng thái Mở/Tắt màn hình (vị trí nổi bật)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: _buildLockStatusCard(),
            ),
          ),
          
          // Phần 1: Hiển thị Dữ liệu Nghiêng (Luôn cập nhật mới nhất)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: _buildTiltMonitorCard(),
            ),
          ),
          
          // Phần 2: Tiêu đề Lịch sử Lock/Unlock
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(left: 16.0, right: 16.0, top: 10.0, bottom: 8.0),
              child: Text(
                'Lịch Sử Sự Kiện (Lock/Unlock)',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(color: Colors.blueAccent),
              ),
            ),
          ),

          // Phần 3: Danh sách Lịch sử Lock/Unlock
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