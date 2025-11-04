FROM debian:stable-slim

ENV FLOW_INSTALL_URL=https://raw.githubusercontent.com/onflow/flow-cli/master/install.sh \
    APP_HOME=/app \
    SEED_DIR=/seed/state \
    FOUNDRY_DIR=/root/.foundry

# Base deps + build essentials for Foundry (Rust) toolchain
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates jq bash openssl netcat-openbsd git \
    build-essential pkg-config libssl-dev \
 && rm -rf /var/lib/apt/lists/*

# --- Install Foundry ---
RUN bash -lc 'curl -L https://foundry.paradigm.xyz | bash' \
 && bash -lc '"$FOUNDRY_DIR/bin/foundryup"' \
 && ln -s "$FOUNDRY_DIR/bin/forge"  /usr/local/bin/forge  \
 && ln -s "$FOUNDRY_DIR/bin/anvil"  /usr/local/bin/anvil  \
 && ln -s "$FOUNDRY_DIR/bin/cast"   /usr/local/bin/cast   \
 && ln -s "$FOUNDRY_DIR/bin/chisel" /usr/local/bin/chisel \
 && forge --version && anvil --version && cast --version

# Install Flow CLI
RUN bash -lc 'curl -fsSL "$FLOW_INSTALL_URL" | bash' \
 && mv /root/.local/bin/flow /usr/local/bin/flow \
 && chmod +x /usr/local/bin/flow \
 && flow version

WORKDIR ${APP_HOME}
COPY . ${APP_HOME}
RUN chmod +x ${APP_HOME}/local/*.sh || true

# Use bash as default shell for subsequent RUNs
SHELL ["/bin/bash", "-lc"]

# ---------- PRE-SEED AT BUILD TIME ----------
RUN set -euo pipefail; \
  mkdir -p "$SEED_DIR"; \
  echo "▶ Start emulator (build-time) with --persist to ${SEED_DIR}"; \
  flow emulator start --verbose --contracts --persist "$SEED_DIR" > /tmp/emulator-build.log 2>&1 & \
  EM_PID=$!; \
  cleanup() { \
    echo "▶ Stop EVM Gateway"; \
    [[ -n "${GW_PID:-}" ]] && kill "$GW_PID" 2>/dev/null || true; \
    [[ -n "${GW_PID:-}" ]] && wait "$GW_PID" 2>/dev/null || true; \
    echo "▶ Stop emulator (build-time)"; \
    kill "$EM_PID" 2>/dev/null || true; \
    wait "$EM_PID" 2>/dev/null || true; \
  }; \
  trap cleanup EXIT; \
  echo -n "⏳ Waiting for emulator ... "; \
  for i in {1..60}; do nc -z 127.0.0.1 3569 && break || { echo -n "."; sleep 1; }; done; echo; \
  echo "▶ Seeding"; \
  ./local/setup_wallets.sh; \
  echo "▶ Start EVM Gateway"; \
  rm -rf db/; \
  flow evm gateway \
    --flow-network-id=emulator \
    --evm-network-id=preview \
    --coinbase=FACF71692421039876a5BB4F10EF7A439D8ef61E \
    --coa-address=e03daebed8ca0615 \
    --coa-key=7549ce91aa82b6b42b060df5ab60d1246ae61e83177b5adb81c697e41d9e587a \
    --gas-price=0 \
    --rpc-port 8545 \
    > /tmp/evm-gateway-build.log 2>&1 & \
  GW_PID=$!; \
  echo -n "⏳ Waiting for EVM Gateway (8545) ... "; \
  for i in {1..120}; do \
    if nc -z 127.0.0.1 8545; then echo " ready."; break; fi; \
    # bail out if the gateway died and show logs
    if ! kill -0 "$GW_PID" 2>/dev/null; then \
      echo; echo "❌ Gateway exited early. Last 200 lines:"; \
      tail -n 200 /tmp/evm-gateway-build.log || true; \
      exit 1; \
    fi; \
    echo -n "."; sleep 1; \
  done; echo; \
  ./local/punchswap/setup_punchswap.sh; \
  ./local/punchswap/e2e_punchswap.sh; \
  ./local/setup_emulator.sh; \
  ./local/setup_bridged_tokens.sh; \
  echo "✅ Build-time seeding complete."

# ---------- RUNTIME ----------
EXPOSE 3569 8080 8545

ENV FLOW_EMULATOR_FLAGS="--verbose --contracts --persist /seed/state"
ENTRYPOINT [ "bash", "-lc", "flow emulator start $FLOW_EMULATOR_FLAGS" ]
