FROM alpine:latest AS downloader
ARG VERSION=1.9.3

# 安装 wget 和 ca-certificates，并添加 --no-check-certificate 解决 SSL 问题
RUN apk add --no-cache wget ca-certificates && \
    wget --no-check-certificate \
         https://github.com/fullstorydev/grpcurl/releases/download/v${VERSION}/grpcurl_${VERSION}_linux_x86_64.tar.gz && \
    tar -xzf grpcurl_${VERSION}_linux_x86_64.tar.gz && \
    # 确保 grpcurl 二进制文件有执行权限
    chmod +x grpcurl

FROM alpine:latest
# 安装 ca-certificates 以便 grpcurl 能够验证 TLS 连接
RUN apk add --no-cache ca-certificates

# 修正路径：grpcurl 解压后在当前目录，而不是根目录
COPY --from=downloader /grpcurl /usr/local/bin/grpcurl

ENTRYPOINT ["grpcurl"]
