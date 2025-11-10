import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math'; // Cần thiết cho tính toán sqrt

// Định nghĩa EventChannel để nhận luồng dữ liệu từ iOS/Native
const EventChannel _eventChannel = EventChannel('com.example.app/monitor_events');
// Định nghĩa MethodChannel để gửi lệnh đến Native (ví dụ: chạy nền)
const MethodChannel _methodChannel = MethodChannel('com.example.app/background_service');

const int _maxHistoryEvents = 100; // Giới hạn lịch sử tilt để tính toán phân tích

// --- Mô hình Dữ liệu ---
class MonitorEvent {
  final String type; // 'LOCK_EVENT' hoặc 'TILT_EVENT'
  final String message;
  final String? location;
  final double? tiltX;
  final double? tiltY;
  final double? tiltZ;
  final DateTime timestamp;

  MonitorEvent({
    required this.type,
    required this.message,
    this.location,
    this.tiltX,
    this.tiltY,
    this.tiltZ,
    required this.timestamp,
  });

  factory MonitorEvent.fromJson(Map<String, dynamic> json) {
    return MonitorEvent(
      type: json['type'] as String,
      message: json['message'] as String,
      location: json['location'] as String?,
      tiltX: (json['tiltX'] as num?)?.toDouble(),
      tiltY: (json['tiltY'] as num?)?.toDouble(),
      tiltZ: (json['tiltZ'] as num?)?.toDouble(),
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
        brightness: Brightness.dark,
        primarySwatch: Colors.blue,
        scaffoldBackgroundColor: const Color(0xFF121212),
        cardColor: const Color(0xFF1E1E1E),
        // Sửa lỗi Material 3: Sử dụng textTheme mặc định
        textTheme: Typography.material2021().englishLike.apply(fontFamily: 'Roboto'),
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

// --- MonitorScreen: Hiển thị và Phân tích Dữ liệu ---
class MonitorScreen extends StatefulWidget {
  const MonitorScreen({super.key});

  @override
  State<MonitorScreen> createState() => _MonitorScreenState();
}

class _MonitorScreenState extends State<MonitorScreen> {
  List<MonitorEvent> _historyEvents = [];
  MonitorEvent? _latestTiltEvent;
  String _connectionStatus = "Đang chờ kết nối...";
  String _lastRawEvent = "Chưa nhận dữ liệu thô nào.";
  
  // --- Biến Trạng Thái Mới ---
  List<MonitorEvent> _tiltHistory = [];
  double _averageTiltDeviation = 0.0;
  double _averageFluctuation = 0.0;
  String _currentLockStatus = 'KHÔNG RÕ'; // Trạng thái ban đầu
  bool _isBackgroundServiceRunning = false;
  // -------------------------

  @override
  void initState() {
    super.initState();
    _startListeningToEvents();
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  // --- Logic Xử lý Dịch vụ Nền ---
  Future<void> _toggleBackgroundService() async {
    // Đây chỉ là mô phỏng giao tiếp với Native code
    final action = _isBackgroundServiceRunning ? 'stopBackgroundService' : 'startBackgroundService';
    final message = _isBackgroundServiceRunning ? "Dịch vụ nền đã dừng." : "Dịch vụ nền đã khởi động.";
    
    try {
      // Gửi lệnh qua MethodChannel
      // Giả sử native code trả về success
      await _methodChannel.invokeMethod(action); 
      
      setState(() {
        _isBackgroundServiceRunning = !_isBackgroundServiceRunning;
      });
      _showMessage(message);
    } on PlatformException catch (e) {
      _showMessage("Lỗi: Không thể thay đổi trạng thái dịch vụ nền. (${e.message})");
    }
  }

  // --- Logic Tính toán Tilt Analytics ---
  // Tính toán độ lệch từ trạng thái nghỉ (0, 0, 1)
  double _calculateTiltDeviation(MonitorEvent event) {
    final double x = event.tiltX ?? 0.0;
    final double y = event.tiltY ?? 0.0;
    final double z = event.tiltZ ?? 0.0;
    // Độ lệch tổng thể (magnitude của vector deviation)
    // Chia cho 1.0 (vector chuẩn) để chuẩn hóa
    return sqrt(x * x + y * y + (z - 1.0) * (z - 1.0));
  }

  void _updateTiltAnalytics(MonitorEvent event) {
    final double deviation = _calculateTiltDeviation(event);

    // 1. Cập nhật lịch sử
    _tiltHistory.add(event);
    if (_tiltHistory.length > _maxHistoryEvents) {
      _tiltHistory.removeAt(0); // Giới hạn kích thước danh sách
    }

    if (_tiltHistory.isEmpty) return;

    final List<double> deviations = _tiltHistory.map((e) => _calculateTiltDeviation(e)).toList();
    final double sumDeviations = deviations.reduce((a, b) => a + b);
    final double avgDeviations = sumDeviations / deviations.length;

    // 2. Tính toán Average Fluctuation (Standard Deviation - Độ lệch chuẩn)
    final double squaredDifferences = deviations.map((d) => (d - avgDeviations) * (d - avgDeviations)).reduce((a, b) => a + b);
    final double variance = squaredDifferences / deviations.length;
    final double stdDev = sqrt(variance); // Độ lệch chuẩn

    setState(() {
      _averageTiltDeviation = avgDeviations;
      _averageFluctuation = stdDev;
    });
  }
  // ----------------------------------------

  void _startListeningToEvents() {
    _eventChannel.receiveBroadcastStream().listen(
      _onEvent,
      onError: _onError,
      onDone: _onDone,
    );
  }

  void _onEvent(dynamic event) {
    setState(() {
      _connectionStatus = "Đã kết nối";
      _lastRawEvent = event.toString(); 

      try {
        final Map<String, dynamic> data = jsonDecode(event as String);
        final monitorEvent = MonitorEvent.fromJson(data);

        if (monitorEvent.type == 'TILT_EVENT') {
          _latestTiltEvent = monitorEvent;
          _updateTiltAnalytics(monitorEvent); // Cập nhật phân tích
        } else {
          _historyEvents.insert(0, monitorEvent);
          // Cập nhật trạng thái khóa máy
          if (monitorEvent.message.contains('Mở Khóa')) {
            _currentLockStatus = 'MỞ KHÓA';
          } else if (monitorEvent.message.contains('Khóa Máy')) {
            _currentLockStatus = 'KHÓA MÁY';
          }
        }
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

  // --- Widget Mới: Thanh Trạng thái Khóa Máy ---
  PreferredSizeWidget _buildLockStatusHeader() {
    final bool isLocked = _currentLockStatus == 'KHÓA MÁY';
    final Color color = isLocked ? Colors.red.shade700 : Colors.green.shade700;
    final IconData icon = isLocked ? Icons.lock : Icons.lock_open;

    return PreferredSize(
      preferredSize: const Size.fromHeight(40.0),
      child: Container(
        color: color.withOpacity(0.8),
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Icon(icon, color: Colors.white, size: 18),
                const SizedBox(width: 8),
                Text(
                  'TRẠNG THÁI MÁY: $_currentLockStatus',
                  style: const TextStyle(
                    fontSize: 14,
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            
            // Nút Chạy Ẩn Dưới Nền
            ElevatedButton.icon(
              onPressed: _toggleBackgroundService,
              icon: Icon(_isBackgroundServiceRunning ? Icons.pause : Icons.play_arrow, size: 16),
              label: Text(_isBackgroundServiceRunning ? 'DỪNG NỀN' : 'CHẠY NỀN', style: const TextStyle(fontSize: 12)),
              style: ElevatedButton.styleFrom(
                backgroundColor: _isBackgroundServiceRunning ? Colors.grey.shade600 : Colors.blue.shade700,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --- Widget Mới: Thẻ Tilt Analytics (Phân tích Tilt) ---
  Widget _buildTiltAnalyticsCard() {
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
                Icon(Icons.analytics, color: Colors.blueAccent, size: 30),
                const SizedBox(width: 10),
                Text(
                  'Phân Tích Nghiêng (Analytics)',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(color: Colors.blueAccent, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const Divider(color: Colors.white10, height: 20),
            
            _buildAnalyticRow(
              'Giá Trị Nghiêng TB (Độ Lệch):',
              _averageTiltDeviation.toStringAsFixed(6),
              'TB Độ lệch khỏi trạng thái nghỉ.',
              Colors.green.shade400,
            ),
            _buildAnalyticRow(
              'Dao Động TB (Độ Lệch Chuẩn):',
              _averageFluctuation.toStringAsFixed(6),
              'Mức độ rung lắc, thay đổi của thiết bị.',
              Colors.orange.shade400,
            ),
            
            const SizedBox(height: 10),
            Text(
              'Tính toán dựa trên ${_tiltHistory.length} sự kiện gần nhất.',
              style: const TextStyle(fontSize: 12, color: Colors.white54),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAnalyticRow(String label, String value, String description, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                label,
                style: const TextStyle(fontSize: 16, color: Colors.white70),
              ),
              Text(
                value,
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: color),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 2.0),
            child: Text(
              description,
              style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic, color: Colors.white38),
            ),
          ),
        ],
      ),
    );
  }


  // Widget hiển thị dữ liệu Tilt mới nhất (còn lại như cũ, nhưng gọi _updateTiltAnalytics đã được thêm vào _onEvent)
  Widget _buildTiltMonitorCard() {
    final double tiltX = _latestTiltEvent?.tiltX ?? 0.0;
    final double tiltY = _latestTiltEvent?.tiltY ?? 0.0;
    final double tiltZ = _latestTiltEvent?.tiltZ ?? 0.0;
    final String tiltMessage = _latestTiltEvent?.message ?? 'Chờ dữ liệu...';
    
    // Sử dụng _calculateTiltDeviation để tính toán màu sắc nhất quán
    final double currentDeviation = _latestTiltEvent != null ? _calculateTiltDeviation(_latestTiltEvent!) : 0.0;
    
    Color tiltColor = Colors.grey;
    if (currentDeviation > 0.05) {
      tiltColor = Colors.yellow.shade700;
    }
    if (currentDeviation > 0.15) {
      tiltColor = Colors.orange.shade700;
    }
    if (currentDeviation > 0.3) {
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
                  'Dữ Liệu Gia Tốc Kế Hiện Tại',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(color: Colors.white, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const Divider(color: Colors.white10, height: 20),
            
            _buildTiltValueRow('Trục X (Nghiêng ngang):', tiltX, tiltColor),
            _buildTiltValueRow('Trục Y (Nghiêng dọc):', tiltY, tiltColor),
            _buildTiltValueRow('Trục Z (Độ sâu/Trọng lực):', tiltZ, tiltColor),

            const SizedBox(height: 15),
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

  Widget _buildTiltValueRow(String label, double value, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 16, color: Colors.white70),
          ),
          Text(
            value.toStringAsFixed(4),
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: color),
          ),
        ],
      ),
    );
  }

  // Widget hiển thị lịch sử Lock/Unlock (không đổi)
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
  
  // Widget hiển thị dữ liệu thô cuối cùng (Debug - không đổi)
  Widget _buildRawDataDebugCard() {
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      color: const Color(0xFF2C2C2C),
      margin: const EdgeInsets.all(12.0),
      child: Padding(
        padding: const EdgeInsets.all(15.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'DEBUG: Dữ Liệu Thô Cuối Cùng (Raw Event)',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: Colors.cyanAccent,
                fontWeight: FontWeight.bold,
              ),
            ),
            const Divider(color: Colors.white10, height: 10),
            const SizedBox(height: 5),
            SelectableText(
              _lastRawEvent,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: Colors.white60,
              ),
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
        // Thanh trạng thái kết nối
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
      // --- Thêm Thanh Trạng Thái Khóa Máy cố định dưới AppBar ---
      // Builder cần thiết để có thể hiển thị SnackBar (ví dụ cho nút Chạy Nền)
      body: Column(
        children: [
          _buildLockStatusHeader(), // Trạng thái Lock/Unlock & Nút Chạy Nền
          Expanded(
            child: CustomScrollView(
              slivers: [
                // Thẻ Tilt Analytics mới
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 12.0, right: 12.0, top: 12.0, bottom: 6.0),
                    child: _buildTiltAnalyticsCard(),
                  ),
                ),

                // Dữ liệu Gia Tốc Kế Hiện Tại
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 6.0),
                    child: _buildTiltMonitorCard(),
                  ),
                ),
                
                // Thẻ Debug
                SliverToBoxAdapter(
                  child: _buildRawDataDebugCard(),
                ),

                // Tiêu đề Lịch sử Lock/Unlock
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 16.0, right: 16.0, top: 10.0, bottom: 8.0),
                    child: Text(
                      'Lịch Sử Sự Kiện (Lock/Unlock)',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(color: Colors.blueAccent),
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
          ),
        ],
      ),
    );
  }
}