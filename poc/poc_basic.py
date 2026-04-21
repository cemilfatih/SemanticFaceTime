import cv2
import mediapipe as mp
import numpy as np
import time

# MediaPipe Yapılandırması
mp_face_mesh = mp.solutions.face_mesh
face_mesh = mp_face_mesh.FaceMesh(static_image_mode=False, max_num_faces=1, refine_landmarks=True)

def get_landmarks(image):
    rgb_image = cv2.cvtColor(image, cv2.COLOR_BGR2RGB)
    results = face_mesh.process(rgb_image)
    if not results.multi_face_landmarks:
        return None
    h, w, _ = image.shape
    return np.array([[int(lm.x * w), int(lm.y * h)] for lm in results.multi_face_landmarks[0].landmark], dtype=np.int32)

# --- YENİ FONKSİYON: TÜM KAREYİ KAPSAYAN MESH ---
def get_extended_mesh_indices(landmarks, frame_shape):
    h, w, _ = frame_shape
    # Görüntünün köşelerini sanal noktalar olarak ekle
    # Bu noktalar saçın, kulakların ve arka planın esnemesini sağlayacak
    extended_points = np.vstack([landmarks, [
        [0, 0], [w-1, 0], [0, h-1], [w-1, h-1], # Köşeler
        [w//2, 0], [0, h//2], [w-1, h//2], [w//2, h-1] # Kenar ortaları
    ]])
    
    rect = (0, 0, w, h)
    subdiv = cv2.Subdiv2D(rect)
    for p in extended_points:
        subdiv.insert((float(p[0]), float(p[1])))
    
    triangles = subdiv.getTriangleList()
    tri_indices = []
    
    for t in triangles:
        pt = [(t[0], t[1]), (t[2], t[3]), (t[4], t[5])]
        indices = []
        for p in pt:
            # Noktaları genişletilmiş listede ara
            dists = np.linalg.norm(extended_points - p, axis=1)
            idx = np.argmin(dists)
            if dists[idx] < 1.0: indices.append(idx)
        if len(indices) == 3: tri_indices.append(indices)
    
    return tri_indices, extended_points

def warp_triangle(img1, img2, t1, t2):
    t1, t2 = np.array(t1, dtype=np.int32), np.array(t2, dtype=np.int32)
    r1, r2 = cv2.boundingRect(t1), cv2.boundingRect(t2)
    if r1[2] <= 0 or r1[3] <= 0 or r2[2] <= 0 or r2[3] <= 0: return
    
    # Kırpma sınırlarını kontrol et (Görüntü dışına çıkmayı önlemek için)
    h1, w1 = img1.shape[:2]
    h2, w2 = img2.shape[:2]
    r1 = (max(0, r1[0]), max(0, r1[1]), min(w1 - r1[0], r1[2]), min(h1 - r1[1], r1[3]))
    r2 = (max(0, r2[0]), max(0, r2[1]), min(w2 - r2[0], r2[2]), min(h2 - r2[1], r2[3]))
    
    if r1[2] <= 0 or r1[3] <= 0 or r2[2] <= 0 or r2[3] <= 0: return

    t1_rect = [(t1[i][0] - r1[0], t1[i][1] - r1[1]) for i in range(3)]
    t2_rect = [(t2[i][0] - r2[0], t2[i][1] - r2[1]) for i in range(3)]
    
    mask = np.zeros((r2[3], r2[2], 3), dtype=np.float32)
    cv2.fillConvexPoly(mask, np.array(t2_rect, dtype=np.int32), (1.0, 1.0, 1.0), 16, 0)
    
    img1_rect = img1[r1[1]:r1[1] + r1[3], r1[0]:r1[0] + r1[2]]
    
    # Affine Transform matrisi
    # Boyutları kontrol et
    if img1_rect.shape[0] != r1[3] or img1_rect.shape[1] != r1[2]: return

    warp_mat = cv2.getAffineTransform(np.float32(t1_rect), np.float32(t2_rect))
    img2_rect = cv2.warpAffine(img1_rect, warp_mat, (r2[2], r2[3]), None, flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_REFLECT_101)
    
    img2_rect = img2_rect.astype(np.float32) * mask
    
    temp_area = img2[r2[1]:r2[1] + r2[3], r2[0]:r2[0] + r2[2]].astype(np.float32)
    img2[r2[1]:r2[1] + r2[3], r2[0]:r2[0] + r2[2]] = (temp_area * (1.0 - mask) + img2_rect).astype(np.uint8)

# --- ANA DÖNGÜ (Full Head Sync) ---
cap = cv2.VideoCapture(0)
last_anchor_time = 0
anchor_frame = None
anchor_points_extended = None
tri_indices = []

print("Sistem başlatılıyor... Tüm kafa senkronizasyonu aktif.")

while cap.isOpened():
    ret, frame = cap.read()
    if not ret: break
    
    current_time = time.time()
    curr_landmarks = get_landmarks(frame)
    
    # 1. Saniyede bir Anchor Update (Full Frame)
    if curr_landmarks is not None and (current_time - last_anchor_time > 1.0):
        anchor_frame = frame.copy()
        # Üçgenleri tüm kareye yayan genişletilmiş mesh oluştur
        tri_indices, anchor_points_extended = get_extended_mesh_indices(curr_landmarks, anchor_frame.shape)
        last_anchor_time = current_time
        print("Anchor Updated!")

    synthetic_frame = np.zeros_like(frame)
    
    if anchor_frame is not None and curr_landmarks is not None:
        # Mevcut kare için genişletilmiş noktaları oluştur (Yüz hareket eder, köşeler sabit)
        w, h = frame.shape[1], frame.shape[0]
        curr_points_extended = np.vstack([curr_landmarks, [
            [0, 0], [w-1, 0], [0, h-1], [w-1, h-1], # Köşeler sabit kalır
            [w//2, 0], [0, h//2], [w-1, h//2], [w//2, h-1]
        ]])
        
        # 30 FPS Landmark hareketini tüm kafa üzerine uygula
        for tri in tri_indices:
            t1 = [anchor_points_extended[tri[0]], anchor_points_extended[tri[1]], anchor_points_extended[tri[2]]]
            t2 = [curr_points_extended[tri[0]], curr_points_extended[tri[1]], curr_points_extended[tri[2]]]
            warp_triangle(anchor_frame, synthetic_frame, t1, t2)
    
    # Görselleştirme
    combined = np.hstack((frame, synthetic_frame))
    cv2.putText(combined, "LIVE", (10, 30), 1, 2, (0, 255, 0), 2)
    cv2.putText(combined, "NANOBAND FACETIME (Semantic)", (frame.shape[1] + 10, 30), 1, 2, (0, 0, 255), 2)
    
    cv2.imshow("NanoBand Full Head Sync PoC", combined)
    if cv2.waitKey(1) & 0xFF == ord('q'): break

cap.release()
cv2.destroyAllWindows()