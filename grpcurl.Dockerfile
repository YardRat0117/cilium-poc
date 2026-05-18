FROM alpine:latest as downloader
ARG VERSION=1.9.3
RUN wget https://github.com/fullstorydev/grpcurl/releases/download/v${VERSION}/grpcurl_${VERSION}_linux_x86_64.tar.gz && \
    tar -xzf grpcurl_${VERSION}_linux_x86_64.tar.gz

FROM alpine:latest
COPY --from=downloader /grpcurl /usr/local/bin/grpcurl
ENTRYPOINT ["grpcurl"]
