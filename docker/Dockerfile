FROM nixos/nix

RUN nix-env -iA \
    nixpkgs.openssh \
    nixpkgs.nodejs_22 \
    nixpkgs.gnused \
    nixpkgs.cacert \
    nixpkgs.google-cloud-sdk \
    nixpkgs.gh \
    nixpkgs.jq

ENV PATH="/usr/local/bin:/root/.nix-profile/bin:${PATH}"
ENV SSL_CERT_FILE=/root/.nix-profile/etc/ssl/certs/ca-bundle.crt
ENV NIX_SSL_CERT_FILE=/root/.nix-profile/etc/ssl/certs/ca-bundle.crt
ENV NPM_CONFIG_PREFIX=/usr/local

# claude is a compiled FHS binary; symlink nix's glibc linker to the standard path
RUN mkdir -p /lib64 && \
    ln -sf "$(find /nix/store -maxdepth 3 -name 'ld-linux-x86-64.so.2' | grep -v debug | head -1)" \
           /lib64/ld-linux-x86-64.so.2

# plugin scripts use #!/bin/bash; symlink nix bash to the standard FHS path
RUN mkdir -p /bin && ln -sf /root/.nix-profile/bin/bash /bin/bash

RUN npm install -g @anthropic-ai/claude-code

RUN mkdir -p /root/.claude
COPY settings.json /root/.claude/settings.json
COPY claude-state.json /root/.claude.json


COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /workspace
ENTRYPOINT ["/entrypoint.sh"]
