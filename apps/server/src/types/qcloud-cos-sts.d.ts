declare module 'qcloud-cos-sts' {
  /// STS 临时密钥返回值。
  interface CredentialResult {
    credentials: {
      tmpSecretId: string;
      tmpSecretKey: string;
      sessionToken: string;
    };
    startTime: number;
    expiredTime: number;
    expiration: string;
    requestId?: string;
  }

  /// STS 临时策略语句。
  interface PolicyStatement {
    effect: 'allow' | 'deny';
    action: string[];
    resource: string[];
    condition?: Record<string, Record<string, number | string>>;
  }

  /// STS 临时密钥请求。
  interface CredentialOptions {
    secretId: string;
    secretKey: string;
    durationSeconds: number;
    proxy?: string;
    policy: {
      version: '2.0';
      statement: PolicyStatement[];
    };
  }

  /// 请求腾讯云 STS 临时密钥。
  export function getCredential(
    options: CredentialOptions,
    callback: (error: Error | null, result: CredentialResult) => void,
  ): void;
}
