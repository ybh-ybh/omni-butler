#!/bin/sh
set -eu

# 凭证卷同时供 MinIO 写入和 API 只读访问。
credential_directory=/credentials
# JSON 文件是持久凭证的完整副本。
credential_json_file="$credential_directory/credentials.json"
# MinIO 从独立文本文件读取访问密钥。
access_key_file="$credential_directory/access-key"
# MinIO 从独立文本文件读取秘密密钥。
secret_key_file="$credential_directory/secret-key"

mkdir -p "$credential_directory"
chmod 700 "$credential_directory"

# 访问密钥优先从唯一持久来源 JSON 恢复。
access_key=''
# 秘密密钥与访问密钥必须来自同一份持久状态。
secret_key=''
if [ -s "$credential_json_file" ]; then
  # 兼容旧初始化容器写入的无空格 JSON 格式。
  credential_json=$(cat "$credential_json_file")
  access_key=${credential_json#*\"accessKeyId\":\"}
  access_key=${access_key%%\"*}
  secret_key=${credential_json#*\"secretAccessKey\":\"}
  secret_key=${secret_key%%\"*}
elif [ -s "$access_key_file" ] && [ -s "$secret_key_file" ]; then
  access_key=$(cat "$access_key_file")
  secret_key=$(cat "$secret_key_file")
else
  # 首次启动从内核随机源生成 160 位访问密钥。
  access_key=$(od -An -N20 -tx1 /dev/urandom | tr -d ' \n')
  # 首次启动从内核随机源生成 256 位秘密密钥。
  secret_key=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
fi

case "$access_key" in
  *[!a-f0-9]*|'')
    echo '图片存储访问密钥损坏，请恢复凭证卷备份；不会自动更换密钥。' >&2
    exit 1
    ;;
esac
if [ "${#access_key}" -ne 40 ]; then
  echo '图片存储访问密钥长度错误，请恢复凭证卷备份；不会自动更换密钥。' >&2
  exit 1
fi
case "$secret_key" in
  *[!a-f0-9]*|'')
    echo '图片存储秘密密钥损坏，请恢复凭证卷备份；不会自动更换密钥。' >&2
    exit 1
    ;;
esac
if [ "${#secret_key}" -ne 64 ]; then
  echo '图片存储秘密密钥长度错误，请恢复凭证卷备份；不会自动更换密钥。' >&2
  exit 1
fi

# 临时文件与目标文件位于同一卷，重命名时保持原子可见。
credential_json_temporary="$credential_json_file.tmp"
# 访问密钥临时文件只在本次启动期间存在。
access_key_temporary="$access_key_file.tmp"
# 秘密密钥临时文件只在本次启动期间存在。
secret_key_temporary="$secret_key_file.tmp"
printf '{"accessKeyId":"%s","secretAccessKey":"%s"}' "$access_key" "$secret_key" > "$credential_json_temporary"
printf '%s' "$access_key" > "$access_key_temporary"
printf '%s' "$secret_key" > "$secret_key_temporary"
chmod 600 "$credential_json_temporary" "$access_key_temporary" "$secret_key_temporary"
chown 1000:1000 "$credential_json_temporary" "$access_key_temporary" "$secret_key_temporary"
mv "$credential_json_temporary" "$credential_json_file"
mv "$access_key_temporary" "$access_key_file"
mv "$secret_key_temporary" "$secret_key_file"
chown 1000:1000 "$credential_directory"

# 使用 Compose 传入的 server 参数替换当前 shell 进程。
exec /usr/bin/minio "$@"
