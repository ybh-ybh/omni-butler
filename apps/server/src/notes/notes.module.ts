import { Module } from '@nestjs/common';
import { AuthModule } from '../auth/auth.module';
import { MinioNoteAudioStore, NoteAudioStore } from './note-audio-store';
import { StorageModule } from '../storage/storage.module';
import { NotesController } from './notes.controller';
import { NotesService } from './notes.service';
import { SpeechRecognitionProvider } from './speech-provider';
import { TencentSpeechProvider } from './tencent-speech.provider';

/// 领域只依赖抽象 provider token，更换厂商无需改笔记或客户端。
@Module({ imports: [AuthModule, StorageModule], controllers: [NotesController], providers: [NotesService, { provide: NoteAudioStore, useClass: MinioNoteAudioStore }, { provide: SpeechRecognitionProvider, useClass: TencentSpeechProvider }], exports: [NoteAudioStore] })
export class NotesModule {}
