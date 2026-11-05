# Same pinned WSL rootfs bootstrap imports, plus the pinned actions-runner
# tarball. Inner dockerd is 27.3.1: that is the daemon phase 1 used to publish
# mysql:8.4 (8.4.11) on 127.0.0.1:3306. The job user has no sudo. The image
# carries the host tools ci.yml and scripts/check-workspace-lints.sh need,
# because a job cannot apt-get. RUSTFLAGS=-C linker-features=-lld needs cc
# from build-essential. setup-node and cargo install unpack with tar, xz, unzip.
FROM scratch
ADD ubuntu-noble-wsl-amd64-wsl.rootfs.tar.gz /

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get full-upgrade -y \
      -o Dpkg::Options::=--force-confdef \
      -o Dpkg::Options::=--force-confold \
    && apt-get install -y --no-install-recommends \
      adduser \
      bash \
      build-essential \
      ca-certificates \
      curl \
      git \
      gnupg \
      iptables \
      jq \
      libdbus-1-dev \
      mysql-client \
      openssl \
      passwd \
      pkg-config \
      tar \
      unzip \
      xz-utils \
    && curl --fail --silent --show-error --location --output /tmp/docker.gpg \
      https://download.docker.com/linux/ubuntu/gpg \
    && echo '1500c1f56fa9e26b9b8f42452a553675796ade0807cdce11975eb98170b3a570  /tmp/docker.gpg' | sha256sum -c - \
    && gpg --show-keys --with-colons /tmp/docker.gpg | awk -F: '/^fpr:/ { print $10 }' | grep -qx '9DC858229FC7DD38854AE2D88D81803C0EBFCD88' \
    && install -d -m 0755 /etc/apt/keyrings \
    && gpg --dearmor < /tmp/docker.gpg > /etc/apt/keyrings/docker.gpg \
    && rm -f /tmp/docker.gpg \
    && printf '%s\n' 'deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu noble stable' \
      > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
      docker-ce=5:27.3.1-1~ubuntu.24.04~noble \
      docker-ce-cli=5:27.3.1-1~ubuntu.24.04~noble \
      containerd.io=1.7.29-1~ubuntu.24.04~noble \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --shell /bin/bash runner \
    && groupadd -f docker \
    && usermod -aG docker runner \
    && if id -nG runner | tr ' ' '\n' | grep -qx sudo; then gpasswd -d runner sudo; fi \
    && rm -f /etc/sudoers.d/runner \
    && if command -v sudo >/dev/null 2>&1; then \
         listing=$(sudo -n -l -U runner 2>&1 || true); \
         printf '%s\n' "$listing"; \
         if printf '%s\n' "$listing" | grep -q 'may run the following'; then \
           echo 'runner has sudo; image build stopped' >&2; exit 1; \
         fi; \
         if ! printf '%s\n' "$listing" | grep -q 'not allowed to run sudo'; then \
           echo 'runner sudo listing was not a denial; image build stopped' >&2; exit 1; \
         fi; \
       fi

COPY ephemeral-entry.sh /opt/aap-runner/ephemeral-entry.sh
COPY actions-runner-linux-x64-2.338.2.tar.gz /tmp/actions-runner.tar.gz

RUN mkdir -p /opt/actions-runner \
    && tar -xzf /tmp/actions-runner.tar.gz -C /opt/actions-runner \
    && rm -f /tmp/actions-runner.tar.gz \
    && /opt/actions-runner/bin/installdependencies.sh \
    && chown -R runner:runner /opt/actions-runner \
    && chmod 755 /opt/aap-runner/ephemeral-entry.sh \
    && if id -nG runner | tr ' ' '\n' | grep -qx sudo; then \
         echo 'runner gained sudo from installdependencies' >&2; exit 1; \
       fi \
    && if command -v sudo >/dev/null 2>&1; then \
         listing=$(sudo -n -l -U runner 2>&1 || true); \
         printf '%s\n' "$listing"; \
         if printf '%s\n' "$listing" | grep -q 'may run the following'; then \
           echo 'runner gained sudo from installdependencies' >&2; exit 1; \
         fi; \
         if ! printf '%s\n' "$listing" | grep -q 'not allowed to run sudo'; then \
           echo 'runner sudo listing was not a denial after installdependencies' >&2; exit 1; \
         fi; \
       fi

# Node.js LTS, system-wide, so `node` and `npm` are on PATH for the runner
# user. Any checksum mismatch fails the build.
RUN curl --fail --silent --show-error --location --output /tmp/node.tar.xz \
      https://nodejs.org/dist/v26.13.0/node-v26.13.0-linux-x64.tar.xz \
    && echo 'd28a96af6c38596f6d9d97c0ee531c13d238d757742387d1928de822d959e997  /tmp/node.tar.xz' | sha256sum -c - \
    && tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 --no-same-owner \
      --anchored --exclude=node-v26.13.0-linux-x64/CHANGELOG.md \
      --exclude=node-v26.13.0-linux-x64/LICENSE --exclude=node-v26.13.0-linux-x64/README.md \
    && rm -f /tmp/node.tar.xz \
    && node --version \
    && npm --version

USER root
ENTRYPOINT ["/opt/aap-runner/ephemeral-entry.sh"]
