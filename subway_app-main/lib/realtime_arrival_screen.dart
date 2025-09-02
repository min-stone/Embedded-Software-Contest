import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

import 'package:train_system/seat_reservation_screen.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:train_system/login_screen.dart';

// API Key provided by the user
const String apiKey = '784b4f45456a776a31313578704c5964';

/// Demo-only train mapping for vision pipeline (detect2roi_final.py).
/// These must match TRAIN_ID and CAR_NUMBER in detect2roi_final.py.
const String kDemoTrainId = '1002-9999';
const String kDemoCarNumber = '1';

class RealtimeArrivalScreen extends StatefulWidget {
  const RealtimeArrivalScreen({super.key});

  @override
  State<RealtimeArrivalScreen> createState() => _RealtimeArrivalScreenState();
}

class _RealtimeArrivalScreenState extends State<RealtimeArrivalScreen> {
  final TextEditingController _stationController = TextEditingController(text: '강남');
  bool _isLoadingArrivals = false;
  String _errorMessage = '';
  List<Map<String, dynamic>> _arrivalData = [];

  @override
  void initState() {
    super.initState();
    _fetchArrivalInfo(_stationController.text);
  }

  Future<void> _logout() async {
    await FirebaseAuth.instance.signOut();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (_) => false,
    );
  }

  Future<void> _fetchArrivalInfo(String stationName) async {
    if (stationName.trim().isEmpty) return;
    setState(() {
      _isLoadingArrivals = true;
      _errorMessage = '';
    });

    try {
      final url = Uri.parse(
        'http://swopenapi.seoul.go.kr/api/subway/$apiKey/json/realtimeStationArrival/0/30/$stationName',
      );
      final resp = await http.get(url);
      if (resp.statusCode != 200) {
        throw Exception('HTTP ${resp.statusCode}');
      }
      final data = jsonDecode(resp.body);

      if (data['errorMessage']?['status'] != 200) {
        throw Exception(data['errorMessage']?['message'] ?? 'API Error');
      }

      final List list = (data['realtimeArrivalList'] ?? []) as List;
      _arrivalData = list.cast<Map<String, dynamic>>();
    } catch (e) {
      setState(() {
        _errorMessage = '데이터를 불러오는 중 오류가 발생했습니다: $e';
      });
    } finally {
      setState(() {
        _isLoadingArrivals = false;
      });
    }
  }

  void _showBoardingCarDialog(Map<String, dynamic> trainInfo) async {
    final selectedCar = await showDialog<int>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('탑승 칸 선택'),
          content: SizedBox(
            width: double.maxFinite,
            child: GridView.builder(
              shrinkWrap: true,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
              ),
              itemCount: 10, // 10칸 가정
              itemBuilder: (context, index) {
                final carNumber = index + 1;
                return ElevatedButton(
                  child: Text('$carNumber'),
                  onPressed: () => Navigator.of(context).pop(carNumber),
                );
              },
            ),
          ),
        );
      },
    );

    if (selectedCar != null) {
      final trainId = '${trainInfo['subwayId']}-${trainInfo['btrainNo']}';
      final carNumber = selectedCar.toString();

      // DEBUG
      // ignore: avoid_print
      print('DEBUG: Navigating to SeatReservationScreen with trainId: $trainId, carNumber: $carNumber');

      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => SeatReservationScreen(
            trainId: trainId,
            carNumber: carNumber,
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('실시간 지하철 도착 정보'),
        actions: [
          // --- DEMO 진입(상단 버튼) ---
          IconButton(
            tooltip: 'DEMO',
            icon: const Icon(Icons.play_circle_outline),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const SeatReservationScreen(
                    trainId: kDemoTrainId,
                    carNumber: kDemoCarNumber,
                  ),
                ),
              );
            },
          ),
          IconButton(
            tooltip: '로그아웃',
            icon: const Icon(Icons.logout),
            onPressed: _logout,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            // Station Text Input
            TextField(
              controller: _stationController,
              decoration: InputDecoration(
                labelText: '역 이름을 입력하세요',
                hintText: '예: 강남, 시청',
                suffixIcon: IconButton(
                  icon: const Icon(Icons.search),
                  onPressed: () => _fetchArrivalInfo(_stationController.text),
                ),
              ),
              onSubmitted: (stationName) => _fetchArrivalInfo(stationName),
            ),
            const SizedBox(height: 20),

            // --- DEMO 열차(목록 상단 카드) ---
            Card(
              child: ListTile(
                leading: const Icon(Icons.play_circle_outline),
                title: const Text('DEMO 열차 (Vision 테스트)'),
                subtitle: const Text('trainId: 1002-9999 · car: 1'),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const SeatReservationScreen(
                        trainId: kDemoTrainId,
                        carNumber: kDemoCarNumber,
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 12),

            // Arrival Info List
            if (_isLoadingArrivals)
              const Center(child: CircularProgressIndicator())
            else if (_errorMessage.isNotEmpty)
              Text(_errorMessage, style: const TextStyle(color: Colors.red))
            else
              Expanded(
                child: ListView.builder(
                  itemCount: _arrivalData.length,
                  itemBuilder: (context, index) {
                    final item = _arrivalData[index];
                    return Card(
                      child: ListTile(
                        leading: Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primary,
                            shape: BoxShape.circle,
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            '${item['subwayId'] ?? ''}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        title: Text('${item['bstatnNm']}행 - ${item['arvlMsg2']}'),
                        subtitle: Text('업데이트: ${item['recptnDt']}'),
                        onTap: () => _showBoardingCarDialog(item),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
