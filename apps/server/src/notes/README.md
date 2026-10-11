# 笔记原音与语音识别

`NotesService` 只依赖 `SpeechRecognitionProvider` 和 `NoteAudioStore`。新增语音厂商时实现 `submit`、`poll` 并在 `NotesModule` 注册适配器；客户端和笔记存储不依赖腾讯字段。

设备接口都使用现有 JWT：

- `GET /notes/audio/capabilities`：服务端能力。
- `PUT /notes/audio/:segmentId`：multipart `file`、`noteId`、`durationMs`、`sha256`，先同步稳定原音元数据。
- `GET /notes/audio/:segmentId/file`：私有下载和 Range 回听；响应 `X-Content-SHA256`。
- `POST /notes/audio/:segmentId/recognitions`：`{operationId,consent:true}`，返回持久任务，重放和并发不重复提交。
- `GET /notes/audio/:segmentId/recognitions/current`：读取最新任务；无任务时 HTTP 200、响应体为空。
- `DELETE /notes/audio/:segmentId/recognitions/current`：停止未发送工作和后续结果处理，`alreadySubmitted` 表明远端可能已计费。

识别 POST 与 GET 的非空回执固定返回 `{id,segmentId,status,transcript,canonicalTranscript,errorCode}`。`transcript` 是本次任务的结果；`canonicalTranscript` 始终存在，来自共享音频行的首次原始转写，尚无原文时为 null。重新识别结果与原文不同只能成为本机候选，即使设备还未同步到原文也不能以任务结果覆盖共享字段。服务内部无任务返回 null，当前 HTTP 层保留 200 空响应体行为。

路径均相对于 `/omni-butler/api/v1`。30 分钟 WAV 可超过腾讯本地音频 5MB 限制，部署可配置 `PUBLIC_BASE_URL=https://自己的域名` 自动推导取音地址，或独立覆盖 `NOTE_ASR_PUBLIC_URL` 为可被腾讯下载的 HTTPS API 根地址（包含 `/omni-butler/api/v1`）。非空独立覆盖优先；升级采用基础地址时应删除或注释旧覆盖。任务短期签名 URL 绑定任务和四小时期限，每次访问再次检查未删除和有效授权状态，不暴露设备令牌。小文件不配置公网地址时使用内联音频。

腾讯 API 官方约束：[创建任务](https://cloud.tencent.com/document/api/1093/37823)、[查询结果](https://cloud.tencent.com/document/api/1093/37822)、[TC3 签名](https://cloud.tencent.com/document/api/213/30654)。`APP_ID` 不参与 API 3.0 签名。`CreateRecTask` 没有幂等请求参数，因此提交响应丢失或提交中崩溃会持久置为 `submissionUnknown`，禁止自动新建计费任务；轮询失败只查询原 `taskId`。原音、原始转写和候选结果分别保存，服务器不直接覆盖用户正文。

快照迁移使用现有部署密钥：先 `PUT /notes/audio/migration/stage`，multipart `syncKey`、`migrationId`、`segmentId`、`sha256`、`mime`、`file`；随后 `POST /sync/migrations`，`snapshotVersion:3`。每个音频元数据必须有匹配的完整暂存文件。仅当用户明确接受不完整迁移时传 `omittedAudioIds` UUID 数组；缺失文件保留不可用元数据。验证失败不替换服务器现有快照，提交时真实原音归属与数据在同一事务接管。未提交暂存 24 小时后清理。

首次创建先 PUT `note_entries`，再 PUT 初始 `note_versions`，初始 `base_revision` 等于本次新修订 UUID。后续正文编辑先 PUT 不可变 `note_versions`（新修订 UUID、编辑起点 `base_revision`、完整正文），再 PATCH `note_entries` 的 `body` 和 `revision`，放同一客户端事务。服务器发现基线不匹配时保留候选并跳过正文覆盖。版本行只允许 PATCH `deleted_at` 跟随整篇删除和恢复，正文及修订事实不可修改。普通编辑只 PATCH 实际变更列；恢复回收站需显式 PATCH `deleted_at:null`。笔记分类与标签使用 `taxonomy_entries.module='notes'`。

`creation_timezone` 原样保存创建时设备的 `timeZoneName|±HH:mm`，不把设备提供的名称推测成 IANA 地区。独立增量迁移为历史行补 `legacy:unknown`；创建后不随时区切换或编辑改变，同步服务与数据库触发器共同禁止修改。部署必须应用新增迁移并更新 PowerSync 查询；v3 完整迁移快照需包含该字段。

标签 PATCH 必须同时包含 `tags` 与 `tags_base`，后者来自客户端编辑前的标签值；两者都是最多十个无重复 UUID 的 JSON 数组文本。服务端按当前标签执行 `当前 ∪ (tags − tags_base) − (tags_base − tags)`，保留其他设备并发新增，也不复活其他设备已移除且本次未主动新增的标签。结果按规范小写 UUID 排序；合并超过十个时整事务拒绝，客户端保留待处理操作。辅助字段只参与同步回执摘要，归一化后剥除，不是数据库列；PUT 与完整迁移快照不能带 `tags_base`。不携带基线的标签 PATCH 被拒绝，其他元数据 PATCH 不需要基线。

生产 `NoteAudioStore` 使用 MinIO，原音和迁移暂存均写入独立私有桶 `omni-butler-note-audio`，内部 `put` 同时保存真实 MIME。对象键、摘要校验、大小限制、数据库及客户端接口保持原有契约。图片使用独立桶 `omni-butler-images`；两者复用连接、私有桶初始化和连接释放，图片开关不影响笔记音频。

Compose 固定内部 `MINIO_ENDPOINT=http://minio:9000`，凭证路径为 `MINIO_CREDENTIALS_FILE=/app/image-storage/credentials.json`。本机开发可显式指定测试端点与凭证文件，不能提交凭证内容。MinIO 失败不会回退写入服务器磁盘，也不会误报上传成功；恢复后使用原身份重试。下载仍经过后端鉴权，腾讯长音频仍使用上面的任务签名 API 链接，不公开桶或对象地址。

必须将 PostgreSQL、`image-storage-data` 和 `image-storage-credentials` 一起备份，即使关闭图片同步也如此。30 天回收站到期或永久删除会经数据库触发器持久记录对象清理工作，提交后删除 MinIO 原音；识别未配置时仍执行清理，删除失败保留回执重试。当前服务器尚未部署笔记功能，本次不执行历史磁盘原音迁移。
