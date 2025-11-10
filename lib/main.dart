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

// --- Mô hình Dữ liệu (ĐÃ CẬP NHẬT với OscillationValue) ---
class MonitorEvent {
  // 'LOCK_EVENT', 'TILT_EVENT', 'UNLOCK_EVENT', 'ALARM_EVENT'
  final String type; 
  final String message;
  final String? location;
  final double? tiltValue;
  // Giá trị dao động/ổn định từ gia tốc kế
  final double? oscillationValue; 
  final DateTime timestamp;

  MonitorEvent({
    required this.type,
    required this.message,
    this.location,
    this.tiltValue,
    this.oscillationValue,
    required this.timestamp,
  });

  factory MonitorEvent.fromJson(Map<String, dynamic> json) {
    // Ép kiểu an toàn cho các giá trị số có thể là null
    final num? tiltNum = json['tiltValue'] as num?;
    final num? oscillationNum = json['oscillationValue'] as num?;
    final num? timestampNum = json['timestamp'] as num?;

    return MonitorEvent(
      type: json['type'] as String,
      message: json['message'] as String,
      location: json['location'] as String?,
      // Chuyển num? sang double?
      tiltValue: tiltNum?.toDouble(), 
      oscillationValue: oscillationNum?.toDouble(),
      // FIX: Swift gửi timestamp là Double (mili giây), phải parse là num và chuyển thành int
      timestamp: DateTime.fromMillisecondsSinceEpoch(timestampNum?.toInt() ?? 0),
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
        scaffoldBackgroundColor: const Color(0xFF121212), // Màu nền tối
        cardColor: const Color(0xFF1E1E1E), // Màu nền thẻ
        // Sử dụng theme dark và font Roboto
        textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'Roboto'), 
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF1F1F1F),
          foregroundColor: Colors.white,
          elevation: 0,
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
  
  bool _isMonitoringActive = false;
  bool _isScreenLocked = true;
  String? _warningStatus; // Cảnh báo vi phạm (null nếu không có)
  StreamSubscription? _eventSubscription;

  @override
  void initState() {
    super.initState();
    // Khởi động theo dõi ngay khi widget được tạo
    _toggleMonitoring(); 
  }

  // --- LOGIC CHẠY ỨNG DỤNG DƯỚI NỀN (MethodChannel) ---
  Future<void> _toggleMonitoring() async {
    // Sử dụng local variable để tránh race condition khi setState
    final bool willActivate = !_isMonitoringActive; 

    setState(() {
      _isMonitoringActive = willActivate;
    });

    if (willActivate) {
      try {
        // Gửi lệnh BẮT ĐẦU SERVICE NỀN đến Native (iOS)
        await _methodChannel.invokeMethod('startBackgroundService');
        _startListeningToEvents();
        setState(() => _connectionStatus = "Đã bắt đầu theo dõi và kết nối.");
      } on PlatformException catch (e) {
        setState(() {
          _isMonitoringActive = false;
          _connectionStatus = "Lỗi khi bắt đầu dịch vụ nền: ${e.message}";
        });
      }
    } else {
      try {
        // Gửi lệnh DỪNG SERVICE NỀN đến Native (iOS)
        await _methodChannel.invokeMethod('stopBackgroundService');
        _stopListeningToEvents();
        setState(() => _connectionStatus = "Đã dừng theo dõi.");
      } on PlatformException catch (e) {
        setState(() => _connectionStatus = "Lỗi khi dừng dịch vụ nền: ${e.message}");
      }
    }
  }

  void _startListeningToEvents() {
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
    // Khi dừng, xóa trạng thái cảnh báo
    setState(() {
      _warningStatus = null;
    });
  }

  // --- LOGIC XỬ LÝ SỰ KIỆN VÀ CẢNH BÁO ---
  void _onEvent(dynamic event) {
    setState(() {
      _connectionStatus = "Đã kết nối";
      try {
        final Map<String, dynamic> data = jsonDecode(event as String);
        final monitorEvent = MonitorEvent.fromJson(data);
        
        // Reset cảnh báo nếu không phải là sự kiện ALARM
        if (monitorEvent.type != 'ALARM_EVENT') {
          _warningStatus = null;
        }

        if (monitorEvent.type == 'TILT_EVENT') {
          _latestTiltEvent = monitorEvent;
        } else {
          // Xử lý LOCK, UNLOCK, và ALARM EVENTS
          // Chỉ thêm vào lịch sử nếu đó là một sự kiện Lock, Unlock hoặc Alarm rõ ràng
          if (monitorEvent.type != 'TILT_EVENT') {
            _historyEvents.insert(0, monitorEvent);
          }
          
          // CẬP NHẬT TRẠNG THÁI KHÓA MÀN HÌNH
          _isScreenLocked = !(monitorEvent.type == 'UNLOCK_EVENT' || monitorEvent.type == 'ALARM_EVENT');
          
          // XỬ LÝ SỰ KIỆN CẢNH BÁO (ALARM_EVENT)
          if (monitorEvent.type == 'ALARM_EVENT') {
            _warningStatus = 'ALARM KÍCH HOẠT: ${monitorEvent.message} - TẠI VỊ TRÍ: ${monitorEvent.location ?? 'Không xác định'}';
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

  @override
  void dispose() {
    _stopListeningToEvents();
    if (_isMonitoringActive) {
      // Đảm bảo dừng service nền khi widget bị hủy
      _methodChannel.invokeMethod('stopBackgroundService').catchError((e) {
        print('Error stopping background service on dispose: $e');
      });
    }
    super.dispose();
  }

  // --- WIDGET: THẺ CẢNH BÁO VI PHẠM ---
  Widget _buildWarningCard() {
    if (_warningStatus == null) return Container();

    return Padding(
      padding: const EdgeInsets.only(bottom: 12.0),
      child: Card(
        elevation: 10,
        color: Colors.red.shade900,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
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
                  maxLines: 5, 
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --- WIDGET: THẺ TRẠNG THÁI KHÓA MÀN HÌNH ---
  Widget _buildLockStatusCard() {
    // LỖI XUẤT HIỆN TẠI ĐÂY: _warningStatus?.contains() trả về bool?, không thể so sánh/negate trực tiếp.
    // FIX: Sử dụng (?? false) để cung cấp giá trị mặc định (false, tức là KHÔNG có cảnh báo) 
    // khi _warningStatus là null, sau đó mới áp dụng toán tử NOT (!).
    final bool isLocked = _isScreenLocked && !(_warningStatus?.contains('ALARM KÍCH HOẠT') ?? false); 
    
    final String statusText = isLocked ? 'THIẾT BỊ ĐANG KHÓA (AN TOÀN)' : 'THIẾT BỊ ĐANG MỞ KHÓA/VI PHẠM';
    final Color statusColor = isLocked ? Colors.green.shade500 : Colors.red.shade500;
    final Color backgroundColor = isLocked ? const Color(0xFF003000) : const Color(0xFF300000);
    final IconData statusIcon = isLocked ? Icons.lock_outline : Icons.lock_open_rounded;

    return Card(
      elevation: 8,
      color: backgroundColor, 
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(statusIcon, color: statusColor, size: 40),
            const SizedBox(width: 15),
            Flexible(
              child: Text(
                statusText,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                  color: statusColor,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Tạo thẻ hiển thị dữ liệu Tilt mới nhất (ĐÃ CẬP NHẬT ĐẦY ĐỦ CHỈ SỐ)
  Widget _buildTiltMonitorCard() {
    final double tiltValue = _latestTiltEvent?.tiltValue ?? 0.0;
    final double oscillationValue = _latestTiltEvent?.oscillationValue ?? 0.0;
    final String tiltMessage = _latestTiltEvent?.message ?? 'Chờ dữ liệu...';
    
    // Tính toán màu sắc dựa trên giá trị nghiêng (tiltValue)
    Color tiltColor = Colors.lightBlue;
    if (tiltValue.abs() > 0.3) {
      tiltColor = Colors.yellow.shade700;
    }
    if (tiltValue.abs() > 0.8) {
      tiltColor = Colors.orange.shade700;
    }
    if (tiltValue.abs() > 1.2) { 
      tiltColor = Colors.red.shade700;
    }

    // Tính toán màu sắc dựa trên độ ổn định (oscillationValue)
    Color oscillationColor = Colors.green.shade400;
    if (oscillationValue > 0.01) {
      oscillationColor = Colors.yellow.shade700;
    }
    if (oscillationValue > 0.05) {
      oscillationColor = Colors.red.shade700;
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
                  'Cảm Biến Nghiêng & Dao Động',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(color: Colors.white, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const Divider(color: Colors.white10, height: 20),
            
            // Chỉ số 1: Góc Nghiêng (Tilt Value)
            Text(
              'Góc Nghiêng TB 5s (Roll/Pitch): ${tiltValue.toStringAsFixed(3)} radians',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: tiltColor),
            ),
            const SizedBox(height: 8),
            
            // Chỉ số 2: Độ Dao Động (Oscillation Value)
            Text( 
              'Độ Dao Động (Ổn Định): ${oscillationValue.toStringAsFixed(5)} radians',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: oscillationColor),
            ),
            const SizedBox(height: 15),

            // Chỉ số 3: Trạng Thái & Cập Nhật
            Text(
              'Trạng Thái: $tiltMessage',
              style: const TextStyle(fontSize: 14, color: Colors.white70),
            ),
            if (_latestTiltEvent != null)
              Text(
                'Cập nhật cuối: ${_latestTiltEvent!.timestamp.toString().substring(11, 19)}',
                style: const TextStyle(fontSize: 12, color: Colors.white54),
              ),
          ],
        ),
      ),
    );
  }

  // Tạo Tile hiển thị sự kiện Lock/Unlock/Alarm
  Widget _buildLockUnlockTile(MonitorEvent event) {
    final bool isAlarm = event.type == 'ALARM_EVENT';
    final bool isUnlocked = event.type.contains('UNLOCK') || isAlarm;
    
    Color eventColor;
    IconData icon;
    String title;

    if (isAlarm) {
      eventColor = Colors.red.shade800;
      icon = Icons.error_outline;
      title = 'CẢNH BÁO VI PHẠM (ALARM)';
    } else if (isUnlocked) {
      eventColor = Colors.green.shade400;
      icon = Icons.lock_open;
      title = 'THIẾT BỊ MỞ KHÓA';
    } else {
      eventColor = Colors.red.shade400;
      icon = Icons.lock;
      title = 'THIẾT BỊ KHÓA';
    }

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4.0),
      elevation: 2,
      // Đánh dấu rõ ràng sự kiện ALARM
      color: isAlarm ? Colors.red.shade900.withOpacity(0.2) : Theme.of(context).cardColor, 
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: eventColor.withOpacity(0.6), width: 1.5),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
        leading: Icon(icon, color: eventColor, size: 32),
        title: Text(
          title,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: eventColor,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Chi tiết: ${event.message}',
              style: TextStyle(color: isAlarm ? Colors.white : Colors.white70),
            ),
            const SizedBox(height: 4),
            Text(
              'Thời gian: ${event.timestamp.toString().substring(0, 19)}',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
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
              padding: const EdgeInsets.symmetric(horizontal: 12.0),
              child: _buildLockStatusCard(),
            ),
          ),
          
          // Dữ liệu Nghiêng (Tilt) - Hiển thị đầy đủ chỉ số
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
                'Lịch Sử Sự Kiện (Lock/Unlock/Alarm)',
                style: titleStyle?.copyWith(color: Colors.blueAccent),
              ),
            ),
          ),

          // Danh sách Lịch sử Lock/Unlock/Alarm
          _historyEvents.isEmpty
              ? SliverToBoxAdapter(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32.0),
                      child: Text(
                        'Chưa có sự kiện Lock/Unlock/Alarm nào được ghi lại.',
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