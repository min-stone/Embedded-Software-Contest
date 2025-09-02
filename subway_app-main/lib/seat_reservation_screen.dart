import 'dart:async';

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart' show FirebaseException;
import 'package:train_system/login_screen.dart';

class SeatReservationScreen extends StatefulWidget {
  final String trainId;
  final String carNumber;

  const SeatReservationScreen({
    super.key,
    required this.trainId,
    required this.carNumber,
  });

  @override
  State<SeatReservationScreen> createState() => _SeatReservationScreenState();
}

class _SeatReservationScreenState extends State<SeatReservationScreen> {
  final _db = FirebaseFirestore.instance;
  User? get _me => FirebaseAuth.instance.currentUser;

  late final DocumentReference _carDocRef;
  late final CollectionReference _seatsCollectionRef;
  Future<void>? _initialization;

  // For the new feature
  StreamSubscription? _seatListener;
  final Set<String> _dialogsShownForSeats = {};

  @override
  void initState() {
    super.initState();
    _carDocRef = _db
        .collection('trains')
        .doc(widget.trainId)
        .collection('cars')
        .doc(widget.carNumber);
    _seatsCollectionRef = _carDocRef.collection('seats');
    _initialization = _initSeatsOnDemand().then((_) {
      _listenForOccupiedSeats();
    });
  }

  @override
  void dispose() {
    _seatListener?.cancel();
    super.dispose();
  }

  Future<void> _initSeatsOnDemand() async {
    final doc = await _carDocRef.get();
    if (!doc.exists) {
      final batch = _db.batch();
      // userSeatLookup: uid -> seatId 맵(빈 맵으로 생성)
      batch.set(_carDocRef, {
        'createdAt': FieldValue.serverTimestamp(),
        'userSeatLookup': <String, dynamic>{},
      });

      for (int i = 1; i <= 12; i++) {
        final ref = _seatsCollectionRef.doc(i.toString()); // seat doc id = seat number
        batch.set(ref, {
          'seatNumber': i,
          'isPriority': (i == 1 || i == 6), // Original priority seat logic
          'reserved': false,
          'reservedBy': null,
          'isOccupied': false,
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }
      await batch.commit();
    } else {
      // 기존 문서에 userSeatLookup 필드가 없을 수 있으므로 한 번 보정(선택적)
      if (!(doc.data() as Map<String, dynamic>).containsKey('userSeatLookup')) {
        await _carDocRef.update({'userSeatLookup': <String, dynamic>{}});
      }
    }
  }

  void _listenForOccupiedSeats() {
    if (_me == null) return;
    _seatListener = _seatsCollectionRef
        .where('reservedBy', isEqualTo: _me!.uid)
        .snapshots()
        .listen((snapshot) {
      for (final docChange in snapshot.docChanges) {
        if (docChange.type == DocumentChangeType.modified) {
          final doc = docChange.doc;
          final data = doc.data() as Map<String, dynamic>;
          final isOccupied = data['isOccupied'] ?? false;
          final seatId = doc.id;

          if (isOccupied && !_dialogsShownForSeats.contains(seatId)) {
            _showOccupiedConfirmDialog();
            _dialogsShownForSeats.add(seatId);
          }
        }
      }
    });
  }

  Future<void> _showOccupiedConfirmDialog() async {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('착석 확인'),
          content: const Text('예약하신 좌석에 앉으신 것이 맞나요?'),
          actions: <Widget>[
            TextButton(
              child: const Text('아니요'),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
            TextButton(
              child: const Text('네, 맞습니다'),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }

  Future<void> _showReservationConfirmDialog(DocumentSnapshot seatDoc) async {
    final d = seatDoc.data() as Map<String, dynamic>;
    final isCurrentlyReserved = d['reserved'] as bool;
    final isMySeat = d['reservedBy'] == _me?.uid;

    final title = isCurrentlyReserved ? '예약 취소' : '좌석 예약';
    final content = isCurrentlyReserved
        ? (isMySeat ? '이 좌석의 예약을 취소하시겠습니까?' : '다른 사용자가 예약한 좌석입니다.')
        : '이 좌석을 예약하시겠습니까?';
    final confirmActionText = isCurrentlyReserved ? '예약 취소' : '예약';

    return showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(title),
          content: Text(content),
          actions: <Widget>[
            TextButton(
              child: const Text('닫기'),
              onPressed: () => Navigator.of(context).pop(),
            ),
            if (!isCurrentlyReserved || isMySeat)
              TextButton(
                child: Text(confirmActionText),
                onPressed: () {
                  Navigator.of(context).pop();
                  _performSeatToggle(seatDoc);
                },
              ),
          ],
        );
      },
    );
  }

  // 트랜잭션에서 '좌석 도큐먼트'와 'cars/{car}/userSeatLookup.{uid}'를 함께 확인/갱신
  Future<void> _performSeatToggle(DocumentSnapshot seatDoc) async {
    final myUid = _me!.uid;
    final seatRef = seatDoc.reference;
    final seatId = seatDoc.id;

    try {
      await _db.runTransaction((tx) async {
        // 1) car 문서 읽고, 내가 이미 어떤 좌석을 갖고 있는지 확인
        final carSnap = await tx.get(_carDocRef);
        if (!carSnap.exists) {
          throw Exception('차량 정보가 존재하지 않습니다.');
        }
        final carData = carSnap.data() as Map<String, dynamic>;
        final Map<String, dynamic> userSeatLookup =
            (carData['userSeatLookup'] as Map?)?.map((k, v) => MapEntry(k.toString(), v)) ??
                <String, dynamic>{};
        final existingSeatId = userSeatLookup[myUid] as String?;

        // 2) 선택한 좌석 문서 읽기
        final snap = await tx.get(seatRef);
        if (!snap.exists) {
          throw Exception('좌석 정보가 존재하지 않습니다.');
        }
        final d = snap.data() as Map<String, dynamic>;

        // 임산부석 제한(기존 로직 유지)
        if (d['isPriority'] != true) {
          throw Exception('임산부 배려석만 선택할 수 있습니다.');
        }

        final reserved = d['reserved'] == true;
        final reservedBy = d['reservedBy'] as String?;

        if (!reserved) {
          // 예약을 새로 하려는 경우: 이미 다른 좌석을 갖고 있으면 거절
          if (existingSeatId != null && existingSeatId.isNotEmpty && existingSeatId != seatId) {
            throw Exception('이미 다른 좌석($existingSeatId)을 예약 중입니다. 먼저 취소해주세요.');
          }

          // 좌석이 비어 있고, 나도 아직 맵에 없거나(=이 좌석을 처음 예약) 같은 좌석을 다시 누른 경우만 허용
          tx.update(seatRef, {
            'reserved': true,
            'reservedBy': myUid,
            'updatedAt': FieldValue.serverTimestamp(),
          });

          // userSeatLookup.{uid} = seatId
          tx.update(_carDocRef, {
            'userSeatLookup.$myUid': seatId,
          });
        } else {
          // 이미 예약됨
          if (reservedBy == myUid) {
            // 내가 예약한 좌석이면: 취소(토글)
            tx.update(seatRef, {
              'reserved': false,
              'reservedBy': null,
              'updatedAt': FieldValue.serverTimestamp(),
            });
            // userSeatLookup에서 내 키 제거
            tx.update(_carDocRef, {
              'userSeatLookup.$myUid': FieldValue.delete(),
            });
          } else {
            // 다른 사람이 예약한 좌석
            throw Exception('이미 다른 사용자가 예약했습니다.');
          }
        }
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('처리가 완료되었습니다. (좌석: $seatId)')),
      );
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString().replaceFirst('Exception: ', '');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  Color _seatColor(Map<String, dynamic> d, String? myUid) {
    final reserved = d['reserved'] == true;
    final reservedBy = d['reservedBy'];
    final isPriority = d['isPriority'] == true;
    final isOccupied = d['isOccupied'] == true; // ← 파이썬이 쓰는 필드

    if (reserved && reservedBy == myUid) {
      return Colors.green; // 내가 예약한 좌석
    }
    if (reserved) {
      return Colors.red; // 다른 사람이 예약함
    }
    if (isOccupied) {
      return Colors.blue; // 비예약 상태지만 실제 사람이 앉아 있음
    }
    return isPriority ? Colors.pink.shade200 : Colors.grey.shade400;
  }

  Widget _seatTile(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;
    final seatNumber = d['seatNumber'] ?? 0;
    final isPriority = d['isPriority'] == true;
    final color = _seatColor(d, _me?.uid);

    return GestureDetector(
      onTap: () => _showReservationConfirmDialog(doc),
      child: Column(
        children: [
          Icon(Icons.chair_rounded, color: color, size: 40),
          Text('$seatNumber', style: const TextStyle(fontWeight: FontWeight.bold)),
          if (isPriority)
            const Text('임산부석', style: TextStyle(color: Colors.pink, fontSize: 10))
          else
            const SizedBox(height: 12),
        ],
      ),
    );
  }

  Widget _rowWithDoors(List<DocumentSnapshot> docs) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        const Text('출입문', style: TextStyle(fontSize: 16)),
        ...docs.map(_seatTile),
        const Text('출입문', style: TextStyle(fontSize: 16)),
      ],
    );
  }

  Future<void> _signOut() async {
    // 화면을 먼저 정리해서 StreamBuilder가 dispose되도록 함
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
        (route) => false,
      );
    }
    // 다음 틱에서 실제 로그아웃 실행 (현재 화면 dispose 보장)
    Future.microtask(() => FirebaseAuth.instance.signOut());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('칸 ${widget.carNumber} - 좌석 예약'),
        actions: [
          IconButton(
            onPressed: _signOut,
            icon: const Icon(Icons.logout),
            tooltip: '로그아웃',
          ),
        ],
      ),
      body: FutureBuilder<void>(
        future: _initialization,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
                child: CircularProgressIndicator(key: ValueKey('init')));
          }
          if (snapshot.hasError) {
            return Center(child: Text('오류가 발생했습니다: ${snapshot.error}'));
          }

          return StreamBuilder<QuerySnapshot>(
            stream: _seatsCollectionRef.orderBy('seatNumber').snapshots(),
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Center(
                    child: CircularProgressIndicator(key: ValueKey('stream')));
              }

              if (snap.hasError) {
                final err = snap.error;
                // 권한 오류면 조용히 로그인으로 리다이렉트
                if (err is FirebaseException && err.code == 'permission-denied') {
                  Future.microtask(() {
                    if (!mounted) return;
                    Navigator.of(context).pushAndRemoveUntil(
                      MaterialPageRoute(builder: (_) => const LoginScreen()),
                      (route) => false,
                    );
                  });
                  return const SizedBox.shrink();
                }
                return Center(child: Text('오류: ${snap.error}'));
              }

              final docs = snap.data?.docs ?? [];
              if (docs.isEmpty) {
                return const Center(
                  child: Text('좌석 정보를 불러오는 중입니다...'),
                );
              }

              final row1 =
                  docs.where((doc) => (doc['seatNumber'] as int) <= 6).toList();
              final row2 =
                  docs.where((doc) => (doc['seatNumber'] as int) > 6).toList();

              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _rowWithDoors(row1),
                      const SizedBox(height: 50),
                      _rowWithDoors(row2),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
