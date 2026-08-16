#!/usr/bin/env bash
# ===========================================================================
# preflight.sh - environment validation. Runs FIRST, fails fast, and is fully
# runnable standalone (`./scripts/preflight.sh`). It is NON-MUTATING: it never
# changes your system, so it is safe to run any time.
#
# For every check it prints PASS / WARN / FAIL. Every FAIL prints the exact
# remediation command for your detected OS, and the script exits non-zero so a
# broken environment can never reach `terraform apply`.
# ===========================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/common.sh"
detect_platform

# --- Required minimum versions (single source of truth) --------------------
MIN_TERRAFORM_VERSION="1.5.0"
MIN_ANSIBLE_VERSION="2.15.0"
MIN_DOCKER_VERSION="20.10.0"      # kreuzwerker/docker v3 needs Docker API 1.41+
MIN_MAX_MAP_COUNT=262144          # Elasticsearch mmap requirement
REQUIRED_MEMORY_MB=3072           # ES(2048)+Kibana(1024) headroom is tight below this
REQUIRED_DISK_GB=6                # images (~2.5GB) + volumes + slack

# --- Values that mirror Terraform defaults (read tfvars if present) --------
TFVARS="${REPO_ROOT}/terraform/terraform.tfvars"
read_tfvar() { # read_tfvar NAME DEFAULT
  local name="$1" def="$2" val=""
  if [ -f "$TFVARS" ]; then
    val="$(grep -E "^[[:space:]]*${name}[[:space:]]*=" "$TFVARS" 2>/dev/null \
      | head -1 | sed -E 's/[^=]*=[[:space:]]*//; s/[",]//g; s/[[:space:]]*$//')"
  fi
  printf '%s' "${val:-$def}"
}
PROJECT_PREFIX="$(read_tfvar project_prefix elk-local)"
HTTPS_PORT="$(read_tfvar published_https_port 8443)"
NETWORK_SUBNET="$(read_tfvar network_subnet 172.31.240.0/24)"

# --- Result tracking -------------------------------------------------------
PASS_COUNT=0; WARN_COUNT=0; FAIL_COUNT=0
pass() { PASS_COUNT=$((PASS_COUNT+1)); printf '  %s[PASS]%s %s\n' "$C_GREEN" "$C_RESET" "$1"; }
warn() { WARN_COUNT=$((WARN_COUNT+1)); printf '  %s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$1"; }
fail() {
  FAIL_COUNT=$((FAIL_COUNT+1)); printf '  %s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$1"
  if [ -n "${2:-}" ]; then printf '         %sfix:%s %s\n' "$C_BOLD" "$C_RESET" "$2"; fi
}

# semver "a >= b" using sort -V
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }

# ---------------------------------------------------------------------------
section "Preflight for ${PROJECT_PREFIX} (kernel=${PLATFORM_KERNEL} arch=${PLATFORM_ARCH} wsl=${IS_WSL})"

# Precompute a few things used by several checks.
DOCKER_OK="false"
DOCKER_DESKTOP="false"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  DOCKER_OK="true"
  if docker info --format '{{.OperatingSystem}}' 2>/dev/null | grep -qi 'docker desktop'; then
    DOCKER_DESKTOP="true"
  fi
fi

# ======================== TOOLING =========================================
section "Tooling"

# 1. docker binary + daemon reachable
if ! command -v docker >/dev/null 2>&1; then
  case "$PLATFORM_KERNEL" in
    Darwin) fix="brew install --cask docker  # then launch Docker Desktop" ;;
    *)      fix="curl -fsSL https://get.docker.com | sh" ;;
  esac
  fail "docker binary not found" "$fix"
elif [ "$DOCKER_OK" != "true" ]; then
  fail "docker is installed but the daemon is unreachable (docker info failed)" \
       "Start Docker: 'sudo systemctl start docker' (Linux) or launch Docker Desktop (macOS/Windows)"
else
  pass "docker present and daemon reachable"
fi

# 2. Docker engine version >= minimum
if [ "$DOCKER_OK" = "true" ]; then
  DOCKER_VER="$(docker version --format '{{.Server.Version}}' 2>/dev/null | sed 's/[^0-9.].*//')"
  if [ -n "$DOCKER_VER" ] && ver_ge "$DOCKER_VER" "$MIN_DOCKER_VERSION"; then
    pass "docker engine ${DOCKER_VER} >= ${MIN_DOCKER_VERSION}"
  else
    fail "docker engine ${DOCKER_VER:-unknown} < required ${MIN_DOCKER_VERSION}" \
         "Upgrade Docker Engine / Docker Desktop to a current release"
  fi
fi

# 3. Can talk to the Docker socket without sudo (Linux)
if [ "$PLATFORM_KERNEL" = "Linux" ] && [ "$DOCKER_DESKTOP" != "true" ]; then
  if [ "$DOCKER_OK" = "true" ]; then
    pass "current user can access the Docker socket without sudo"
  else
    fail "current user cannot access the Docker socket" \
         "sudo usermod -aG docker \$USER && newgrp docker   # then re-run"
  fi
fi

# 4. terraform present + version
if ! command -v terraform >/dev/null 2>&1; then
  case "$PLATFORM_KERNEL" in
    Darwin) fix="brew tap hashicorp/tap && brew install hashicorp/tap/terraform" ;;
    *)      fix="See https://developer.hashicorp.com/terraform/install (or use 'tofu' from your package manager)" ;;
  esac
  fail "terraform not found" "$fix"
else
  TF_VER="$(terraform version -json 2>/dev/null | sed -n 's/.*"terraform_version":[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  [ -n "$TF_VER" ] || TF_VER="$(terraform version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
  if [ -n "$TF_VER" ] && ver_ge "$TF_VER" "$MIN_TERRAFORM_VERSION"; then
    pass "terraform ${TF_VER} >= ${MIN_TERRAFORM_VERSION}"
  else
    fail "terraform ${TF_VER:-unknown} < required ${MIN_TERRAFORM_VERSION}" \
         "Upgrade terraform to >= ${MIN_TERRAFORM_VERSION}"
  fi
fi

# 5. ansible-playbook present + version
if ! command -v ansible-playbook >/dev/null 2>&1; then
  case "$PLATFORM_KERNEL" in
    Darwin) fix="brew install ansible   # or: pipx install ansible-core" ;;
    *)      fix="pipx install ansible-core   # or your distro's ansible package" ;;
  esac
  fail "ansible-playbook not found" "$fix"
else
  ANS_VER="$(ansible-playbook --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  if [ -n "$ANS_VER" ] && ver_ge "$ANS_VER" "$MIN_ANSIBLE_VERSION"; then
    pass "ansible-core ${ANS_VER} >= ${MIN_ANSIBLE_VERSION}"
  else
    fail "ansible-core ${ANS_VER:-unknown} < required ${MIN_ANSIBLE_VERSION}" \
         "Upgrade: pipx upgrade ansible-core"
  fi
fi

# 6. Python 3 + docker SDK importable by the SAME interpreter Ansible uses.
# This mismatch (Ansible in a venv/pipx, docker SDK in system python) is a
# classic silent failure, so we resolve Ansible's interpreter explicitly.
if command -v ansible-playbook >/dev/null 2>&1; then
  ANSIBLE_PY="$(ansible-playbook --version 2>/dev/null | sed -n 's/.*python version = [^(]*(\(.*\)).*/\1/p' | awk '{print $1}')"
fi
ANSIBLE_PY="${ANSIBLE_PY:-$(command -v python3 || true)}"
if [ -z "$ANSIBLE_PY" ] || ! command -v "$ANSIBLE_PY" >/dev/null 2>&1; then
  ANSIBLE_PY="python3"
fi
if ! command -v python3 >/dev/null 2>&1 && ! command -v "$ANSIBLE_PY" >/dev/null 2>&1; then
  fail "python3 not found" "Install Python 3.9+"
elif "$ANSIBLE_PY" -c 'import docker' >/dev/null 2>&1; then
  pass "docker Python SDK importable by Ansible's interpreter (${ANSIBLE_PY})"
else
  fail "docker Python SDK not importable by Ansible's interpreter (${ANSIBLE_PY})" \
       "${ANSIBLE_PY} -m pip install docker    # install into the SAME interpreter Ansible runs"
fi

# 7. Required Ansible collections
if command -v ansible-galaxy >/dev/null 2>&1; then
  COLL_LIST="$(ANSIBLE_COLLECTIONS_PATH="${REPO_ROOT}/ansible/collections:${HOME}/.ansible/collections" \
    ansible-galaxy collection list 2>/dev/null || true)"
  missing_coll=""
  for c in community.docker community.crypto; do
    echo "$COLL_LIST" | grep -q "^${c} " || missing_coll="${missing_coll} ${c}"
  done
  if [ -z "$missing_coll" ]; then
    pass "required Ansible collections present (community.docker, community.crypto)"
  else
    fail "missing Ansible collection(s):${missing_coll}" \
         "ansible-galaxy collection install -r ansible/requirements.yml"
  fi
else
  fail "ansible-galaxy not found" "Install ansible-core (provides ansible-galaxy)"
fi

# 8. Handy CLI tools used by verify.sh
for tool in curl openssl jq; do
  if command -v "$tool" >/dev/null 2>&1; then
    pass "${tool} present"
  else
    # jq is a convenience in verify.sh; the others are relied on.
    if [ "$tool" = "jq" ]; then
      warn "jq not present (verify.sh degrades to grep-based checks)"
    else
      fail "${tool} not present" "Install ${tool} with your package manager"
    fi
  fi
done

# ======================== HOST CAPACITY ===================================
section "Host capacity"

# 9. RAM available to Docker. docker info reports the DAEMON's view, which is
# correct for both native Linux and the Docker Desktop VM.
if [ "$DOCKER_OK" = "true" ]; then
  MEM_BYTES="$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)"
  MEM_MB=$(( MEM_BYTES / 1024 / 1024 ))
  if [ "$MEM_MB" -ge "$REQUIRED_MEMORY_MB" ]; then
    pass "memory available to Docker: ${MEM_MB}MB >= ${REQUIRED_MEMORY_MB}MB"
  elif [ "$DOCKER_DESKTOP" = "true" ]; then
    fail "Docker Desktop VM has ${MEM_MB}MB (< ${REQUIRED_MEMORY_MB}MB)" \
         "Raise it in Docker Desktop -> Settings -> Resources -> Memory, then restart Docker"
  else
    fail "host memory available to Docker is ${MEM_MB}MB (< ${REQUIRED_MEMORY_MB}MB)" \
         "Free memory or lower elasticsearch_memory_mb/elasticsearch_heap in terraform.tfvars"
  fi
fi

# 10. Free disk on the Docker data root.
if [ "$DOCKER_OK" = "true" ]; then
  DROOT="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)"
  # On Docker Desktop DROOT is inside the VM; df it on the host best-effort.
  CHECK_PATH="$DROOT"; [ -d "$CHECK_PATH" ] || CHECK_PATH="$HOME"
  FREE_GB="$(df -Pk "$CHECK_PATH" 2>/dev/null | awk 'NR==2 {printf "%d", $4/1024/1024}' || true)"
  if [ -n "$FREE_GB" ] && [ "$FREE_GB" -ge "$REQUIRED_DISK_GB" ]; then
    pass "free disk near Docker data root: ${FREE_GB}GB >= ${REQUIRED_DISK_GB}GB"
  else
    warn "could not confirm >= ${REQUIRED_DISK_GB}GB free (measured ${FREE_GB:-?}GB at ${CHECK_PATH}); on Docker Desktop check the VM disk image size"
  fi
fi

# 11. CPU architecture + image manifest availability
case "$PLATFORM_ARCH" in
  x86_64|amd64) pass "architecture ${PLATFORM_ARCH}: Elastic images publish a native amd64 manifest" ;;
  arm64|aarch64) pass "architecture ${PLATFORM_ARCH}: Elastic 8.x and nginx publish native arm64 manifests (Apple Silicon supported)" ;;
  *) warn "unusual architecture ${PLATFORM_ARCH}: verify the pinned image tags publish a matching manifest" ;;
esac

# ======================== KERNEL / OS ======================================
section "Kernel / OS specifics"

# 12. vm.max_map_count >= 262144
if [ "$PLATFORM_KERNEL" = "Linux" ] && [ "$DOCKER_DESKTOP" != "true" ] && [ "$IS_WSL" != "true" ]; then
  MMC="$(cat /proc/sys/vm/max_map_count 2>/dev/null || echo 0)"
  if [ "$MMC" -ge "$MIN_MAX_MAP_COUNT" ]; then
    pass "vm.max_map_count=${MMC} >= ${MIN_MAX_MAP_COUNT}"
  else
    fail "vm.max_map_count=${MMC} < ${MIN_MAX_MAP_COUNT} (Elasticsearch will refuse to start)" \
         "sudo sysctl -w vm.max_map_count=${MIN_MAX_MAP_COUNT}   # persist: echo 'vm.max_map_count=${MIN_MAX_MAP_COUNT}' | sudo tee /etc/sysctl.d/99-elasticsearch.conf"
  fi
else
  # Docker Desktop / WSL2: the sysctl lives in the Docker/WSL VM, not the host.
  # Try to read it from inside the VM without pulling an image if we can.
  if [ "$DOCKER_OK" = "true" ] && docker image inspect busybox:latest >/dev/null 2>&1; then
    MMC="$(docker run --rm busybox:latest cat /proc/sys/vm/max_map_count 2>/dev/null || echo 0)"
    if [ "$MMC" -ge "$MIN_MAX_MAP_COUNT" ]; then
      pass "vm.max_map_count in the Docker VM = ${MMC} >= ${MIN_MAX_MAP_COUNT}"
    else
      fail "vm.max_map_count in the Docker VM = ${MMC} < ${MIN_MAX_MAP_COUNT}" \
           "WSL2: add 'kernel.max_map_count=${MIN_MAX_MAP_COUNT}' via /etc/sysctl.conf inside the WSL distro and 'wsl --shutdown'. Docker Desktop: it is usually set already; if not, run 'docker run --rm --privileged busybox sysctl -w vm.max_map_count=${MIN_MAX_MAP_COUNT}'"
    fi
  else
    warn "cannot read vm.max_map_count for the Docker VM without pulling an image. On Docker Desktop it defaults to a high value; on WSL2 set 'kernel.max_map_count=${MIN_MAX_MAP_COUNT}' in the distro and 'wsl --shutdown' if ES fails to boot"
  fi
fi

# 13. cgroup v1 vs v2
if [ -d /sys/fs/cgroup ]; then
  CG_TYPE="$(stat -fc %T /sys/fs/cgroup 2>/dev/null || echo unknown)"
  case "$CG_TYPE" in
    cgroup2fs) pass "cgroup v2 detected (memory limits honoured natively)" ;;
    tmpfs)     warn "cgroup v1 detected; container memory limits still apply but v2 is recommended on modern kernels" ;;
    *)         warn "cgroup type '${CG_TYPE}' unrecognised; memory limits should still apply" ;;
  esac
else
  warn "cannot determine cgroup version on this platform (expected on macOS Docker Desktop)"
fi

# 14. WSL2 quirks
if [ "$IS_WSL" = "true" ]; then
  warn "WSL2 detected: ensure Docker memory is sized via %UserProfile%\\.wslconfig ([wsl2] memory=4GB) and beware clock skew after host sleep ('sudo hwclock -s' or restart WSL)"
else
  pass "not running under WSL2"
fi

# 15. SELinux enforcing (bind-mount label issues)
if command -v getenforce >/dev/null 2>&1; then
  SE="$(getenforce 2>/dev/null || echo Disabled)"
elif [ -r /sys/fs/selinux/enforce ]; then
  SE="$([ "$(cat /sys/fs/selinux/enforce)" = "1" ] && echo Enforcing || echo Permissive)"
else
  SE="Disabled"
fi
if [ "$SE" = "Enforcing" ]; then
  warn "SELinux is Enforcing: named volumes are unaffected, but if you switch to host bind-mounts add ':z'/':Z'. This stack uses named volumes, so no action is usually required"
else
  pass "SELinux not enforcing (${SE})"
fi

# 16. AppArmor / rootless / podman-as-docker detection
if [ "$DOCKER_OK" = "true" ]; then
  if docker version 2>/dev/null | grep -qi podman || docker info 2>/dev/null | grep -qi podman; then
    warn "This looks like Podman masquerading as docker. It may work, but was not tested; a real Docker Engine is recommended"
  elif docker info --format '{{.SecurityOptions}}' 2>/dev/null | grep -qi rootless; then
    warn "Rootless Docker detected: set docker_host to unix://\$XDG_RUNTIME_DIR/docker.sock in terraform.tfvars if apply cannot reach the socket"
  else
    pass "standard rootful Docker Engine detected"
  fi
  if [ -d /sys/kernel/security/apparmor ]; then
    pass "AppArmor present (default docker profile is compatible)"
  fi
fi

# ======================== ENVIRONMENT COLLISIONS ==========================
section "Environment collisions"

# 17. Published port is free
port_in_use() {
  if command -v ss >/dev/null 2>&1; then ss -ltn 2>/dev/null | grep -qE "[:.]${1}[[:space:]]"
  elif command -v lsof >/dev/null 2>&1; then lsof -iTCP:"${1}" -sTCP:LISTEN >/dev/null 2>&1
  else return 1; fi
}
if port_in_use "$HTTPS_PORT"; then
  OCC="$( (command -v lsof >/dev/null 2>&1 && lsof -iTCP:"$HTTPS_PORT" -sTCP:LISTEN -Fc 2>/dev/null | sed -n 's/^c//p' | head -1) || echo 'unknown process')"
  fail "published port ${HTTPS_PORT} is already in use by: ${OCC}" \
       "Free it, or set 'published_https_port = <free port>' in terraform/terraform.tfvars"
else
  pass "published port ${HTTPS_PORT} is free"
fi

# 18. No leftover resources from a previous run with this prefix
if [ "$DOCKER_OK" = "true" ]; then
  LEFT="$(docker ps -a --filter "name=${PROJECT_PREFIX}-" --format '{{.Names}}' 2>/dev/null | wc -l | tr -d ' ')"
  LEFTV="$(docker volume ls --filter "name=${PROJECT_PREFIX}-" --format '{{.Name}}' 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$LEFT" = "0" ] && [ "$LEFTV" = "0" ]; then
    pass "no leftover containers/volumes with prefix '${PROJECT_PREFIX}-'"
  else
    warn "found ${LEFT} container(s) and ${LEFTV} volume(s) with prefix '${PROJECT_PREFIX}-' from a previous run -> run 'make reset' for a clean cold start"
  fi
fi

# 19. Network subnet collision
if [ "$DOCKER_OK" = "true" ]; then
  if docker network ls --format '{{.Name}}' | grep -q "^${PROJECT_PREFIX}-net$"; then
    warn "docker network '${PROJECT_PREFIX}-net' already exists -> 'make reset' before deploying"
  elif docker network inspect "$(docker network ls -q)" 2>/dev/null | grep -q "\"Subnet\": \"${NETWORK_SUBNET}\""; then
    fail "subnet ${NETWORK_SUBNET} is already used by another docker network" \
         "Set 'network_subnet = <free /24>' in terraform/terraform.tfvars"
  else
    pass "network subnet ${NETWORK_SUBNET} does not collide with an existing docker network"
  fi
  # Route/VPN overlap (best-effort, Linux only)
  if command -v ip >/dev/null 2>&1 && ip route 2>/dev/null | grep -q "${NETWORK_SUBNET%/*}"; then
    warn "a host route mentions ${NETWORK_SUBNET%.*}.x; if you use a VPN on this range, change network_subnet"
  fi
fi

# 20. Corporate proxy / TLS interception
if [ -n "${HTTP_PROXY:-}${HTTPS_PROXY:-}${http_proxy:-}${https_proxy:-}" ]; then
  warn "proxy env vars are set (HTTP(S)_PROXY). Ensure Docker's daemon proxy is configured too, or image pulls will fail"
else
  pass "no HTTP(S)_PROXY interception variables set"
fi
if [ -n "${REQUESTS_CA_BUNDLE:-}${SSL_CERT_FILE:-}${NODE_EXTRA_CA_CERTS:-}" ]; then
  warn "a custom CA bundle is configured (REQUESTS_CA_BUNDLE/SSL_CERT_FILE). Corporate TLS interception can break registry pulls and the internal CA trust chain"
fi

# 21. Docker Hub / registry reachability
if command -v curl >/dev/null 2>&1; then
  # 401 from the registry v2 root means "reachable, auth required" -> good.
  REG_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 https://registry-1.docker.io/v2/ 2>/dev/null || true)"
  REG_CODE="${REG_CODE:-000}"
  if [ "$REG_CODE" = "401" ] || [ "$REG_CODE" = "200" ]; then
    pass "Docker registry reachable (HTTP ${REG_CODE})"
  else
    warn "could not confirm Docker registry reachability (HTTP ${REG_CODE}); pulls may fail or be rate-limited. If images are already pulled this is harmless"
  fi
fi

# 22. inotify watches + file-descriptor limits (Linux)
if [ "$PLATFORM_KERNEL" = "Linux" ]; then
  WATCHES="$(cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null || echo 0)"
  if [ "$WATCHES" -ge 65536 ]; then
    pass "fs.inotify.max_user_watches=${WATCHES} is sufficient"
  else
    warn "fs.inotify.max_user_watches=${WATCHES} is low; raise with: sudo sysctl -w fs.inotify.max_user_watches=524288"
  fi
  NOFILE="$(ulimit -n 2>/dev/null || echo 0)"
  if [ "$NOFILE" = "unlimited" ] || { [ "$NOFILE" -ge 4096 ] 2>/dev/null; }; then
    pass "open-file limit (ulimit -n=${NOFILE}) is adequate"
  else
    warn "open-file limit ulimit -n=${NOFILE} is low; consider raising it for Elasticsearch"
  fi
fi

# 23. Clock skew (uses the registry Date header if reachable)
if command -v curl >/dev/null 2>&1; then
  REMOTE_DATE="$(curl -sI --max-time 8 https://registry-1.docker.io/v2/ 2>/dev/null | awk -F': ' 'tolower($1)=="date"{print $2}' | tr -d '\r' || true)"
  if [ -n "$REMOTE_DATE" ]; then
    REMOTE_EPOCH="$(date -d "$REMOTE_DATE" +%s 2>/dev/null || echo 0)"
    if [ "$REMOTE_EPOCH" != "0" ]; then
      SKEW=$(( $(date +%s) - REMOTE_EPOCH )); SKEW=${SKEW#-}
      if [ "$SKEW" -le 120 ]; then
        pass "system clock within ${SKEW}s of network time (certs will validate)"
      else
        fail "system clock is off by ~${SKEW}s; TLS certificate validity checks may fail" \
             "Sync your clock (Linux: 'sudo chronyc makestep' or 'sudo hwclock -s'; WSL2: 'sudo hwclock -s')"
      fi
    fi
  else
    warn "could not measure clock skew (registry unreachable); ensure your clock is correct so certs validate"
  fi
fi

# ============================ SUMMARY ======================================
section "Summary"
printf '  %sPASS=%d  WARN=%d  FAIL=%d%s\n' "$C_BOLD" "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT" "$C_RESET"
if [ "$FAIL_COUNT" -gt 0 ]; then
  log_err "preflight FAILED: fix the ${FAIL_COUNT} item(s) above, then re-run. Deployment was NOT started."
  exit 1
fi
log_ok "preflight passed (${WARN_COUNT} warning(s)). Safe to deploy."
exit 0
