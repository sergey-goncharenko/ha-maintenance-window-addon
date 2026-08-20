# Default lets CI (buildx, no --build-arg) produce a multi-arch image, while
# Supervisor's local-build fallback can still override via build.yaml.
ARG BUILD_FROM=alpine:3.20
FROM ${BUILD_FROM}

# Plain Alpine: no bashio, no apk step, no extra layers. run.sh is POSIX sh, so
# busybox ash is all that is required. Keeping the image tiny is deliberate -
# on a 1 GB Pi the pull itself has to be cheap.
COPY run.sh /run.sh
RUN chmod a+x /run.sh

# Build metadata (accepted so the shared CI workflow can pass them uniformly)
ARG BUILD_ARCH
ARG BUILD_DATE
ARG BUILD_DESCRIPTION
ARG BUILD_NAME
ARG BUILD_REF
ARG BUILD_REPOSITORY
ARG BUILD_VERSION
LABEL \
    io.hass.name="${BUILD_NAME}" \
    io.hass.description="${BUILD_DESCRIPTION}" \
    io.hass.arch="${BUILD_ARCH}" \
    io.hass.type="addon" \
    io.hass.version="${BUILD_VERSION}" \
    org.opencontainers.image.source="https://github.com/${BUILD_REPOSITORY}" \
    org.opencontainers.image.revision="${BUILD_REF}" \
    org.opencontainers.image.created="${BUILD_DATE}"

CMD [ "/run.sh" ]
