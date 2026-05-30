FROM nixos/nix

RUN nix-env -iA \
    nixpkgs.openssh \
    nixpkgs.nodejs_22 \
    nixpkgs.gnused \
    nixpkgs.cacert \
    nixpkgs.curl \
    nixpkgs.google-cloud-sdk \
    nixpkgs.gh \
    nixpkgs.jq

ENV PATH="/usr/local/bin:/root/.nix-profile/bin:${PATH}"
ENV SSL_CERT_FILE=/root/.nix-profile/etc/ssl/certs/ca-bundle.crt
ENV NIX_SSL_CERT_FILE=/root/.nix-profile/etc/ssl/certs/ca-bundle.crt
ENV NPM_CONFIG_PREFIX=/usr/local

# claude is a compiled FHS binary; symlink nix's glibc linker to the standard path
# Both the linker name and its expected directory differ by architecture:
#   x86_64  -> /lib64/ld-linux-x86-64.so.2
#   aarch64 -> /lib/ld-linux-aarch64.so.1
RUN case "$(uname -m)" in \
        x86_64)  linker_name="ld-linux-x86-64.so.2"; linker_dir="/lib64" ;; \
        aarch64) linker_name="ld-linux-aarch64.so.1"; linker_dir="/lib"  ;; \
        *) echo "Unsupported arch: $(uname -m)" && exit 1 ;; \
    esac && \
    mkdir -p "${linker_dir}" && \
    if [ ! -e "${linker_dir}/${linker_name}" ]; then \
        linker="$(find /nix/store -name "${linker_name}" | grep -v debug | head -1)"; \
        [ -n "$linker" ] && ln -sf "$linker" "${linker_dir}/${linker_name}"; \
    fi

# plugin scripts use #!/bin/bash; symlink nix bash to the standard FHS path
RUN mkdir -p /bin && ln -sf /root/.nix-profile/bin/bash /bin/bash

RUN npm install -g @anthropic-ai/claude-code

RUN curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | RTK_INSTALL_DIR=/usr/local/bin sh

COPY .gitconfig /root/.gitconfig

RUN mkdir -p /root/.claude
COPY settings.json /root/.claude/settings.json
COPY claude-state.json /root/.claude.json

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /workspace
ENTRYPOINT ["/entrypoint.sh"]
