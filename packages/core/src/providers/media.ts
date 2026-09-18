/**
 * core 的文件访问端口。core 自身零文件 IO：
 * node 侧用 Blob，RN 侧用 { uri, name, type }，两边各自只认自己那种 FormData part。
 */
export interface MediaIO {
  /** 图片必须 inline base64 才能进视觉模型 */
  imageData(rel: string): Promise<{ base64: string; mime: string }>;
  /** 返回 fetch body 可直接 append 的音频 part（RN 直传文件，不把 m4a 读进 JS 内存） */
  audioPart(rel: string, mime: string): Promise<unknown>;
  /** 回放用的绝对 URI（expo-audio 要 file://） */
  fileUri(rel: string): string;
  /** 删除卡片的媒体文件（删草稿时回收） */
  removeCardMedia(relPaths: string[]): Promise<void>;
}
