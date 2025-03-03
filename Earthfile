VERSION 0.8

ARG --global SPECTRO_PUB_REPO=us-docker.pkg.dev/palette-images
ARG --global UBUNTU_IMAGE=${SPECTRO_PUB_REPO}/third-party/ubuntu:22.04
FROM ${UBUNTU_IMAGE}

ARG --global VERSION

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

release-fips:
    BUILD +package-tar \
        --PLATFORM=linux \
        --ARCH=amd64 \
        --ARCH=arm64 \
        --FIPS=true

    BUILD +palette-agent \
        --PLATFORM=linux \
        --ARCH=amd64 \
        --ARCH=arm64 \
        --FIPS=true

    BUILD +install-script \
        --FIPS=true

nightly:
    BUILD +package-tar \
        --PLATFORM=linux \
        --ARCH=amd64
    
    BUILD +palette-agent \
        --PLATFORM=linux \
        --ARCH=amd64
    
    BUILD +install-script

nightly-fips:
    BUILD +package-tar \
        --PLATFORM=linux \
        --ARCH=amd64 \
        --FIPS=true

    BUILD +palette-agent \
        --PLATFORM=linux \
        --ARCH=amd64 \
        --FIPS=true

    BUILD +install-script \
        --FIPS=true

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

    ARG FIPS=false
    ARG PE_VERSION=$(head -n 1 PE_VERSION)
    ARG PLATFORM=linux
    ARG ARCH=amd64
    ARG STYLUS_IMAGE=${SPECTRO_PUB_REPO}/edge/stylus-agent-mode-${PLATFORM}-${ARCH}:${PE_VERSION}
    
    WORKDIR /workdir
    COPY (+stylus-image/opt/spectrocloud/bin/palette-agent --PLATFORM=${PLATFORM} --ARCH=${ARCH} --STYLUS_IMAGE=${STYLUS_IMAGE}) /workdir/
    RUN chmod +x /workdir/palette-agent

    LET BIN_NAME=palette-agent-${PLATFORM}-${ARCH}
    IF $FIPS
        SET BIN_NAME=palette-agent-fips-${PLATFORM}-${ARCH}
    END

    SAVE ARTIFACT /workdir/palette-agent AS LOCAL ./build/${BIN_NAME}

package-tar:
    FROM +ubuntu
    
    ARG FIPS=false
    ARG PE_VERSION=$(head -n 1 PE_VERSION)
    ARG PLATFORM=linux
    ARG ARCH=amd64
    ARG STYLUS_IMAGE=${SPECTRO_PUB_REPO}/edge/stylus-agent-mode-${PLATFORM}-${ARCH}:${PE_VERSION}
    IF $FIPS
        ARG TAR_NAME=agent-mode-fips-${PLATFORM}-${ARCH}
    ELSE
        ARG TAR_NAME=agent-mode-${PLATFORM}-${ARCH}
    END

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

    ARG PE_VERSION=$(head -n 1 PE_VERSION)
    ARG IMAGE_REPO=${SPECTRO_PUB_REPO}/edge
    # https://github.com/spectrocloud/agent-mode/releases/download/v4.5.0-rc2/palette-agent-linux-amd64
    ARG AGENT_URL_PREFIX=https://github.com/spectrocloud/agent-mode/releases/download/${VERSION}
    ARG FIPS=false
    LET BIN_PREFIX=palette-agent
    LET SCRIPT_NAME=palette-agent-install.sh
    IF $FIPS
        SET BIN_PREFIX=palette-agent-fips
        SET SCRIPT_NAME=palette-agent-install-fips.sh
    END
    
    ENV PE_VERSION=${PE_VERSION}
    ENV IMAGE_REPO=${IMAGE_REPO}
    ENV AGENT_URL_PREFIX=${AGENT_URL_PREFIX}
    ENV BIN_PREFIX=${BIN_PREFIX}

    WORKDIR /workdir
    COPY palette-agent-install.sh.tmpl /workdir/palette-agent-install.sh.tmpl
    RUN envsubst '${PE_VERSION} ${IMAGE_REPO} ${AGENT_URL_PREFIX} ${BIN_PREFIX}' < /workdir/palette-agent-install.sh.tmpl > /workdir/${SCRIPT_NAME}
    RUN chmod +x /workdir/${SCRIPT_NAME}

    SAVE ARTIFACT /workdir/${SCRIPT_NAME} AS LOCAL ./build/${SCRIPT_NAME}
