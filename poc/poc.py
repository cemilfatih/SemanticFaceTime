import cv2
import mediapipe as mp
import numpy as np
import time

# --- AYARLAR VE SABİTLER ---
mp_face_mesh = mp.solutions.face_mesh
# Daha stabil bir mesh için confidence değerlerini artırdık
face_mesh = mp_face_mesh.FaceMesh(static_image_mode=False, max_num_faces=1, refine_landmarks=True, min_detection_confidence=0.6, min_tracking_confidence=0.6)

FRAME_KB = 50.0      
LANDMARK_KB = 0.5    
STANDARD_FPS = 30.0  

# DÜZELTME 1: Tavan FPS'i düşürdük ki aradaki fark "Vay canına" dedirtsin.
STABLE_INTERVAL = 1.0       # Sabit: 1 FPS
TALKING_INTERVAL = 0.5      # Konuşma: 2 FPS
HEAD_MOVE_INTERVAL = 0.2    # Kafa Hareketi: 5 FPS (Önceden 10'du, çok yüksekti)
TALK_THRESHOLD = 1.8        
HEAD_THRESHOLD = 5.0        

# DÜZELTME 2: EMA Yumuşatma Çarpanı (0.0 ile 1.0 arası)
# Değer küçüldükçe hareket daha "kaymak" gibi olur ama biraz gecikme (lag) yapabilir. 0.5 ile 0.7 arası idealdir.
SMOOTHING_FACTOR = 0.6  

def get_landmarks(image):
    rgb_image = cv2.cvtColor(image, cv2.COLOR_BGR2RGB)
    results = face_mesh.process(rgb_image)
    if not results.multi_face_landmarks: return None
    h, w, _ = image.shape
    return np.array([[int(lm.x * w), int(lm.y * h)] for lm in results.multi_face_landmarks[0].landmark], dtype=np.float32) # float yaptık

def calculate_motion(prev_lms, curr_lms):
    if prev_lms is None or curr_lms is None: return 0
    return np.mean(np.linalg.norm(curr_lms - prev_lms, axis=1))

def get_mouth_openness(lms):
    # MediaPipe'ta 13=Üst iç dudak, 14=Alt iç dudak
    # İkisi arasındaki dikey piksel mesafesini ölçer
    if lms is None or len(lms) < 15: return 0
    return np.linalg.norm(lms[13] - lms[14])

def get_extended_mesh_indices(landmarks, frame_shape):
    h, w, _ = frame_shape
    extended_points = np.vstack([landmarks, [
        [0, 0], [w-1, 0], [0, h-1], [w-1, h-1],
        [w//2, 0], [0, h//2], [w-1, h//2], [w//2, h-1]
    ]])
    
    # HATA DÜZELTMESİ: OpenCV sınır krizini önlemek için hayali çerçeveyi genişletiyoruz
    # Ekran boyutundan (w, h) dışarı doğru -50 ve +100 piksel pay bırakıyoruz.
    rect = (-50, -50, w + 100, h + 100) 
    subdiv = cv2.Subdiv2D(rect)
    
    for p in extended_points:
        subdiv.insert((float(p[0]), float(p[1])))
    
    triangles = subdiv.getTriangleList()
    tri_indices = []
    for t in triangles:
        pt = [(t[0], t[1]), (t[2], t[3]), (t[4], t[5])]
        indices = []
        for p in pt:
            dists = np.linalg.norm(extended_points - p, axis=1)
            idx = np.argmin(dists)
            if dists[idx] < 1.0: indices.append(idx)
        if len(indices) == 3: tri_indices.append(indices)
    return tri_indices, extended_points


def warp_triangle(img1, img2, t1, t2):
    t1, t2 = np.array(t1, dtype=np.int32), np.array(t2, dtype=np.int32)
    
    # HATA DÜZELTMESİ: Noktaların kamera ekranından dışarı taşmasını engelle (Clamping)
    h, w = img1.shape[:2]
    t1 = np.clip(t1, [0, 0], [w - 1, h - 1])
    t2 = np.clip(t2, [0, 0], [w - 1, h - 1])
    
    r1, r2 = cv2.boundingRect(t1), cv2.boundingRect(t2)
    if r1[2] <= 0 or r1[3] <= 0 or r2[2] <= 0 or r2[3] <= 0: return
    
    img1_rect = img1[r1[1]:r1[1] + r1[3], r1[0]:r1[0] + r1[2]]
    t1_rect = t1 - [r1[0], r1[1]]
    t2_rect = t2 - [r2[0], r2[1]]
    
    warp_mat = cv2.getAffineTransform(np.float32(t1_rect), np.float32(t2_rect))
    img2_rect = cv2.warpAffine(img1_rect, warp_mat, (r2[2], r2[3]), None, flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_REFLECT_101)
    
    mask = np.zeros((r2[3], r2[2], 3), dtype=np.uint8)
    cv2.fillConvexPoly(mask, np.int32(t2_rect), (255, 255, 255))
    
    # Ekstra Güvenlik: Hedef dilim ile maske boyutu tam uyuşmuyorsa bu üçgeni atla
    slice_img2 = img2[r2[1]:r2[1] + r2[3], r2[0]:r2[0] + r2[2]]
    if slice_img2.shape != mask.shape:
        return
        
    img2_rect_masked = cv2.bitwise_and(img2_rect, mask)
    img2_bg_masked = cv2.bitwise_and(slice_img2, cv2.bitwise_not(mask))
    img2[r2[1]:r2[1] + r2[3], r2[0]:r2[0] + r2[2]] = cv2.add(img2_bg_masked, img2_rect_masked)

# --- ANA DÖNGÜ ---
cap = cv2.VideoCapture(0)
last_anchor_time = time.time()
anchor_frame = None
anchor_points_ext = None
prev_landmarks = None
tri_indices = []
current_interval = STABLE_INTERVAL

# Titremeyi önleyen hafıza değişkeni
smoothed_lms = None 

print("NanoBand 3-Panel: Akıcılık Optimize Edildi...")

while cap.isOpened():
    ret, frame = cap.read()
    if not ret: break
    
    raw_lms = get_landmarks(frame)
    status = "STABLE"
    color = (0, 255, 0)
    
    if raw_lms is not None:
        if smoothed_lms is None:
            smoothed_lms = raw_lms.copy()
        else:
            # Yumuşatmayı azalttık (0.8) ki gecikme hissi bitsin, daha canlı olsun
            smoothed_lms = (smoothed_lms * 0.2) + (raw_lms * 0.8)
        
        curr_lms = smoothed_lms.astype(np.int32)
        
        motion_score = calculate_motion(prev_landmarks, curr_lms)
        curr_mouth_open = get_mouth_openness(curr_lms)
        
        # 1. Harekete Göre Zaman Aralığı Belirleme
        if motion_score >= HEAD_THRESHOLD:
            current_interval = HEAD_MOVE_INTERVAL
            status = "HEAD MOVING"
            color = (0, 0, 255)
        elif motion_score >= TALK_THRESHOLD:
            current_interval = TALKING_INTERVAL
            status = "TALKING"
            color = (0, 255, 255)
        else:
            current_interval = STABLE_INTERVAL
            status = "STABLE"
            color = (0, 255, 0)

        force_update = False
        
        # 2. AĞIZ FARKINDALIKLI SEMANTİK TETİKLEYİCİ (Mouth-Aware Trigger)
        if anchor_frame is not None and anchor_points_ext is not None:
            anchor_mouth_open = get_mouth_openness(anchor_points_ext[:468])
            # Eğer ağız açıklığı referans fotoğrafa göre 8 pikselden fazla değiştiyse! (Dişler çıktı/kayboldu)
            if abs(curr_mouth_open - anchor_mouth_open) > 8.0:
                force_update = True
                status = "MOUTH TRIGGER!"
                color = (255, 0, 255) # Mor renkli uyarı

        # Anchor Update Kararı (Ya zaman dolacak, ya da ağız tetikleyecek)
        time_elapsed = time.time() - last_anchor_time
        if time_elapsed > current_interval or force_update:
            anchor_frame = frame.copy()
            tri_indices, anchor_points_ext = get_extended_mesh_indices(curr_lms, anchor_frame.shape)
            last_anchor_time = time.time()

        prev_landmarks = curr_lms.copy()

    if anchor_frame is None or raw_lms is None:
        continue

    # --- 1. SOL EKRAN: Orijinal Video ---
    panel_1 = frame.copy()

    # --- 2. ORTA EKRAN: Sadece Düşük FPS (Takılan Video) ---
    panel_2 = anchor_frame.copy()

    # --- 3. SAĞ EKRAN: NanoBand (Warping Var - Akıcı) ---
    panel_3 = np.zeros_like(frame)
    w, h = frame.shape[1], frame.shape[0]
    curr_points_ext = np.vstack([curr_lms, [
        [0, 0], [w-1, 0], [0, h-1], [w-1, h-1],
        [w//2, 0], [0, h//2], [w-1, h//2], [w//2, h-1]
    ]])
    for tri in tri_indices:
        t1 = anchor_points_ext[tri]
        t2 = curr_points_ext[tri]
        warp_triangle(anchor_frame, panel_3, t1, t2)

    # --- VERİ VE TASARRUF HESAPLAMASI ---
    standard_bandwidth = STANDARD_FPS * FRAME_KB 
    current_fps = 1.0 / current_interval
    nanoband_bandwidth = (current_fps * FRAME_KB) + (STANDARD_FPS * LANDMARK_KB)
    savings_percent = ((standard_bandwidth - nanoband_bandwidth) / standard_bandwidth) * 100

    # --- EKRANLARI KÜÇÜLT VE BİRLEŞTİR ---
    scale = 0.5 
    p1 = cv2.resize(panel_1, (0, 0), fx=scale, fy=scale)
    p2 = cv2.resize(panel_2, (0, 0), fx=scale, fy=scale)
    p3 = cv2.resize(panel_3, (0, 0), fx=scale, fy=scale)

    cv2.putText(p1, "1. ORIGINAL (30 FPS)", (10, 30), 1, 1.2, (255, 255, 255), 2)
    cv2.putText(p2, f"2. NO AI ({current_fps:.1f} FPS)", (10, 30), 1, 1.2, (0, 0, 255), 2)
    cv2.putText(p3, "3. NANOBAND AI", (10, 30), 1, 1.2, (0, 255, 0), 2)

    combined = np.hstack((p1, p2, p3))
    info_panel = np.zeros((100, combined.shape[1], 3), dtype=np.uint8)
    
    text_mode = f"STATE: {status} | Anchor Interval: {current_interval}s"
    text_bw = f"Standard BW: {standard_bandwidth:.0f} KB/s | NanoBand BW: {nanoband_bandwidth:.0f} KB/s"
    text_save = f"BANDWIDTH SAVINGS: %{savings_percent:.1f}"

    cv2.putText(info_panel, text_mode, (20, 30), 1, 1.5, color, 2)
    cv2.putText(info_panel, text_bw, (20, 60), 1, 1.2, (200, 200, 200), 2)
    cv2.putText(info_panel, text_save, (20, 90), 1, 2.0, (0, 255, 0), 2) 

    final_output = np.vstack((combined, info_panel))
    cv2.imshow("NanoBand 3-Way Demo", final_output)
    
    if cv2.waitKey(1) & 0xFF == ord('q'): break

cap.release()
cv2.destroyAllWindows()