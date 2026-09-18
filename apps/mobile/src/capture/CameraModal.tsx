import { useEffect, useRef, useState } from 'react';
import { ActivityIndicator, Image, Modal, Pressable, StyleSheet, Text, View } from 'react-native';
import { CameraView, useCameraPermissions } from 'expo-camera';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { Radius, Spacing } from '@/constants/theme';
import { useTheme } from '@/hooks/use-theme';
import { Button } from '@/ui/kit';
import type { PickedImage } from './picker';

/**
 * 连拍/单拍：张数不限，只给构图引导、不做任何硬性截断（需求 5.1）。
 * 刻意不用独立路由：拍完要把照片交回录入页，走路由传参会把状态切碎。
 */
export function CameraModal({
  visible,
  onClose,
  onConfirm,
}: {
  visible: boolean;
  onClose: () => void;
  onConfirm: (photos: PickedImage[]) => void;
}) {
  const theme = useTheme();
  const insets = useSafeAreaInsets();
  const [permission, requestPermission] = useCameraPermissions();
  const cameraRef = useRef<CameraView>(null);
  const [shots, setShots] = useState<PickedImage[]>([]);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (visible && permission && !permission.granted) void requestPermission();
  }, [visible, permission, requestPermission]);

  useEffect(() => {
    if (!visible) setShots([]);
  }, [visible]);

  const take = async () => {
    if (!cameraRef.current || busy) return;
    setBusy(true);
    try {
      const photo = await cameraRef.current.takePictureAsync({ quality: 1, exif: false });
      if (photo) setShots((prev) => [...prev, { uri: photo.uri, width: photo.width, height: photo.height }]);
    } finally {
      setBusy(false);
    }
  };

  if (!visible) return null;

  const granted = permission?.granted ?? false;

  return (
    // 同上：显式传值，不要用布尔简写（简写等于恒 true，弹窗关不掉）
    <Modal visible={visible} animationType="slide" onRequestClose={onClose}>
      <View style={[styles.root, { backgroundColor: '#000000' }]}>
        {granted ? (
          <CameraView ref={cameraRef} style={styles.preview} facing="back" />
        ) : (
          <View style={styles.center}>
            <Text style={styles.hint}>需要相机权限才能拍照</Text>
            <Button title="授予权限" onPress={() => void requestPermission()} />
          </View>
        )}

        <View style={[styles.top, { paddingTop: insets.top + Spacing.two }]}>
          <Text style={styles.guide}>第一张拍全貌 → 再拍局部 → 最后特写</Text>
          <Text style={styles.counter}>已拍 {shots.length} 张（不限张数）</Text>
        </View>

        {shots.length > 0 ? (
          <View style={styles.thumbs}>
            {shots.slice(-6).map((s, i) => (
              <Image key={`${s.uri}-${i}`} source={{ uri: s.uri }} style={styles.thumb} />
            ))}
          </View>
        ) : null}

        <View style={[styles.bottom, { paddingBottom: insets.bottom + Spacing.three }]}>
          <Button title="取消" variant="secondary" compact onPress={onClose} />
          <Pressable
            onPress={() => void take()}
            disabled={busy || !granted}
            style={[styles.shutter, { borderColor: '#ffffff', opacity: busy ? 0.5 : 1 }]}>
            {busy ? <ActivityIndicator color="#ffffff" /> : null}
          </Pressable>
          <Button
            title={shots.length > 0 ? `用这 ${shots.length} 张` : '完成'}
            compact
            disabled={shots.length === 0}
            onPress={() => {
              onConfirm(shots);
              onClose();
            }}
          />
        </View>
      </View>
    </Modal>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1 },
  preview: { flex: 1 },
  center: { flex: 1, alignItems: 'center', justifyContent: 'center', gap: Spacing.three },
  hint: { color: '#ffffff', fontSize: 15 },
  top: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    paddingHorizontal: Spacing.three,
    gap: 4,
  },
  guide: { color: '#ffffff', fontSize: 14, fontWeight: '600' },
  counter: { color: '#D5D8DD', fontSize: 12 },
  thumbs: {
    position: 'absolute',
    right: Spacing.three,
    top: 120,
    gap: 6,
  },
  thumb: { width: 48, height: 48, borderRadius: Radius.sm },
  bottom: {
    position: 'absolute',
    left: 0,
    right: 0,
    bottom: 0,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: Spacing.three,
    gap: Spacing.three,
  },
  shutter: {
    width: 68,
    height: 68,
    borderRadius: 34,
    borderWidth: 4,
    alignItems: 'center',
    justifyContent: 'center',
  },
});
