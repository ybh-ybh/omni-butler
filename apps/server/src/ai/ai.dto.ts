import { IsBoolean, IsIn, IsInt, IsOptional, IsString, IsUUID, MaxLength, Min, MinLength, ValidateIf } from 'class-validator';

/// 所有配置写入使用同一总版本，防止设备间覆盖。
export class AiRevisionDto {
  /// 客户端最后读到的设置版本。
  @IsInt() @Min(0) revision!: number;
}
/// 当前配置及整理开关一次提交。
export class AiSettingsDto extends AiRevisionDto {
  /// 明确的空值代表不选择配置，省略字段不能被解释为清空。
  @ValidateIf((_object: unknown, value: unknown) => value !== null) @IsUUID() activeProfileId!: string | null;
  /// 后端共享开关，默认关闭。
  @IsBoolean() notePolishEnabled!: boolean;
}
/// 不落库的连接测试同样校验供应商与模型参数。
export class AiTestDto {
  /// 可选身份仅用来读取同归属的已存密钥。
  @IsOptional() @IsUUID() profileId?: string;
  /// 三种供应商入口统一使用 Responses API。
  @IsIn(['zhipu', 'deepseek', 'custom']) provider!: string;
  /// 仅公网 HTTPS 地址，由服务端继续执行 SSRF 检查。
  @IsString() @MinLength(1) @MaxLength(2048) baseUrl!: string;
  /// 模型名允许供应商自行增加新型号。
  @IsString() @MinLength(1) @MaxLength(128) model!: string;
  /// 空 Key 表示保留或使用已存密钥。
  @IsOptional() @IsString() @MaxLength(4096) apiKey?: string;
  /// 保存及草稿连接测试共用思考开关，拒绝字符串或null隐式转换。
  @ValidateIf((_object: unknown, value: unknown) => value !== undefined) @IsBoolean() thinkingEnabled?: boolean;
}
/// 配置新建和更新字段共享校验，密钥更新为显式行为。
export class AiProfileDto extends AiTestDto {
  /// 当前设置总版本。
  @IsInt() @Min(0) revision!: number;
  /// 用户识别多套配置的名称。
  @IsString() @MinLength(1) @MaxLength(80) name!: string;
  /// 显式声明图片输入能力；旧客户端省略时保留已有配置值。
  @ValidateIf((_object: unknown, value: unknown) => value !== undefined) @IsBoolean() multimodal?: boolean;
  /// 显式删除密钥，不能与替换同时提交。
  @IsOptional() @IsBoolean() removeApiKey?: boolean;
}
/// 重试有新的计费操作身份，重放同一身份不会重复提交。
export class NotePolishDto {
  /// 用户本次明确重试的稳定身份。
  @IsUUID() operationId!: string;
  /// 整理只针对指定 ASR 原文。
  @IsUUID() recognitionId!: string;
}
