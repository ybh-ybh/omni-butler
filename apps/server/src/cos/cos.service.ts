import {
  BadRequestException,
  Injectable,
  ServiceUnavailableException,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import * as STS from 'qcloud-cos-sts';
import type { AuthUser } from '../auth/auth.types';
import type { CreateDownloadCredentialDto } from './dto/create-download-credential.dto';
import type { CreateUploadCredentialDto } from './dto/create-upload-credential.dto';

/// 客户端访问单个 COS 对象所需的临时授权结果。
interface ObjectCredential {
  /// STS 临时身份。
  credentials: {
    /// 临时 SecretId。
    tmpSecretId: string;
    /// 临时 SecretKey。
    tmpSecretKey: string;
    /// 临时会话 Token。
    sessionToken: string;
  };
  /// 服务端签发起始秒时间戳。
  startTime: number;
  /// 临时密钥过期秒时间戳。
  expiredTime: number;
  /// 目标 COS 存储桶。
  bucket: string;
  /// 目标 COS 地域。
  region: string;
  /// 服务端分配且只能写入的对象键。
  objectKey: string;
}

/// 服务端 COS 固定配置。
interface CosConfiguration {
  /// 腾讯云 SecretId。
  secretId: string;
  /// 腾讯云 SecretKey。
  secretKey: string;
  /// COS 存储桶全名。
  bucket: string;
  /// COS 地域。
  region: string;
  /// STS 临时密钥有效秒数。
  durationSeconds: number;
}

/// 腾讯云 COS 最小权限临时密钥服务。
@Injectable()
export class CosService {
  /// 注入环境配置。
  constructor(private readonly config: ConfigService) {}

  /// 为当前用户的一条附件生成单对象上传权限。
  async createUploadCredential(
    user: AuthUser,
    input: CreateUploadCredentialDto,
  ): Promise<ObjectCredential> {
    // 当前 COS 服务配置。
    const configuration = this.loadConfiguration();
    // 允许的最大上传字节数。
    const maxUploadBytes = Number(
      this.config.get<string>('COS_MAX_UPLOAD_BYTES') ?? 20 * 1024 * 1024,
    );
    if (input.sizeBytes > maxUploadBytes) {
      throw new BadRequestException(`文件不能超过 ${maxUploadBytes} 字节`);
    }
    if (!input.mimeType.startsWith('image/')) {
      throw new BadRequestException('第一阶段仅允许上传图片附件');
    }
    // 安全文件扩展名。
    const extension = this.safeExtension(input.fileName, input.mimeType);
    // 当前用户唯一对象路径。
    const objectKey = [
      'users',
      user.sub,
      input.businessType,
      input.businessId,
      `${input.attachmentId}.${extension}`,
    ].join('/');
    // 存储桶账号 AppId。
    return this.issueCredential({
      configuration,
      objectKey,
      actions: ['name/cos:PutObject'],
      condition: {
        numeric_less_than_equal: {
          'cos:content-length': input.sizeBytes,
        },
      },
    });
  }

  /// 为当前用户已同步的私有附件生成单对象读取权限。
  async createDownloadCredential(
    user: AuthUser,
    input: CreateDownloadCredentialDto,
  ): Promise<ObjectCredential> {
    // 当前用户合法对象键前缀。
    const userPrefix = `users/${user.sub}/`;
    if (!input.objectKey.startsWith(userPrefix)) {
      throw new BadRequestException('不能读取其他账号的附件');
    }
    // 服务端生成路径的完整结构约束。
    const objectPattern = new RegExp(
      `^users/${this.escapeRegExp(user.sub)}/` +
        '(quoteBanner|inventoryImage|membershipImage)/' +
        '(home-banner|[0-9a-f-]{36})/[0-9a-f-]{36}\\.[a-z0-9]{1,8}$',
      'i',
    );
    if (!objectPattern.test(input.objectKey)) {
      throw new BadRequestException('附件对象键格式无效');
    }
    // 当前 COS 服务配置。
    const configuration = this.loadConfiguration();
    return this.issueCredential({
      configuration,
      objectKey: input.objectKey,
      actions: ['name/cos:GetObject'],
    });
  }

  /// 读取并校验服务端 COS 配置。
  private loadConfiguration(): CosConfiguration {
    // 服务端腾讯云 SecretId。
    const secretId = this.config.get<string>('TENCENT_SECRET_ID');
    // 服务端腾讯云 SecretKey。
    const secretKey = this.config.get<string>('TENCENT_SECRET_KEY');
    // 目标 COS 存储桶全名。
    const bucket = this.config.get<string>('TENCENT_COS_BUCKET');
    // 目标 COS 地域。
    const region = this.config.get<string>('TENCENT_COS_REGION');
    if (!secretId || !secretKey || !bucket || !region) {
      throw new ServiceUnavailableException('COS 尚未完成服务器配置');
    }
    // STS 临时密钥有效秒数。
    const durationSeconds = Number(
      this.config.get<string>('COS_STS_DURATION_SECONDS') ?? 1800,
    );
    return { secretId, secretKey, bucket, region, durationSeconds };
  }

  /// 向腾讯云 STS 申请只作用于一个对象的临时密钥。
  private async issueCredential(input: {
    configuration: CosConfiguration;
    objectKey: string;
    actions: string[];
    condition?: Record<string, Record<string, number | string>>;
  }): Promise<ObjectCredential> {
    // 已校验的 COS 配置。
    const { configuration } = input;
    // 存储桶账号 AppId。
    const appId = configuration.bucket.match(/-(\d+)$/)?.[1];
    if (!appId) {
      throw new ServiceUnavailableException('COS 存储桶名称必须包含 AppId');
    }
    // 单个对象的 COS 资源名称。
    const resource = `qcs::cos:${configuration.region}:uid/${appId}:${configuration.bucket}/${input.objectKey}`;
    // 腾讯云 STS 临时身份。
    const result = await new Promise<
      Parameters<typeof STS.getCredential>[1] extends (
        error: Error | null,
        result: infer TResult,
      ) => void
        ? TResult
        : never
    >((resolve, reject) => {
      STS.getCredential(
        {
          secretId: configuration.secretId,
          secretKey: configuration.secretKey,
          durationSeconds: configuration.durationSeconds,
          policy: {
            version: '2.0',
            statement: [
              {
                effect: 'allow',
                action: input.actions,
                resource: [resource],
                condition: input.condition,
              },
            ],
          },
        },
        (error, credential) => {
          if (error) {
            reject(error);
          } else {
            resolve(credential);
          }
        },
      );
    });
    return {
      credentials: result.credentials,
      startTime: result.startTime,
      expiredTime: result.expiredTime,
      bucket: configuration.bucket,
      region: configuration.region,
      objectKey: input.objectKey,
    };
  }

  /// 转义动态正则表达式文本。
  private escapeRegExp(value: string): string {
    return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  }

  /// 根据文件名和 MIME 类型返回白名单扩展名。
  private safeExtension(fileName: string, mimeType: string): string {
    // MIME 类型对应的标准扩展名。
    const mimeExtensions: Record<string, string> = {
      'image/jpeg': 'jpg',
      'image/png': 'png',
      'image/webp': 'webp',
      'image/gif': 'gif',
      'image/heic': 'heic',
    };
    // MIME 类型给出的扩展名。
    const mimeExtension = mimeExtensions[mimeType.toLowerCase()];
    if (mimeExtension) {
      return mimeExtension;
    }
    // 文件名中的原始扩展名。
    const fileExtension = fileName.split('.').pop()?.toLowerCase();
    if (fileExtension && /^[a-z0-9]{1,8}$/.test(fileExtension)) {
      return fileExtension;
    }
    return 'bin';
  }
}
