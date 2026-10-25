import { Injectable } from '@nestjs/common';
import { spawn } from 'node:child_process';
import { join } from 'node:path';
import {
  ATTACHMENT_LIMITS,
  AttachmentParseError,
  type ParsedAttachment,
} from './attachment.types';

/// 子进程隔离解析器故障与内存分配，生产不依赖ts-node。
@Injectable()
export class AttachmentProcess {
  /// 输入输出均有硬上限，超时后终止进程而非只放弃Promise。
  parse(bytes: Buffer, extension: string): Promise<ParsedAttachment> {
    return new Promise((resolve, reject) => {
      // 开发与测试读取TS源码，构建产物直接执行JS。
      const source = __filename.endsWith('.ts');
      // 子进程仅接收解析器入口及受控扩展名。
      const args = [
        '--max-old-space-size=384',
        ...(source
          ? ['-r', require.resolve('ts-node/register/transpile-only')]
          : []),
        join(__dirname, `attachment-parser.worker.${source ? 'ts' : 'js'}`),
        extension,
      ];
      // 不把数据库、模型或对象存储密钥传给文档解析器。
      const child = spawn(process.execPath, args, {
        windowsHide: true,
        stdio: ['pipe', 'pipe', 'ignore'],
        env: {
          PATH: process.env.PATH,
          SystemRoot: process.env.SystemRoot,
          TEMP: process.env.TEMP,
          TMP: process.env.TMP,
          TS_NODE_COMPILER_OPTIONS: '{"module":"commonjs"}',
        },
      });
      // 有界输出只短暂保留在当前调用。
      const chunks: Buffer[] = [];
      // 输出字节含base64图片，仍有独立总上限。
      let size = 0;
      // 防止error、close和timeout重复结算。
      let finished = false;
      // 终止原因先记录，等子进程close后才释放调用方。
      let failureCode: string | undefined;
      // 固定错误码不带底层日志或文档文本。
      const fail = (code: string): void => {
        if (finished || failureCode) return;
        failureCode = code;
        clearTimeout(timer);
        child.kill('SIGKILL');
      };
      // 总时限包含启动与完整解析。
      const timer = setTimeout(
        () => fail('ATTACHMENT_PARSE_TIMEOUT'),
        ATTACHMENT_LIMITS.parseTimeoutMs,
      );
      child.on('error', () => fail('ATTACHMENT_PARSER_UNAVAILABLE'));
      child.stdin.on('error', () => undefined);
      child.stdout.on('data', (chunk: Buffer) => {
        size += chunk.length;
        if (size > 24 * 1024 * 1024) fail('ATTACHMENT_OUTPUT_LIMIT');
        else chunks.push(chunk);
      });
      child.on('close', (code, signal) => {
        if (finished) return;
        finished = true;
        clearTimeout(timer);
        if (failureCode || signal) {
          reject(
            new AttachmentParseError(failureCode ?? 'ATTACHMENT_PARSE_FAILED'),
          );
          return;
        }
        try {
          // 子进程输出也校验结构，异常退出不能冒充成功。
          const output = JSON.parse(Buffer.concat(chunks).toString('utf8')) as {
            ok?: boolean;
            code?: string;
            result?: ParsedAttachment;
          };
          if (
            code !== 0 ||
            !output.ok ||
            !output.result ||
            !Array.isArray(output.result.chunks) ||
            !Array.isArray(output.result.images)
          )
            throw new AttachmentParseError(
              output.code && /^ATTACHMENT_[A-Z_]+$/.test(output.code)
                ? output.code
                : 'ATTACHMENT_PARSE_FAILED',
            );
          resolve(output.result);
        } catch (error) {
          reject(
            error instanceof AttachmentParseError
              ? error
              : new AttachmentParseError('ATTACHMENT_PARSE_FAILED'),
          );
        }
      });
      child.stdin.end(bytes);
    });
  }
}
