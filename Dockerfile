FROM debian:stable-slim

ENV FLOW_INSTALL_URL=https://raw.githubusercontent.com/onflow/flow-cli/master/install.sh \
    APP_HOME=/app \
    SEED_DIR=/seed/state

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates jq bash openssl netcat-openbsd git \
 && rm -rf /var/lib/apt/lists/*

# Install Flow CLI
RUN bash -lc 'curl -fsSL "$FLOW_INSTALL_URL" | bash' \
 && mv /root/.local/bin/flow /usr/local/bin/flow \
 && chmod +x /usr/local/bin/flow \
 && flow version

WORKDIR ${APP_HOME}
# Bring in your project files (flow.json, contracts/, scripts/, transactions/, etc.)
COPY . ${APP_HOME}
RUN chmod +x ${APP_HOME}/scripts/*.sh || true

# ---------- PRE-SEED AT BUILD TIME ----------
# Start emulator in background with --persist, wait, seed, then stop.
RUN bash -lc '\
  set -euo pipefail; \
  mkdir -p "$SEED_DIR"; \
  echo "▶ Start emulator (build-time) with --persist to ${SEED_DIR}"; \
  flow emulator start --verbose --persist "$SEED_DIR" > /tmp/emulator-build.log 2>&1 & \
  EM_PID=$!; \
  echo -n "⏳ Waiting for emulator ... "; \
  for i in {1..60}; do nc -z 127.0.0.1 3569 && break || { echo -n "."; sleep 1; }; done; echo; \
  echo "▶ Seeding"; \
  # Your seed scripts can use `--network emulator` exactly like at runtime:
  [ -x ./local/setup_wallets.sh ] && ./local/setup_wallets.sh || true; \
  [ -x ./local/setup_emulator.sh ] && ./local/setup_emulator.sh || true; \
  echo "▶ Stop emulator (build-time)"; \
  kill $EM_PID && wait $EM_PID || true \
'

# ---------- RUNTIME ----------
EXPOSE 3569 8080
ENV FLOW_EMULATOR_FLAGS="--verbose --persist /seed/state"

# At runtime we just start the emulator that already contains the baked state.
ENTRYPOINT [ "bash", "-lc", "flow emulator start $FLOW_EMULATOR_FLAGS" ]
