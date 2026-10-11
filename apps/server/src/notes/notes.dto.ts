import { Type } from 'class-transformer';
import { Equals, IsInt, IsString, IsUUID, Matches, Max, Min, MinLength } from 'class-validator';

/// 单段上传表单只描述已有的同步音频事实。
export class NoteAudioUploadDto {
  /// 原音所属的笔记。
  @IsUUID() noteId!: string;
  /// 已停止录音的实际时长。
  @Type(() => Number) @IsInt() @Min(1) @Max(1800000) durationMs!: number;
  /// 真实完整原音摘要。
  @Matches(/^[a-f0-9]{64}$/) sha256!: string;
}
/// 云端提交必须显式授权，并持久使用同一操作身份重试。
export class NoteRecognitionDto {
  /// 幂等身份。
  @IsUUID() operationId!: string;
  /// 每次请求携带当前有效授权。
  @Equals(true) consent!: boolean;
}
/// 完整迁移前先使用现有部署密钥暂存真实原音。
export class NoteAudioStageDto {
  /// 与快照迁移一致的部署验证密钥，不保存明文。
  @IsString() @MinLength(16) syncKey!: string;
  /// 后续原子替换请求使用的迁移身份。
  @IsUUID() migrationId!: string;
  /// 同步原音的稳定身份。
  @IsUUID() segmentId!: string;
  /// 完整字节摘要。
  @Matches(/^[a-f0-9]{64}$/) sha256!: string;
  /// 原音容器 MIME，与快照一致。
  @IsString() @Matches(/^audio\/(wav|mp4|mpeg|aac|ogg|flac)$/) mime!: string;
}
