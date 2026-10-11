import { BadRequestException, Body, Controller, Delete, Get, Headers, Param, Post, Put, Query, Res, UploadedFile, UseGuards, UseInterceptors } from '@nestjs/common';
import { FileInterceptor } from '@nestjs/platform-express';
import type { Response } from 'express';
import type { AuthUser } from '../auth/auth.types';
import { CurrentUser } from '../auth/current-user.decorator';
import { JwtAuthGuard } from '../auth/jwt-auth.guard';
import { NoteAudioStageDto, NoteAudioUploadDto, NoteRecognitionDto } from './notes.dto';
import { NOTE_AUDIO_MAX_BYTES, NotesService } from './notes.service';

/// 与已有设备会话共用归属授权，原音不是公共静态文件。
@Controller('notes/audio')
export class NotesController {
  /// 注入持久原音和识别服务。
  constructor(private readonly notes: NotesService) {}
  /// 配置缺失时客户端仍能纯本地记录。
  @Get('capabilities') @UseGuards(JwtAuthGuard)
  capabilities(): ReturnType<NotesService['capabilities']> { return this.notes.capabilities(); }
  /// 完整迁移使用部署密钥在服务中授权，不要求即将被重建撤销的会话。
  @Put('migration/stage')
  @UseInterceptors(FileInterceptor('file', { limits: { fileSize: NOTE_AUDIO_MAX_BYTES, files: 1, fields: 6, fieldSize: 1024 } }))
  stage(@Body() input: NoteAudioStageDto, @UploadedFile() file?: { buffer: Buffer }): ReturnType<NotesService['stage']> {
    if (!file?.buffer) throw new BadRequestException('缺少迁移原音文件');
    return this.notes.stage(input, file.buffer);
  }
  /// 短期签名原音，仅在已授权云端任务执行期间有效。
  @Get('provider/:jobId')
  async providerDownload(@Param('jobId') jobId: string, @Query('expires') expires: string, @Query('signature') signature: string, @Headers('range') range: string | undefined, @Res() response: Response): Promise<void> { this.send(response, await this.notes.providerDownload(jobId, expires, signature), range); }
  /// 经校验的原音上传重放不改变既有内容。
  @Put(':segmentId') @UseGuards(JwtAuthGuard)
  @UseInterceptors(FileInterceptor('file', { limits: { fileSize: NOTE_AUDIO_MAX_BYTES, files: 1, fields: 3, fieldSize: 256 } }))
  upload(@CurrentUser() user: AuthUser, @Param('segmentId') segmentId: string, @Body() input: NoteAudioUploadDto, @UploadedFile() file?: { buffer: Buffer }): ReturnType<NotesService['upload']> {
    if (!file?.buffer) throw new BadRequestException('缺少原音文件');
    return this.notes.upload(user, segmentId, input, file.buffer);
  }
  /// 下载与回听支持单一字节 Range，防止长音频拖动失败。
  @Get(':segmentId/file') @UseGuards(JwtAuthGuard)
  async download(@CurrentUser() user: AuthUser, @Param('segmentId') segmentId: string, @Headers('range') range: string | undefined, @Res() response: Response): Promise<void> { this.send(response, await this.notes.download(user.sub, segmentId), range); }
  /// 创建或重放当前云端识别。
  @Post(':segmentId/recognitions') @UseGuards(JwtAuthGuard)
  recognize(@CurrentUser() user: AuthUser, @Param('segmentId') segmentId: string, @Body() input: NoteRecognitionDto): ReturnType<NotesService['recognize']> { return this.notes.recognize(user, segmentId, input.operationId, input.consent); }
  /// 轮询本系统任务不触发服务商提交。
  @Get(':segmentId/recognitions/current') @UseGuards(JwtAuthGuard)
  current(@CurrentUser() user: AuthUser, @Param('segmentId') segmentId: string): ReturnType<NotesService['current']> { return this.notes.current(user, segmentId); }
  /// 在线送达后撤销尚未发送工作，已提交结果停止进入笔记。
  @Delete(':segmentId/recognitions/current') @UseGuards(JwtAuthGuard)
  cancel(@CurrentUser() user: AuthUser, @Param('segmentId') segmentId: string): ReturnType<NotesService['cancel']> { return this.notes.cancel(user, segmentId); }
  /// 固定私有缓存策略并实现完整范围边界。
  private send(response: Response, audio: { bytes: Buffer; mime: string; sha256: string }, range: string | undefined): void {
    response.setHeader('Content-Type', audio.mime);
    response.setHeader('Cache-Control', 'private, no-store');
    response.setHeader('X-Content-Type-Options', 'nosniff');
    response.setHeader('Accept-Ranges', 'bytes');
    response.setHeader('X-Content-SHA256', audio.sha256);
    if (!range) { response.setHeader('Content-Length', audio.bytes.length); response.send(audio.bytes); return; }
    // 单个范围语法，多范围不做隐式截断。
    const match = /^bytes=(\d*)-(\d*)$/.exec(range);
    if (!match || (!match[1] && !match[2])) { response.status(416).setHeader('Content-Range', `bytes */${audio.bytes.length}`); response.end(); return; }
    // 普通范围起点或 suffix 起点。
    const start = match[1] ? Number(match[1]) : Math.max(0, audio.bytes.length - Number(match[2]));
    // 普通范围终点或读到末尾。
    const end = match[1] && match[2] ? Math.min(Number(match[2]), audio.bytes.length - 1) : audio.bytes.length - 1;
    if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start < 0 || start > end || start >= audio.bytes.length) { response.status(416).setHeader('Content-Range', `bytes */${audio.bytes.length}`); response.end(); return; }
    response.status(206).setHeader('Content-Range', `bytes ${start}-${end}/${audio.bytes.length}`);
    response.setHeader('Content-Length', end - start + 1);
    response.send(audio.bytes.subarray(start, end + 1));
  }
}
