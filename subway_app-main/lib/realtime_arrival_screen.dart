import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

import 'package:train_system/seat_reservation_screen.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:train_system/login_screen.dart';

// API Key provided by the user
const String apiKey = '784b4f45456a776a31313578704c5964';

class RealtimeArrivalScreen extends StatefulWidget {
  const RealtimeArrivalScreen({super.key});

  @override
  State<RealtimeArrivalScreen> createState() => _RealtimeArrivalScreenState();
}

class _RealtimeArrivalScreenState extends State<RealtimeArrivalScreen> {
  final TextEditingController _stationController = TextEditingController();
  List<dynamic> _arrivalData = [];
  bool _isLoadingArrivals = false;
  String _errorMessage = '';

  Future<void> _fetchArrivalInfo(String stationName) async {
    if (stationName.isEmpty) {
      setState(() {
        _errorMessage = '역 이름을 입력해주세요.';
      });
      return;
    }

    setState(() {
      _isLoadingArrivals = true;
      _errorMessage = '';
      _arrivalData = [];
    });

    final encodedStationName = Uri.encodeComponent(stationName);
    final url = Uri.parse(
        'http://swopenapi.seoul.go.kr/api/subway/$apiKey/json/realtimeStationArrival/0/60/$encodedStationName');

    try {
      final response = await http.get(url);
      final data = json.decode(utf8.decode(response.bodyBytes));

      if (data['errorMessage'] != null &&
          data['errorMessage']['status'] != 200) {
        setState(() {
          _errorMessage = data['errorMessage']['message'];
        });
      } else if (data['realtimeArrivalList'] != null &&
          (data['realtimeArrivalList'] as List).isNotEmpty) {
        var arrivalList = data['realtimeArrivalList'] as List;

        // Sort the list by line and then by direction
        arrivalList.sort((a, b) {
          // 1. Sort by subway line (subwayId)
          int lineCompare = a['subwayId'].compareTo(b['subwayId']);
          if (lineCompare != 0) {
            return lineCompare;
          }
          // 2. If lines are the same, sort by destination (bstatnNm)
          return a['bstatnNm'].compareTo(b['bstatnNm']);
        });

        setState(() {
          _arrivalData = arrivalList;
        });
      } else {
        setState(() {
          _errorMessage = '해당 역에 대한 도착 정보가 없습니다.';
        });
      }
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

  Future<void> _showBoardingCarDialog(Map<String, dynamic> trainInfo) async {
    final selectedCar = await showDialog<int>(
      context: context,
      builder: (BuildContext context) {
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
              itemCount: 10, // Assuming 10 cars
              itemBuilder: (context, index) {
                final carNumber = index + 1;
                return ElevatedButton(
                  child: Text('$carNumber'),
                  onPressed: () {
                    Navigator.of(context).pop(carNumber);
                  },
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

      // DEBUG: Print trainId and carNumber for the Python script
      // ignore: avoid_print
      print('DEBUG: Navigating to SeatReservationScreen with trainId: $trainId, carNumber: $carNumber');

      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => SeatReservationScreen(
            trainId: trainId,
            carNumber: carNumber,
          ),
        ),
      );
    }
  }

  Future<void> _logout() async {
    try {
      await FirebaseAuth.instance.signOut();
      if (!mounted) return;
      // 로그인 화면으로 스택을 초기화하며 이동
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
        (route) => false,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('로그아웃 실패: $e')),
      );
    }
  }

  @override
  void dispose() {
    _stationController.dispose();
    super.dispose();
  }

  Map<String, dynamic> _getLineInfo(String subwayId) {
    switch (subwayId) {
      case '1001': return {'name': '1', 'color': const Color(0xFF0052A4)};
      case '1002': return {'name': '2', 'color': const Color(0xFF00A84D)};
      case '1003': return {'name': '3', 'color': const Color(0xFFEF7C1C)};
      case '1004': return {'name': '4', 'color': const Color(0xFF00A4E3)};
      case '1005': return {'name': '5', 'color': const Color(0xFF996CAC)};
      case '1006': return {'name': '6', 'color': const Color(0xFFCD7C2F)};
      case '1007': return {'name': '7', 'color': const Color(0xFF747F00)};
      case '1008': return {'name': '8', 'color': const Color(0xFFE6186C)};
      case '1009': return {'name': '9', 'color': const Color(0xFFBDB092)};
      default: return {'name': '?', 'color': Colors.grey};
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('실시간 지하철 도착 정보'),
        actions: [
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
                    final lineInfo = _getLineInfo(item['subwayId']);
                    final lineColor = lineInfo['color'] as Color;
                    final lineName = lineInfo['name'] as String;

                    return Card(
                      margin: const EdgeInsets.symmetric(vertical: 8.0),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: lineColor,
                          child: Text(
                            lineName,
                            style: const TextStyle(
                                color: Colors.white, fontWeight: FontWeight.bold),
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
