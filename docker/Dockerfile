# Releases:
#   https://hub.docker.com/_/docker/tags
ARG DOCKER_VERSION=28
FROM docker:${DOCKER_VERSION}

LABEL maintainer="Josh.5 <jsunnex@gmail.com>"

RUN \
    echo "**** Install entrypoint dependencies ****" \
        && apk add --no-cache \
            bash \
            wget \
    && \
    echo "**** Install Sentry installation dependencies ****" \
        && apk add --no-cache \
            coreutils \
            cgroup-tools \
    && \
    echo "**** Install Sentry config dependencies ****" \
        && wget -q "https://github.com/mikefarah/yq/releases/download/v4.43.1/yq_linux_amd64" \
            -O "/usr/bin/yq" \
        && chmod +x "/usr/bin/yq" \
    && \
    echo

COPY overlay/ /

ENTRYPOINT ["/entrypoint.sh"]
CMD []
