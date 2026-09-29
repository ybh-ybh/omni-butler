# syntax=docker/dockerfile:1.7
# 固定最终社区源码；构建不依赖已撤销的官方二进制分发。
FROM golang:1.24-alpine3.22@sha256:3641e0d9b931dc4f2f185dcd669c4679670e9277c8166a838ddb98a2d4389cb5 AS build
RUN apk add --no-cache git ca-certificates
WORKDIR /src
ENV CGO_ENABLED=0
RUN git init minio && cd minio && git remote add origin https://github.com/minio/minio.git \
    && git fetch --depth 1 origin 9e49d5e7a648f00e26f2246f4dc28e6b07f8c84a \
    && git checkout --detach FETCH_HEAD \
    && test "$(git rev-parse HEAD)" = 9e49d5e7a648f00e26f2246f4dc28e6b07f8c84a \
    && test "$(grep -c 's3APIMiddleware(api.PutObjectExtractHandler, traceHdrsS3HFlag)' cmd/api-router.go)" = 1 \
    && sed -i 's/s3APIMiddleware(api.PutObjectExtractHandler, traceHdrsS3HFlag)/s3APIMiddleware(errorResponseHandler, traceHdrsS3HFlag)/' cmd/api-router.go \
    && ! grep -q 'api.PutObjectExtractHandler' cmd/api-router.go \
    && go mod download && go mod verify \
    && go build -mod=readonly -trimpath -buildvcs=false -o /out/minio .
# 拒绝本应用不使用的未签名流式请求，避免最终社区版本的认证绕过路径。
RUN cd /src/minio \
    && test "$(grep -c 'var handler http.HandlerFunc = func(w http.ResponseWriter, r \*http.Request) {' cmd/api-router.go)" = 1 \
    && sed -i '/var handler http.HandlerFunc = func(w http.ResponseWriter, r \*http.Request) {/a\        if r.Header.Get("X-Amz-Content-Sha256") == "STREAMING-UNSIGNED-PAYLOAD-TRAILER" { errorResponseHandler(w, r); return }' cmd/api-router.go \
    && go build -mod=readonly -trimpath -buildvcs=false -o /out/minio .

FROM alpine:3.22
RUN apk add --no-cache ca-certificates \
    && mkdir /data /credentials \
    && chown 1000:1000 /data /credentials
COPY --from=build /out/minio /usr/local/bin/minio
COPY --from=build /src/minio/LICENSE /licenses/minio-LICENSE
LABEL org.opencontainers.image.source="https://github.com/minio/minio" \
      org.opencontainers.image.revision="9e49d5e7a648f00e26f2246f4dc28e6b07f8c84a" \
      io.omni-butler.hardening="Snowball extraction and unsigned streaming trailers disabled; internal API-only storage"
USER 1000:1000
EXPOSE 9000
CMD ["minio", "server", "/data", "--address", ":9000"]
