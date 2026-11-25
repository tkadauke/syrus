# syntax=docker/dockerfile:1
# check=error=true

# The standard Syrus coworker base image.
#
# Built through the Runtime Image Service build plane (rootless buildah, no
# network except the administrator's build allowlist) and referenced only by
# digest. It contains every bundled agent-provider CLI and the support tools a
# coworker turn needs, so switching provider never requires a rebuild.
#
# Rules this file keeps:
#   - Everything is pinned: the base image by digest, apt/npm versions by ARG,
#     and every downloaded artifact by a checksum verified in the same RUN.
#   - No credential is ever an ARG, ENV, COPY, or RUN input. Provider
#     credentials are injected per turn at runtime and never stored in a layer.
#   - The image runs as a fixed non-root identity and needs no write access to
#     its own filesystem: Container Execution mounts it read-only and provides
#     the workspace, provider home, and /tmp. Nothing here relies on being able
#     to write outside those paths at runtime.
#
# See docs/engineering/operations/coworker-base-image.md for the update
# mechanism. images/coworker-base/base.yml is the machine-readable contract.

# Debian 12 (bookworm-slim) multi-arch index, pinned by digest. Update it with
# the rest of the pins (see the operations doc), never by editing a tag.
ARG BASE_IMAGE=docker.io/library/debian:bookworm-slim@sha256:e67eeead736ff7bbe258ef088bff683635c561b1fcfefad0806c1df4ab49ce0e
FROM ${BASE_IMAGE}

ARG DEBIAN_FRONTEND=noninteractive
ARG NODE_MAJOR=22
ARG NODESOURCE_GPG_FINGERPRINT=6F71F525282841EEDAF851B42F59B5F99B1BE0B4
ARG CLAUDE_CODE_VERSION=2.1.330
ARG CODEX_CLI_VERSION=0.171.0
ARG ANTIGRAVITY_CLI_VERSION=1.2.1
ARG ANTIGRAVITY_CLI_BUILD=5123043593420800
ARG ANTIGRAVITY_CLI_LINUX_AMD64_SHA512=0629fe69e6949b35707935ef35da016074ea29a5d989a05f740713e0a9e927bf52ff1eada0204d3338779a469c938b6b7c5c44de2d296e5e8db255d26568de38
ARG ANTIGRAVITY_CLI_LINUX_ARM64_SHA512=f6dd6057a82dcbc4ab0878d99c4b84cfc45c3e2f12647eaf435322ecdd18d0190620bca943185f542431b93f34f5ea19cf84e8fdb902e64529e110bfa0a5a46f
ARG MUSE_LAUNCHER_URL=https://api.meta.ai/muse-launcher.sh
ARG MUSE_LAUNCHER_SHA256=ffb95b823e2a71f49ce98f9ddcb7cd7c731b77615aae9f5f253819c69453079f
ARG MUSE_VERSION=1.4.9-R6297.1
ARG MUSE_LINUX_AMD64_SHA256=a228010021276e112aa8422eb56ae82c0375405701950f6529bed4c9fe8abe05
ARG MUSE_LINUX_ARM64_SHA256=d64c61f4357b246fb46ab4f01332b36066bb4ac17541a88f520680354a32e06a

# The identity the image runs as. Container Execution passes the same uid:gid
# explicitly; this default only has to agree with it.
ARG COWORKER_UID=1000
ARG COWORKER_GID=1000

# Support tools: version control and transport (git, ssh, curl), code search
# (ripgrep, fd), data handling (jq, unzip, less), a scripting runtime
# (python3), and procps for process inspection. Node comes from NodeSource
# because the npm-packaged provider CLIs need a current LTS.
RUN set -eu; \
    apt-get update -qq; \
    apt-get install --no-install-recommends -y \
      ca-certificates curl git gnupg jq less openssh-client procps python3 ripgrep fd-find unzip; \
    ln -s "$(command -v fdfind)" /usr/local/bin/fd; \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key -o /tmp/nodesource.key; \
    test "$(gpg --show-keys --with-colons /tmp/nodesource.key | awk -F: '$1 == "fpr" { print $10; exit }')" = "${NODESOURCE_GPG_FINGERPRINT}"; \
    gpg --dearmor -o /usr/share/keyrings/nodesource.gpg /tmp/nodesource.key; \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" > /etc/apt/sources.list.d/nodesource.list; \
    apt-get update -qq; \
    apt-get install --no-install-recommends -y nodejs; \
    rm -f /tmp/nodesource.key /etc/apt/sources.list.d/nodesource.list /usr/share/keyrings/nodesource.gpg; \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

# Claude Code and Codex are npm packages pinned to exact versions.
RUN set -eu; \
    npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" "@openai/codex@${CODEX_CLI_VERSION}"; \
    npm cache clean --force; \
    rm -rf /root/.npm /tmp/*

# Antigravity (agy): checksum-pinned release tarball per architecture.
RUN set -eu; \
    case "$(dpkg --print-architecture)" in \
      amd64) agy_dir=x64; agy_arch=x64; agy_sha512="${ANTIGRAVITY_CLI_LINUX_AMD64_SHA512}" ;; \
      arm64) agy_dir=arm; agy_arch=arm64; agy_sha512="${ANTIGRAVITY_CLI_LINUX_ARM64_SHA512}" ;; \
      *) echo "unsupported architecture for Antigravity CLI: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    tarball=/tmp/antigravity-cli.tar.gz; \
    curl -fsSL -o "$tarball" \
      "https://storage.googleapis.com/antigravity-public/antigravity-cli/${ANTIGRAVITY_CLI_VERSION}-${ANTIGRAVITY_CLI_BUILD}/linux-${agy_dir}/cli_linux_${agy_arch}.tar.gz"; \
    echo "${agy_sha512}  ${tarball}" | sha512sum -c -; \
    tar -xzf "$tarball" -C /tmp antigravity; \
    install -m 0755 /tmp/antigravity /usr/local/bin/agy; \
    rm -f "$tarball" /tmp/antigravity

# Muse: the launcher and the native binary it dispatches to are both
# checksum-pinned. Auto-update is disabled; the pinned version is the version.
RUN set -eu; \
    case "$(dpkg --print-architecture)" in \
      amd64) muse_arch=x86; muse_sha256="${MUSE_LINUX_AMD64_SHA256}" ;; \
      arm64) muse_arch=aarch64; muse_sha256="${MUSE_LINUX_ARM64_SHA256}" ;; \
      *) echo "unsupported architecture for Muse: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    mkdir -p /opt/muse/bin; \
    curl -fsSL "${MUSE_LAUNCHER_URL}" -o /opt/muse/bin/muse; \
    echo "${MUSE_LAUNCHER_SHA256}  /opt/muse/bin/muse" | sha256sum -c -; \
    muse_binary="/opt/muse/bin/muse-bin-${MUSE_VERSION}"; \
    curl -fsSL "https://lookaside.facebook.com/lookaside/muse/download/?channel=muse&version=${MUSE_VERSION}&file=muse-${muse_arch}-linux" -o "$muse_binary"; \
    echo "${muse_sha256}  ${muse_binary}" | sha256sum -c -; \
    chmod 0755 /opt/muse/bin/muse "$muse_binary"; \
    printf '%s\n' "${MUSE_VERSION}" > /opt/muse/bin/.muse-version
ENV PATH="/opt/muse/bin:${PATH}" \
    MUSE_NO_AUTO_UPDATE="1"

# The runtime contract probe: Syrus runs it (under the same confinement real
# turns get) to verify identity, provider binaries, and read-only operation.
COPY --chmod=0755 syrus-base-probe /usr/local/bin/syrus-base-probe

# The non-root identity and the mount points Container Execution fills in.
# /workspace, the provider home, and /tmp are the only writable paths at
# runtime; they are provided as mounts, so the directories exist here empty.
RUN set -eu; \
    groupadd --system --gid "${COWORKER_GID}" coworker; \
    useradd coworker --uid "${COWORKER_UID}" --gid "${COWORKER_GID}" --no-create-home --home-dir /home/coworker --shell /bin/bash; \
    mkdir -p /workspace /home/coworker; \
    chown "${COWORKER_UID}:${COWORKER_GID}" /workspace /home/coworker; \
    chmod 1777 /tmp

# Identity and layout contract, recorded as OCI labels. Keep in step with
# images/coworker-base/base.yml (a spec enforces it).
LABEL org.opencontainers.image.title="syrus-coworker-base" \
      org.opencontainers.image.source="https://github.com/tkadauke/syrus" \
      io.syrus.coworker-base.generation="1" \
      io.syrus.coworker-base.runtime-abi="1" \
      io.syrus.coworker-base.user="coworker" \
      io.syrus.coworker-base.providers="claude,codex,agy,muse"

ENV HOME=/home/coworker \
    NPM_CONFIG_UPDATE_NOTIFIER=false \
    CLAUDE_CODE_DISABLE_AUTOUPDATER=1 \
    DISABLE_AUTOUPDATER=1

# Build-time smoke test, run as the final non-root identity: every provider
# binary starts, and the identity is not root.
USER ${COWORKER_UID}:${COWORKER_GID}
WORKDIR /workspace
RUN /usr/local/bin/syrus-base-probe --build

CMD ["/bin/bash"]
