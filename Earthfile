VERSION 0.8

ARG --global SPECTRO_PUB_REPO=us-docker.pkg.dev/palette-images
ARG --global UBUNTU_IMAGE=${SPECTRO_PUB_REPO}/third-party/ubuntu:22.04
FROM ${UBUNTU_IMAGE}

release:
    BUILD +package-tar \
        --PLATFORM=linux \
        --ARCH=amd64 \
        --ARCH=arm64
    
    BUILD +palette-agent \
        --PLATFORM=linux \
        --ARCH=amd64 \
        --ARCH=arm64

    BUILD +install-script

ubuntu:
    FROM ${UBUNTU_IMAGE}
    RUN apt-get update && apt-get install -y systemctl gettext-base
    COPY PE_VERSION PE_VERSION

stylus-image:
    ARG PLATFORM=linux
    ARG ARCH=amd64
    ARG STYLUS_IMAGE
    FROM --platform=$PLATFORM/$ARCH $STYLUS_IMAGE
    SAVE ARTIFACT ./*

palette-agent:
    FROM +ubuntu

    ARG VERSION=$(head -n 1 PE_VERSION)
    ARG PLATFORM=linux
    ARG ARCH=amd64
    ARG STYLUS_IMAGE=${SPECTRO_PUB_REPO}/edge/stylus-agent-mode-${PLATFORM}-${ARCH}:${VERSION}
    
    WORKDIR /workdir
    COPY (+stylus-image/opt/spectrocloud/bin/palette-agent --PLATFORM=${PLATFORM} --ARCH=${ARCH} --STYLUS_IMAGE=${STYLUS_IMAGE}) /workdir/
    RUN chmod +x /workdir/palette-agent

    SAVE ARTIFACT /workdir/palette-agent AS LOCAL ./build/palette-agent-${PLATFORM}-${ARCH}

package-tar:
    FROM +ubuntu
    
    ARG VERSION=$(head -n 1 PE_VERSION)
    ARG PLATFORM=linux
    ARG ARCH=amd64
    ARG STYLUS_IMAGE=${SPECTRO_PUB_REPO}/edge/stylus-agent-mode-${PLATFORM}-${ARCH}:${VERSION}
    ARG TAR_NAME=agent-mode-${PLATFORM}-${ARCH}

    WORKDIR /workdir/var/lib/spectro
    COPY (+stylus-image/ --PLATFORM=${PLATFORM} --ARCH=${ARCH} --STYLUS_IMAGE=${STYLUS_IMAGE}) /workdir/var/lib/spectro/stylus
    
    COPY package/tar/spectro-init.service /etc/systemd/system/spectro-init.service
    COPY package/tar/spectro-init.sh /workdir/var/lib/spectro/spectro-init.sh
    RUN mkdir -p /workdir/etc/systemd/system
    RUN cp -rfv /workdir/var/lib/spectro/stylus/etc/systemd/system/spectro* /etc/systemd/system/
    RUN cp -rfv /etc/systemd/system/spectro* /workdir/etc/systemd/system/

    RUN for service in /etc/systemd/system/spectro*; do systemctl enable "$(basename "$service")"; done

    RUN mkdir -p /workdir/etc/systemd/system/multi-user.target.wants
    RUN cp -rfv /etc/systemd/system/multi-user.target.wants/spectro* /workdir/etc/systemd/system/multi-user.target.wants/
    RUN mkdir -p /workdir/etc/systemd/system/local-fs.target.wants
    RUN cp -rfv /etc/systemd/system/local-fs.target.wants/spectro* /workdir/etc/systemd/system/local-fs.target.wants/
    RUN mkdir -p /workdir/etc/systemd/system/sysinit.target.wants
    RUN cp -rfv /etc/systemd/system/sysinit.target.wants/spectro* /workdir/etc/systemd/system/sysinit.target.wants/

    RUN tar -cvf /${TAR_NAME}.tar -C /workdir .

    SAVE ARTIFACT /${TAR_NAME}.tar  AS LOCAL ./build/

install-script:
    FROM +ubuntu

    ARG VERSION
    ARG PE_VERSION=$(head -n 1 PE_VERSION)
    ARG IMAGE_REPO=${SPECTRO_PUB_REPO}/edge
    # https://github.com/spectrocloud/agent-mode/releases/download/v4.5.0-rc2/palette-agent-linux-amd64
    ARG AGENT_URL_PREFIX=https://github.com/spectrocloud/agent-mode/releases/download/${VERSION}
    
    ENV PE_VERSION=${PE_VERSION}
    ENV IMAGE_REPO=${IMAGE_REPO}
    ENV AGENT_URL_PREFIX=${AGENT_URL_PREFIX}

    WORKDIR /workdir
    COPY install.sh.tmpl /workdir/install.sh.tmpl
    RUN envsubst '${PE_VERSION} ${IMAGE_REPO} ${AGENT_URL_PREFIX}' < /workdir/install.sh.tmpl > /workdir/install.sh
    RUN chmod +x /workdir/install.sh

    SAVE ARTIFACT /workdir/install.sh AS LOCAL ./build/install.sh
