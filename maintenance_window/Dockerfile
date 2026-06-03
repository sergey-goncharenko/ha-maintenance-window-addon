ARG BUILD_FROM=ghcr.io/home-assistant/amd64-base:latest
# hadolint ignore=DL3006
FROM ${BUILD_FROM}

# Ensure shell pipefail behaviour for RUN commands
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Install runtime dependencies.
#   bash      - scripting
#   jq        - JSON parsing for Supervisor API responses (bashio also uses it)
#   curl      - HTTP calls to the Supervisor API
#   coreutils - reliable date/sleep arithmetic for scheduling
#   tzdata    - timezone data so schedules respect the configured TZ
RUN apk add --no-cache \
    bash \
    jq \
    curl \
    coreutils \
    tzdata

# Copy the s6-overlay service definitions and helper scripts.
COPY rootfs /

# Copy the legacy/standalone entrypoint as well (useful for local testing).
COPY run.sh /usr/bin/maintenance-window-run.sh
RUN chmod a+x /usr/bin/maintenance-window-run.sh \
    && chmod a+x /etc/s6-overlay/s6-rc.d/maintenance_window/run \
    && chmod a+x /etc/s6-overlay/s6-rc.d/maintenance_window/finish

# Build metadata labels (filled in by the Home Assistant builder).
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
    io.hass.version="${BUILD_VERSION}"
