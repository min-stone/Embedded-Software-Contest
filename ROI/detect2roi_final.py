#!/usr/bin/env python3
# detect2roi_final.py
# - 파라미터 없이 실행(상단 상수로 설정)
# - YOLO 좌석 점유 추정 → 같은 상태가 HOLD_SEC 이상 유지될 때만 Firestore 반영
# - Firestore 경로: /trains/{TRAIN_ID}/cars/{CAR_NUMBER}/seats/{seatId}
# - 갱신 필드: isOccupied, visionUpdatedAt (reserved/reservedBy는 건드리지 않음)

import os, sys, json, time
import numpy as np
import cv2
from ultralytics import YOLO

# -------------------- [설정] --------------------
VIDEO_SRC    = 'test_video2.mp4'   # '0' → 웹캠, 그 외는 파일 경로
MODEL_PATH   = 'yolov8n-pose.pt'
ROI_JSON     = 'seat_roi.json'
CONF         = 0.3
SERVICE_KEY  = 'hahaha-79a4a-77a0d09dc1d4.json'
HOLD_SEC     = 1.0

TRAIN_ID     = '1002-9999'  # ★ Flutter와 동일하게 맞추기
CAR_NUMBER   = '1'          # ★ Flutter와 동일하게 맞추기

# ⚡ 프레임 스킵(추론 간격): 1이면 스킵 안 함, 2면 2프레임에 1번 추론
FRAME_STRIDE = 2
# ------------------------------------------------

# -------------------- Firestore --------------------
_FIREBASE_OK = False
_db = None
_SEAT_DOC_CACHE = {}  # "seatNumber(str)" -> doc.reference
_LAST_WRITTEN_OCC = {}  # "seatId(str)" -> bool, 마지막으로 Firestore에 쓴 점유 상태

try:
    import firebase_admin
    from firebase_admin import credentials, firestore
except Exception:
    firebase_admin = None
    credentials = None
    firestore = None

def init_firestore():
    """SERVICE_KEY로 Firestore 초기화. 실패하면 비활성화."""
    global _FIREBASE_OK, _db
    if firebase_admin is None or credentials is None or firestore is None:
        print("[WARN] firebase_admin 모듈을 사용할 수 없어 Firestore 연동을 비활성화합니다.")
        _FIREBASE_OK = False
        return
    if not SERVICE_KEY or not os.path.exists(SERVICE_KEY):
        print(f"[WARN] 서비스 키 파일을 찾을 수 없습니다: {SERVICE_KEY!r} → Firestore 비활성화")
        _FIREBASE_OK = False
        return
    try:
        cred = credentials.Certificate(SERVICE_KEY)
        try:
            firebase_admin.initialize_app(cred)
        except ValueError:
            pass  # 이미 초기화됨
        _db = firestore.client()
        _FIREBASE_OK = True
        print(f"[Firestore] OK. target=/trains/{TRAIN_ID}/cars/{CAR_NUMBER}/seats/*")
    except Exception as e:
        print(f"[WARN] Firestore 초기화 실패: {e} → Firestore 비활성화")
        _FIREBASE_OK = False

def seats_collection():
    """당신의 DB 스키마로 경로 구성"""
    return (_db.collection("trains")
              .document(str(TRAIN_ID))
              .collection("cars")
              .document(str(CAR_NUMBER))
              .collection("seats"))

def build_seat_doc_cache():
    """해당 칸(seats)에서 seatNumber로 문서를 찾아 캐시에 올림(성능용)"""
    _SEAT_DOC_CACHE.clear()
    if not _FIREBASE_OK:
        return
    try:
        for doc in seats_collection().stream():
            data = doc.to_dict() or {}
            sn = data.get("seatNumber")
            if sn is not None:
                _SEAT_DOC_CACHE[str(sn)] = doc.reference
    except Exception as e:
        print(f"[WARN] 좌석 캐시 구축 실패: {e}")

def write_occupancy_to_firestore(occ: dict):
    """
    occ: {"1": True, "2": False, ...}
    - seatNumber 로 기존 문서를 찾되 없으면 문서ID=seatNumber 로 생성
    - 비전 결과는 isOccupied 갱신
    - 추가: isOccupied 가 True->False 로 바뀌는 "하강 에지"에서 reserved 를 False 로 자동 해제 + reservedBy 삭제
    """
    if not _FIREBASE_OK:
        return

    global _LAST_WRITTEN_OCC
    col = seats_collection()
    batch = _db.batch()

    # 하강 에지(occupied True -> False) 좌석 계산
    falling_keys = set()
    for sid_raw, taken in occ.items():
        key = str(int(sid_raw))      # "05" -> "5"
        prev = _LAST_WRITTEN_OCC.get(key)
        curr = bool(taken)
        if prev is True and curr is False:
            falling_keys.add(key)

    try:
        for sid_raw, taken in occ.items():
            key = str(int(sid_raw))
            ref = _SEAT_DOC_CACHE.get(key)

            if ref is None:
                # 문서 캐시 없으면 find-or-create
                q = col.where("seatNumber", "==", int(key)).limit(1).stream()
                found = None
                for d in q: found = d
                if found is None:
                    ref = col.document(key)
                else:
                    ref = found.reference
                _SEAT_DOC_CACHE[key] = ref

            # 기본 갱신 필드
            data = {
                "seatNumber": int(key),
                "isOccupied": bool(taken),
                "visionUpdatedAt": firestore.SERVER_TIMESTAMP
            }

            # 하강 에지에서 예약 해제 + 예약자 삭제
            if key in falling_keys:
                data["reserved"] = False
                from firebase_admin import firestore as _fs
                data["reservedBy"] = _fs.DELETE_FIELD

            print(f"[Firestore] upsert /trains/{TRAIN_ID}/cars/{CAR_NUMBER}/seats/{key}  "
                  f"isOccupied={bool(taken)}"
                  f"{'  (clear reserved)' if key in falling_keys else ''}")

            batch.set(ref, data, merge=True)

        batch.commit()

        # 마지막으로 쓴 상태 캐싱(다음 호출에서 에지 판별용)
        _LAST_WRITTEN_OCC = {str(int(k)): bool(v) for k, v in occ.items()}

    except Exception as e:
        print(f"[WARN] Firestore 쓰기 실패: {e}")

# ---------------------------------------------------

# -------------------- 비전 유틸 --------------------
def poly_centroid(poly: np.ndarray):
    M = cv2.moments(poly)
    if abs(M['m00']) < 1e-6:
        return tuple(poly.mean(axis=0).astype(int))
    cx = int(M['m10'] / M['m00']); cy = int(M['m01'] / M['m00'])
    return (cx, cy)

def point_in_poly(pt, poly):
    return cv2.pointPolygonTest(poly, pt, False) >= 0

def bbox_iou_xyxy(a, b):
    ax1,ay1,ax2,ay2 = a; bx1,by1,bx2,by2 = b
    ix1, iy1 = max(ax1,bx1), max(ay1,by1)
    ix2, iy2 = min(ax2,bx2), min(ay2,by2)
    iw, ih = max(0, ix2-ix1), max(0, iy2-iy1)
    inter = iw * ih
    if inter <= 0: return 0.0
    area_a = (ax2-ax1)*(ay2-ay1); area_b = (bx2-bx1)*(by2-by1)
    return inter / (area_a + area_b - inter + 1e-6)

def load_and_scale_rois(roi_path, target_w, target_h):
    """ROI JSON에 meta.ref_w/ref_h가 있으면 스케일링"""
    data = json.load(open(roi_path, "r", encoding="utf-8"))
    if isinstance(data, dict) and "meta" in data and "rois" in data:
        ref_w = data["meta"].get("ref_w", target_w)
        ref_h = data["meta"].get("ref_h", target_h)
        raw = data["rois"]
    else:
        ref_w, ref_h = target_w, target_h
        raw = data
    sx = target_w / float(ref_w); sy = target_h / float(ref_h)
    rois = {str(sid): (np.array(pts, np.float32) * [sx, sy]).astype(np.int32)
            for sid, pts in raw.items()}
    return rois
# ---------------------------------------------------

# -------------------- 점유 계산 --------------------
def compute_occupancy(img, model, rois, seat_centers, conf=0.3):
    res = model(img, conf=conf, verbose=False, device='cpu')[0]  # CPU 고정
    boxes_xyxy = res.boxes.xyxy.cpu().numpy() if res.boxes is not None else np.empty((0,4))
    use_pose   = (res.keypoints is not None) and (res.keypoints.xy is not None)

    anchor_points = []
    if use_pose:
        kps = res.keypoints.xy.cpu().numpy()  # [N,17,2]
        for i, xyxy in enumerate(boxes_xyxy):
            if i >= len(kps):
                x1,y1,x2,y2 = xyxy
                anchor_points.append((int((x1+x2)/2), int(y2))); continue
            left_hip  = kps[i, 11]; right_hip = kps[i, 12]
            if np.all(left_hip > 0) and np.all(right_hip > 0):
                ax = int((left_hip[0] + right_hip[0]) / 2)
                ay = int((left_hip[1] + right_hip[1]) / 2)
                anchor_points.append((ax, ay))
            else:
                x1,y1,x2,y2 = xyxy
                anchor_points.append((int((x1+x2)/2), int(y2)))
    else:
        for xyxy in boxes_xyxy:
            x1,y1,x2,y2 = xyxy
            anchor_points.append((int((x1+x2)/2), int(y2)))

    assigned_seat = {}
    taken_seats   = set()

    # 1차: 폴리곤 내부 여부
    for i, (ax, ay) in enumerate(anchor_points):
        candidates = [sid for sid, poly in rois.items() if point_in_poly((ax, ay), poly)]
        if len(candidates) == 1:
            if candidates[0] not in taken_seats:
                assigned_seat[i] = candidates[0]; taken_seats.add(candidates[0])
        elif len(candidates) > 1:
            best = None; best_d = 1e9
            for sid in candidates:
                cx, cy = seat_centers[sid]
                d = (ax-cx)**2 + (ay-cy)**2
                if sid not in taken_seats and d < best_d:
                    best_d = d; best = sid
            if best is not None:
                assigned_seat[i] = best; taken_seats.add(best)

    # 2차: 근접 + IoU 보완
    H, W = img.shape[:2]
    th_pix = max(H, W) * 0.06
    t_iou  = 0.02
    for i, (ax, ay) in enumerate(anchor_points):
        if i in assigned_seat: continue
        order = sorted(rois.keys(), key=lambda sid: (ax-seat_centers[sid][0])**2 + (ay-seat_centers[sid][1])**2)
        for sid in order:
            if sid in taken_seats: continue
            cx, cy = seat_centers[sid]
            d = ((ax-cx)**2 + (ay-cy)**2) ** 0.5
            if d > th_pix: continue
            x1,y1,x2,y2 = boxes_xyxy[i]
            rx, ry, rw, rh = cv2.boundingRect(rois[sid])
            iou = bbox_iou_xyxy([x1,y1,x2,y2], [rx,ry,rx+rw,ry+rh])
            if iou >= t_iou:
                assigned_seat[i] = sid; taken_seats.add(sid); break

    occupied = {str(sid): False for sid in rois.keys()}
    for _, sid in assigned_seat.items():
        occupied[str(sid)] = True
    return occupied
# ---------------------------------------------------

def is_image(path):
    ext = os.path.splitext(path)[1].lower()
    return ext in ['.jpg', '.jpeg', '.png', '.bmp', '.webp', '.tif', '.tiff']

def states_equal(a, b):
    if a is None or b is None: return False
    if len(a) != len(b): return False
    for k in a.keys():
        if a[k] != b.get(k): return False
    return True

def main():
    # Firestore 준비
    init_firestore()
    if _FIREBASE_OK:
        build_seat_doc_cache()

    # YOLO (CPU)
    model = YOLO(MODEL_PATH)
    model.to('cpu')

    src = VIDEO_SRC

    # --- 웹캠 ---
    if src == '0':
        cap = cv2.VideoCapture(0)
        if not cap.isOpened():
            print('웹캠을 열 수 없습니다.'); sys.exit(1)

        fno = 0
        rois = None
        seat_centers = None

        stable_state = None
        pending_state = None
        pending_since = None
        start_ts = time.time()

        while True:
            ok, frame = cap.read()
            if not ok: break
            fno += 1

            if rois is None:
                H, W = frame.shape[:2]
                rois = load_and_scale_rois(ROI_JSON, W, H)
                rois = {str(k): np.array(v, np.int32) for k, v in rois.items()}
                seat_centers = {str(sid): poly_centroid(poly) for sid, poly in rois.items()}

            # ⚡ 프레임 스킵: N프레임마다 한 번만 추론
            if FRAME_STRIDE > 1 and (fno % FRAME_STRIDE != 0):
                if cv2.waitKey(1) & 0xFF == ord('q'):
                    break
                continue

            t = time.time() - start_ts
            occ = compute_occupancy(frame, model, rois, seat_centers, conf=CONF)

            # 디바운스
            if stable_state is None:
                if pending_state is None or not states_equal(occ, pending_state):
                    pending_state = occ.copy(); pending_since = t
                else:
                    if (t - pending_since) >= HOLD_SEC:
                        stable_state = pending_state.copy()
                        print(json.dumps({"frame": fno, "t": round(t,3), "seats": stable_state}, ensure_ascii=False))
                        write_occupancy_to_firestore(stable_state)
            else:
                if states_equal(occ, stable_state):
                    pending_state = None; pending_since = None
                else:
                    if pending_state is None or not states_equal(occ, pending_state):
                        pending_state = occ.copy(); pending_since = t
                    else:
                        if (t - pending_since) >= HOLD_SEC:
                            stable_state = pending_state.copy()
                            print(json.dumps({"frame": fno, "t": round(t,3), "seats": stable_state}, ensure_ascii=False))
                            write_occupancy_to_firestore(stable_state)
                            pending_state = None; pending_since = None

            if cv2.waitKey(1) & 0xFF == ord('q'):
                break

        cap.release()
        return

    # --- 파일 입력 ---
    if not os.path.exists(src) and not is_image(src):
        print(f"입력 경로를 찾을 수 없습니다: {src}")
        sys.exit(1)

    if is_image(src):
        img = cv2.imread(src)
        if img is None:
            print('이미지를 열 수 없습니다.'); sys.exit(1)
        H, W = img.shape[:2]
        rois = load_and_scale_rois(ROI_JSON, W, H)
        rois = {str(k): np.array(v, np.int32) for k, v in rois.items()}
        seat_centers = {str(sid): poly_centroid(poly) for sid, poly in rois.items()}
        occ = compute_occupancy(img, model, rois, seat_centers, conf=CONF)
        print(json.dumps({"frame": 1, "t": 0.0, "seats": occ}, ensure_ascii=False))
        write_occupancy_to_firestore(occ)
    else:
        cap = cv2.VideoCapture(src)
        if not cap.isOpened():
            print('영상을 열 수 없습니다.'); sys.exit(1)

        ok, frame = cap.read()
        if not ok:
            print("첫 프레임을 읽을 수 없습니다."); sys.exit(1)
        H, W = frame.shape[:2]
        rois = load_and_scale_rois(ROI_JSON, W, H)
        rois = {str(k): np.array(v, np.int32) for k, v in rois.items()}
        seat_centers = {str(sid): poly_centroid(poly) for sid, poly in rois.items()}

        fps = cap.get(cv2.CAP_PROP_FPS)
        fps = float(fps) if fps and fps > 0 else None
        start_ts = time.time()

        stable_state = None
        pending_state = None
        pending_since = None

        fno = 1
        while True:
            pos_msec = cap.get(cv2.CAP_PROP_POS_MSEC)
            if pos_msec and pos_msec > 0:  t = pos_msec / 1000.0
            elif fps:                      t = (fno - 1) / fps
            else:                          t = time.time() - start_ts

            # ⚡ 프레임 스킵: N프레임마다 한 번만 추론
            if FRAME_STRIDE > 1 and (fno % FRAME_STRIDE != 0):
                ok, frame = cap.read()
                if not ok: break
                fno += 1
                continue

            occ = compute_occupancy(frame, model, rois, seat_centers, conf=CONF)

            # 디바운스
            if stable_state is None:
                if pending_state is None or not states_equal(occ, pending_state):
                    pending_state = occ.copy(); pending_since = t
                else:
                    if (t - pending_since) >= HOLD_SEC:
                        stable_state = pending_state.copy()
                        print(json.dumps({"frame": fno, "t": round(t,3), "seats": stable_state}, ensure_ascii=False))
                        write_occupancy_to_firestore(stable_state)
            else:
                if states_equal(occ, stable_state):
                    pending_state = None; pending_since = None
                else:
                    if pending_state is None or not states_equal(occ, pending_state):
                        pending_state = occ.copy(); pending_since = t
                    else:
                        if (t - pending_since) >= HOLD_SEC:
                            stable_state = pending_state.copy()
                            print(json.dumps({"frame": fno, "t": round(t,3), "seats": stable_state}, ensure_ascii=False))
                            write_occupancy_to_firestore(stable_state)
                            pending_state = None; pending_since = None

            ok, frame = cap.read()
            if not ok: break
            fno += 1

        cap.release()

if __name__ == '__main__':
    main()
