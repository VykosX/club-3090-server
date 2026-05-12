#!/usr/bin/env bash
set -euo pipefail

SCRIPT_VERSION="2026-05-11.v0.5.27"

printf 'Club-3090 Server Installer %s\n' "${SCRIPT_VERSION}"

# club-3090 headless server/control installer
# Install:
#   curl -fsSL https://tinyurl.com/club-3090-webserver | bash
# Update control/admin/proxy/console services only:
#   curl -fsSL https://tinyurl.com/club-3090-webserver | bash -s -- --update
# Migrate an existing /opt/ai/club-3090 checkout to a fresh upstream clone:
#   curl -fsSL https://tinyurl.com/club-3090-webserver | bash -s -- --migrate
# Restart a broken/incomplete migration from scratch:
#   curl -fsSL https://tinyurl.com/club-3090-webserver | bash -s -- --migrate restart
# Custom admin/proxy ports:
#   bash install-club3090-server.sh --ports 18008:18009
# Save a Hugging Face token for setup and later admin-panel downloads:
#   bash install-club3090-server.sh --hf-token hf_xxx
# Enable loopback-only local automation API:
#   bash install-club3090-server.sh --local-automation
# Overrides:
#   CLUB3090_DIR=/path/to/club-3090 DEFAULT_MODE=vllm/dual-dflash HF_TOKEN=hf_xxx bash install-club3090-server.sh
# If DEFAULT_MODE is unset, the installer auto-selects:
#   - vllm/default on 0-1 detected GPUs
#   - vllm/dual on 2+ detected GPUs

CONTROL_DIR="/opt/club3090-control"
NETWORK_STATE_FILE="${CONTROL_DIR}/network_state.json"
TLS_CERT_FILE="${CONTROL_DIR}/tls.crt"
TLS_KEY_FILE="${CONTROL_DIR}/tls.key"
CADDYFILE_PATH="${CONTROL_DIR}/Caddyfile"
MIGRATION_STATE_FILE="${CONTROL_DIR}/migration-state.env"

ACTION="install"
ONLINE_MODE="disable"
ONLINE_TLS_MODE="disable"
LOCAL_AUTOMATION_MODE="disable"
PORTS_SPEC=""
HF_TOKEN_INPUT=""
MIGRATION_FORCE_RESTART=0
UPSTREAM_REPO_URL="${CLUB3090_REPO_URL:-https://github.com/noonghunna/club-3090.git}"
while [[ "$#" -gt 0 ]]; do
  case "${1}" in
    --update)
      ACTION="update"
      shift
      ;;
    --migrate)
      ACTION="migrate"
      if [[ "$#" -ge 2 && "${2}" == "restart" ]]; then
        MIGRATION_FORCE_RESTART=1
        shift 2
      else
        shift
      fi
      ;;
    --install)
      ACTION="install"
      shift
      ;;
    --online)
      ONLINE_MODE="enable"
      shift
      ;;
    --use-https|use-https)
      ONLINE_TLS_MODE="enable"
      shift
      ;;
    --local-automation)
      LOCAL_AUTOMATION_MODE="enable"
      shift
      ;;
    --hf-token|--hf_token)
      if [[ "$#" -lt 2 ]]; then
        echo "ERROR: --hf-token requires a value." >&2
        exit 1
      fi
      HF_TOKEN_INPUT="${2}"
      shift 2
      ;;
    --ports)
      if [[ "$#" -lt 2 ]]; then
        echo "ERROR: --ports requires a value like 8008:8009" >&2
        exit 1
      fi
      PORTS_SPEC="${2}"
      shift 2
      ;;
    *)
      echo "ERROR: Unknown argument: ${1}" >&2
      exit 1
      ;;
  esac
done

ADMIN_PORT="${CLUB3090_ADMIN_PORT:-8008}"
PROXY_PORT="${CLUB3090_PROXY_PORT:-8009}"
LOCAL_API_PORT="${CLUB3090_LOCAL_API_PORT:-10881}"

read_existing_service_port() {
  local key="$1"
  local unit="/etc/systemd/system/club3090-control.service"
  if [[ -r "${unit}" ]]; then
    sed -n "s/^Environment=${key}=//p" "${unit}" 2>/dev/null | head -n 1
  fi
}

read_existing_server_flag() {
  local key="$1"
  local path="${CONTROL_DIR}/server_config.json"
  if [[ -r "${path}" ]] && command -v python3 >/dev/null 2>&1; then
    python3 - "$path" "$key" <<'PYFLAG' 2>/dev/null
import json, sys
path, key = sys.argv[1], sys.argv[2]
try:
    with open(path, "r", encoding="utf-8") as f:
        obj = json.load(f)
except Exception:
    sys.exit(0)
val = obj.get(key)
if isinstance(val, bool):
    print("true" if val else "false")
elif val is not None:
    print(val)
PYFLAG
  fi
}

read_repo_env_value() {
  local path="$1"
  local key="$2"
  if [[ -r "${path}" ]] && command -v python3 >/dev/null 2>&1; then
    python3 - "$path" "$key" <<'PYENVREAD' 2>/dev/null
import sys
path, key = sys.argv[1], sys.argv[2]
try:
    with open(path, "r", encoding="utf-8") as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            if k.strip() == key:
                print(v.strip())
                break
except Exception:
    pass
PYENVREAD
  fi
}

if [[ ( "${ACTION}" == "update" || "${ACTION}" == "migrate" ) && -z "${PORTS_SPEC}" ]]; then
  existing_admin_port="$(read_existing_service_port CLUB3090_ADMIN_PORT || true)"
  existing_proxy_port="$(read_existing_service_port CLUB3090_PROXY_PORT || true)"
  existing_local_api_port="$(read_existing_service_port CLUB3090_LOCAL_API_PORT || true)"
  if [[ "${existing_admin_port:-}" =~ ^[0-9]+$ ]]; then
    ADMIN_PORT="${existing_admin_port}"
  fi
  if [[ "${existing_proxy_port:-}" =~ ^[0-9]+$ ]]; then
    PROXY_PORT="${existing_proxy_port}"
  fi
  if [[ "${existing_local_api_port:-}" =~ ^[0-9]+$ ]]; then
    LOCAL_API_PORT="${existing_local_api_port}"
  fi
fi

if [[ -n "${PORTS_SPEC}" ]]; then
  if [[ "${PORTS_SPEC}" =~ ^([0-9]{2,5}):([0-9]{2,5})$ ]]; then
    ADMIN_PORT="${BASH_REMATCH[1]}"
    PROXY_PORT="${BASH_REMATCH[2]}"
  else
    echo "ERROR: --ports must look like 8008:8009" >&2
    exit 1
  fi
fi

validate_port() {
  local p="$1"
  [[ "${p}" =~ ^[0-9]+$ ]] || return 1
  (( p >= 1 && p <= 65535 ))
}

if ! validate_port "${ADMIN_PORT}"; then
  echo "ERROR: Invalid admin port: ${ADMIN_PORT}" >&2
  exit 1
fi
if ! validate_port "${PROXY_PORT}"; then
  echo "ERROR: Invalid proxy port: ${PROXY_PORT}" >&2
  exit 1
fi
if [[ "${ADMIN_PORT}" == "${PROXY_PORT}" ]]; then
  echo "ERROR: Admin and proxy ports must be different." >&2
  exit 1
fi
if [[ "${ADMIN_PORT}" == "${LOCAL_API_PORT}" ]] || [[ "${PROXY_PORT}" == "${LOCAL_API_PORT}" ]]; then
  echo "ERROR: Admin, proxy, and local API ports must all be different." >&2
  exit 1
fi

choose_loopback_port() {
  local preferred="$1"
  shift
  local candidate
  local used_ports="$*"
  for candidate in "${preferred}" $((preferred + 1000)) $((preferred + 2000)) $((preferred + 10000)); do
    if validate_port "${candidate}"; then
      case " ${used_ports} " in
        *" ${candidate} "*) ;;
        *)
          if command -v ss >/dev/null 2>&1; then
            if ss -ltnH "( sport = :${candidate} )" 2>/dev/null | grep -q .; then
              continue
            fi
          fi
          printf '%s\n' "${candidate}"
          return 0
          ;;
      esac
    fi
  done
  return 1
}

CLUB3090_DIR="${CLUB3090_DIR:-/opt/ai/club-3090}"
DEFAULT_MODE="${DEFAULT_MODE:-}"
CONTROL_PY="${CONTROL_DIR}/control.py"
FOLLOW_SH="${CONTROL_DIR}/follow-vllm-log.sh"
START_SH="${CONTROL_DIR}/start-vllm-last-mode.sh"
HEADLESS_X_SH="${CONTROL_DIR}/prepare-headless-x.sh"
ACTIVE_MODE_FILE="${CONTROL_DIR}/active_mode"
BASH_BIN="${BASH_BIN:-$(command -v bash || true)}"
PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"
REPO_ENV_FILE="${CLUB3090_DIR}/.env"
HF_TOKEN_VALUE="${HF_TOKEN_INPUT:-${HF_TOKEN:-}}"

if [[ -z "${HF_TOKEN_VALUE}" ]]; then
  existing_saved_hf_token="$(read_repo_env_value "${REPO_ENV_FILE}" "HF_TOKEN" || true)"
  if [[ -n "${existing_saved_hf_token:-}" ]]; then
    HF_TOKEN_VALUE="${existing_saved_hf_token}"
  fi
fi

if [[ -n "${HF_TOKEN_VALUE}" ]]; then
  export HF_TOKEN="${HF_TOKEN_VALUE}"
fi

ONLINE_EFFECTIVE_ENABLED="false"
ONLINE_TLS_EFFECTIVE_ENABLED="false"
LOCAL_AUTOMATION_EFFECTIVE_ENABLED="false"
if [[ "${ONLINE_MODE}" == "enable" ]]; then
  ONLINE_EFFECTIVE_ENABLED="true"
fi
if [[ "${ONLINE_TLS_MODE}" == "enable" ]]; then
  ONLINE_TLS_EFFECTIVE_ENABLED="true"
fi
if [[ "${LOCAL_AUTOMATION_MODE}" == "enable" ]]; then
  LOCAL_AUTOMATION_EFFECTIVE_ENABLED="true"
fi
if [[ "${ONLINE_TLS_EFFECTIVE_ENABLED}" == "true" && "${ONLINE_EFFECTIVE_ENABLED}" != "true" ]]; then
  echo "ERROR: HTTPS can only be enabled together with --online." >&2
  exit 1
fi

CONTROL_ADMIN_BIND_HOST="0.0.0.0"
CONTROL_PROXY_BIND_HOST="0.0.0.0"
CONTROL_ADMIN_BIND_PORT="${ADMIN_PORT}"
CONTROL_PROXY_BIND_PORT="${PROXY_PORT}"
if [[ "${ONLINE_TLS_EFFECTIVE_ENABLED}" == "true" ]]; then
  CONTROL_ADMIN_BIND_HOST="127.0.0.1"
  CONTROL_PROXY_BIND_HOST="127.0.0.1"
  CONTROL_ADMIN_BIND_PORT="$(choose_loopback_port 18008 "${ADMIN_PORT}" "${PROXY_PORT}" "${LOCAL_API_PORT}")"
  CONTROL_PROXY_BIND_PORT="$(choose_loopback_port 18009 "${ADMIN_PORT}" "${PROXY_PORT}" "${LOCAL_API_PORT}" "${CONTROL_ADMIN_BIND_PORT}")"
  if [[ -z "${CONTROL_ADMIN_BIND_PORT:-}" || -z "${CONTROL_PROXY_BIND_PORT:-}" ]]; then
    echo "ERROR: Could not allocate internal loopback ports for Caddy-backed HTTPS mode." >&2
    exit 1
  fi
fi

detect_gpu_count() {
  local count="${CLUB3090_GPU_COUNT_OVERRIDE:-}"
  if [[ -n "${count}" ]] && [[ "${count}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "${count}"
    return 0
  fi
  if command -v nvidia-smi >/dev/null 2>&1; then
    count="$(nvidia-smi --query-gpu=index --format=csv,noheader,nounits 2>/dev/null | awk 'NF{c++} END{print c+0}')"
    if [[ "${count}" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "${count}"
      return 0
    fi
    count="$(nvidia-smi -L 2>/dev/null | awk '/^GPU [0-9]+:/{c++} END{print c+0}')"
    if [[ "${count}" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "${count}"
      return 0
    fi
  fi
  printf '0\n'
}

GPU_COUNT="$(detect_gpu_count)"
AUTO_DEFAULT_MODE="vllm/default"
if [[ "${GPU_COUNT}" -gt 1 ]]; then
  AUTO_DEFAULT_MODE="vllm/dual"
fi

if [[ -z "${DEFAULT_MODE}" ]]; then
  DEFAULT_MODE="${AUTO_DEFAULT_MODE}"
fi

if [[ ! -d "${CLUB3090_DIR}" && "${ACTION}" != "install" && ! ( "${ACTION}" == "migrate" && "${MIGRATION_FORCE_RESTART}" == "1" ) ]]; then
  echo "ERROR: CLUB3090_DIR does not exist: ${CLUB3090_DIR}" >&2
  echo "Re-run with: CLUB3090_DIR=/actual/path/to/club-3090 bash install-club3090-server.sh" >&2
  exit 1
fi

if [[ ! -f "${CLUB3090_DIR}/scripts/switch.sh" && "${ACTION}" != "install" && ! ( "${ACTION}" == "migrate" && "${MIGRATION_FORCE_RESTART}" == "1" ) ]]; then
  echo "ERROR: Could not find ${CLUB3090_DIR}/scripts/switch.sh" >&2
  exit 1
fi

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "ERROR: This installer only supports Linux hosts." >&2
  exit 1
fi

if [[ ! -r /etc/os-release ]]; then
  echo "ERROR: Could not read /etc/os-release to detect the Linux distribution." >&2
  exit 1
fi

if [[ "${EUID}" -eq 0 ]]; then
  SUDO=()
else
  if ! command -v sudo >/dev/null 2>&1; then
    echo "ERROR: sudo is required when not running as root." >&2
    exit 1
  fi
  SUDO=(sudo)
fi

request_root_permissions() {
  if [[ "${#SUDO[@]}" -eq 0 ]]; then
    return 0
  fi
  printf 'Requesting root permissions\n'
  if ! "${SUDO[@]}" -v; then
    echo "ERROR: Failed to obtain root permissions with sudo." >&2
    exit 1
  fi
}

request_root_permissions

log_step() {
  printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*"
}

bootstrap_upstream_repo_for_install() {
  if [[ "${ACTION}" != "install" ]]; then
    return 0
  fi
  if [[ -f "${CLUB3090_DIR}/scripts/switch.sh" ]]; then
    return 0
  fi
  if [[ -d "${CLUB3090_DIR}" ]]; then
    echo "ERROR: ${CLUB3090_DIR} already exists but is missing scripts/switch.sh." >&2
    echo "Remove or repair that directory, or point CLUB3090_DIR at a valid club-3090 checkout." >&2
    exit 1
  fi
  local parent_dir owner_name owner_group
  parent_dir="$(dirname "${CLUB3090_DIR}")"
  owner_name="${SUDO_USER:-$(id -un)}"
  owner_group="$(id -gn "${owner_name}" 2>/dev/null || id -gn)"
  log_step "Cloning upstream club-3090 into ${CLUB3090_DIR}"
  "${SUDO[@]}" mkdir -p "${parent_dir}"
  if ! "${SUDO[@]}" env GIT_TERMINAL_PROMPT=0 git clone --progress "${UPSTREAM_REPO_URL}" "${CLUB3090_DIR}"; then
    echo "ERROR: Failed to clone ${UPSTREAM_REPO_URL} into ${CLUB3090_DIR}" >&2
    exit 1
  fi
  "${SUDO[@]}" chmod -R a+rX "${CLUB3090_DIR}" >/dev/null 2>&1 || true
  if [[ -d "${CLUB3090_DIR}/scripts" ]]; then
    "${SUDO[@]}" find "${CLUB3090_DIR}/scripts" -maxdepth 1 -type f -name '*.sh' -exec chmod 755 {} +
  fi
  "${SUDO[@]}" chown -R "${owner_name}:${owner_group}" "${CLUB3090_DIR}" >/dev/null 2>&1 || true
  if [[ ! -f "${CLUB3090_DIR}/scripts/switch.sh" ]]; then
    echo "ERROR: Upstream clone completed but ${CLUB3090_DIR}/scripts/switch.sh is still missing." >&2
    exit 1
  fi
}

bootstrap_upstream_repo_for_install

if [[ ! -d "${CLUB3090_DIR}" && ! ( "${ACTION}" == "migrate" && "${MIGRATION_FORCE_RESTART}" == "1" ) ]]; then
  echo "ERROR: CLUB3090_DIR does not exist: ${CLUB3090_DIR}" >&2
  exit 1
fi

if [[ ! -f "${CLUB3090_DIR}/scripts/switch.sh" && ! ( "${ACTION}" == "migrate" && "${MIGRATION_FORCE_RESTART}" == "1" ) ]]; then
  echo "ERROR: Could not find ${CLUB3090_DIR}/scripts/switch.sh" >&2
  exit 1
fi

restore_repo_for_forced_migration_restart() {
  if [[ "${ACTION}" != "migrate" || "${MIGRATION_FORCE_RESTART}" != "1" ]]; then
    return 0
  fi
  if [[ -d "${CLUB3090_DIR}" ]]; then
    return 0
  fi
  if [[ ! -r "${MIGRATION_STATE_FILE}" ]]; then
    return 0
  fi
  local backup_dir=""
  local parsed_dir=""
  set +u
  # shellcheck disable=SC1090
  . "${MIGRATION_STATE_FILE}"
  set -u
  backup_dir="${MIGRATION_BACKUP_DIR:-}"
  parsed_dir="${MIGRATION_REPO_DIR:-}"
  if [[ -n "${parsed_dir}" ]]; then
    CLUB3090_DIR="${parsed_dir}"
    REPO_ENV_FILE="${CLUB3090_DIR}/.env"
  fi
  if [[ -n "${backup_dir}" && -d "${backup_dir}" && ! -d "${CLUB3090_DIR}" ]]; then
    status_line "Forced migrate restart: restoring backed-up repo from ${backup_dir} to ${CLUB3090_DIR} before restarting"
    "${SUDO[@]}" mv "${backup_dir}" "${CLUB3090_DIR}"
  fi
}

restore_repo_for_forced_migration_restart

if [[ -z "${BASH_BIN}" ]]; then
  echo "ERROR: bash is required but was not found in PATH." >&2
  exit 1
fi

source /etc/os-release
OS_ID_LOWER="$(printf '%s' "${ID:-}" | tr '[:upper:]' '[:lower:]')"
OS_LIKE_LOWER="$(printf '%s' "${ID_LIKE:-}" | tr '[:upper:]' '[:lower:]')"
OS_FAMILY="unsupported"

case "${OS_ID_LOWER}" in
  arch|manjaro|endeavouros)
    OS_FAMILY="arch"
    ;;
  ubuntu|debian|linuxmint|pop)
    OS_FAMILY="debian"
    ;;
  *)
    if [[ "${OS_LIKE_LOWER}" == *arch* ]]; then
      OS_FAMILY="arch"
    elif [[ "${OS_LIKE_LOWER}" == *debian* ]] || [[ "${OS_LIKE_LOWER}" == *ubuntu* ]]; then
      OS_FAMILY="debian"
    fi
    ;;
esac

if [[ "${OS_FAMILY}" == "unsupported" ]]; then
  echo "ERROR: Unsupported distribution: ${PRETTY_NAME:-${ID:-unknown}}. Supported families: Arch and Ubuntu/Debian." >&2
  exit 1
fi

log_done() {
  printf '[%s] done: %s\n' "$(date +%H:%M:%S)" "$*"
}

append_control_log_line() {
  local line
  line="$(date +'%Y-%m-%d %H:%M:%S') $*"
  printf '%s\n' "${line}"
  "${SUDO[@]}" mkdir -p "${CONTROL_DIR}" >/dev/null 2>&1 || true
  printf '%s\n' "${line}" | "${SUDO[@]}" tee -a "${CONTROL_DIR}/control.log" >/dev/null 2>&1 || true
  printf '%s\n' "${line}" | "${SUDO[@]}" tee -a "${CONTROL_DIR}/audit.log" >/dev/null 2>&1 || true
}

status_line() {
  printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"
}

shell_quote() {
  printf '%q' "$1"
}

ensure_control_dir() {
  "${SUDO[@]}" mkdir -p "${CONTROL_DIR}" >/dev/null 2>&1 || true
}

migration_state_defaults() {
  MIGRATION_STATUS=""
  MIGRATION_RUN_ID=""
  MIGRATION_STARTED_AT=""
  MIGRATION_UPDATED_AT=""
  MIGRATION_LAST_STEP=""
  MIGRATION_REMOTE_HEAD=""
  MIGRATION_REPO_URL=""
  MIGRATION_REPO_DIR=""
  MIGRATION_BACKUP_DIR=""
  MIGRATION_REPO_RENAMED=0
  MIGRATION_REPO_CLONED=0
  MIGRATION_ASSETS_MERGED=0
  MIGRATION_BOOTSTRAP_INVENTORY_DONE=0
  MIGRATION_SETUP_DONE=0
  MIGRATION_POST_SETUP_INVENTORY_DONE=0
  MIGRATION_UPDATE_DONE=0
  MIGRATION_FINAL_INVENTORY_DONE=0
  MIGRATION_SERVICES_REFRESHED=0
}

migration_state_defaults

load_migration_state() {
  migration_state_defaults
  if [[ ! -f "${MIGRATION_STATE_FILE}" ]]; then
    return 1
  fi
  set +u
  # shellcheck disable=SC1090
  . "${MIGRATION_STATE_FILE}"
  set -u
  return 0
}

save_migration_state() {
  ensure_control_dir
  "${SUDO[@]}" tee "${MIGRATION_STATE_FILE}" >/dev/null <<STATE
MIGRATION_STATUS=$(printf '%q' "${MIGRATION_STATUS}")
MIGRATION_RUN_ID=$(printf '%q' "${MIGRATION_RUN_ID}")
MIGRATION_STARTED_AT=$(printf '%q' "${MIGRATION_STARTED_AT}")
MIGRATION_UPDATED_AT=$(printf '%q' "${MIGRATION_UPDATED_AT}")
MIGRATION_LAST_STEP=$(printf '%q' "${MIGRATION_LAST_STEP}")
MIGRATION_REMOTE_HEAD=$(printf '%q' "${MIGRATION_REMOTE_HEAD}")
MIGRATION_REPO_URL=$(printf '%q' "${MIGRATION_REPO_URL}")
MIGRATION_REPO_DIR=$(printf '%q' "${MIGRATION_REPO_DIR}")
MIGRATION_BACKUP_DIR=$(printf '%q' "${MIGRATION_BACKUP_DIR}")
MIGRATION_REPO_RENAMED=$(printf '%q' "${MIGRATION_REPO_RENAMED}")
MIGRATION_REPO_CLONED=$(printf '%q' "${MIGRATION_REPO_CLONED}")
MIGRATION_ASSETS_MERGED=$(printf '%q' "${MIGRATION_ASSETS_MERGED}")
MIGRATION_BOOTSTRAP_INVENTORY_DONE=$(printf '%q' "${MIGRATION_BOOTSTRAP_INVENTORY_DONE}")
MIGRATION_SETUP_DONE=$(printf '%q' "${MIGRATION_SETUP_DONE}")
MIGRATION_POST_SETUP_INVENTORY_DONE=$(printf '%q' "${MIGRATION_POST_SETUP_INVENTORY_DONE}")
MIGRATION_UPDATE_DONE=$(printf '%q' "${MIGRATION_UPDATE_DONE}")
MIGRATION_FINAL_INVENTORY_DONE=$(printf '%q' "${MIGRATION_FINAL_INVENTORY_DONE}")
MIGRATION_SERVICES_REFRESHED=$(printf '%q' "${MIGRATION_SERVICES_REFRESHED}")
STATE
}

write_repo_env_value() {
  local path="$1"
  local key="$2"
  local value="$3"
  "${SUDO[@]}" "${PYTHON_BIN}" - "${path}" "${key}" "${value}" <<'PYENVWRITE'
import os, sys
path, key, value = sys.argv[1:4]
rows = []
found = False
if os.path.exists(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for raw in f:
            line = raw.rstrip("\n")
            stripped = line.strip()
            if stripped and not stripped.startswith("#") and "=" in line:
                k, _v = line.split("=", 1)
                if k.strip() == key:
                    rows.append(f"{key}={value}")
                    found = True
                    continue
            rows.append(line)
if not found:
    rows.append(f"{key}={value}")
os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
with open(path, "w", encoding="utf-8", newline="\n") as f:
    for line in rows:
        f.write(line.rstrip("\n") + "\n")
PYENVWRITE
}

persist_hf_token_if_available() {
  if [[ -z "${HF_TOKEN_VALUE}" ]]; then
    append_control_log_line "hf token: no token provided or previously saved; gated model downloads may require one later"
    return 0
  fi
  append_control_log_line "hf token: persisting token to ${REPO_ENV_FILE} for setup and later admin download reuse"
  write_repo_env_value "${REPO_ENV_FILE}" "HF_TOKEN" "${HF_TOKEN_VALUE}"
}

detect_upstream_remote_head() {
  git ls-remote "${UPSTREAM_REPO_URL}" HEAD 2>/dev/null | awk 'NR==1{print $1}'
}

git_repo_head() {
  local path="$1"
  if [[ ! -d "${path}/.git" ]]; then
    return 1
  fi
  git -C "${path}" rev-parse HEAD 2>/dev/null | head -n 1
}

migration_update_state() {
  local step="$1"
  MIGRATION_STATUS="in_progress"
  MIGRATION_LAST_STEP="${step}"
  MIGRATION_UPDATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  save_migration_state
}

migration_mark_flag_done() {
  local flag_name="$1"
  local step="$2"
  printf -v "${flag_name}" '%s' "1"
  migration_update_state "${step}"
}

migration_pending_summary() {
  local pending=()
  [[ "${MIGRATION_REPO_RENAMED}" == "1" ]] || pending+=("rename")
  [[ "${MIGRATION_REPO_CLONED}" == "1" ]] || pending+=("clone")
  [[ "${MIGRATION_ASSETS_MERGED}" == "1" ]] || pending+=("asset-merge")
  [[ "${MIGRATION_BOOTSTRAP_INVENTORY_DONE}" == "1" ]] || pending+=("inventory-bootstrap")
  [[ "${MIGRATION_SETUP_DONE}" == "1" ]] || pending+=("setup")
  [[ "${MIGRATION_POST_SETUP_INVENTORY_DONE}" == "1" ]] || pending+=("inventory-post-setup")
  [[ "${MIGRATION_UPDATE_DONE}" == "1" ]] || pending+=("update.sh")
  [[ "${MIGRATION_FINAL_INVENTORY_DONE}" == "1" ]] || pending+=("inventory-final")
  if [[ "${#pending[@]}" -eq 0 ]]; then
    printf '%s' "none"
  else
    local joined=""
    local item
    for item in "${pending[@]}"; do
      if [[ -n "${joined}" ]]; then
        joined+=", "
      fi
      joined+="${item}"
    done
    printf '%s' "${joined}"
  fi
}

prepare_migration_state() {
  ensure_control_dir
  local remote_head=""
  remote_head="$(detect_upstream_remote_head || true)"
  if [[ "${MIGRATION_FORCE_RESTART}" == "1" ]]; then
    if [[ -f "${MIGRATION_STATE_FILE}" ]]; then
      append_control_log_line "migrate forced restart requested; deleting previous resume state at ${MIGRATION_STATE_FILE}"
      "${SUDO[@]}" rm -f "${MIGRATION_STATE_FILE}" >/dev/null 2>&1 || true
    fi
    migration_state_defaults
  fi
  if load_migration_state && [[ -n "${MIGRATION_STATUS}" && "${MIGRATION_STATUS}" != "complete" ]]; then
    if [[ -n "${remote_head}" && -n "${MIGRATION_REMOTE_HEAD}" && "${remote_head}" != "${MIGRATION_REMOTE_HEAD}" ]]; then
      append_control_log_line "migrate resume state found but upstream HEAD changed from ${MIGRATION_REMOTE_HEAD} to ${remote_head}; restarting unfinished migration phases"
      MIGRATION_REMOTE_HEAD="${remote_head}"
      MIGRATION_REPO_URL="${UPSTREAM_REPO_URL}"
      MIGRATION_REPO_DIR="${CLUB3090_DIR}"
      MIGRATION_REPO_CLONED=0
      MIGRATION_ASSETS_MERGED=0
      MIGRATION_BOOTSTRAP_INVENTORY_DONE=0
      MIGRATION_SETUP_DONE=0
      MIGRATION_POST_SETUP_INVENTORY_DONE=0
      MIGRATION_UPDATE_DONE=0
      MIGRATION_FINAL_INVENTORY_DONE=0
      MIGRATION_SERVICES_REFRESHED=0
      if [[ -n "${MIGRATION_BACKUP_DIR}" && -d "${MIGRATION_BACKUP_DIR}" && ! -d "${CLUB3090_DIR}" ]]; then
        MIGRATION_REPO_RENAMED=1
      fi
      migration_update_state "resume_restart_new_upstream_head"
    else
      append_control_log_line "migrate resume detected: last_step=${MIGRATION_LAST_STEP:-unknown}, backup=${MIGRATION_BACKUP_DIR:-unknown}, pending=$(migration_pending_summary)"
    fi
    return 0
  fi
  migration_state_defaults
  MIGRATION_STATUS="in_progress"
  MIGRATION_RUN_ID="$(date +%Y%m%d-%H%M%S)"
  MIGRATION_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  MIGRATION_UPDATED_AT="${MIGRATION_STARTED_AT}"
  MIGRATION_LAST_STEP="initialized"
  MIGRATION_REMOTE_HEAD="${remote_head}"
  MIGRATION_REPO_URL="${UPSTREAM_REPO_URL}"
  MIGRATION_REPO_DIR="${CLUB3090_DIR}"
  save_migration_state
  append_control_log_line "migrate state initialized: remote_head=${MIGRATION_REMOTE_HEAD:-unknown}, repo=${CLUB3090_DIR}"
}

finalize_migration_state_success() {
  MIGRATION_STATUS="complete"
  MIGRATION_LAST_STEP="complete"
  MIGRATION_UPDATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  append_control_log_line "migrate completed successfully"
  "${SUDO[@]}" rm -f "${MIGRATION_STATE_FILE}" >/dev/null 2>&1 || true
  migration_state_defaults
}

migration_exit_trap() {
  local rc=$?
  if [[ "${ACTION}" == "migrate" ]]; then
    if [[ "${rc}" -ne 0 ]]; then
      ensure_control_dir
      load_migration_state || true
      if [[ -n "${MIGRATION_STARTED_AT}" ]]; then
        MIGRATION_STATUS="interrupted"
        MIGRATION_UPDATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        save_migration_state
        status_line "Migration interrupted at step '${MIGRATION_LAST_STEP:-unknown}'. Resume later with --migrate."
        status_line "Remaining migration phases: $(migration_pending_summary)"
      fi
    fi
  fi
}

trap 'migration_exit_trap' EXIT
trap 'exit 130' INT TERM

run_live_command() {
  local label="$1"
  local cwd="$2"
  local command="$3"
  status_line "${label}: starting"
  status_line "${label}: command: ${command}"
  "${SUDO[@]}" env CLUB3090_STATUS_LABEL="${label}" CLUB3090_STATUS_CWD="${cwd}" CLUB3090_STATUS_COMMAND="${command}" CLUB3090_STATUS_HEARTBEAT_SECONDS="2" "${PYTHON_BIN}" - <<'PYRUNLIVE'
import os
import selectors
import subprocess
import sys
import time

label = os.environ.get("CLUB3090_STATUS_LABEL", "command")
cwd = os.environ.get("CLUB3090_STATUS_CWD") or None
command = os.environ.get("CLUB3090_STATUS_COMMAND", "")
heartbeat_seconds = float(os.environ.get("CLUB3090_STATUS_HEARTBEAT_SECONDS", "2") or "2")
start = time.time()
last_emit = start
env = os.environ.copy()
if cwd:
    env_path = os.path.join(cwd, ".env")
    if os.path.exists(env_path):
        try:
            with open(env_path, "r", encoding="utf-8", errors="replace") as f:
                for raw in f:
                    line = raw.strip()
                    if not line or line.startswith("#") or "=" not in line:
                        continue
                    key, value = line.split("=", 1)
                    env[key.strip()] = value.strip()
        except Exception:
            pass
proc = subprocess.Popen(
    ["bash", "-lc", command],
    cwd=cwd,
    env=env,
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
)
selector = selectors.DefaultSelector()
assert proc.stdout is not None
fd = proc.stdout.fileno()
os.set_blocking(fd, False)
selector.register(proc.stdout, selectors.EVENT_READ)
buffer = ""

def stamp(message):
    print(f"[{time.strftime('%H:%M:%S')}] {label}: {message}", flush=True)

while True:
    events = selector.select(timeout=heartbeat_seconds)
    if events:
        for key, _mask in events:
            chunk = os.read(key.fd, 8192)
            if not chunk:
                continue
            buffer += chunk.decode("utf-8", errors="replace")
            while "\n" in buffer:
                line, buffer = buffer.split("\n", 1)
                line = line.rstrip("\r")
                if line:
                    stamp(line)
                else:
                    stamp("")
                last_emit = time.time()
    else:
        if proc.poll() is None:
            elapsed = int(time.time() - start)
            idle = int(time.time() - last_emit)
            stamp(f"still running ({elapsed}s elapsed, {idle}s since last output)")
            last_emit = time.time()
    if proc.poll() is not None:
        try:
            remainder = os.read(fd, 8192)
        except BlockingIOError:
            remainder = b""
        if remainder:
            buffer += remainder.decode("utf-8", errors="replace")
        if buffer:
            for line in buffer.splitlines():
                stamp(line.rstrip("\r"))
            buffer = ""
        break

rc = proc.wait()
stamp(f"finished with exit code {rc} after {int(time.time() - start)}s")
sys.exit(rc)
PYRUNLIVE
}

count_tree_files() {
  local path="$1"
  if [[ ! -e "${path}" ]]; then
    printf '0\n'
    return 0
  fi
  find "${path}" -type f 2>/dev/null | wc -l | awk '{print $1}'
}

merge_dir_contents_logged() {
  local label="$1"
  local src="$2"
  local dst="$3"
  if [[ ! -d "${src}" ]]; then
    append_control_log_line "${label}: source missing, skipping (${src})"
    return 0
  fi
  local file_count
  file_count="$(count_tree_files "${src}")"
  migration_update_state "merge_${label}"
  append_control_log_line "${label}: merging ${file_count} files from ${src} into ${dst}"
  run_live_command "${label}" "/" "mkdir -p $(shell_quote "${dst}") && cp -a $(shell_quote "${src}")/. $(shell_quote "${dst}")/"
}

quarantine_non_git_genesis_dirs() {
  local quarantine_root="${MIGRATION_BACKUP_DIR:-${CLUB3090_DIR}-migrate-artifacts}/preserved-genesis"
  local genesis_dir
  local rel
  local dest
  while IFS= read -r genesis_dir; do
    [[ -n "${genesis_dir}" ]] || continue
    if [[ -d "${genesis_dir}/.git" ]]; then
      append_control_log_line "genesis quarantine: keeping existing git checkout ${genesis_dir}"
      continue
    fi
    rel="${genesis_dir#"${CLUB3090_DIR}/"}"
    dest="${quarantine_root}/${rel//\//__}.pre-setup"
    append_control_log_line "genesis quarantine: moving non-git directory ${genesis_dir} to ${dest}"
    run_live_command "genesis quarantine" "/" "mkdir -p $(shell_quote "$(dirname "${dest}")") && mv $(shell_quote "${genesis_dir}") $(shell_quote "${dest}")"
  done < <(find "${CLUB3090_DIR}/models" -type d -path '*/vllm/patches/genesis' 2>/dev/null || true)
}

merge_dir_contents() {
  local src="$1"
  local dst="$2"
  if [[ ! -d "${src}" ]]; then
    return 0
  fi
  "${SUDO[@]}" mkdir -p "${dst}"
  "${SUDO[@]}" cp -a "${src}/." "${dst}/"
}

merge_env_files() {
  local dest="$1"
  local src="$2"
  local old_root="${3:-}"
  local new_root="${4:-}"
  if [[ ! -f "${src}" ]]; then
    return 0
  fi
  "${SUDO[@]}" "${PYTHON_BIN}" - "${dest}" "${src}" "${old_root}" "${new_root}" <<'PYMERGEENV'
import os, sys
dest, src, old_root, new_root = sys.argv[1:5]
def parse(path):
    data = {}
    if not os.path.exists(path):
        return data
    for raw in open(path, "r", encoding="utf-8", errors="replace").read().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        if key:
            data[key] = value.strip()
    return data
def rewrite_repo_local_paths(data):
    if not old_root or not new_root:
        return data
    prefix = old_root.rstrip("/") + "/"
    for key, value in list(data.items()):
        text = str(value or "").strip()
        if key in {"MODEL_DIR", "HF_HOME", "TRANSFORMERS_CACHE"} and text.startswith(prefix):
            data[key] = new_root.rstrip("/") + "/" + text[len(prefix):]
    return data
merged = parse(dest)
incoming = rewrite_repo_local_paths(parse(src))
merged.update(incoming)
os.makedirs(os.path.dirname(dest) or ".", exist_ok=True)
with open(dest, "w", encoding="utf-8", newline="\n") as f:
    for key in sorted(merged):
        f.write(f"{key}={merged[key]}\n")
PYMERGEENV
}

rebuild_runtime_inventory_cli() {
  local phase_flag="${1:-}"
  local phase_step="${2:-inventory_rebuild}"
  if [[ "${ACTION}" == "migrate" || -n "${phase_flag}" ]]; then
    migration_update_state "${phase_step}"
  fi
  append_control_log_line "runtime inventory rebuild starting (${phase_step})"
  run_live_command "runtime inventory rebuild" "/" "env CLUB3090_DIR=$(shell_quote "${CLUB3090_DIR}") $(shell_quote "${PYTHON_BIN}") $(shell_quote "${CONTROL_PY}") --rebuild-inventory"
  append_control_log_line "runtime inventory rebuild finished (${phase_step})"
  if [[ -n "${phase_flag}" ]]; then
    migration_mark_flag_done "${phase_flag}" "${phase_step}_complete"
  fi
}

collect_required_setup_commands() {
  "${SUDO[@]}" env CLUB3090_DIR="${CLUB3090_DIR}" "${PYTHON_BIN}" - "${CONTROL_DIR}" <<'PYSETUPCMDS'
import json, os, sys
control_dir = sys.argv[1]
inventory_path = os.path.join(control_dir, "runtime_inventory.json")
instances_path = os.path.join(control_dir, "instances.json")
active_mode_path = os.path.join(control_dir, "active_mode")
last_good_mode_path = os.path.join(control_dir, "last_good_mode")
def load_json(path, default):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return default
def read_text(path):
    try:
        return open(path, "r", encoding="utf-8").read().strip()
    except Exception:
        return ""
inventory = load_json(inventory_path, {})
variants = list(inventory.get("variants") or [])
lookup = {}
for variant in variants:
    for key in (variant.get("variant_id"), variant.get("upstream_tag"), variant.get("compose_rel_path")):
        if key:
            lookup[str(key)] = variant
modes = []
for value in (read_text(active_mode_path), read_text(last_good_mode_path)):
    if value:
        modes.append(value)
for row in load_json(instances_path, []):
    if isinstance(row, dict) and row.get("enabled") and row.get("mode"):
        modes.append(str(row.get("mode")))
commands = []
seen = set()
for mode in modes:
    variant = lookup.get(str(mode))
    if not variant:
        continue
    command = str(variant.get("install_command") or "").strip()
    if command and command not in seen:
        seen.add(command)
        commands.append(command)
for command in commands:
    print(command)
PYSETUPCMDS
}

collect_required_update_models() {
  "${SUDO[@]}" env CLUB3090_DIR="${CLUB3090_DIR}" "${PYTHON_BIN}" - "${CONTROL_DIR}" <<'PYUPDATEMODELS'
import json, os, sys
control_dir = sys.argv[1]
inventory_path = os.path.join(control_dir, "runtime_inventory.json")
instances_path = os.path.join(control_dir, "instances.json")
active_mode_path = os.path.join(control_dir, "active_mode")
last_good_mode_path = os.path.join(control_dir, "last_good_mode")
def load_json(path, default):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return default
def read_text(path):
    try:
        return open(path, "r", encoding="utf-8").read().strip()
    except Exception:
        return ""
inventory = load_json(inventory_path, {})
variants = list(inventory.get("variants") or [])
lookup = {}
for variant in variants:
    for key in (variant.get("variant_id"), variant.get("upstream_tag"), variant.get("compose_rel_path")):
        if key:
            lookup[str(key)] = variant
modes = []
for value in (read_text(active_mode_path), read_text(last_good_mode_path)):
    if value:
        modes.append(value)
for row in load_json(instances_path, []):
    if isinstance(row, dict) and row.get("enabled") and row.get("mode"):
        modes.append(str(row.get("mode")))
seen = set()
models = []
for mode in modes:
    variant = lookup.get(str(mode))
    if not variant:
        continue
    model_id = str(variant.get("model_id") or "").strip()
    if model_id and model_id not in seen:
        seen.add(model_id)
        models.append(model_id)
for model_id in models:
    print(model_id)
PYUPDATEMODELS
}

run_required_setup_commands() {
  local commands=()
  mapfile -t commands < <(collect_required_setup_commands)
  if [[ "${#commands[@]}" -eq 0 ]]; then
    append_control_log_line "migrate setup: no required setup commands detected from persisted state"
    migration_mark_flag_done "MIGRATION_SETUP_DONE" "setup_skipped_no_commands"
    return 0
  fi
  local cmd
  local idx=0
  local total="${#commands[@]}"
  for cmd in "${commands[@]}"; do
    [[ -n "${cmd}" ]] || continue
    idx=$((idx + 1))
    migration_update_state "setup_command_${idx}_of_${total}"
    append_control_log_line "migrate setup command: ${cmd}"
    run_live_command "model setup ${idx}/${total}" "${CLUB3090_DIR}" "${cmd}"
  done
  migration_mark_flag_done "MIGRATION_SETUP_DONE" "setup_complete"
}

run_required_update_scripts() {
  local models=()
  mapfile -t models < <(collect_required_update_models)
  if [[ "${#models[@]}" -eq 0 ]]; then
    migration_update_state "update_script_full_repo"
    append_control_log_line "migrate update.sh command: bash scripts/update.sh"
    run_live_command "upstream update.sh" "${CLUB3090_DIR}" "bash scripts/update.sh"
    migration_mark_flag_done "MIGRATION_UPDATE_DONE" "update_complete_full_repo"
    return 0
  fi
  local model
  local idx=0
  local total="${#models[@]}"
  for model in "${models[@]}"; do
    [[ -n "${model}" ]] || continue
    idx=$((idx + 1))
    migration_update_state "update_script_${idx}_of_${total}_${model}"
    append_control_log_line "migrate update.sh command: bash scripts/update.sh --force ${model}"
    run_live_command "upstream update.sh ${idx}/${total}" "${CLUB3090_DIR}" "bash scripts/update.sh --force $(shell_quote "${model}")"
  done
  migration_mark_flag_done "MIGRATION_UPDATE_DONE" "update_complete"
}

migrate_repo_checkout() {
  local timestamp local_head remote_head backup_dir repo_head_after_clone partial_dir
  local_head="$(git_repo_head "${CLUB3090_DIR}" || true)"
  remote_head="${MIGRATION_REMOTE_HEAD:-}"
  if [[ -z "${MIGRATION_BACKUP_DIR}" ]]; then
    timestamp="$(date +%Y%m%d-%H%M%S)"
    MIGRATION_BACKUP_DIR="${CLUB3090_DIR}-backup_${timestamp}"
    save_migration_state
  fi
  backup_dir="${MIGRATION_BACKUP_DIR}"

  if [[ "${MIGRATION_REPO_RENAMED}" != "1" && -n "${local_head}" && -n "${remote_head}" && "${local_head}" == "${remote_head}" ]]; then
    append_control_log_line "migrate checkout replacement skipped: local repo HEAD already matches upstream (${local_head})"
    MIGRATION_REPO_RENAMED=1
    MIGRATION_REPO_CLONED=1
    MIGRATION_ASSETS_MERGED=1
    migration_update_state "local_checkout_already_current"
    return 0
  fi

  if [[ "${MIGRATION_REPO_RENAMED}" != "1" ]]; then
    if [[ ! -d "${CLUB3090_DIR}" ]]; then
      echo "ERROR: --migrate requires an existing checkout at ${CLUB3090_DIR}" >&2
      exit 1
    fi
    if [[ -e "${backup_dir}" ]]; then
      echo "ERROR: backup path already exists: ${backup_dir}" >&2
      exit 1
    fi
    migration_update_state "backup_path_selected"
    append_control_log_line "migrate backup path chosen: ${backup_dir}"
    run_live_command "migrate rename existing checkout" "/" "mv $(shell_quote "${CLUB3090_DIR}") $(shell_quote "${backup_dir}")"
    migration_mark_flag_done "MIGRATION_REPO_RENAMED" "rename_complete"
    append_control_log_line "migrate rename success: ${CLUB3090_DIR} -> ${backup_dir}"
  else
    append_control_log_line "migrate rename step already complete; using backup at ${backup_dir}"
  fi

  if [[ ! -d "${backup_dir}" ]]; then
    echo "ERROR: migration backup directory is missing: ${backup_dir}" >&2
    exit 1
  fi

  if [[ "${MIGRATION_REPO_CLONED}" != "1" ]]; then
    if repo_head_after_clone="$(git_repo_head "${CLUB3090_DIR}" || true)" && [[ -n "${repo_head_after_clone}" ]]; then
      append_control_log_line "migrate clone step already satisfied by existing checkout at ${CLUB3090_DIR} (${repo_head_after_clone})"
      migration_mark_flag_done "MIGRATION_REPO_CLONED" "clone_already_present"
    else
      if [[ -e "${CLUB3090_DIR}" ]]; then
        partial_dir="${CLUB3090_DIR}-partial_$(date +%Y%m%d-%H%M%S)"
        append_control_log_line "migrate found partial clone target at ${CLUB3090_DIR}; moving it aside to ${partial_dir}"
        run_live_command "migrate quarantine partial clone" "/" "mv $(shell_quote "${CLUB3090_DIR}") $(shell_quote "${partial_dir}")"
      fi
      migration_update_state "clone_fresh_upstream_repo"
      run_live_command "migrate git clone" "/" "GIT_TERMINAL_PROMPT=0 git clone --progress $(shell_quote "${UPSTREAM_REPO_URL}") $(shell_quote "${CLUB3090_DIR}")"
      repo_head_after_clone="$(git_repo_head "${CLUB3090_DIR}" || true)"
      append_control_log_line "migrate clone success: ${UPSTREAM_REPO_URL} -> ${CLUB3090_DIR} (${repo_head_after_clone:-unknown-head})"
      migration_mark_flag_done "MIGRATION_REPO_CLONED" "clone_complete"
    fi
  else
    append_control_log_line "migrate clone step already complete for ${CLUB3090_DIR}"
  fi

  if [[ "${MIGRATION_ASSETS_MERGED}" != "1" ]]; then
    migration_update_state "asset_merge_start"
    merge_dir_contents_logged "migrate models-cache merge" "${backup_dir}/models-cache" "${CLUB3090_DIR}/models-cache"
    if [[ -f "${backup_dir}/.env" ]]; then
      append_control_log_line "migrate env merge: merging ${backup_dir}/.env into ${CLUB3090_DIR}/.env"
      merge_env_files "${CLUB3090_DIR}/.env" "${backup_dir}/.env" "${backup_dir}" "${CLUB3090_DIR}"
    else
      append_control_log_line "migrate env merge: no .env found in ${backup_dir}, skipping"
    fi
    local backup_model_dir_raw backup_model_dir_resolved new_model_dir_raw new_model_dir_resolved
    backup_model_dir_raw="$(read_repo_env_value "${backup_dir}/.env" "MODEL_DIR" || true)"
    if [[ -n "${backup_model_dir_raw}" ]]; then
      if [[ "${backup_model_dir_raw}" = /* ]]; then
        if [[ "${backup_model_dir_raw}" == "${CLUB3090_DIR}"* ]]; then
          backup_model_dir_resolved="${backup_dir}${backup_model_dir_raw#"${CLUB3090_DIR}"}"
        else
          backup_model_dir_resolved="${backup_model_dir_raw}"
        fi
      else
        backup_model_dir_resolved="$(cd "${backup_dir}" && cd "${backup_model_dir_raw}" 2>/dev/null && pwd || true)"
      fi
    else
      backup_model_dir_resolved="${backup_dir}/models-cache"
    fi
    new_model_dir_raw="$(read_repo_env_value "${CLUB3090_DIR}/.env" "MODEL_DIR" || true)"
    if [[ -n "${new_model_dir_raw}" ]]; then
      if [[ "${new_model_dir_raw}" = /* ]]; then
        new_model_dir_resolved="${new_model_dir_raw}"
      else
        new_model_dir_resolved="$(cd "${CLUB3090_DIR}" && cd "${new_model_dir_raw}" 2>/dev/null && pwd || true)"
      fi
    else
      new_model_dir_resolved="${CLUB3090_DIR}/models-cache"
    fi
    append_control_log_line "migrate model-dir resolution: backup_raw=${backup_model_dir_raw:-<default>} backup_resolved=${backup_model_dir_resolved:-<unresolved>} new_raw=${new_model_dir_raw:-<default>} new_resolved=${new_model_dir_resolved:-<unresolved>}"
    if [[ -n "${backup_model_dir_resolved:-}" && -d "${backup_model_dir_resolved}" && -n "${new_model_dir_resolved:-}" ]]; then
      if [[ "${backup_model_dir_resolved}" != "${new_model_dir_resolved}" ]]; then
        merge_dir_contents_logged "migrate effective model dir merge" "${backup_model_dir_resolved}" "${new_model_dir_resolved}"
      else
        append_control_log_line "migrate effective model dir merge skipped: source and target resolve to the same path (${new_model_dir_resolved})"
      fi
    else
      append_control_log_line "migrate effective model dir merge skipped: source missing or unresolved"
    fi
    while IFS= read -r cache_dir; do
      [[ -n "${cache_dir}" ]] || continue
      if [[ "${cache_dir}" == *"/patches/genesis/"* || "${cache_dir}" == *"/patches/genesis" ]]; then
        append_control_log_line "migrate cache merge skipped for genesis patch tree: ${cache_dir}"
        continue
      fi
      local rel
      rel="${cache_dir#"${backup_dir}/"}"
      merge_dir_contents_logged "migrate cache merge ${rel}" "${cache_dir}" "${CLUB3090_DIR}/${rel}"
    done < <(find "${backup_dir}/models" -type d -path '*/cache' 2>/dev/null || true)
    append_control_log_line "migrate asset merge summary: repo-local models-cache preserved, effective MODEL_DIR mirrored, compose cache directories copied, .env merged if present"
    migration_mark_flag_done "MIGRATION_ASSETS_MERGED" "asset_merge_complete"
  else
    append_control_log_line "migrate asset merge step already complete"
  fi
}

APT_UPDATED=0
install_packages() {
  if [[ "$#" -eq 0 ]]; then
    return 0
  fi
  case "${OS_FAMILY}" in
    arch)
      "${SUDO[@]}" pacman -S --needed --noconfirm "$@"
      ;;
    debian)
      if [[ "${APT_UPDATED}" -eq 0 ]]; then
        "${SUDO[@]}" apt-get update
        APT_UPDATED=1
      fi
      DEBIAN_FRONTEND=noninteractive "${SUDO[@]}" apt-get install -y "$@"
      ;;
  esac
}

install_aur_package_if_possible() {
  local pkg="$1"
  if command -v yay >/dev/null 2>&1; then
    yay -S --needed --noconfirm "${pkg}"
    return $?
  fi
  if command -v paru >/dev/null 2>&1; then
    paru -S --needed --noconfirm "${pkg}"
    return $?
  fi
  return 1
}

require_command_after_install() {
  local cmd="$1"
  local why="$2"
  if command -v "${cmd}" >/dev/null 2>&1; then
    return 0
  fi
  echo "ERROR: Required dependency '${cmd}' is still missing after installation attempts. ${why}" >&2
  exit 1
}

ensure_command_or_install() {
  local cmd="$1"
  local description="$2"
  shift 2
  if command -v "${cmd}" >/dev/null 2>&1; then
    return 0
  fi
  echo "${description}"
  if ! install_packages "$@"; then
    echo "WARNING: Failed to install packages for ${cmd}. Continuing, but related features may be unavailable." >&2
    return 1
  fi
  command -v "${cmd}" >/dev/null 2>&1
}

ensure_pamtester_available() {
  if command -v pamtester >/dev/null 2>&1; then
    return 0
  fi
  echo "Installing pamtester for Linux account authentication..."
  case "${OS_FAMILY}" in
    arch)
      install_packages pamtester >/dev/null 2>&1 || true
      if ! command -v pamtester >/dev/null 2>&1; then
        install_aur_package_if_possible pamtester >/dev/null 2>&1 || true
      fi
      ;;
    debian)
      install_packages pamtester >/dev/null 2>&1 || true
      ;;
  esac
  require_command_after_install pamtester "The admin UI depends on it for local account authentication. Install it manually if your distribution does not package it."
}

ensure_headless_nvidia_dependencies() {
  local need_install=0
  if ! command -v Xorg >/dev/null 2>&1; then
    need_install=1
  fi
  if ! command -v nvidia-settings >/dev/null 2>&1; then
    need_install=1
  fi
  if [[ "${need_install}" -eq 0 ]]; then
    return 0
  fi
  echo "Installing headless NVIDIA fan-control dependencies..."
  case "${OS_FAMILY}" in
    arch)
      install_packages xorg-server xorg-xinit nvidia-settings || true
      ;;
    debian)
      install_packages xserver-xorg-core xinit nvidia-settings || true
      ;;
  esac
  require_command_after_install Xorg "Headless fan control and NVIDIA tuning rely on a private Xorg display."
  require_command_after_install nvidia-settings "Fan control and GPU tuning rely on nvidia-settings."
}

install_caddy_official_debian_repo() {
  if command -v caddy >/dev/null 2>&1; then
    return 0
  fi
  echo "Installing Caddy from the official Debian/Ubuntu repository..."
  install_packages ca-certificates debian-keyring debian-archive-keyring apt-transport-https curl gpg >/dev/null 2>&1 || true
  require_command_after_install curl "Caddy installation needs curl to configure the official repository."
  require_command_after_install gpg "Caddy installation needs gpg to configure the official repository."
  "${SUDO[@]}" mkdir -p /usr/share/keyrings /etc/apt/sources.list.d
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | "${SUDO[@]}" gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | "${SUDO[@]}" tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
  "${SUDO[@]}" chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg /etc/apt/sources.list.d/caddy-stable.list
  APT_UPDATED=0
  install_packages caddy >/dev/null 2>&1 || true
}

ensure_caddy_available() {
  if command -v caddy >/dev/null 2>&1; then
    return 0
  fi
  case "${OS_FAMILY}" in
    arch)
      echo "Installing Caddy..."
      install_packages caddy >/dev/null 2>&1 || true
      ;;
    debian)
      install_caddy_official_debian_repo
      ;;
  esac
  require_command_after_install caddy "HTTPS mode uses Caddy as the TLS reverse-proxy frontend."
}

read_network_state_field() {
  local key="$1"
  if [[ -r "${NETWORK_STATE_FILE}" ]] && command -v python3 >/dev/null 2>&1; then
    python3 - "${NETWORK_STATE_FILE}" "${key}" <<'PYSTATE' 2>/dev/null
import json, sys
path, key = sys.argv[1], sys.argv[2]
try:
    with open(path, "r", encoding="utf-8") as f:
        obj = json.load(f)
except Exception:
    sys.exit(0)
val = obj.get(key)
if isinstance(val, list):
    print(",".join(str(x) for x in val))
elif val is not None:
    print(val)
PYSTATE
  fi
}

write_network_state() {
  local firewall_manager="$1"
  local upnp_enabled="$2"
  local tls_enabled="$3"
  if [[ -z "${PYTHON_BIN}" ]]; then
    return 1
  fi
  "${SUDO[@]}" "${PYTHON_BIN}" - "${NETWORK_STATE_FILE}" "${firewall_manager}" "${upnp_enabled}" "${tls_enabled}" "${ADMIN_PORT}" "${PROXY_PORT}" <<'PYNSTATE'
import json, os, sys
path, firewall_manager, upnp_enabled, tls_enabled, admin_port, proxy_port = sys.argv[1:]
os.makedirs(os.path.dirname(path), exist_ok=True)
obj = {
    "firewall_manager": firewall_manager,
    "firewall_ports": [int(admin_port), int(proxy_port)],
    "upnp_ports": [int(admin_port), int(proxy_port)] if upnp_enabled == "true" else [],
    "tls_enabled": tls_enabled == "true",
}
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(obj, f, indent=2, sort_keys=True)
os.replace(tmp, path)
PYNSTATE
}

close_tracked_online_exposure() {
  local old_fw old_ports old_upnp_ports old_port
  old_fw="$(read_network_state_field firewall_manager || true)"
  old_ports="$(read_network_state_field firewall_ports || true)"
  old_upnp_ports="$(read_network_state_field upnp_ports || true)"
  for old_port in ${old_ports//,/ }; do
    [[ "${old_port}" =~ ^[0-9]+$ ]] || continue
    case "${old_fw}" in
      ufw)
        "${SUDO[@]}" ufw delete allow "${old_port}"/tcp >/dev/null 2>&1 || true
        ;;
      firewalld)
        if command -v firewall-cmd >/dev/null 2>&1 && "${SUDO[@]}" firewall-cmd --state >/dev/null 2>&1; then
          "${SUDO[@]}" firewall-cmd --permanent --remove-port="${old_port}"/tcp >/dev/null 2>&1 || true
        fi
        ;;
      iptables)
        if command -v iptables >/dev/null 2>&1; then
          while "${SUDO[@]}" iptables -C INPUT -p tcp --dport "${old_port}" -j ACCEPT >/dev/null 2>&1; do
            "${SUDO[@]}" iptables -D INPUT -p tcp --dport "${old_port}" -j ACCEPT >/dev/null 2>&1 || break
          done
        fi
        ;;
    esac
  done
  for old_port in ${old_upnp_ports//,/ }; do
    [[ "${old_port}" =~ ^[0-9]+$ ]] || continue
    if command -v upnpc >/dev/null 2>&1; then
      upnpc -d "${old_port}" tcp >/dev/null 2>&1 || true
    fi
  done
  if [[ "${old_fw}" == "firewalld" ]] && command -v firewall-cmd >/dev/null 2>&1 && "${SUDO[@]}" firewall-cmd --state >/dev/null 2>&1; then
    "${SUDO[@]}" firewall-cmd --reload >/dev/null 2>&1 || true
  fi
  if [[ -e "${NETWORK_STATE_FILE}" ]]; then
    "${SUDO[@]}" rm -f "${NETWORK_STATE_FILE}" >/dev/null 2>&1 || true
  fi
}

ensure_https_certificate() {
  local local_ip public_ip san_list san_file
  if [[ -r "${TLS_CERT_FILE}" && -r "${TLS_KEY_FILE}" ]]; then
    return 0
  fi
  ensure_command_or_install openssl "Installing OpenSSL for HTTPS certificate generation..." openssl >/dev/null 2>&1 || true
  require_command_after_install openssl "HTTPS mode needs OpenSSL to generate a certificate."
  local_ip="$(detect_primary_local_ip)"
  public_ip=""
  if command -v curl >/dev/null 2>&1; then
    public_ip="$(curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  fi
  san_list="DNS:localhost,DNS:$(hostname)"
  if [[ -n "${local_ip}" ]]; then
    san_list+=",IP:${local_ip}"
  fi
  if [[ -n "${public_ip}" ]]; then
    san_list+=",IP:${public_ip}"
  fi
  san_file="$(mktemp)"
  cat > "${san_file}" <<EOF
[req]
distinguished_name=req_distinguished_name
x509_extensions=v3_req
prompt=no

[req_distinguished_name]
CN=$(hostname)

[v3_req]
subjectAltName=${san_list}
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
EOF
  "${SUDO[@]}" mkdir -p "${CONTROL_DIR}"
  "${SUDO[@]}" openssl req -x509 -nodes -newkey rsa:2048 -days 365 -keyout "${TLS_KEY_FILE}" -out "${TLS_CERT_FILE}" -config "${san_file}" >/dev/null 2>&1 || {
    rm -f "${san_file}"
    echo "ERROR: Failed to generate TLS certificate for HTTPS mode." >&2
    exit 1
  }
  rm -f "${san_file}"
  "${SUDO[@]}" chmod 600 "${TLS_KEY_FILE}" || true
}

detect_primary_local_ip() {
  local ip_value=""
  if command -v ip >/dev/null 2>&1; then
    ip_value="$(ip route get 1.1.1.1 2>/dev/null | awk '/src /{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  fi
  if [[ -z "${ip_value}" ]]; then
    ip_value="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  printf '%s\n' "${ip_value}"
}

close_runtime_exposure() {
  local runtime_port
  for runtime_port in $(seq 8010 8020) $(seq 8200 8299); do
    if command -v ufw >/dev/null 2>&1; then
      "${SUDO[@]}" ufw delete allow "${runtime_port}"/tcp >/dev/null 2>&1 || true
    elif command -v firewall-cmd >/dev/null 2>&1 && "${SUDO[@]}" firewall-cmd --state >/dev/null 2>&1; then
      "${SUDO[@]}" firewall-cmd --permanent --remove-port="${runtime_port}"/tcp >/dev/null 2>&1 || true
    elif command -v iptables >/dev/null 2>&1; then
      while "${SUDO[@]}" iptables -C INPUT -p tcp --dport "${runtime_port}" -j ACCEPT >/dev/null 2>&1; do
        "${SUDO[@]}" iptables -D INPUT -p tcp --dport "${runtime_port}" -j ACCEPT >/dev/null 2>&1 || break
      done
    fi
    if command -v upnpc >/dev/null 2>&1; then
      upnpc -d "${runtime_port}" tcp >/dev/null 2>&1 || true
    fi
  done
  if command -v firewall-cmd >/dev/null 2>&1 && "${SUDO[@]}" firewall-cmd --state >/dev/null 2>&1; then
    "${SUDO[@]}" firewall-cmd --reload >/dev/null 2>&1 || true
  fi
}

configure_online_exposure() {
  local local_ip
  local_ip="$(detect_primary_local_ip)"
  local opened_fw=0
  local opened_upnp=0
  local firewall_manager="none"

  echo "Configuring online exposure for ports ${ADMIN_PORT} (admin) and ${PROXY_PORT} (proxy)..."
  echo "Runtime backend ports like 8010-8020 and 8200+ will remain private."
  close_tracked_online_exposure
  close_runtime_exposure

  if command -v ufw >/dev/null 2>&1; then
    "${SUDO[@]}" ufw allow "${ADMIN_PORT}"/tcp >/dev/null 2>&1 || true
    "${SUDO[@]}" ufw allow "${PROXY_PORT}"/tcp >/dev/null 2>&1 || true
    opened_fw=1
    firewall_manager="ufw"
  elif command -v firewall-cmd >/dev/null 2>&1 && "${SUDO[@]}" firewall-cmd --state >/dev/null 2>&1; then
    "${SUDO[@]}" firewall-cmd --permanent --add-port="${ADMIN_PORT}"/tcp >/dev/null 2>&1 || true
    "${SUDO[@]}" firewall-cmd --permanent --add-port="${PROXY_PORT}"/tcp >/dev/null 2>&1 || true
    "${SUDO[@]}" firewall-cmd --reload >/dev/null 2>&1 || true
    opened_fw=1
    firewall_manager="firewalld"
  elif command -v iptables >/dev/null 2>&1; then
    "${SUDO[@]}" iptables -C INPUT -p tcp --dport "${ADMIN_PORT}" -j ACCEPT >/dev/null 2>&1 || "${SUDO[@]}" iptables -I INPUT -p tcp --dport "${ADMIN_PORT}" -j ACCEPT >/dev/null 2>&1 || true
    "${SUDO[@]}" iptables -C INPUT -p tcp --dport "${PROXY_PORT}" -j ACCEPT >/dev/null 2>&1 || "${SUDO[@]}" iptables -I INPUT -p tcp --dport "${PROXY_PORT}" -j ACCEPT >/dev/null 2>&1 || true
    opened_fw=1
    firewall_manager="iptables"
  fi

  if command -v upnpc >/dev/null 2>&1 && [[ -n "${local_ip}" ]]; then
    upnpc -e "club3090-admin" -a "${local_ip}" "${ADMIN_PORT}" "${ADMIN_PORT}" tcp >/dev/null 2>&1 && opened_upnp=1 || true
    upnpc -e "club3090-proxy" -a "${local_ip}" "${PROXY_PORT}" "${PROXY_PORT}" tcp >/dev/null 2>&1 && opened_upnp=1 || true
  fi

  if [[ "${opened_fw}" -eq 0 ]]; then
    echo "WARNING: No supported firewall manager was configured automatically. Admin and proxy ports may still need manual allow rules." >&2
  fi
  if [[ "${opened_upnp}" -eq 0 ]]; then
    echo "WARNING: UPnP port forwarding was not confirmed. Router support may be unavailable or disabled." >&2
  fi
  write_network_state "${firewall_manager}" "$([[ "${opened_upnp}" -eq 1 ]] && echo true || echo false)" "${ONLINE_TLS_EFFECTIVE_ENABLED}" >/dev/null 2>&1 || true
}

ensure_local_control_access() {
  local firewall_manager="none"
  local opened_fw=0

  echo "Ensuring local/LAN access for ports ${ADMIN_PORT} (admin) and ${PROXY_PORT} (proxy)..."

  if command -v ufw >/dev/null 2>&1; then
    "${SUDO[@]}" ufw allow "${ADMIN_PORT}"/tcp >/dev/null 2>&1 || true
    "${SUDO[@]}" ufw allow "${PROXY_PORT}"/tcp >/dev/null 2>&1 || true
    opened_fw=1
    firewall_manager="ufw"
  elif command -v firewall-cmd >/dev/null 2>&1 && "${SUDO[@]}" firewall-cmd --state >/dev/null 2>&1; then
    "${SUDO[@]}" firewall-cmd --permanent --add-port="${ADMIN_PORT}"/tcp >/dev/null 2>&1 || true
    "${SUDO[@]}" firewall-cmd --permanent --add-port="${PROXY_PORT}"/tcp >/dev/null 2>&1 || true
    "${SUDO[@]}" firewall-cmd --reload >/dev/null 2>&1 || true
    opened_fw=1
    firewall_manager="firewalld"
  elif command -v iptables >/dev/null 2>&1; then
    "${SUDO[@]}" iptables -C INPUT -p tcp --dport "${ADMIN_PORT}" -j ACCEPT >/dev/null 2>&1 || "${SUDO[@]}" iptables -I INPUT -p tcp --dport "${ADMIN_PORT}" -j ACCEPT >/dev/null 2>&1 || true
    "${SUDO[@]}" iptables -C INPUT -p tcp --dport "${PROXY_PORT}" -j ACCEPT >/dev/null 2>&1 || "${SUDO[@]}" iptables -I INPUT -p tcp --dport "${PROXY_PORT}" -j ACCEPT >/dev/null 2>&1 || true
    opened_fw=1
    firewall_manager="iptables"
  fi

  if [[ "${opened_fw}" -eq 0 ]]; then
    echo "WARNING: No supported firewall manager was configured automatically. Admin and proxy ports may still need manual allow rules." >&2
  fi
  write_network_state "${firewall_manager}" "false" "${ONLINE_TLS_EFFECTIVE_ENABLED}" >/dev/null 2>&1 || true
}

log_step "Preparing dependencies for ${PRETTY_NAME:-${ID:-unknown}} (${OS_FAMILY})"

if ! command -v systemctl >/dev/null 2>&1; then
  echo "ERROR: systemctl is required because this installer configures systemd services." >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker was not found in PATH. Install Docker before running this installer." >&2
  exit 1
elif ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
  echo "ERROR: Docker Compose was not detected. club-3090 variants rely on 'docker compose' or 'docker-compose'." >&2
  exit 1
fi

case "${OS_FAMILY}" in
  arch)
    ensure_command_or_install python3 "Installing Python 3..." python
    ensure_command_or_install cpupower "cpupower is recommended for CPU governor power management. Installing it..." cpupower || true
    ensure_pamtester_available
    if [[ "${ONLINE_EFFECTIVE_ENABLED}" == "true" ]]; then
      ensure_command_or_install upnpc "Installing miniupnpc for online port forwarding..." miniupnpc || true
      ensure_command_or_install ufw "Installing ufw for online firewall management..." ufw || true
    fi
    if [[ "${ONLINE_TLS_EFFECTIVE_ENABLED}" == "true" ]]; then
      ensure_command_or_install openssl "Installing OpenSSL for HTTPS certificate generation..." openssl || true
      ensure_caddy_available
    fi
    ;;
  debian)
    ensure_command_or_install python3 "Installing Python 3..." python3
    ensure_command_or_install cpupower "cpupower is recommended for CPU governor power management. Installing Ubuntu/Debian CPU power tools..." linux-tools-common || ensure_command_or_install cpupower "Falling back to distro-specific cpupower packages..." linux-cpupower || ensure_command_or_install cpupower "Falling back to generic Linux CPU power tools meta-package..." linux-tools-generic || true
    ensure_pamtester_available
    if [[ "${ONLINE_EFFECTIVE_ENABLED}" == "true" ]]; then
      ensure_command_or_install upnpc "Installing miniupnpc for online port forwarding..." miniupnpc || true
      ensure_command_or_install ufw "Installing ufw for online firewall management..." ufw || true
    fi
    if [[ "${ONLINE_TLS_EFFECTIVE_ENABLED}" == "true" ]]; then
      ensure_command_or_install openssl "Installing OpenSSL for HTTPS certificate generation..." openssl || true
      ensure_caddy_available
    fi
    ;;
esac

ensure_headless_nvidia_dependencies

# Optional: report free/used space on unmounted NTFS volumes when ntfsinfo supports it.
if ! command -v ntfsinfo >/dev/null 2>&1; then
  echo "Installing NTFS utilities for storage metrics..."
  install_packages ntfs-3g || true
fi

PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"
if [[ -z "${PYTHON_BIN}" ]]; then
  echo "ERROR: python3 is required but was not found after dependency installation." >&2
  exit 1
fi

log_done "Dependency preparation complete"

if [[ "${ACTION}" == "migrate" ]]; then
  log_step "Preparing resumable migration state"
  prepare_migration_state
  log_done "Migration state prepared"
fi

persist_hf_token_if_available

"${SUDO[@]}" mkdir -p "${CONTROL_DIR}"

# Disable older manual GPU power-limit services from earlier setup; v2.6 manages this dynamically.
"${SUDO[@]}" systemctl disable --now nvidia-tweaks.service 2>/dev/null || true
"${SUDO[@]}" systemctl disable --now set-gpu-power.service 2>/dev/null || true

# On update, stop the previous console follower first so a noisy old version
# does not keep spamming the active TTY while files are being replaced.
if [[ "${ACTION}" == "update" || "${ACTION}" == "migrate" ]]; then
  log_step "Stopping currently managed club-3090 services before ${ACTION}"
  # Stop old services before replacing files so a broken/stale Python process cannot
  # keep serving old code while the update is being installed.
  "${SUDO[@]}" systemctl stop club3090-console-log.service 2>/dev/null || true
  "${SUDO[@]}" systemctl stop club3090-control.service 2>/dev/null || true
  "${SUDO[@]}" systemctl stop club3090-caddy.service 2>/dev/null || true
  "${SUDO[@]}" systemctl stop club3090-headless-x.service 2>/dev/null || true
  "${SUDO[@]}" systemctl stop club3090-headless-x-v213.service 2>/dev/null || true
  if [[ "${ACTION}" == "migrate" ]]; then
    "${SUDO[@]}" systemctl stop club3090-vllm.service 2>/dev/null || true
    if [[ -f "${CLUB3090_DIR}/scripts/switch.sh" ]]; then
      (cd "${CLUB3090_DIR}" && "${SUDO[@]}" bash scripts/switch.sh --down) >/dev/null 2>&1 || true
    fi
  fi
  log_done "Old services stopped"
fi

if [[ "${ACTION}" == "migrate" ]]; then
  log_step "Migrating upstream club-3090 checkout"
  migrate_repo_checkout
  log_done "Upstream checkout migrated"
fi

log_step "Writing embedded control backend to ${CONTROL_PY}"
"${SUDO[@]}" tee "${CONTROL_PY}" >/dev/null <<'PYCTRL'
#!/usr/bin/env python3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit
import mimetypes
import base64
import codecs
import collections
import glob
import hashlib
import json
import math
import os
import platform
import re
import secrets
import select
import shlex
import shutil
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

CLUB3090_DIR = os.environ.get("CLUB3090_DIR", "/opt/ai/club-3090")
CONTROL_DIR = "/opt/club3090-control"
SCRIPT_VERSION = os.environ.get("CLUB3090_SCRIPT_VERSION", "unknown")
ACTIVE_MODE_FILE = os.path.join(CONTROL_DIR, "active_mode")
LAST_GOOD_MODE_FILE = os.path.join(CONTROL_DIR, "last_good_mode")
CONTROL_LOG_FILE = os.path.join(CONTROL_DIR, "control.log")
AUDIT_LOG_FILE = os.path.join(CONTROL_DIR, "audit.log")
UI_CONFIG_FILE = os.path.join(CONTROL_DIR, "ui_config.json")
CUSTOM_PRESETS_FILE = os.path.join(CONTROL_DIR, "custom_presets.json")
INSTANCES_CONFIG_FILE = os.path.join(CONTROL_DIR, "instances.json")
SERVER_CONFIG_FILE = os.path.join(CONTROL_DIR, "server_config.json")
USERS_FILE = os.path.join(CONTROL_DIR, "users.json")
GROUPS_FILE = os.path.join(CONTROL_DIR, "groups.json")
CHAT_CONVERSATIONS_DIR = os.path.join(CONTROL_DIR, "conversations")
CHAT_STATE_FILE = os.path.join(CHAT_CONVERSATIONS_DIR, "state.json")
CHAT_ATTACHMENTS_DIR = os.path.join(CHAT_CONVERSATIONS_DIR, "attachments")
LOCAL_API_TOKEN_FILE = os.path.join(CONTROL_DIR, "local_api_token")
INSTANCES_DIR = os.path.join(CONTROL_DIR, "instances")
RUNTIME_INVENTORY_FILE = os.path.join(CONTROL_DIR, "runtime_inventory.json")
SWITCH_FAILURE_FILE = os.path.join(CONTROL_DIR, "switch_failure.json")
DEFAULT_MODE = os.environ.get("DEFAULT_MODE", "vllm/default")
ADMIN_PORT = int(os.environ.get("CLUB3090_ADMIN_PORT", "8008"))
PROXY_PORT = int(os.environ.get("CLUB3090_PROXY_PORT", "8009"))
LOCAL_API_PORT = int(os.environ.get("CLUB3090_LOCAL_API_PORT", "10881"))
ADMIN_BIND_HOST = os.environ.get("CLUB3090_ADMIN_BIND_HOST", "0.0.0.0")
PROXY_BIND_HOST = os.environ.get("CLUB3090_PROXY_BIND_HOST", "0.0.0.0")
ADMIN_BIND_PORT = int(os.environ.get("CLUB3090_ADMIN_BIND_PORT", str(ADMIN_PORT)))
PROXY_BIND_PORT = int(os.environ.get("CLUB3090_PROXY_BIND_PORT", str(PROXY_PORT)))
HTTPS_CERT_FILE = os.path.join(CONTROL_DIR, "tls.crt")
HTTPS_KEY_FILE = os.path.join(CONTROL_DIR, "tls.key")

MODES = {}
SINGLE_GPU_MODES = ()
DUAL_GPU_MODES = ()
VARIANT_SPECS = {}
VARIANT_BY_ID = {}
VARIANT_BY_TAG = {}
VARIANT_BY_CONTAINER = {}
VARIANT_BY_SERVICE = {}
VARIANT_BY_COMPOSE = {}
MODEL_INDEX = {}
INSTANCE_PORT_BASE = int(os.environ.get("CLUB3090_INSTANCE_PORT_BASE", "8200"))
PAIR_INSTANCE_PORT_BASE = int(os.environ.get("CLUB3090_PAIR_INSTANCE_PORT_BASE", "8300"))
COMPOSE_BIN = os.environ.get("CLUB3090_COMPOSE_BIN", "docker compose")

PRESETS = {
    "chat": {
        "chat_template_kwargs": {"enable_thinking": False},
        "temperature": 1.0, "top_p": 0.95, "top_k": 20, "min_p": 0,
        "presence_penalty": 1.5, "repetition_penalty": 1.0,
    },
    "general": {
        "chat_template_kwargs": {"enable_thinking": False},
        "temperature": 0.7, "top_p": 0.8, "top_k": 20, "min_p": 0,
        "presence_penalty": 1.5, "repetition_penalty": 1.0,
    },
    "coding": {
        "chat_template_kwargs": {"enable_thinking": False},
        "temperature": 0.6, "top_p": 0.95, "top_k": 20, "min_p": 0,
        "presence_penalty": 0, "repetition_penalty": 1.0,
    },
    "coding_fast": {
        "chat_template_kwargs": {"enable_thinking": False},
        "temperature": 0.8, "top_p": 0.95, "top_k": 20, "min_p": 0,
        "presence_penalty": 0, "repetition_penalty": 1.0,
    },
    "thinking": {
        "chat_template_kwargs": {"enable_thinking": True},
        "temperature": 1.0, "top_p": 0.95, "top_k": 20, "min_p": 0,
        "presence_penalty": 1.5,
    },
    "preserve-thinking": {
        "chat_template_kwargs": {"enable_thinking": True, "preserve_thinking": True},
        "temperature": 1.0, "top_p": 0.95, "top_k": 20, "min_p": 0,
        "presence_penalty": 1.5,
    },
}

DEFAULT_PRESET_DESCRIPTIONS = {
    "chat": "No thinking, temperature 1.0, top_p 0.95, top_k 20, min_p 0, presence penalty 1.5.",
    "general": "No thinking, lower temperature 0.7, top_p 0.8, top_k 20, presence penalty 1.5.",
    "coding": "Coding-tuned sampling: no thinking, temperature 0.6, top_p 0.95, no presence penalty.",
    "coding_fast": "Faster/looser coding preset: no thinking, temperature 0.8, top_p 0.95, no presence penalty.",
    "thinking": "Enables Qwen thinking with temperature 1.0, top_p 0.95, presence penalty 1.5.",
    "preserve-thinking": "Enables thinking and preserves thinking output with same as above parameters.",
}
LENGTH_PREFIXES = {"short-": 4096, "concise-": 512}
HOP_HEADERS = {"connection","keep-alive","proxy-authenticate","proxy-authorization","te","trailers","transfer-encoding","upgrade","content-length","host"}

switch_lock = threading.Lock()
metrics_lock = threading.Lock()
auth_cache = {}
AUTH_CACHE_SECONDS = 120
ADMIN_SESSION_COOKIE_NAME = "club3090_admin_session"
ADMIN_SESSION_TTL_SECONDS = int(os.environ.get("CLUB3090_ADMIN_SESSION_TTL_SECONDS", "86400"))
ADMIN_AUTH_DENIAL_LOG_WINDOW_SECONDS = int(os.environ.get("CLUB3090_ADMIN_AUTH_DENIAL_LOG_WINDOW_SECONDS", "30"))
startup_time = time.time()
recent_requests = collections.deque(maxlen=120)
series_points = collections.deque(maxlen=240)
request_queue = collections.deque(maxlen=50)
metrics = {"total_requests":0,"active_requests":0,"completed_requests":0,"failed_requests":0,"streaming_requests":0,"queued_requests":0,"cold_starts":0,"failovers":0,"last_latency_s":None,"last_ttft_s":None,"last_tokens_per_second":None,"last_estimated_tokens":None,"last_preset":None,"last_path":None,"last_status":None}
LOG_BOOTSTRAP_MARKER = os.environ.get("CLUB3090_LOG_BOOTSTRAP_MARKER", "Application startup complete")
LOG_TAIL_MAX_BYTES = int(os.environ.get("CLUB3090_LOG_TAIL_MAX_BYTES", "102400"))
runtime_log_watchers = {}
runtime_log_watchers_lock = threading.Lock()
latest_gpu_rows = []
latest_system_snapshot = {"memory": {}, "cpu": {"cores": []}, "disks": [], "network": {}, "info": {}}
latest_metrics_collected_at = 0.0
gpu_session_peaks = {}
disk_stats_cache = {"value": [], "time": 0.0}
system_info_cache = {"value": {}, "time": 0.0}
status_snapshot_cache = {}
status_snapshot_updated_at = 0.0
status_snapshot_lock = threading.Lock()
slow_cache_lock = threading.Lock()
docker_names_cache = {
    "running": {"value": [], "time": 0.0},
    "all": {"value": [], "time": 0.0},
}
service_status_cache = {}
gpu_count_cache = {"value": 0, "time": 0.0}
compose_metadata_cache = {}
runtime_log_metrics_cache = {}
runtime_log_metric_memory = {}
target_request_metrics = {}
runtime_inventory_lock = threading.Lock()
runtime_inventory_cache = {}
runtime_inventory_built_at = 0.0
model_install_job_lock = threading.Lock()
admin_session_lock = threading.Lock()
admin_sessions = {}
admin_auth_denial_lock = threading.Lock()
admin_auth_denial_state = {}
audit_rate_limit_lock = threading.Lock()
audit_rate_limit_state = {}
AUDIT_RATE_LIMIT_WINDOWS = {
    "admin_auth_denied": 5,
    "local_api_denied": 5,
    "proxy_auth_denied": 5,
}
model_install_job = {
    "active": False,
    "status": "idle",
    "model_id": "",
    "variant_id": "",
    "command": "",
    "started_at": 0,
    "finished_at": 0,
    "return_code": None,
    "summary": "",
    "inventory_rebuild_ok": None,
}
admin_task_job_lock = threading.Lock()
admin_task_job = {
    "active": False,
    "status": "idle",
    "task": "",
    "label": "",
    "command": "",
    "started_at": 0,
    "finished_at": 0,
    "return_code": None,
    "summary": "",
    "mode": "",
    "container": "",
    "url": "",
}
switch_job_lock = threading.Lock()
switch_job = {
    "active": False,
    "status": "idle",
    "mode": "",
    "target": "",
    "started_at": 0,
    "finished_at": 0,
    "error": "",
}

POWER_IDLE_AFTER_SECONDS = int(os.environ.get("CLUB3090_POWER_IDLE_AFTER_SECONDS", "600"))
CONTAINER_STOP_AFTER_SECONDS = int(os.environ.get("CLUB3090_CONTAINER_STOP_AFTER_SECONDS", "3600"))
CONTAINER_AUTO_STOP_ENABLED = False
GPU_ACTIVE_POWER_LIMIT_W = int(os.environ.get("CLUB3090_GPU_ACTIVE_POWER_LIMIT_W", "280"))
GPU_IDLE_POWER_LIMIT_W = int(os.environ.get("CLUB3090_GPU_IDLE_POWER_LIMIT_W", "120"))
GPU_IDLE_LOCK_CLOCKS = os.environ.get("CLUB3090_GPU_IDLE_LOCK_CLOCKS", "210,900")
GPU_ACTIVE_LOCK_CLOCKS = os.environ.get("CLUB3090_GPU_ACTIVE_LOCK_CLOCKS", "")
CPU_ACTIVE_GOVERNOR = os.environ.get("CLUB3090_CPU_ACTIVE_GOVERNOR", "performance")
CPU_IDLE_GOVERNOR = os.environ.get("CLUB3090_CPU_IDLE_GOVERNOR", "powersave")
FAN_CURVE = [(30, 35), (35, 40), (40, 45), (45, 55), (50, 65), (55, 75), (60, 85), (65, 95)]
FAN_MAX_SPEED = int(os.environ.get("CLUB3090_FAN_MAX_SPEED", "100"))
FAN_MIN_SAFE_SPEED = int(os.environ.get("CLUB3090_FAN_MIN_SAFE_SPEED", "35"))
WOL_MAC = os.environ.get("CLUB3090_WOL_MAC", "")
WOL_BROADCAST = os.environ.get("CLUB3090_WOL_BROADCAST", "255.255.255.255")
PERFORMANCE_PROFILES = {
    "eco": {"gpu_active": 240, "gpu_idle": 90, "idle_clocks": "210,705", "cpu_active": "schedutil", "cpu_idle": "powersave", "idle_after": 300, "stop_after": 1800},
    "balanced": {"gpu_active": GPU_ACTIVE_POWER_LIMIT_W, "gpu_idle": GPU_IDLE_POWER_LIMIT_W, "idle_clocks": GPU_IDLE_LOCK_CLOCKS, "cpu_active": CPU_ACTIVE_GOVERNOR, "cpu_idle": CPU_IDLE_GOVERNOR, "idle_after": POWER_IDLE_AFTER_SECONDS, "stop_after": CONTAINER_STOP_AFTER_SECONDS},
    "default": {"gpu_active": 280, "gpu_idle": 120, "idle_clocks": "", "cpu_active": "schedutil", "cpu_idle": "powersave", "idle_after": 900, "stop_after": 3600},
    "turbo": {"gpu_active": 350, "gpu_idle": 160, "idle_clocks": "", "cpu_active": "performance", "cpu_idle": "schedutil", "idle_after": 1800, "stop_after": 7200},
}
current_profile = "balanced"
last_inference_time = time.time()
last_request_finished_at = time.time()
power_optimizations_enabled = True
fan_manual_override = False
fan_curve_pause_until = 0.0
power_state = {"gpu":"unknown", "cpu":"unknown", "container":"running", "fans":"auto", "power_optimizations":"enabled", "last_action":"startup", "last_error":""}
cooling_scope_instance_id = "GLOBAL"
fan_curve_resume_token = 0

def log_control(message):
    os.makedirs(CONTROL_DIR, exist_ok=True)
    line = time.strftime("%Y-%m-%d %H:%M:%S") + " " + str(message).rstrip() + "\n"
    try:
        with open(CONTROL_LOG_FILE, "a", encoding="utf-8") as f:
            f.write(line)
    except Exception:
        pass


def audit_event_category(event_type):
    name = str(event_type or "").strip().lower()
    if name.startswith("proxy_"):
        return "proxy"
    if name.startswith("admin_ui_"):
        return "ui"
    if name.startswith("admin_"):
        return "admin"
    if name.startswith("local_api_"):
        return "automation"
    if name.startswith("user_") or name.startswith("group_"):
        return "access"
    if name.startswith("model_install_") or name.startswith("instance_"):
        return "runtime"
    return "system"


def _audit_rate_limit_key(event_type, fields):
    parts = [str(event_type or "")]
    for key in ("reason", "user", "client", "path", "instance", "action"):
        value = fields.get(key)
        if value not in (None, ""):
            parts.append(f"{key}={value}")
    return "|".join(parts)


def should_emit_audit_event(event_type, fields):
    window = int(AUDIT_RATE_LIMIT_WINDOWS.get(str(event_type or ""), 0) or 0)
    if window <= 0:
        return True
    now = time.time()
    key = _audit_rate_limit_key(event_type, fields)
    with audit_rate_limit_lock:
        last = float(audit_rate_limit_state.get(key, 0.0) or 0.0)
        if last and (now - last) < window:
            return False
        audit_rate_limit_state[key] = now
        stale_before = now - max(window * 2, 30)
        for stale_key, stale_ts in list(audit_rate_limit_state.items()):
            if stale_ts < stale_before:
                audit_rate_limit_state.pop(stale_key, None)
    return True


def log_audit(event_type, **fields):
    os.makedirs(CONTROL_DIR, exist_ok=True)
    if not should_emit_audit_event(event_type, fields):
        return
    entry = {
        "ts": int(time.time()),
        "event": str(event_type),
        "category": audit_event_category(event_type),
    }
    for key, value in fields.items():
        try:
            json.dumps(value)
            entry[key] = value
        except Exception:
            entry[key] = str(value)
    try:
        with open(AUDIT_LOG_FILE, "a", encoding="utf-8") as f:
            f.write(json.dumps(entry, sort_keys=True) + "\n")
    except Exception:
        pass


def script_user_agent():
    version = str(SCRIPT_VERSION or "").strip() or "unknown"
    return f"club3090-control/{version}"


def append_audit_text_line(text):
    os.makedirs(CONTROL_DIR, exist_ok=True)
    line = str(text or "").rstrip("\n") + "\n"
    try:
        with open(AUDIT_LOG_FILE, "a", encoding="utf-8") as f:
            f.write(line)
    except Exception:
        pass


def read_switch_failure():
    data = read_json_file(SWITCH_FAILURE_FILE, {})
    return data if isinstance(data, dict) else {}


def write_switch_failure(mode, error_text):
    payload = {
        "mode": canonical_mode_selector(mode),
        "error": str(error_text or "")[-12000:],
        "ts": int(time.time()),
    }
    write_json_file(SWITCH_FAILURE_FILE, payload)
    return payload


def clear_switch_failure(mode=""):
    existing = read_switch_failure()
    if not existing:
        return
    target_mode = canonical_mode_selector(mode) if mode else ""
    if target_mode and str(existing.get("mode") or "") != target_mode:
        return
    try:
        os.remove(SWITCH_FAILURE_FILE)
    except FileNotFoundError:
        pass
    except Exception:
        pass


def write_json_atomic_if_changed(path, data, *, indent=None, sort_keys=False, separators=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    rendered = json.dumps(
        data,
        indent=indent,
        sort_keys=sort_keys,
        separators=separators,
        ensure_ascii=False,
    )
    if indent is not None:
        rendered += "\n"
    try:
        with open(path, "r", encoding="utf-8") as f:
            existing = f.read()
        if existing == rendered:
            return False
    except Exception:
        pass
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write(rendered)
    os.replace(tmp, path)
    return True


def model_install_job_snapshot():
    with model_install_job_lock:
        return dict(model_install_job)


def _set_model_install_job(**updates):
    with model_install_job_lock:
        model_install_job.update(updates)
        return dict(model_install_job)


def admin_task_job_snapshot():
    with admin_task_job_lock:
        return dict(admin_task_job)


def _set_admin_task_job(**updates):
    with admin_task_job_lock:
        admin_task_job.update(updates)
        return dict(admin_task_job)


def switch_job_snapshot():
    with switch_job_lock:
        return dict(switch_job)


def _set_switch_job(**updates):
    with switch_job_lock:
        switch_job.update(updates)
        return dict(switch_job)


def switch_job_active():
    with switch_job_lock:
        return bool(switch_job.get("active"))


def _run_model_install_job(model_id, variant_id, install_command):
    prefix = f"[model-install {model_id}]"
    append_audit_text_line(f"{prefix} starting {install_command}")
    _set_model_install_job(
        active=True,
        status="running",
        model_id=model_id,
        variant_id=variant_id,
        command=install_command,
        started_at=int(time.time()),
        finished_at=0,
        return_code=None,
        summary="Running model install job",
        inventory_rebuild_ok=None,
    )
    rc = 999
    rebuild_ok = False
    try:
        process = subprocess.Popen(
            ["bash", "-lc", install_command],
            cwd=CLUB3090_DIR,
            env=_repo_subprocess_env(),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        try:
            if process.stdout is not None:
                for raw_line in process.stdout:
                    append_audit_text_line(f"{prefix} {str(raw_line or '').rstrip()}")
        finally:
            rc = int(process.wait())
    except Exception as e:
        append_audit_text_line(f"{prefix} launcher error: {e}")
        rc = 999
    if rc == 0:
        try:
            rebuild_runtime_inventory()
            rebuild_ok = True
            append_audit_text_line(f"{prefix} inventory rebuild succeeded")
        except Exception as e:
            rebuild_ok = False
            append_audit_text_line(f"{prefix} inventory rebuild failed: {e}")
    else:
        append_audit_text_line(f"{prefix} command failed with return code {rc}")
    summary = f"Model install {'completed' if rc == 0 else 'failed'} (rc={rc})"
    _set_model_install_job(
        active=False,
        status=("success" if rc == 0 else "failed"),
        finished_at=int(time.time()),
        return_code=rc,
        summary=summary,
        inventory_rebuild_ok=rebuild_ok if rc == 0 else False,
    )
    log_audit(
        "model_install_job_finished",
        model_id=model_id,
        variant_id=variant_id,
        return_code=rc,
        inventory_rebuild_ok=rebuild_ok if rc == 0 else False,
    )
    append_audit_text_line(f"{prefix} {summary}")


def start_model_install_job(model_id, variant_id, install_command):
    inventory = load_runtime_inventory()
    variant = next((row for row in inventory.get("variants") or [] if str(row.get("variant_id") or "") == str(variant_id or "")), None)
    if not variant:
        raise ValueError("Unknown variant")
    if str(variant.get("model_id") or "") != str(model_id or ""):
        raise ValueError("Variant/model mismatch")
    expected_command = str(variant.get("install_command") or "").strip()
    requested_command = str(install_command or "").strip()
    if not expected_command:
        raise ValueError("This preset does not have a supported install command")
    if expected_command != requested_command:
        raise ValueError("Install command validation failed")
    with admin_task_job_lock:
        if admin_task_job.get("active"):
            raise RuntimeError("Wait for the current admin task to finish before starting a model install")
    with model_install_job_lock:
        if model_install_job.get("active"):
            raise RuntimeError("A model install job is already running")
        model_install_job.update(
            {
                "active": True,
                "status": "queued",
                "model_id": model_id,
                "variant_id": variant_id,
                "command": expected_command,
                "started_at": int(time.time()),
                "finished_at": 0,
                "return_code": None,
                "summary": "Queued model install job",
                "inventory_rebuild_ok": None,
            }
        )
    threading.Thread(
        target=_run_model_install_job,
        args=(str(model_id), str(variant_id), expected_command),
        name=f"club3090-model-install-{_selector_token(model_id)}",
        daemon=True,
    ).start()
    log_audit("model_install_job_started", model_id=model_id, variant_id=variant_id)
    return model_install_job_snapshot()


def _active_runtime_task_context():
    mode = active_mode()
    spec = resolve_variant_spec(mode) or {}
    port = int(active_port() or 0)
    return {
        "mode": mode,
        "spec": spec,
        "port": port,
        "url": (f"http://localhost:{port}" if port > 0 else ""),
        "container": current_container(),
        "engine": str(spec.get("engine") or "").strip(),
        "served_model_name": str(spec.get("served_model_name") or "").strip(),
    }


def _build_admin_task_command(task_name):
    task = _selector_token(task_name)
    if task not in {"benchmark", "report"}:
        raise ValueError("Unsupported admin task")
    runtime = _active_runtime_task_context()
    if task == "benchmark":
        if runtime["port"] <= 0 or not port_open(runtime["port"], timeout=0.25):
            raise RuntimeError("Benchmark requires a running backend. Start a preset first.")
        parts = [f"URL={shlex.quote(runtime['url'])}", "PREFLIGHT_NO_AUTODETECT=1"]
        if runtime["container"]:
            parts.append(f"CONTAINER={shlex.quote(runtime['container'])}")
        if runtime["served_model_name"]:
            parts.append(f"MODEL={shlex.quote(runtime['served_model_name'])}")
        parts.append("bash scripts/bench.sh")
        return {
            "task": "benchmark",
            "label": "Benchmark",
            "command": " ".join(parts),
            "mode": runtime["mode"],
            "container": runtime["container"],
            "url": runtime["url"],
        }
    parts = []
    if runtime["container"]:
        parts.append(f"CONTAINER={shlex.quote(runtime['container'])}")
    if runtime["engine"] in {"vllm", "llamacpp"}:
        parts.append(f"ENGINE_KIND={shlex.quote(runtime['engine'])}")
    parts.append("bash scripts/report.sh")
    return {
        "task": "report",
        "label": "Run Report",
        "command": " ".join(parts),
        "mode": runtime["mode"],
        "container": runtime["container"],
        "url": runtime["url"],
    }


def _run_admin_task_job(task_info):
    task = dict(task_info or {})
    task_name = str(task.get("task") or "task").strip() or "task"
    label = str(task.get("label") or task_name).strip() or task_name
    command = str(task.get("command") or "").strip()
    prefix = f"[admin-task {task_name}]"
    append_audit_text_line(f"{prefix} starting {command}")
    _set_admin_task_job(
        active=True,
        status="running",
        task=task_name,
        label=label,
        command=command,
        started_at=int(time.time()),
        finished_at=0,
        return_code=None,
        summary=f"{label} running",
        mode=str(task.get("mode") or ""),
        container=str(task.get("container") or ""),
        url=str(task.get("url") or ""),
    )
    rc = 999
    try:
        process = subprocess.Popen(
            ["bash", "-lc", command],
            cwd=CLUB3090_DIR,
            env=_repo_subprocess_env(),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        try:
            if process.stdout is not None:
                for raw_line in process.stdout:
                    append_audit_text_line(f"{prefix} {str(raw_line or '').rstrip()}")
        finally:
            rc = int(process.wait())
    except Exception as e:
        append_audit_text_line(f"{prefix} launcher error: {e}")
        rc = 999
    if rc != 0:
        append_audit_text_line(f"{prefix} command failed with return code {rc}")
    summary = f"{label} {'completed' if rc == 0 else 'failed'} (rc={rc})"
    _set_admin_task_job(
        active=False,
        status=("success" if rc == 0 else "failed"),
        finished_at=int(time.time()),
        return_code=rc,
        summary=summary,
    )
    log_audit(
        "admin_task_job_finished",
        task=task_name,
        label=label,
        mode=str(task.get("mode") or ""),
        container=str(task.get("container") or ""),
        url=str(task.get("url") or ""),
        return_code=rc,
    )
    append_audit_text_line(f"{prefix} {summary}")


def start_admin_task_job(task_name):
    task_info = _build_admin_task_command(task_name)
    with admin_task_job_lock:
        if admin_task_job.get("active"):
            raise RuntimeError("Another admin task is already running")
    with model_install_job_lock:
        if model_install_job.get("active"):
            raise RuntimeError("Wait for the current model install job to finish before starting this task")
    _set_admin_task_job(
        active=True,
        status="queued",
        task=str(task_info.get("task") or ""),
        label=str(task_info.get("label") or ""),
        command=str(task_info.get("command") or ""),
        started_at=int(time.time()),
        finished_at=0,
        return_code=None,
        summary=f"{str(task_info.get('label') or task_name)} queued",
        mode=str(task_info.get("mode") or ""),
        container=str(task_info.get("container") or ""),
        url=str(task_info.get("url") or ""),
    )
    threading.Thread(
        target=_run_admin_task_job,
        args=(task_info,),
        name=f"club3090-admin-task-{_selector_token(task_name)}",
        daemon=True,
    ).start()
    log_audit(
        "admin_task_job_started",
        task=str(task_info.get("task") or ""),
        label=str(task_info.get("label") or ""),
        mode=str(task_info.get("mode") or ""),
        container=str(task_info.get("container") or ""),
        url=str(task_info.get("url") or ""),
    )
    return admin_task_job_snapshot()


def start_self_update_job(scope):
    scope_name = _selector_token(scope)
    if scope_name not in {"controller", "club3090"}:
        raise ValueError("Invalid update scope")
    with admin_task_job_lock:
        if admin_task_job.get("active"):
            raise RuntimeError("Wait for the current admin task to finish before starting an update")
    with model_install_job_lock:
        if model_install_job.get("active"):
            raise RuntimeError("Wait for the current model install job to finish before starting an update")
    mode_flag = "--update" if scope_name == "controller" else "--migrate"
    label = "admin script update" if scope_name == "controller" else "club-3090 migration"
    command = f"set -o pipefail; curl -fsSL https://tinyurl.com/club-3090-webserver | bash -s -- {mode_flag}"
    prefix = f"[self-update {scope_name}]"
    append_audit_text_line(f"{prefix} queued {label}")
    append_audit_text_line(f"{prefix} command: {command}")
    log_audit("self_update_job_started", scope=scope_name, command=command)
    audit_log_path = shlex.quote(AUDIT_LOG_FILE)
    launcher = (
        f'printf "%s\\n" "{prefix} starting {label}" >> {audit_log_path}; '
        "sleep 1; "
        f'bash -lc {shlex.quote(command)} >> {audit_log_path} 2>&1; '
        'rc=$?; '
        f'printf "%s\\n" "{prefix} finished (rc=${{rc}})" >> {audit_log_path}; '
        f'printf "%s\\n" "{prefix} update flow complete" >> {audit_log_path}'
    )
    subprocess.Popen(
        ["bash", "-lc", launcher],
        cwd=CLUB3090_DIR,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    return {
        "ok": True,
        "scope": scope_name,
        "label": label,
        "command": command,
        "focus_log_source": "audit",
    }


def default_target_request_metrics():
    return {
        "last_status": None,
        "last_latency_s": None,
        "last_ttft_s": None,
        "last_tokens_per_second": None,
        "last_estimated_tokens": None,
        "last_input_tokens": None,
        "last_output_tokens": None,
        "last_total_tokens": None,
        "last_tool_calls": None,
        "last_preset": None,
        "last_path": None,
        "last_request_at": 0,
    }


def snapshot_target_request_metrics():
    with metrics_lock:
        return {key: dict(value) for key, value in target_request_metrics.items()}

def read_ui_config():
    default = {
        "show_global_logs": True,
        "active_tab": "overview",
        "selected_scope": "GPU0",
        "current_log_source": "docker",
    }
    try:
        with open(UI_CONFIG_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
        if not isinstance(data, dict):
            return default
        merged = dict(default)
        if "show_global_logs" in data:
            merged["show_global_logs"] = bool(data.get("show_global_logs"))
        if str(data.get("active_tab") or "") in {"overview", "system", "presets", "users", "metrics", "logs", "audit", "chat"}:
            merged["active_tab"] = str(data.get("active_tab"))
        if str(data.get("current_log_source") or "") in {"docker", "audit"}:
            merged["current_log_source"] = str(data.get("current_log_source"))
        if data.get("selected_scope") not in (None, ""):
            merged["selected_scope"] = str(data.get("selected_scope"))
        return merged
    except Exception:
        return default

def write_ui_config(data):
    current = read_ui_config()
    original = dict(current)
    if "show_global_logs" in data:
        current["show_global_logs"] = bool(data["show_global_logs"])
    if str(data.get("active_tab") or "") in {"overview", "system", "presets", "users", "metrics", "logs", "audit", "chat"}:
        current["active_tab"] = str(data.get("active_tab"))
    if str(data.get("current_log_source") or "") in {"docker", "audit"}:
        current["current_log_source"] = str(data.get("current_log_source"))
    if data.get("selected_scope") not in (None, ""):
        current["selected_scope"] = str(data.get("selected_scope"))
    if current == original:
        return current, False
    write_json_atomic_if_changed(UI_CONFIG_FILE, current, separators=(",", ":"))
    return current, True


def read_json_file(path, default):
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, type(default)) else default
    except Exception:
        return default


def write_json_file(path, data):
    write_json_atomic_if_changed(path, data, indent=2, sort_keys=True)


def default_chat_state():
    return {
        "activeConversationId": "",
        "conversations": [],
        "promptTemplates": [],
    }


def _chat_attachment_kind(value):
    return "image" if str(value or "").strip().lower() == "image" else "text"


def sanitize_chat_attachment(item):
    item = item if isinstance(item, dict) else {}
    kind = _chat_attachment_kind(item.get("kind"))
    row = {
        "id": str(item.get("id") or "").strip(),
        "kind": kind,
        "name": str(item.get("name") or "").strip() or ("image" if kind == "image" else "attachment"),
        "mime": str(item.get("mime") or "").strip(),
        "source": str(item.get("source") or "").strip(),
    }
    if kind == "image":
        row["url"] = str(item.get("url") or "").strip()
    else:
        row["text"] = str(item.get("text") or "")
    size_bytes = item.get("size_bytes")
    try:
        if size_bytes not in (None, ""):
            row["size_bytes"] = max(0, int(size_bytes))
    except Exception:
        pass
    return row


def sanitize_chat_message(item):
    item = item if isinstance(item, dict) else {}
    row = {
        "role": str(item.get("role") or "").strip().lower() or "user",
        "text": str(item.get("text") or ""),
        "attachments": [sanitize_chat_attachment(attachment) for attachment in (item.get("attachments") or []) if isinstance(attachment, dict)],
    }
    for key in (
        "reasoningText",
        "reasoning_content",
        "reasoning",
        "modelLabel",
        "thinkingExpanded",
        "thinkingDone",
        "thinkingLive",
        "thinkingStartedAt",
        "thinkingDurationMs",
    ):
        value = item.get(key)
        if value not in (None, ""):
            row[key] = value
    return row


def sanitize_chat_conversation(item):
    item = item if isinstance(item, dict) else {}
    try:
        threshold_pct = int(item.get("autoCompactThresholdPct") or 95)
    except Exception:
        threshold_pct = 95
    try:
        compaction_sequence = max(1, int(item.get("compactionSequence") or 1))
    except Exception:
        compaction_sequence = 1
    row = {
        "id": str(item.get("id") or "").strip(),
        "title": str(item.get("title") or "").strip() or "Untitled conversation",
        "folder": str(item.get("folder") or "").strip(),
        "summary": str(item.get("summary") or ""),
        "autoNamed": bool(item.get("autoNamed")),
        "createdAt": int(item.get("createdAt") or int(time.time() * 1000)),
        "updatedAt": int(item.get("updatedAt") or int(time.time() * 1000)),
        "lastUsedAt": int(item.get("lastUsedAt") or int(time.time() * 1000)),
        "statsCollapsed": bool(item.get("statsCollapsed")),
        "presetId": str(item.get("presetId") or ""),
        "apiPresetName": str(item.get("apiPresetName") or ""),
        "params": dict(item.get("params") or {}) if isinstance(item.get("params"), dict) else {},
        "systemPrompt": str(item.get("systemPrompt") or ""),
        "autoCompactEnabled": item.get("autoCompactEnabled") is not False,
        "autoCompactThresholdPct": threshold_pct,
        "messages": [sanitize_chat_message(message) for message in (item.get("messages") or []) if isinstance(message, dict)],
        "attachments": [sanitize_chat_attachment(attachment) for attachment in (item.get("attachments") or []) if isinstance(attachment, dict)],
        "draftText": str(item.get("draftText") or ""),
        "compactedFromId": str(item.get("compactedFromId") or ""),
        "compactionSequence": compaction_sequence,
    }
    for key in (
        "lastInputTokens",
        "lastOutputTokens",
        "lastTotalTokens",
        "lastCtxSizeTokens",
        "lastKvCacheUsagePct",
        "lastRuntimeRequestAt",
    ):
        value = item.get(key)
        if value not in (None, ""):
            row[key] = value
    return row


def sanitize_chat_state_payload(payload):
    payload = payload if isinstance(payload, dict) else {}
    conversations = [
        sanitize_chat_conversation(conversation)
        for conversation in (payload.get("conversations") or [])
        if isinstance(conversation, dict)
    ]
    prompt_templates = []
    for item in payload.get("promptTemplates") or []:
        if not isinstance(item, dict):
            continue
        name = str(item.get("name") or "").strip()
        text = str(item.get("text") or "")
        if not name and not text:
            continue
        prompt_templates.append(
            {
                "id": str(item.get("id") or secrets.token_hex(6)),
                "name": name,
                "text": text,
            }
        )
    active_id = str(payload.get("activeConversationId") or "").strip()
    if not active_id and conversations:
        active_id = str(conversations[0].get("id") or "")
    return {
        "activeConversationId": active_id,
        "conversations": conversations,
        "promptTemplates": prompt_templates,
    }


def read_chat_state():
    data = read_json_file(CHAT_STATE_FILE, default_chat_state())
    return sanitize_chat_state_payload(data)


def write_chat_state(payload):
    state = sanitize_chat_state_payload(payload)
    write_json_file(CHAT_STATE_FILE, state)
    return state


def _chat_attachment_blob_path(attachment_id):
    return os.path.join(CHAT_ATTACHMENTS_DIR, f"{attachment_id}.bin")


def _chat_attachment_meta_path(attachment_id):
    return os.path.join(CHAT_ATTACHMENTS_DIR, f"{attachment_id}.json")


def chat_attachment_url(attachment_id):
    return f"/admin/chat-attachments/{attachment_id}"


def read_chat_attachment_meta(attachment_id):
    return read_json_file(_chat_attachment_meta_path(attachment_id), {})


def save_chat_attachment(item):
    item = item if isinstance(item, dict) else {}
    kind = _chat_attachment_kind(item.get("kind"))
    if kind != "image":
        raise ValueError("Only image attachments are uploaded separately.")
    data_url = str(item.get("data_url") or "").strip()
    if not data_url.startswith("data:") or ";base64," not in data_url:
        raise ValueError("Image attachment must include a base64 data URL.")
    header, encoded = data_url.split(",", 1)
    mime = str(item.get("mime") or "").strip()
    if not mime:
        mime = str(header[5:].split(";", 1)[0] or "").strip()
    if not mime.startswith("image/"):
        raise ValueError("Only image attachments are supported.")
    try:
        raw = base64.b64decode(encoded, validate=True)
    except Exception as exc:
        raise ValueError("Invalid image attachment encoding.") from exc
    attachment_id = str(item.get("id") or f"chat-attachment-{secrets.token_hex(8)}").strip()
    if not attachment_id:
        raise ValueError("Attachment id is required.")
    os.makedirs(CHAT_ATTACHMENTS_DIR, exist_ok=True)
    with open(_chat_attachment_blob_path(attachment_id), "wb") as handle:
        handle.write(raw)
    meta = {
        "id": attachment_id,
        "kind": "image",
        "name": str(item.get("name") or "image").strip() or "image",
        "mime": mime,
        "source": str(item.get("source") or "").strip(),
        "size_bytes": len(raw),
        "created_at": int(time.time()),
        "url": chat_attachment_url(attachment_id),
    }
    write_json_file(_chat_attachment_meta_path(attachment_id), meta)
    return meta


def read_chat_attachment_response(attachment_id):
    meta = read_chat_attachment_meta(attachment_id)
    if not isinstance(meta, dict) or not meta.get("id"):
        return None, None
    blob_path = _chat_attachment_blob_path(attachment_id)
    try:
        with open(blob_path, "rb") as handle:
            payload = handle.read()
    except Exception:
        return None, None
    mime = str(meta.get("mime") or "").strip() or "application/octet-stream"
    return payload, mime


def local_chat_attachment_id_from_url(url):
    raw = str(url or "").strip()
    if not raw:
        return ""
    try:
        path = urlsplit(raw).path
    except Exception:
        path = raw
    prefix = "/admin/chat-attachments/"
    if not path.startswith(prefix):
        return ""
    attachment_id = path[len(prefix):].strip().split("/", 1)[0]
    return re.sub(r"[^A-Za-z0-9._-]+", "", attachment_id)


def chat_attachment_data_url(url):
    attachment_id = local_chat_attachment_id_from_url(url)
    if not attachment_id:
        return str(url or "").strip()
    payload, mime = read_chat_attachment_response(attachment_id)
    if payload is None:
        return str(url or "").strip()
    return f"data:{mime};base64,{base64.b64encode(payload).decode('ascii')}"
    return data


def _format_model_display_name(model_id):
    if not model_id:
        return "Unknown Model"
    if model_id == "qwen3.6-27b":
        return "Qwen3.6-27B"
    if model_id == "gemma-4-31b":
        return "Gemma 4 31B"
    return str(model_id).replace("-", " ")


def _selector_token(text):
    token = re.sub(r"[^a-zA-Z0-9]+", "-", str(text or "").strip().lower()).strip("-")
    return token or "variant"


def _variant_id_from_rel_path(rel_path):
    rel = str(rel_path or "").replace("\\", "/").strip("/")
    if not rel:
        return "variant-unknown"
    stem = rel[:-4] if rel.endswith(".yml") else rel
    return "variant-" + _selector_token(stem)


def _mode_selector_for_variant(variant):
    if not isinstance(variant, dict):
        return ""
    return str(variant.get("upstream_tag") or variant.get("variant_id") or "").strip()


def _variant_rel_compose_path(variant):
    return str((variant or {}).get("compose_rel_path") or "").replace("\\", "/").strip("/")


def _normalize_engine(engine):
    raw = str(engine or "").strip().lower().replace("_", "-")
    if raw == "llama-cpp":
        return "llamacpp"
    return raw


def _load_repo_env_map():
    env_path = os.path.join(CLUB3090_DIR, ".env")
    result = {}
    try:
        with open(env_path, "r", encoding="utf-8", errors="replace") as f:
            for raw_line in f:
                line = str(raw_line or "").strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                key = str(key or "").strip()
                if not key:
                    continue
                value = str(value or "").strip().strip("'").strip('"')
                result[key] = value
    except Exception:
        return {}
    return result


def _repo_subprocess_env():
    env = os.environ.copy()
    for key, value in _load_repo_env_map().items():
        if key:
            env[str(key)] = str(value)
    return env


def _resolve_variant_model_dir_root(variant=None):
    env_map = _load_repo_env_map()
    raw = str(env_map.get("MODEL_DIR") or "").strip()
    if not raw:
        return os.path.join(CLUB3090_DIR, "models-cache")
    if os.path.isabs(raw):
        return raw
    compose_root = str((variant or {}).get("compose_project_dir_abs_path") or "").strip()
    if compose_root:
        candidate = os.path.normpath(os.path.join(compose_root, raw))
        if os.path.exists(candidate):
            return candidate
    return os.path.normpath(os.path.join(CLUB3090_DIR, raw))


def _dir_has_filetype(path, suffixes):
    try:
        if not os.path.isdir(path):
            return False
        for root, _dirs, files in os.walk(path):
            for name in files:
                lower = str(name or "").lower()
                if any(lower.endswith(sfx) for sfx in suffixes):
                    return True
    except Exception:
        return False
    return False


def _extract_default_number(raw, minimum_digits=2):
    text = str(raw or "")
    match = re.search(r"\$\{[^}:]+:-([0-9]{%d,})\}" % int(minimum_digits), text)
    if match:
        return int(match.group(1))
    match = re.search(r"([0-9]{%d,})" % int(minimum_digits), text)
    if match:
        return int(match.group(1))
    return None


def _extract_shell_default_value(raw):
    text = str(raw or "").strip().strip('"').strip("'")
    match = re.match(r"^\$\{[^}:]+:-([^}]+)\}$", text)
    if match:
        return match.group(1).strip()
    return text


def _extract_token_count(raw):
    text = str(raw or "").strip()
    if not text:
        return None
    match = re.search(r"([0-9]+(?:\.[0-9]+)?)\s*([KMB])?\b", text, re.IGNORECASE)
    if not match:
        return None
    value = float(match.group(1))
    suffix = str(match.group(2) or "").upper()
    scale = {"": 1, "K": 1000, "M": 1000 * 1000, "B": 1000 * 1000 * 1000}.get(suffix, 1)
    try:
        return int(value * scale)
    except Exception:
        return None


def _normalize_status_kind(status_raw):
    text = str(status_raw or "").strip().lower()
    if not text:
        return "unknown"
    if "deprecated" in text:
        return "deprecated"
    if "upstream" in text and ("blocked" in text or "gated" in text):
        return "upstream_gated"
    if "preview" in text:
        return "preview"
    if "experimental" in text or "community" in text:
        return "experimental"
    if "caveat" in text or "known issue" in text or "warning" in text:
        return "production_caveat"
    if "production" in text or "prod" in text:
        return "production"
    return "unknown"


def _category_for_variant(topology, status_kind):
    topology_text = str(topology or "").strip().lower()
    if status_kind in {"experimental", "preview", "upstream_gated", "deprecated"}:
        return "experimental"
    if topology_text.startswith("single"):
        return "single"
    if topology_text.startswith("dual"):
        return "dual"
    if topology_text.startswith("multi"):
        return "multi"
    return "experimental"


def _scope_kind_for_topology(topology):
    topology_text = str(topology or "").strip().lower()
    if topology_text.startswith("single"):
        return "single"
    if topology_text.startswith("dual"):
        return "dual"
    if topology_text.startswith("multi"):
        return "multi"
    return "global_only"


def _read_compose_profile_header(path):
    profile = {}
    current_key = None
    in_profile = False
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for raw_line in f:
                line = str(raw_line or "").rstrip("\n")
                stripped = line.lstrip()
                if not stripped.startswith("#"):
                    if in_profile and profile:
                        break
                    continue
                comment = stripped[1:]
                if "Profile (at-a-glance)" in comment:
                    in_profile = True
                    current_key = None
                    continue
                if not in_profile:
                    continue
                if profile and re.match(r"^\s*-{8,}\s*$", comment):
                    break
                match = re.match(r"^\s*([A-Za-z][A-Za-z0-9 /-]*):\s*(.*)$", comment)
                if match:
                    current_key = re.sub(r"[^a-z0-9]+", "_", match.group(1).strip().lower()).strip("_")
                    profile[current_key] = match.group(2).strip()
                    continue
                if current_key and re.match(r"^\s{10,}\S", comment):
                    extra = comment.strip()
                    if extra:
                        profile[current_key] = (profile.get(current_key, "") + " " + extra).strip()
                    continue
                if profile:
                    break
    except Exception:
        return {}
    return profile


def _read_compose_status_hints(path, max_lines=160):
    hints = []
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for idx, raw_line in enumerate(f):
                if idx >= int(max_lines):
                    break
                line = str(raw_line or "").strip()
                if not line.startswith("#"):
                    continue
                match = re.match(r"^#\s*Status:\s*(.+)$", line)
                if match:
                    hints.append(match.group(1).strip())
    except Exception:
        return ""
    return hints[0].strip() if hints else ""


def _read_compose_runtime_metadata(path):
    service_name = ""
    container_name = ""
    default_port = None
    served_model_name = ""
    max_model_len = None
    model_path = ""
    mmproj_path = ""
    speculative_json = ""
    draft_model_path = ""
    command_items = []
    in_command = False
    in_ports = False
    current_indent = 0
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for raw_line in f:
                line = str(raw_line or "").rstrip("\n")
                if not line.strip() or line.lstrip().startswith("#"):
                    continue
                indent = len(line) - len(line.lstrip(" "))
                stripped = line.strip()
                if stripped == "services:":
                    continue
                if not service_name and indent == 2 and stripped.endswith(":"):
                    service_name = stripped[:-1]
                    continue
                if indent <= 4 and not stripped.startswith("- "):
                    in_command = False
                    in_ports = False
                if stripped == "command:":
                    in_command = True
                    current_indent = indent
                    continue
                if stripped == "ports:":
                    in_ports = True
                    current_indent = indent
                    continue
                if in_command and indent > current_indent and stripped.startswith("- "):
                    item = stripped[2:].strip()
                    if len(item) >= 2 and item[0] == item[-1] and item[0] in {"'", '"'}:
                        item = item[1:-1]
                    command_items.append(item)
                    continue
                if in_ports and indent > current_indent and stripped.startswith("- "):
                    port_item = stripped[2:].strip().strip('"').strip("'")
                    parsed_port = _extract_default_number(port_item, minimum_digits=2)
                    if parsed_port is not None and default_port is None:
                        default_port = parsed_port
                    continue
                if not container_name:
                    match = re.match(r"^container_name:\s*(.+)$", stripped)
                    if match:
                        container_name = match.group(1).strip().strip('"').strip("'")
                        continue
    except Exception:
        return {}
    for idx, item in enumerate(command_items):
        if item == "--model" and idx + 1 < len(command_items):
            model_path = _extract_shell_default_value(command_items[idx + 1])
        elif item.startswith("--model="):
            model_path = _extract_shell_default_value(item.split("=", 1)[1])
        if item == "-m" and idx + 1 < len(command_items):
            model_path = _extract_shell_default_value(command_items[idx + 1])
        elif item.startswith("-m="):
            model_path = _extract_shell_default_value(item.split("=", 1)[1])
        if item == "--served-model-name" and idx + 1 < len(command_items):
            served_model_name = command_items[idx + 1]
        elif item.startswith("--served-model-name="):
            served_model_name = item.split("=", 1)[1]
        if item == "--max-model-len" and idx + 1 < len(command_items):
            max_model_len = _extract_default_number(command_items[idx + 1], minimum_digits=4)
        elif item.startswith("--max-model-len="):
            max_model_len = _extract_default_number(item.split("=", 1)[1], minimum_digits=4)
        if item == "-c" and idx + 1 < len(command_items) and max_model_len is None:
            max_model_len = _extract_default_number(command_items[idx + 1], minimum_digits=4)
        elif item.startswith("-c=") and max_model_len is None:
            max_model_len = _extract_default_number(item.split("=", 1)[1], minimum_digits=4)
        if item == "--mmproj" and idx + 1 < len(command_items):
            mmproj_path = _extract_shell_default_value(command_items[idx + 1])
        elif item.startswith("--mmproj="):
            mmproj_path = _extract_shell_default_value(item.split("=", 1)[1])
        if item == "--speculative-config" and idx + 1 < len(command_items):
            speculative_json = command_items[idx + 1]
        elif item.startswith("--speculative-config="):
            speculative_json = item.split("=", 1)[1]
    drafted_tokens = None
    speculative_method = None
    if speculative_json:
        try:
            parsed = json.loads(speculative_json)
            speculative_method = str(parsed.get("method") or "").strip() or None
            drafted_tokens = parsed.get("num_speculative_tokens")
            draft_model_path = str(parsed.get("model") or "").strip()
        except Exception:
            speculative_method = None
            drafted_tokens = None
            draft_model_path = ""
    return {
        "service_name": service_name,
        "container_name": container_name,
        "default_port": default_port,
        "served_model_name": served_model_name,
        "max_model_len": max_model_len,
        "model_path": model_path,
        "mmproj_path": mmproj_path,
        "speculative_method": speculative_method,
        "drafted_tokens": drafted_tokens,
        "draft_model_path": draft_model_path,
    }


def _parse_switch_variants():
    switch_path = os.path.join(CLUB3090_DIR, "scripts", "switch.sh")
    tag_by_compose = {}
    if not os.path.exists(switch_path):
        return tag_by_compose
    try:
        with open(switch_path, "r", encoding="utf-8", errors="replace") as f:
            for raw_line in f:
                line = str(raw_line or "").strip()
                match = re.match(r'^\[([^\]]+)\]="([^|"]+)\|([^|"]+)\|([^"]+)"$', line)
                if not match:
                    continue
                tag = match.group(1).strip()
                compose_dir = match.group(3).strip().strip("/")
                compose_file = match.group(4).strip().strip("/")
                rel_path = (compose_dir + "/" + compose_file).replace("\\", "/").strip("/")
                if tag and rel_path:
                    tag_by_compose[rel_path] = tag
    except Exception:
        return {}
    return tag_by_compose


def _qwen_llamacpp_install_command(model_dir_root):
    model_root = os.path.join(model_dir_root, "qwen3.6-27b")
    gguf_dir = os.path.join(model_root, "unsloth-q3kxl")
    return (
        f'hf download unsloth/Qwen3.6-27B-GGUF Qwen3.6-27B-UD-Q3_K_XL.gguf mmproj-F16.gguf --local-dir "{gguf_dir}"'
        f' && mkdir -p "{model_root}"'
        f' && if [ -f "{os.path.join(gguf_dir, "mmproj-F16.gguf")}" ]; then cp -f "{os.path.join(gguf_dir, "mmproj-F16.gguf")}" "{os.path.join(model_root, "mmproj-F16.gguf")}"; fi'
    )


def _hf_cache_subdir_from_model_path(model_path):
    path = str(model_path or "").replace("\\", "/").strip()
    marker = "/root/.cache/huggingface/"
    if marker in path:
        tail = path.split(marker, 1)[1].strip("/")
        if tail:
            return tail
    return ""


def _container_model_subpath(model_path):
    path = str(model_path or "").replace("\\", "/").strip()
    if not path:
        return ""
    for marker in ("/root/.cache/huggingface/", "/models/"):
        if marker in path:
            tail = path.split(marker, 1)[1].strip("/")
            if tail:
                return tail
    return path.strip("/")


def _detect_variant_install_state(variant, model_dir_root):
    model_id = str((variant or {}).get("model_id") or "").strip()
    engine = str((variant or {}).get("engine") or "").strip()
    selector = _mode_selector_for_variant(variant)
    rel_path = _variant_rel_compose_path(variant).lower()
    compose_model_subdir = _hf_cache_subdir_from_model_path((variant or {}).get("model_path"))
    draft_model_subdir = _hf_cache_subdir_from_model_path((variant or {}).get("draft_model_path"))
    base_ready = False
    ready = False
    install_command = ""
    install_reason = ""
    if model_id == "qwen3.6-27b":
        base_subdir = compose_model_subdir or "qwen3.6-27b-autoround-int4"
        draft_subdir = draft_model_subdir or "qwen3.6-27b-dflash"
        base_ready = _dir_has_filetype(os.path.join(model_dir_root, base_subdir), {".safetensors"})
        dflash_ready = _dir_has_filetype(os.path.join(model_dir_root, draft_subdir), {".safetensors"})
        gguf_file = os.path.join(model_dir_root, "qwen3.6-27b", "unsloth-q3kxl", "Qwen3.6-27B-UD-Q3_K_XL.gguf")
        mmproj_file = os.path.join(model_dir_root, "qwen3.6-27b", "mmproj-F16.gguf")
        mmproj_sidecar = os.path.join(model_dir_root, "qwen3.6-27b", "unsloth-q3kxl", "mmproj-F16.gguf")
        llama_ready = os.path.isfile(gguf_file) and (os.path.isfile(mmproj_file) or os.path.isfile(mmproj_sidecar))
        if engine == "llamacpp":
            ready = llama_ready
            install_command = _qwen_llamacpp_install_command(model_dir_root)
            install_reason = "GGUF and mmproj assets are required for Qwen llama.cpp variants."
        elif compose_model_subdir and compose_model_subdir != "qwen3.6-27b-autoround-int4":
            return {
                "install_state": "unavailable",
                "install_command": "",
                "install_reason": f"This preset expects model assets under {compose_model_subdir}, but no supported install workflow is defined for that upstream variant yet.",
            }
        elif "dflash" in selector.lower() or "dflash" in rel_path:
            ready = base_ready and dflash_ready
            install_command = "WITH_DFLASH_DRAFT=1 bash scripts/setup.sh qwen3.6-27b"
            install_reason = "This preset needs the base Qwen weights plus the Qwen DFlash draft model."
        else:
            ready = base_ready
            install_command = "bash scripts/setup.sh qwen3.6-27b"
            install_reason = "This preset needs the base Qwen vLLM weights."
    elif model_id == "gemma-4-31b":
        base_subdir = compose_model_subdir or "gemma-4-31b-autoround-int4"
        draft_subdir = draft_model_subdir or "gemma-4-31b-it-dflash"
        base_ready = _dir_has_filetype(os.path.join(model_dir_root, base_subdir), {".safetensors"})
        assistant_ready = _dir_has_filetype(os.path.join(model_dir_root, "gemma-4-31b-it-assistant"), {".safetensors"})
        dflash_ready = _dir_has_filetype(os.path.join(model_dir_root, draft_subdir), {".safetensors"})
        if "dflash" in selector.lower() or "dflash" in rel_path:
            ready = base_ready and dflash_ready
            install_command = "WITH_DFLASH_DRAFT=1 bash scripts/setup.sh gemma-4-31b"
            install_reason = "This preset needs the base Gemma weights plus the Gemma DFlash drafter."
        else:
            ready = base_ready and assistant_ready
            install_command = "bash scripts/setup.sh gemma-4-31b"
            install_reason = "This preset needs the base Gemma weights plus the official Gemma assistant drafter."
    else:
        return {
            "install_state": "unavailable",
            "install_command": "",
            "install_reason": f"No install workflow is defined for model {model_id}.",
        }
    return {
        "install_state": "ready" if ready else "requires_download",
        "install_command": install_command,
        "install_reason": "" if ready else install_reason,
    }


def ensure_variant_install_ready(variant):
    spec = variant if isinstance(variant, dict) else {}
    model_dir_root = _resolve_variant_model_dir_root(spec)
    state = _detect_variant_install_state(spec, model_dir_root)
    install_state = str(state.get("install_state") or "").strip().lower()
    if install_state == "ready":
        return
    selector = canonical_mode_selector(_mode_selector_for_variant(spec) or spec.get("selector") or spec.get("upstream_tag") or spec.get("variant_id"))
    reason = str(state.get("install_reason") or "").strip()
    install_command = str(state.get("install_command") or "").strip()
    details = [f"Required model assets for {selector or 'this preset'} are not ready under {model_dir_root}."]
    if reason:
        details.append(reason)
    if install_command:
        details.append(f"Run from {CLUB3090_DIR}: {install_command}")
    raise RuntimeError("\n".join(details))


def _choose_fallback_variant(kind, preferred_model_id="", category=""):
    inventory = load_runtime_inventory()
    variants = list(inventory.get("variants") or [])
    preferred_statuses = {"production", "production_caveat"}
    wanted_model = str(preferred_model_id or "").strip()
    wanted_category = str(category or "").strip()
    candidates = []
    for variant in variants:
        if str(variant.get("scope_kind") or "") != str(kind or ""):
            continue
        status_kind = str(variant.get("status_kind") or "")
        rank = 0 if status_kind in preferred_statuses else 1
        if wanted_category and str(variant.get("category") or "") == wanted_category:
            rank -= 1
        if wanted_model and str(variant.get("model_id") or "") == wanted_model:
            rank -= 2
        candidates.append((rank, _mode_selector_for_variant(variant), variant))
    candidates.sort(key=lambda item: (item[0], item[1]))
    return candidates[0][2] if candidates else None


def _rebuild_runtime_mode_tables(inventory):
    global MODES, SINGLE_GPU_MODES, DUAL_GPU_MODES, VARIANT_SPECS
    global VARIANT_BY_ID, VARIANT_BY_TAG, VARIANT_BY_CONTAINER, VARIANT_BY_SERVICE, VARIANT_BY_COMPOSE, MODEL_INDEX
    modes = {}
    single_modes = []
    dual_modes = []
    variant_specs = {}
    by_id = {}
    by_tag = {}
    by_container = {}
    by_service = {}
    by_compose = {}
    model_index = {}
    for model in inventory.get("models") or []:
        model_index[str(model.get("model_id") or "")] = dict(model)
    for variant in inventory.get("variants") or []:
        entry = dict(variant)
        selector = _mode_selector_for_variant(entry)
        variant_id = str(entry.get("variant_id") or "").strip()
        compose_rel = _variant_rel_compose_path(entry)
        spec = {
            "variant_id": variant_id,
            "selector": selector,
            "upstream_tag": str(entry.get("upstream_tag") or "").strip() or None,
            "model_id": str(entry.get("model_id") or "").strip(),
            "engine": str(entry.get("engine") or "").strip(),
            "topology": str(entry.get("topology") or "").strip(),
            "category": str(entry.get("category") or "").strip(),
            "scope_kind": str(entry.get("scope_kind") or "").strip(),
            "compose_rel_path": compose_rel,
            "compose_abs_path": str(entry.get("compose_abs_path") or "").strip(),
            "compose_dir_abs_path": str(entry.get("compose_dir_abs_path") or "").strip(),
            "compose_project_dir_abs_path": str(entry.get("compose_project_dir_abs_path") or "").strip(),
            "service": str(entry.get("service_name") or entry.get("service") or "").strip(),
            "service_name": str(entry.get("service_name") or entry.get("service") or "").strip(),
            "container_name": str(entry.get("container_name") or "").strip(),
            "default_port": int(entry.get("default_port") or 0),
            "served_model_name": str(entry.get("served_model_name") or "").strip(),
            "max_model_len": entry.get("max_model_len"),
            "drafter": str(entry.get("drafter") or "").strip(),
            "kv_format": str(entry.get("kv_format") or "").strip(),
            "vision": str(entry.get("vision") or "").strip(),
            "genesis": str(entry.get("genesis") or "").strip(),
            "status_kind": str(entry.get("status_kind") or "").strip(),
            "status_raw": str(entry.get("status_raw") or "").strip(),
            "quality_summary": str(entry.get("quality_summary") or "").strip(),
            "best_for": str(entry.get("best_for") or "").strip(),
            "caveats": str(entry.get("caveats") or "").strip(),
            "install_state": str(entry.get("install_state") or "").strip(),
            "install_command": str(entry.get("install_command") or "").strip(),
            "install_reason": str(entry.get("install_reason") or "").strip(),
            "speculative_method": entry.get("speculative_method"),
            "drafted_tokens": entry.get("drafted_tokens"),
        }
        for key in {variant_id, selector, compose_rel}:
            if key:
                variant_specs[key] = spec
                if spec["default_port"]:
                    modes[key] = int(spec["default_port"])
        if variant_id:
            by_id[variant_id] = spec
        if spec.get("upstream_tag"):
            by_tag[spec["upstream_tag"]] = spec
        if spec.get("container_name"):
            by_container[spec["container_name"]] = spec
        if spec.get("service_name"):
            by_service[spec["service_name"]] = spec
        if compose_rel:
            by_compose[compose_rel] = spec
        canonical = selector or variant_id
        if spec["scope_kind"] == "single" and canonical:
            single_modes.append(canonical)
        elif spec["scope_kind"] == "dual" and canonical:
            dual_modes.append(canonical)
    MODES = modes
    SINGLE_GPU_MODES = tuple(dict.fromkeys(single_modes))
    DUAL_GPU_MODES = tuple(dict.fromkeys(dual_modes))
    VARIANT_SPECS = variant_specs
    VARIANT_BY_ID = by_id
    VARIANT_BY_TAG = by_tag
    VARIANT_BY_CONTAINER = by_container
    VARIANT_BY_SERVICE = by_service
    VARIANT_BY_COMPOSE = by_compose
    MODEL_INDEX = model_index


def rebuild_runtime_inventory():
    global runtime_inventory_cache, runtime_inventory_built_at
    repo_root = os.path.abspath(CLUB3090_DIR)
    tag_by_compose = _parse_switch_variants()
    try:
        repo_head = subprocess.check_output(
            ["git", "rev-parse", "HEAD"],
            cwd=repo_root,
            text=True,
            stderr=subprocess.DEVNULL,
            timeout=5,
        ).strip()
    except Exception:
        repo_head = ""
    inventory = {
        "built_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "repo_root": repo_root,
        "repo_head": repo_head,
        "switch_script_present": os.path.exists(os.path.join(repo_root, "scripts", "switch.sh")),
        "setup_script_present": os.path.exists(os.path.join(repo_root, "scripts", "setup.sh")),
        "launch_script_present": os.path.exists(os.path.join(repo_root, "scripts", "launch.sh")),
        "update_script_present": os.path.exists(os.path.join(repo_root, "scripts", "update.sh")),
        "models": [],
        "variants": [],
    }
    model_rows = {}
    pattern = os.path.join(repo_root, "models", "*", "*", "compose", "**", "*.yml")
    compose_paths = sorted(glob.glob(pattern, recursive=True))
    for compose_abs_path in compose_paths:
        rel_path = os.path.relpath(compose_abs_path, repo_root).replace("\\", "/")
        parts = rel_path.split("/")
        if len(parts) < 6 or parts[0] != "models":
            continue
        model_id = parts[1]
        engine = _normalize_engine(parts[2])
        topology = parts[4]
        profile = _read_compose_profile_header(compose_abs_path)
        status_hints = _read_compose_status_hints(compose_abs_path)
        runtime_meta = _read_compose_runtime_metadata(compose_abs_path)
        status_text = str(profile.get("status") or "").strip()
        if not status_text:
            status_text = status_hints
        variant = {
            "variant_id": _variant_id_from_rel_path(rel_path),
            "upstream_tag": tag_by_compose.get(rel_path),
            "model_id": model_id,
            "engine": engine,
            "topology": topology,
            "compose_rel_path": rel_path,
            "compose_abs_path": compose_abs_path,
            "compose_dir_abs_path": os.path.dirname(compose_abs_path),
            "compose_project_dir_abs_path": os.path.join(repo_root, "models", model_id, parts[2], "compose"),
            "service_name": runtime_meta.get("service_name") or "",
            "container_name": runtime_meta.get("container_name") or "",
            "default_port": runtime_meta.get("default_port") or 0,
            "served_model_name": runtime_meta.get("served_model_name") or "",
            "max_model_len": runtime_meta.get("max_model_len") or _extract_token_count(profile.get("max_ctx")),
            "model_path": runtime_meta.get("model_path") or "",
            "mmproj_path": runtime_meta.get("mmproj_path") or "",
            "draft_model_path": runtime_meta.get("draft_model_path") or "",
            "drafter": str(profile.get("drafter") or "").strip(),
            "kv_format": str(profile.get("kv") or "").strip(),
            "vision": str(profile.get("vision") or "").strip(),
            "genesis": str(profile.get("genesis") or "").strip(),
            "status_raw": status_text,
            "status_kind": _normalize_status_kind(status_text),
            "caveats": str(profile.get("caveats") or "").strip(),
            "best_for": str(profile.get("best_for") or "").strip(),
            "quality_summary": str(profile.get("quality") or "").strip(),
            "speculative_method": runtime_meta.get("speculative_method"),
            "drafted_tokens": runtime_meta.get("drafted_tokens"),
        }
        if variant["status_kind"] == "unknown" and variant["caveats"]:
            variant["status_kind"] = "production_caveat"
        variant["category"] = _category_for_variant(variant["topology"], variant["status_kind"])
        variant["scope_kind"] = _scope_kind_for_topology(variant["topology"])
        variant.update(_detect_variant_install_state(variant, _resolve_variant_model_dir_root(variant)))
        inventory["variants"].append(variant)
        model_row = model_rows.setdefault(
            model_id,
            {
                "model_id": model_id,
                "display_name": _format_model_display_name(model_id),
                "engine_groups": [],
                "installed_state": "missing",
                "setup_supported": False,
                "default_install_command": "",
                "categories": {
                    "single": [],
                    "dual": [],
                    "multi": [],
                    "experimental": [],
                },
                "summary": "",
            },
        )
        if engine not in model_row["engine_groups"]:
            model_row["engine_groups"].append(engine)
        if variant["category"] in model_row["categories"]:
            model_row["categories"][variant["category"]].append(variant["variant_id"])
        if not model_row["summary"] and variant["best_for"]:
            model_row["summary"] = variant["best_for"]
    for model_id, model_row in model_rows.items():
        variants = [row for row in inventory["variants"] if row.get("model_id") == model_id]
        safe_variants = [row for row in variants if row.get("status_kind") in {"production", "production_caveat"}]
        any_ready = any(row.get("install_state") == "ready" for row in safe_variants)
        any_known = any(row.get("install_state") in {"ready", "requires_download"} for row in variants)
        any_partial = any(row.get("install_state") == "ready" for row in variants)
        any_downloadable = any(row.get("install_state") == "requires_download" for row in variants)
        preferred_summary_order = {"vllm/default": 0, "vllm/gemma-mtp": 0, "llamacpp/default": 1}
        preferred_summaries = [
            row for row in variants
            if str(row.get("upstream_tag") or "") in preferred_summary_order
        ]
        preferred_summaries.sort(key=lambda row: preferred_summary_order.get(str(row.get("upstream_tag") or ""), 99))
        if preferred_summaries:
            model_row["summary"] = str(preferred_summaries[0].get("best_for") or model_row.get("summary") or "")
        else:
            fallback_summary = next((str(row.get("best_for") or "") for row in safe_variants if row.get("best_for")), "")
            if fallback_summary:
                model_row["summary"] = fallback_summary
        model_row["default_install_command"] = next(
            (
                str(row.get("install_command") or "")
                for row in variants
                if row.get("install_command")
                and str(row.get("engine") or "") == "vllm"
                and "WITH_DFLASH_DRAFT=1" not in str(row.get("install_command") or "")
            ),
            "",
        )
        if not model_row["default_install_command"]:
            model_row["default_install_command"] = next(
                (
                    str(row.get("install_command") or "")
                    for row in variants
                    if row.get("install_command") and "WITH_DFLASH_DRAFT=1" not in str(row.get("install_command") or "")
                ),
                "",
            )
        if not model_row["default_install_command"]:
            model_row["default_install_command"] = next((str(row.get("install_command") or "") for row in variants if row.get("install_command")), "")
        model_row["setup_supported"] = bool(model_row["default_install_command"])
        if any_ready:
            model_row["installed_state"] = "ready" if not any_downloadable else "partial"
        elif any_partial or any_downloadable:
            model_row["installed_state"] = "partial" if any_partial else "missing"
        elif any_known:
            model_row["installed_state"] = "missing"
        else:
            model_row["installed_state"] = "unsupported"
        model_row["engine_groups"].sort()
        inventory["models"].append(model_row)
    inventory["models"].sort(key=lambda row: row.get("display_name") or row.get("model_id") or "")
    inventory["variants"].sort(key=lambda row: (row.get("model_id") or "", row.get("category") or "", _mode_selector_for_variant(row)))
    write_json_file(RUNTIME_INVENTORY_FILE, inventory)
    _rebuild_runtime_mode_tables(inventory)
    with runtime_inventory_lock:
        runtime_inventory_cache = dict(inventory)
        runtime_inventory_built_at = time.time()
    return inventory


def load_runtime_inventory(force=False, rebuild_if_missing=True):
    global runtime_inventory_cache, runtime_inventory_built_at
    now = time.time()
    with runtime_inventory_lock:
        cached = dict(runtime_inventory_cache) if runtime_inventory_cache else {}
        cached_at = float(runtime_inventory_built_at or 0.0)
    if cached and not force and cached_at and (now - cached_at) < 10.0:
        return cached
    if not force:
        data = read_json_file(RUNTIME_INVENTORY_FILE, {})
        if isinstance(data, dict) and data.get("variants"):
            _rebuild_runtime_mode_tables(data)
            with runtime_inventory_lock:
                runtime_inventory_cache = dict(data)
                runtime_inventory_built_at = time.time()
            return data
    if rebuild_if_missing:
        return rebuild_runtime_inventory()
    return {}


def canonical_mode_selector(mode):
    spec = VARIANT_SPECS.get(str(mode or "").strip()) or VARIANT_BY_TAG.get(str(mode or "").strip())
    return str((spec or {}).get("selector") or mode or "").strip()


def resolve_variant_spec(mode):
    selector = str(mode or "").strip()
    if not selector:
        return None
    if not VARIANT_SPECS:
        load_runtime_inventory()
    return VARIANT_SPECS.get(selector) or VARIANT_BY_TAG.get(selector) or VARIANT_BY_ID.get(selector) or VARIANT_BY_COMPOSE.get(selector.replace("\\", "/"))


def default_single_mode_selector():
    load_runtime_inventory()
    if DEFAULT_MODE in SINGLE_GPU_MODES:
        return canonical_mode_selector(DEFAULT_MODE)
    variant = _choose_fallback_variant("single", preferred_model_id="qwen3.6-27b", category="single")
    if variant:
        return _mode_selector_for_variant(variant)
    return SINGLE_GPU_MODES[0] if SINGLE_GPU_MODES else canonical_mode_selector(DEFAULT_MODE or "vllm/default")


def default_dual_mode_selector():
    load_runtime_inventory()
    if DEFAULT_MODE in DUAL_GPU_MODES:
        return canonical_mode_selector(DEFAULT_MODE)
    variant = _choose_fallback_variant("dual", preferred_model_id="qwen3.6-27b", category="dual")
    if variant:
        return _mode_selector_for_variant(variant)
    return DUAL_GPU_MODES[0] if DUAL_GPU_MODES else canonical_mode_selector(DEFAULT_MODE or "vllm/dual")


def default_server_config():
    return {
        "allow_proxy_without_api_key": True,
        "online_enabled": False,
        "upnp_enabled": False,
        "https_enabled": False,
        "https_cert_file": HTTPS_CERT_FILE,
        "https_key_file": HTTPS_KEY_FILE,
        "admin_path": "/admin",
        "local_api_enabled": False,
        "local_api_port": LOCAL_API_PORT,
        "gpu_pairing_enabled": True,
        "selected_preset_model": "",
        "mcp_servers": [],
    }


def sanitize_mcp_servers(rows):
    normalized = []
    seen = set()
    for raw in rows if isinstance(rows, list) else []:
        if not isinstance(raw, dict):
            continue
        server_id = str(raw.get("id") or "").strip() or secrets.token_hex(6)
        if server_id in seen:
            continue
        seen.add(server_id)
        command = str(raw.get("command") or "").strip()
        if not command:
            continue
        normalized.append({
            "id": server_id,
            "name": str(raw.get("name") or server_id).strip() or server_id,
            "command": command,
            "enabled": bool(raw.get("enabled", True)),
        })
    return normalized


def read_server_config():
    data = read_json_file(SERVER_CONFIG_FILE, {})
    if not isinstance(data, dict):
        data = {}
    merged = default_server_config()
    for key in merged:
        if key in data:
            merged[key] = data[key]
    merged["allow_proxy_without_api_key"] = bool(merged.get("allow_proxy_without_api_key", True))
    merged["online_enabled"] = bool(merged.get("online_enabled", False))
    merged["upnp_enabled"] = bool(merged.get("upnp_enabled", False))
    merged["https_enabled"] = bool(merged.get("https_enabled", False))
    merged["local_api_enabled"] = bool(merged.get("local_api_enabled", False))
    if "gpu_pairing_enabled" in data:
        merged["gpu_pairing_enabled"] = bool(data.get("gpu_pairing_enabled"))
    else:
        merged["gpu_pairing_enabled"] = detect_gpu_count_runtime() != 2
    try:
        merged["local_api_port"] = int(merged.get("local_api_port", LOCAL_API_PORT))
    except Exception:
        merged["local_api_port"] = LOCAL_API_PORT
    merged["https_cert_file"] = str(merged.get("https_cert_file") or HTTPS_CERT_FILE)
    merged["https_key_file"] = str(merged.get("https_key_file") or HTTPS_KEY_FILE)
    merged["admin_path"] = "/admin"
    merged["selected_preset_model"] = str(data.get("selected_preset_model") or "").strip()
    merged["mcp_servers"] = sanitize_mcp_servers(data.get("mcp_servers") or [])
    return merged


def write_server_config(data):
    current = read_server_config()
    original = dict(current)
    for key in ("allow_proxy_without_api_key", "online_enabled", "upnp_enabled", "https_enabled", "local_api_enabled", "gpu_pairing_enabled"):
        if key in data:
            current[key] = bool(data[key])
    if "local_api_port" in data:
        try:
            current["local_api_port"] = int(data["local_api_port"])
        except Exception:
            pass
    for key in ("https_cert_file", "https_key_file"):
        if key in data and data[key]:
            current[key] = str(data[key])
    if "selected_preset_model" in data:
        current["selected_preset_model"] = str(data.get("selected_preset_model") or "").strip()
    if "mcp_servers" in data:
        current["mcp_servers"] = sanitize_mcp_servers(data.get("mcp_servers") or [])
    current["admin_path"] = "/admin"
    if current != original:
        write_json_file(SERVER_CONFIG_FILE, current)
    return current


MCP_CLIENTS = {}
MCP_CLIENTS_LOCK = threading.Lock()


class McpStdioClient:
    def __init__(self, server_row):
        self.server = dict(server_row or {})
        self.proc = None
        self.lock = threading.Lock()
        self.request_id = 0

    def _ensure_started(self):
        if self.proc and self.proc.poll() is None:
            return
        command = str(self.server.get("command") or "").strip()
        if not command:
            raise RuntimeError("MCP server command is empty")
        self.proc = subprocess.Popen(
            shlex.split(command),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            cwd=CLUB3090_DIR,
            bufsize=0,
        )
        self.request_id += 1
        init_id = self.request_id
        self._write_message({"jsonrpc": "2.0", "id": init_id, "method": "initialize", "params": {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "club3090-control", "version": SCRIPT_VERSION},
        }})
        while True:
            payload = self._read_message(timeout=20)
            if payload.get("id") != init_id:
                continue
            if payload.get("error"):
                raise RuntimeError(str(payload.get("error")))
            break
        self._write_message({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})

    def _write_message(self, payload):
        raw = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        header = f"Content-Length: {len(raw)}\r\n\r\n".encode("utf-8")
        self.proc.stdin.write(header + raw)
        self.proc.stdin.flush()

    def _read_message(self, timeout=20):
        stdout = self.proc.stdout
        if stdout is None:
            raise RuntimeError("MCP stdout is unavailable")
        fd = stdout.fileno()
        deadline = time.time() + max(1.0, float(timeout or 20))
        header = b""
        while b"\r\n\r\n" not in header:
            remaining = max(0.1, deadline - time.time())
            ready, _, _ = select.select([fd], [], [], remaining)
            if not ready:
                raise RuntimeError("Timed out waiting for MCP response headers")
            chunk = os.read(fd, 1)
            if not chunk:
                raise RuntimeError("MCP server closed the connection")
            header += chunk
        header_text = header.decode("utf-8", errors="ignore")
        match = re.search(r"Content-Length:\s*(\d+)", header_text, re.I)
        if not match:
            raise RuntimeError("MCP response did not include Content-Length")
        length = int(match.group(1))
        body = b""
        while len(body) < length:
            remaining = max(0.1, deadline - time.time())
            ready, _, _ = select.select([fd], [], [], remaining)
            if not ready:
                raise RuntimeError("Timed out waiting for MCP response body")
            chunk = os.read(fd, length - len(body))
            if not chunk:
                raise RuntimeError("MCP server closed during response body")
            body += chunk
        return json.loads(body.decode("utf-8", errors="ignore") or "{}")

    def _notify(self, method, params):
        with self.lock:
            self._ensure_started()
            self._write_message({"jsonrpc": "2.0", "method": method, "params": params or {}})

    def _request(self, method, params, timeout=20):
        with self.lock:
            self._ensure_started()
            self.request_id += 1
            req_id = self.request_id
            self._write_message({"jsonrpc": "2.0", "id": req_id, "method": method, "params": params or {}})
            while True:
                payload = self._read_message(timeout=timeout)
                if payload.get("id") != req_id:
                    continue
                if payload.get("error"):
                    raise RuntimeError(str(payload.get("error")))
                return payload.get("result") or {}

    def tools(self):
        result = self._request("tools/list", {}, timeout=20)
        return list(result.get("tools") or [])

    def call_tool(self, name, arguments):
        result = self._request("tools/call", {"name": name, "arguments": arguments or {}}, timeout=60)
        return result

    def close(self):
        proc = self.proc
        self.proc = None
        if not proc:
            return
        try:
            proc.terminate()
            proc.wait(timeout=2)
        except Exception:
            try:
                proc.kill()
            except Exception:
                pass


def get_mcp_client(server_row):
    server_id = str(server_row.get("id") or "").strip()
    if not server_id:
        raise RuntimeError("Invalid MCP server definition")
    with MCP_CLIENTS_LOCK:
        client = MCP_CLIENTS.get(server_id)
        if client and client.server.get("command") == server_row.get("command"):
            return client
        if client:
            client.close()
        client = McpStdioClient(server_row)
        MCP_CLIENTS[server_id] = client
        return client


def close_removed_mcp_clients(server_rows):
    active_ids = {str(row.get("id") or "").strip() for row in server_rows if isinstance(row, dict)}
    with MCP_CLIENTS_LOCK:
        for server_id, client in list(MCP_CLIENTS.items()):
            if server_id not in active_ids:
                try:
                    client.close()
                finally:
                    MCP_CLIENTS.pop(server_id, None)


def mcp_server_status(server_row):
    row = dict(server_row or {})
    if not row.get("enabled"):
        return {**row, "status": "disabled", "tools": [], "error": ""}
    try:
        client = get_mcp_client(row)
        tools = client.tools()
        return {
            **row,
            "status": "connected",
            "tools": [
                {
                    "name": str(tool.get("name") or ""),
                    "description": str(tool.get("description") or ""),
                }
                for tool in tools
                if isinstance(tool, dict)
            ],
            "error": "",
        }
    except Exception as e:
        return {**row, "status": "error", "tools": [], "error": str(e)}

def validate_mcp_server_row(server_row):
    row = dict(server_row or {})
    if not str(row.get("command") or "").strip():
        raise ValueError("MCP server command is required")
    client = get_mcp_client(row)
    tools = client.tools()
    return {
        **row,
        "status": "connected",
        "tools": [
            {
                "name": str(tool.get("name") or ""),
                "description": str(tool.get("description") or ""),
            }
            for tool in tools
            if isinstance(tool, dict)
        ],
        "error": "",
    }


def list_mcp_server_statuses():
    rows = sanitize_mcp_servers(read_server_config().get("mcp_servers") or [])
    close_removed_mcp_clients(rows)
    return [mcp_server_status(row) for row in rows]


def build_enabled_mcp_tools():
    tools = []
    tool_map = {}
    for server in list_mcp_server_statuses():
        if server.get("status") != "connected":
            continue
        client = get_mcp_client(server)
        for tool in client.tools():
            if not isinstance(tool, dict):
                continue
            base_name = str(tool.get("name") or "").strip()
            if not base_name:
                continue
            qualified = f"{server['id']}__{base_name}"
            tool_map[qualified] = {"server": server, "name": base_name}
            tools.append({
                "type": "function",
                "function": {
                    "name": qualified,
                    "description": str(tool.get("description") or f"{server['name']} :: {base_name}"),
                    "parameters": tool.get("inputSchema") or {"type": "object", "properties": {}},
                },
            })
    return tools, tool_map


def call_enabled_mcp_tool(tool_name, arguments, tool_map):
    mapping = dict(tool_map.get(str(tool_name) or "") or {})
    if not mapping:
        raise RuntimeError(f"Unknown MCP tool: {tool_name}")
    client = get_mcp_client(mapping["server"])
    result = client.call_tool(mapping["name"], arguments or {})
    parts = []
    for item in list(result.get("content") or []):
        if not isinstance(item, dict):
            continue
        if item.get("type") == "text":
            parts.append(str(item.get("text") or ""))
        elif "text" in item:
            parts.append(str(item.get("text") or ""))
    if not parts and result.get("structuredContent") is not None:
        parts.append(json.dumps(result.get("structuredContent"), indent=2, ensure_ascii=False))
    return "\n".join([part for part in parts if part]).strip() or json.dumps(result, indent=2, ensure_ascii=False)


def ensure_local_api_token():
    try:
        if os.path.exists(LOCAL_API_TOKEN_FILE):
            token = open(LOCAL_API_TOKEN_FILE, "r", encoding="utf-8").read().strip()
            if token:
                return token
        token = secrets.token_urlsafe(32)
        os.makedirs(CONTROL_DIR, exist_ok=True)
        with open(LOCAL_API_TOKEN_FILE, "w", encoding="utf-8") as f:
            f.write(token + "\n")
        os.chmod(LOCAL_API_TOKEN_FILE, 0o600)
        return token
    except Exception:
        return ""


def safe_user_name(name):
    name = str(name or "").strip()
    if not name:
        raise ValueError("User name is required")
    if len(name) > 64:
        raise ValueError("User name is too long")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", name):
        raise ValueError("User names may only contain letters, numbers, dot, underscore, and hyphen")
    return name


def normalize_limit_int(value):
    if value in ("", None, False):
        return None
    n = int(value)
    if n < 0:
        raise ValueError("Limits cannot be negative")
    return n


def normalize_limit_float(value):
    if value in ("", None, False):
        return None
    n = float(value)
    if n < 0:
        raise ValueError("Limits cannot be negative")
    return round(n, 3)


DEFAULT_USAGE_WEIGHTS = {
    "input_tokens": 1.0,
    "output_tokens": 1.0,
    "tool_calls": 4000.0,
    "thinking_seconds": 250.0,
}
USAGE_RETENTION_SECONDS = 8 * 24 * 3600


def first_defined(*values):
    for value in values:
        if value not in ("", None, False):
            return value
    return None


def normalize_weight(value, default=None, fill_defaults=False):
    if value in ("", None, False):
        if fill_defaults:
            return round(float(default or 0.0), 3)
        return None
    n = float(value)
    if n < 0:
        raise ValueError("Weights cannot be negative")
    return round(n, 3)


def normalize_limits(raw, fill_defaults=False):
    raw = raw if isinstance(raw, dict) else {}
    return {
        "score_per_5h": normalize_limit_float(raw.get("score_per_5h")),
        "score_per_week": normalize_limit_float(raw.get("score_per_week")),
        "max_tokens_per_message": normalize_limit_int(raw.get("max_tokens_per_message")),
        "max_tool_calls_per_message": normalize_limit_int(raw.get("max_tool_calls_per_message")),
        "input_token_weight": normalize_weight(raw.get("input_token_weight"), DEFAULT_USAGE_WEIGHTS["input_tokens"], fill_defaults=fill_defaults),
        "output_token_weight": normalize_weight(raw.get("output_token_weight"), DEFAULT_USAGE_WEIGHTS["output_tokens"], fill_defaults=fill_defaults),
        "tool_call_weight": normalize_weight(raw.get("tool_call_weight"), DEFAULT_USAGE_WEIGHTS["tool_calls"], fill_defaults=fill_defaults),
        "thinking_second_weight": normalize_weight(raw.get("thinking_second_weight"), DEFAULT_USAGE_WEIGHTS["thinking_seconds"], fill_defaults=fill_defaults),
    }


def default_user_usage():
    return {
        "events": [],
        "last_request_at": 0,
    }


def usage_weights_from_limits(limits):
    limits = normalize_limits(limits or {}, fill_defaults=True)
    return {
        "input_tokens": float(limits.get("input_token_weight") or DEFAULT_USAGE_WEIGHTS["input_tokens"]),
        "output_tokens": float(limits.get("output_token_weight") or DEFAULT_USAGE_WEIGHTS["output_tokens"]),
        "tool_calls": float(limits.get("tool_call_weight") or DEFAULT_USAGE_WEIGHTS["tool_calls"]),
        "thinking_seconds": float(limits.get("thinking_second_weight") or DEFAULT_USAGE_WEIGHTS["thinking_seconds"]),
    }


def usage_score(metrics, limits):
    weights = usage_weights_from_limits(limits)
    return round(
        max(0, int(metrics.get("input_tokens") or 0)) * weights["input_tokens"]
        + max(0, int(metrics.get("output_tokens") or 0)) * weights["output_tokens"]
        + max(0, int(metrics.get("tool_calls") or 0)) * weights["tool_calls"]
        + max(0.0, float(metrics.get("thinking_seconds") or 0.0)) * weights["thinking_seconds"],
        3,
    )


def normalize_usage_event(event):
    if not isinstance(event, dict):
        return None
    try:
        ts = int(event.get("ts") or 0)
    except Exception:
        ts = 0
    try:
        status = int(event.get("status") or 0)
    except Exception:
        status = 0
    input_tokens = max(0, int(first_defined(event.get("input_tokens"), event.get("prompt_tokens"), 0) or 0))
    output_tokens = max(0, int(first_defined(event.get("output_tokens"), event.get("completion_tokens"), event.get("tokens"), 0) or 0))
    tool_calls = max(0, int(event.get("tool_calls") or 0))
    thinking_seconds = round(max(0.0, float(event.get("thinking_seconds") or 0.0)), 3)
    requests = max(0, int(event.get("requests") or 0))
    if not requests and (input_tokens or output_tokens or tool_calls or thinking_seconds):
        requests = 1
    return {
        "ts": ts,
        "requests": requests,
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "tool_calls": tool_calls,
        "thinking_seconds": thinking_seconds,
        "status": status,
    }


def prune_usage_events(events):
    keep_after = int(time.time()) - USAGE_RETENTION_SECONDS
    clean = []
    for event in events or []:
        normalized = normalize_usage_event(event)
        if normalized and int(normalized.get("ts") or 0) >= keep_after:
            clean.append(normalized)
    return clean


def usage_window_totals(events, since_ts, limits):
    totals = {
        "requests": 0,
        "input_tokens": 0,
        "output_tokens": 0,
        "tool_calls": 0,
        "thinking_seconds": 0.0,
        "score": 0.0,
    }
    for raw_event in events or []:
        event = normalize_usage_event(raw_event)
        if not event or int(event.get("ts") or 0) < since_ts:
            continue
        totals["requests"] += int(event.get("requests") or 0)
        totals["input_tokens"] += int(event.get("input_tokens") or 0)
        totals["output_tokens"] += int(event.get("output_tokens") or 0)
        totals["tool_calls"] += int(event.get("tool_calls") or 0)
        totals["thinking_seconds"] = round(totals["thinking_seconds"] + float(event.get("thinking_seconds") or 0.0), 3)
        totals["score"] = round(totals["score"] + usage_score(event, limits), 3)
    return totals


def normalize_group_names(value):
    items = value
    if items in ("", None, False):
        return []
    if isinstance(items, str):
        items = [x.strip() for x in items.split(",") if x.strip()]
    if not isinstance(items, list):
        raise ValueError("groups must be a list")
    names = []
    for item in items:
        name = safe_user_name(item)
        if name not in names:
            names.append(name)
    return names


def normalize_group_record(raw_name, raw):
    if not isinstance(raw, dict):
        raise ValueError("Group record must be an object")
    name = safe_user_name(raw.get("name") or raw_name)
    allowed_targets = raw.get("allowed_targets")
    if allowed_targets in (None, "", []):
        allowed_targets = ["*"]
    if isinstance(allowed_targets, str):
        allowed_targets = [x.strip() for x in allowed_targets.split(",") if x.strip()]
    if not isinstance(allowed_targets, list):
        raise ValueError("allowed_targets must be a list")
    allowed_clean = []
    for item in allowed_targets:
        item = str(item or "").strip()
        if not item:
            continue
        item_upper = item.upper()
        item_lower = item.lower()
        if item == "*" or item_lower in ("legacy", "all"):
            allowed_clean.append("*" if item == "*" or item_lower == "all" else "legacy")
            continue
        if re.fullmatch(r"GPU[0-9]+", item_upper):
            allowed_clean.append(item_upper)
            continue
        raise ValueError("Allowed targets must be *, legacy, or GPU<n>")
    if not allowed_clean:
        allowed_clean = ["*"]
    limits_raw = raw.get("limits") if isinstance(raw.get("limits"), dict) else raw
    limits = normalize_limits(limits_raw)
    return {
        "name": name,
        "enabled": bool(raw.get("enabled", True)),
        "created_at": int(raw.get("created_at") or time.time()),
        "description": str(raw.get("description") or "").strip(),
        "allowed_targets": sorted(set(allowed_clean), key=lambda x: ("*" not in x, x)),
        "limits": limits,
    }


def read_groups():
    data = read_json_file(GROUPS_FILE, {})
    if not isinstance(data, dict):
        data = {}
    clean = {}
    for raw_name, raw_group in data.items():
        try:
            grp = normalize_group_record(raw_name, raw_group)
            clean[grp["name"]] = grp
        except Exception:
            continue
    return clean


def write_groups(data):
    normalized = {}
    for raw_name, raw_group in (data or {}).items():
        grp = normalize_group_record(raw_name, raw_group)
        normalized[grp["name"]] = grp
    write_json_file(GROUPS_FILE, normalized)
    return normalized


def public_group_view(group):
    return {
        "name": group["name"],
        "enabled": bool(group.get("enabled", True)),
        "created_at": int(group.get("created_at") or 0),
        "description": str(group.get("description") or ""),
        "allowed_targets": list(group.get("allowed_targets") or ["*"]),
        "limits": dict(group.get("limits") or {}),
        "resolved_limits": normalize_limits(group.get("limits") or {}, fill_defaults=True),
    }


def list_groups_public():
    return [public_group_view(g) for _, g in sorted(read_groups().items())]


def normalize_user_record(raw_name, raw):
    if not isinstance(raw, dict):
        raise ValueError("User record must be an object")
    name = safe_user_name(raw.get("name") or raw_name)
    allowed_targets = raw.get("allowed_targets")
    if allowed_targets in (None, "", []):
        allowed_targets = ["*"]
    if isinstance(allowed_targets, str):
        allowed_targets = [x.strip() for x in allowed_targets.split(",") if x.strip()]
    if not isinstance(allowed_targets, list):
        raise ValueError("allowed_targets must be a list")
    allowed_clean = []
    for item in allowed_targets:
        item = str(item or "").strip()
        if not item:
            continue
        item_upper = item.upper()
        item_lower = item.lower()
        if item == "*" or item_lower in ("legacy", "all"):
            allowed_clean.append("*" if item == "*" or item_lower == "all" else "legacy")
            continue
        if re.fullmatch(r"GPU[0-9]+", item_upper):
            allowed_clean.append(item_upper)
            continue
        raise ValueError("Allowed targets must be *, legacy, or GPU<n>")
    if not allowed_clean:
        allowed_clean = ["*"]
    groups = normalize_group_names(raw.get("groups"))
    limits_raw = raw.get("limits") if isinstance(raw.get("limits"), dict) else raw
    limits = normalize_limits(limits_raw)
    usage = default_user_usage()
    raw_usage = raw.get("usage") if isinstance(raw.get("usage"), dict) else {}
    usage["last_request_at"] = int(raw_usage.get("last_request_at") or 0)
    usage["events"] = prune_usage_events(raw_usage.get("events") or [])
    api_key_hash = str(raw.get("api_key_hash") or "").strip()
    api_key_plain = str(raw.get("api_key_plain") or raw.get("api_key") or "").strip()
    if api_key_plain:
        digest = hashlib.sha256(api_key_plain.encode("utf-8")).hexdigest()
        if not api_key_hash or api_key_hash != digest:
            api_key_hash = digest
    return {
        "name": name,
        "enabled": bool(raw.get("enabled", True)),
        "created_at": int(raw.get("created_at") or time.time()),
        "allowed_targets": sorted(set(allowed_clean), key=lambda x: ("*" not in x, x)),
        "groups": groups,
        "limits": limits,
        "usage": usage,
        "api_key_hash": api_key_hash,
        "api_key_plain": api_key_plain,
    }


def read_users():
    data = read_json_file(USERS_FILE, {})
    if not isinstance(data, dict):
        data = {}
    clean = {}
    for raw_name, raw_user in data.items():
        try:
            user = normalize_user_record(raw_name, raw_user)
            clean[user["name"]] = user
        except Exception:
            continue
    return clean


def write_users(data):
    normalized = {}
    for raw_name, raw_user in (data or {}).items():
        user = normalize_user_record(raw_name, raw_user)
        normalized[user["name"]] = user
    write_json_file(USERS_FILE, normalized)
    return normalized


def effective_group_records(user):
    groups = read_groups()
    names = user.get("groups") or []
    return [groups[name] for name in names if name in groups and groups[name].get("enabled", True)]


def effective_allowed_targets(user):
    allowed = set(user.get("allowed_targets") or ["*"])
    for group in effective_group_records(user):
        allowed.update(group.get("allowed_targets") or [])
    if not allowed:
        allowed.add("*")
    return sorted(allowed, key=lambda x: ("*" not in x, x))


def effective_limits(user):
    merged = dict(user.get("limits") or {})
    for group in effective_group_records(user):
        for key, value in (group.get("limits") or {}).items():
            if merged.get(key) is None and value is not None:
                merged[key] = value
    return normalize_limits(merged, fill_defaults=True)


def public_user_view(user):
    usage = user.get("usage") or default_user_usage()
    now = int(time.time())
    effective_targets = effective_allowed_targets(user)
    merged_limits = effective_limits(user)
    window_5h = usage_window_totals(usage.get("events") or [], now - (5 * 3600), merged_limits)
    window_week = usage_window_totals(usage.get("events") or [], now - (7 * 24 * 3600), merged_limits)
    return {
        "name": user["name"],
        "enabled": bool(user.get("enabled", True)),
        "created_at": int(user.get("created_at") or 0),
        "allowed_targets": list(user.get("allowed_targets") or ["*"]),
        "groups": list(user.get("groups") or []),
        "effective_allowed_targets": effective_targets,
        "limits": dict(user.get("limits") or {}),
        "effective_limits": merged_limits,
        "usage": {
            "last_request_at": int(usage.get("last_request_at") or 0),
            "window_5h": window_5h,
            "window_week": window_week,
        },
        "has_api_key": bool(user.get("api_key_hash")),
        "api_key_available": bool(user.get("api_key_plain")),
    }


def list_users_public():
    return [public_user_view(u) for _, u in sorted(read_users().items())]


def issue_api_key_for_user(name):
    users = read_users()
    if name not in users:
        raise ValueError("User not found")
    key = "club3090_" + secrets.token_urlsafe(24)
    users[name]["api_key_hash"] = hashlib.sha256(key.encode("utf-8")).hexdigest()
    users[name]["api_key_plain"] = key
    write_users(users)
    log_control(f"USER reset_api_key name={name}")
    log_audit("user_api_key_reset", user=name)
    return key, public_user_view(users[name])


def show_api_key_for_user(name):
    users = read_users()
    if name not in users:
        raise ValueError("User not found")
    key = str(users[name].get("api_key_plain") or "").strip()
    if not key:
        raise ValueError("This API key was created before v4.46 and cannot be recovered. Reset it once to store a viewable copy.")
    return key, public_user_view(users[name])


def save_user_record(payload):
    if not isinstance(payload, dict):
        raise ValueError("User payload must be an object")
    name = safe_user_name(payload.get("name"))
    users = read_users()
    existing = users.get(name)
    merged = {
        "name": name,
        "enabled": bool(payload.get("enabled", True if existing is None else existing.get("enabled", True))),
        "created_at": int(existing.get("created_at") if existing else time.time()),
        "allowed_targets": payload.get("allowed_targets", existing.get("allowed_targets", ["*"]) if existing else ["*"]),
        "groups": payload.get("groups", existing.get("groups", []) if existing else []),
        "limits": payload.get("limits", existing.get("limits", {}) if existing else {}),
        "usage": existing.get("usage", default_user_usage()) if existing else default_user_usage(),
        "api_key_hash": existing.get("api_key_hash", "") if existing else "",
        "api_key_plain": existing.get("api_key_plain", "") if existing else "",
    }
    users[name] = normalize_user_record(name, merged)
    write_users(users)
    log_control(f"USER saved name={name}")
    log_audit("user_saved", user=name, enabled=users[name]["enabled"], allowed_targets=users[name]["allowed_targets"], limits=users[name]["limits"])
    created_key = None
    if payload.get("generate_api_key") or not users[name].get("api_key_hash"):
        created_key, view = issue_api_key_for_user(name)
        return view, created_key
    return public_user_view(users[name]), None


def delete_user_record(name):
    name = safe_user_name(name)
    users = read_users()
    if name not in users:
        raise ValueError("User not found")
    del users[name]
    write_users(users)
    log_control(f"USER deleted name={name}")
    log_audit("user_deleted", user=name)
    return list_users_public()


def save_group_record(payload):
    if not isinstance(payload, dict):
        raise ValueError("Group payload must be an object")
    name = safe_user_name(payload.get("name"))
    groups = read_groups()
    existing = groups.get(name)
    merged = {
        "name": name,
        "enabled": bool(payload.get("enabled", True if existing is None else existing.get("enabled", True))),
        "created_at": int(existing.get("created_at") if existing else time.time()),
        "description": str(payload.get("description", existing.get("description", "") if existing else "")),
        "allowed_targets": payload.get("allowed_targets", existing.get("allowed_targets", ["*"]) if existing else ["*"]),
        "limits": payload.get("limits", existing.get("limits", {}) if existing else {}),
    }
    groups[name] = normalize_group_record(name, merged)
    write_groups(groups)
    log_control(f"GROUP saved name={name}")
    log_audit("group_saved", group=name, enabled=groups[name]["enabled"], allowed_targets=groups[name]["allowed_targets"], limits=groups[name]["limits"])
    return public_group_view(groups[name])


def delete_group_record(name):
    name = safe_user_name(name)
    groups = read_groups()
    if name not in groups:
        raise ValueError("Group not found")
    del groups[name]
    write_groups(groups)
    users = read_users()
    changed = False
    for user_name, user in users.items():
        current_groups = [g for g in (user.get("groups") or []) if g != name]
        if current_groups != (user.get("groups") or []):
            user["groups"] = current_groups
            users[user_name] = normalize_user_record(user_name, user)
            changed = True
    if changed:
        write_users(users)
    log_control(f"GROUP deleted name={name}")
    log_audit("group_deleted", group=name)
    return list_groups_public()


def extract_api_key(headers):
    auth = headers.get("Authorization", "") or headers.get("authorization", "")
    if auth.startswith("Bearer "):
        return auth.split(" ", 1)[1].strip()
    for key in ("X-API-Key", "x-api-key", "api-key"):
        val = headers.get(key, "")
        if val:
            return str(val).strip()
    return ""


def get_user_by_api_key(raw_key):
    if not raw_key:
        return None
    digest = hashlib.sha256(raw_key.encode("utf-8")).hexdigest()
    for user in read_users().values():
        if user.get("enabled", True) and user.get("api_key_hash") == digest:
            return user
    return None


def resolve_target_id(instance_id=None):
    if instance_id:
        return str(instance_id).upper()
    primary = primary_instance()
    return primary["id"] if primary else "legacy"


def target_gpu_labels(target_id):
    parsed = parse_instance_identifier(target_id)
    if not parsed:
        return []
    return [f"GPU{int(idx)}" for idx in parsed.get("gpu_indices") or []]


def user_can_access_target(user, target_id):
    allowed = set(effective_allowed_targets(user))
    if "*" in allowed or target_id in allowed:
        return True
    labels = target_gpu_labels(target_id)
    return bool(labels) and all(label in allowed for label in labels)


def is_quota_counted_path(upstream_path):
    return upstream_path.startswith("/v1/chat/completions") or upstream_path.startswith("/v1/completions")


def estimate_text_tokens(text):
    text = str(text or "")
    return max(0, int(len(text) / 4)) if text else 0


def collect_request_text_fragments(value, out):
    if value in ("", None, False):
        return
    if isinstance(value, str):
        out.append(value)
        return
    if isinstance(value, list):
        for item in value:
            collect_request_text_fragments(item, out)
        return
    if isinstance(value, dict):
        for key in ("text", "content", "prompt", "input", "instructions", "system", "developer", "user", "assistant"):
            if key in value:
                collect_request_text_fragments(value.get(key), out)


def extract_request_usage(body):
    usage = {
        "input_tokens": 0,
        "requested_output_tokens": 0,
        "estimated_total_tokens": 0,
        "requested_tool_calls": None,
    }
    if not body:
        return usage
    text = body.decode("utf-8", errors="ignore") if isinstance(body, (bytes, bytearray)) else str(body)
    usage["input_tokens"] = estimate_text_tokens(text)
    try:
        obj = json.loads(text)
    except Exception:
        usage["estimated_total_tokens"] = usage["input_tokens"]
        return usage
    if isinstance(obj, dict):
        fragments = []
        for key in ("messages", "prompt", "input", "instructions"):
            if key in obj:
                collect_request_text_fragments(obj.get(key), fragments)
        if fragments:
            usage["input_tokens"] = max(usage["input_tokens"], estimate_text_tokens(" ".join(fragments)))
        try:
            usage["requested_output_tokens"] = max(0, int(first_defined(obj.get("max_completion_tokens"), obj.get("max_tokens")) or 0))
        except Exception:
            usage["requested_output_tokens"] = 0
        try:
            requested_tools = first_defined(obj.get("max_tool_calls"), obj.get("max_parallel_tool_calls"))
            if requested_tools not in ("", None, False):
                usage["requested_tool_calls"] = max(0, int(requested_tools))
            elif isinstance(obj.get("tool_choice"), dict):
                usage["requested_tool_calls"] = 1
            elif str(obj.get("tool_choice") or "").strip().lower() == "required":
                usage["requested_tool_calls"] = 1
        except Exception:
            usage["requested_tool_calls"] = None
    usage["estimated_total_tokens"] = usage["input_tokens"] + usage["requested_output_tokens"]
    return usage


def user_limit_error(user, count_request, request_usage=None):
    if not count_request:
        return None
    usage = user.get("usage") or default_user_usage()
    limits = effective_limits(user)
    request_usage = request_usage or {}
    estimated_total_tokens = max(0, int(request_usage.get("estimated_total_tokens") or 0))
    max_tokens_per_message = limits.get("max_tokens_per_message")
    if max_tokens_per_message is not None and estimated_total_tokens > int(max_tokens_per_message):
        return "per-message token limit reached"
    requested_tool_calls = request_usage.get("requested_tool_calls")
    max_tool_calls_per_message = limits.get("max_tool_calls_per_message")
    if max_tool_calls_per_message is not None and requested_tool_calls is not None and int(requested_tool_calls) > int(max_tool_calls_per_message):
        return "per-message tool-call limit reached"
    now = int(time.time())
    events = usage.get("events") or []
    window_5h = usage_window_totals(events, now - (5 * 3600), limits)
    window_week = usage_window_totals(events, now - (7 * 24 * 3600), limits)
    estimated_score = usage_score({
        "input_tokens": max(0, int(request_usage.get("input_tokens") or 0)),
        "output_tokens": max(0, int(request_usage.get("requested_output_tokens") or 0)),
        "tool_calls": max(0, int(requested_tool_calls or 0)),
        "thinking_seconds": 0.0,
    }, limits)
    if limits.get("score_per_5h") is not None and round(window_5h["score"] + estimated_score, 3) > float(limits["score_per_5h"]):
        return "5-hour usage score limit reached"
    if limits.get("score_per_week") is not None and round(window_week["score"] + estimated_score, 3) > float(limits["score_per_week"]):
        return "weekly usage score limit reached"
    return None


def authorize_proxy_request(headers, instance_id, upstream_path, request_usage=None):
    cfg = read_server_config()
    target_id = resolve_target_id(instance_id)
    count_request = is_quota_counted_path(upstream_path)
    raw_key = extract_api_key(headers)
    user = get_user_by_api_key(raw_key) if raw_key else None
    if user is not None:
        if not user_can_access_target(user, target_id):
            log_audit("proxy_access_denied", reason="target_not_allowed", user=user["name"], target=target_id, path=upstream_path)
            return False, 403, {"error": "API key is not allowed to access this backend", "target": target_id}
        err = user_limit_error(user, count_request=count_request, request_usage=request_usage)
        if err:
            log_audit("proxy_quota_denied", user=user["name"], target=target_id, path=upstream_path, reason=err)
            return False, 429, {"error": err, "user": user["name"]}
        return True, {"mode": "user", "user_name": user["name"], "target_id": target_id, "count_request": count_request}
    if cfg.get("allow_proxy_without_api_key", True):
        return True, {"mode": "anonymous", "user_name": None, "target_id": target_id, "count_request": False}
    log_audit("proxy_auth_denied", reason="missing_or_invalid_api_key", target=target_id, path=upstream_path)
    return False, 401, {"error": "Missing or invalid API key"}


def extract_response_usage(payload):
    usage = {"tokens": 0, "input_tokens": 0, "output_tokens": 0, "tool_calls": 0}
    try:
        obj = json.loads(payload.decode("utf-8", errors="ignore"))
    except Exception:
        return usage
    if isinstance(obj, dict):
        if isinstance(obj.get("usage"), dict):
            try:
                usage_block = obj["usage"]
                usage["input_tokens"] = max(0, int(first_defined(usage_block.get("prompt_tokens"), usage_block.get("input_tokens")) or 0))
                usage["output_tokens"] = max(0, int(first_defined(usage_block.get("completion_tokens"), usage_block.get("output_tokens")) or 0))
                usage["tokens"] = max(0, int(usage_block.get("total_tokens") or (usage["input_tokens"] + usage["output_tokens"])))
                if usage["output_tokens"] == 0 and usage["tokens"] and usage["input_tokens"] == 0:
                    usage["output_tokens"] = usage["tokens"]
            except Exception:
                usage["tokens"] = 0
        tool_calls = 0
        for choice in obj.get("choices") or []:
            if not isinstance(choice, dict):
                continue
            msg = choice.get("message") if isinstance(choice.get("message"), dict) else {}
            tool_calls += len(msg.get("tool_calls") or [])
        usage["tool_calls"] = tool_calls
    return usage


def record_user_usage(user_name, count_request, status_code, request_usage, response_usage, thinking_seconds):
    if not user_name or not count_request:
        return
    users = read_users()
    user = users.get(user_name)
    if not user:
        return
    usage = user.get("usage") or default_user_usage()
    limits = effective_limits(user)
    now = int(time.time())
    request_usage = request_usage or {}
    response_usage = response_usage or {}
    input_tokens = max(0, int(first_defined(response_usage.get("input_tokens"), request_usage.get("input_tokens"), 0) or 0))
    output_tokens = max(0, int(first_defined(response_usage.get("output_tokens"), response_usage.get("tokens"), 0) or 0))
    tool_calls = max(0, int(response_usage.get("tool_calls") or 0))
    thinking_seconds = round(max(0.0, float(thinking_seconds or 0.0)), 3)
    score = usage_score({
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "tool_calls": tool_calls,
        "thinking_seconds": thinking_seconds,
    }, limits)
    usage["last_request_at"] = now
    usage.setdefault("events", [])
    usage["events"].append({
        "ts": now,
        "requests": 1,
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "tool_calls": tool_calls,
        "thinking_seconds": thinking_seconds,
        "status": int(status_code or 0),
        "score": score,
    })
    usage["events"] = prune_usage_events(usage.get("events") or [])
    user["usage"] = usage
    users[user_name] = normalize_user_record(user_name, user)
    write_users(users)
    combined_tokens = input_tokens + output_tokens
    overages = []
    if limits.get("max_tokens_per_message") is not None and combined_tokens > int(limits["max_tokens_per_message"]):
        overages.append("message_tokens")
    if limits.get("max_tool_calls_per_message") is not None and tool_calls > int(limits["max_tool_calls_per_message"]):
        overages.append("message_tool_calls")
    window_5h = usage_window_totals(user["usage"].get("events") or [], now - (5 * 3600), limits)
    window_week = usage_window_totals(user["usage"].get("events") or [], now - (7 * 24 * 3600), limits)
    if limits.get("score_per_5h") is not None and window_5h["score"] > float(limits["score_per_5h"]):
        overages.append("score_5h")
    if limits.get("score_per_week") is not None and window_week["score"] > float(limits["score_per_week"]):
        overages.append("score_week")
    log_audit("proxy_usage", user=user_name, status=int(status_code or 0), input_tokens=input_tokens, output_tokens=output_tokens, total_tokens=combined_tokens, tool_calls=tool_calls, thinking_seconds=thinking_seconds, score=score)
    if overages:
        log_audit("proxy_usage_overage", user=user_name, status=int(status_code or 0), kinds=overages, total_tokens=combined_tokens, tool_calls=tool_calls, thinking_seconds=thinking_seconds, score=score)


def local_api_token_ok(header_value):
    token = ensure_local_api_token()
    supplied = str(header_value or "").strip()
    return bool(token) and bool(supplied) and secrets.compare_digest(token, supplied)


def _safe_preset_name(name):
    name = str(name or "").strip()
    if not name:
        raise ValueError("Preset endpoint name is required")
    if len(name) > 48:
        raise ValueError("Preset endpoint name is too long")
    allowed = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
    if any(ch not in allowed for ch in name):
        raise ValueError("Preset endpoint names may only contain letters, numbers, underscore, and hyphen")
    if name.startswith("short-") or name.startswith("concise-"):
        raise ValueError("Preset endpoint names cannot start with short- or concise-")
    if name in PRESETS:
        raise ValueError("Default presets cannot be overwritten")
    return name

def _coerce_preset_value(key, value):
    if value is None or value == "":
        return None
    if key in ("top_k", "max_tokens", "max_completion_tokens", "truncate_prompt_tokens", "seed", "min_tokens", "logprobs", "top_logprobs"):
        return int(value)
    if key in ("temperature", "top_p", "min_p", "presence_penalty", "frequency_penalty", "repetition_penalty", "length_penalty"):
        return float(value)
    return value

def sanitize_custom_preset(raw):
    if not isinstance(raw, dict):
        raise ValueError("Preset body must be an object")
    payload = {}
    numeric_keys = ("temperature", "top_p", "top_k", "min_p", "presence_penalty", "frequency_penalty", "repetition_penalty", "length_penalty", "max_tokens", "max_completion_tokens", "min_tokens", "truncate_prompt_tokens", "seed", "logprobs", "top_logprobs")
    for key in numeric_keys:
        if key in raw:
            val = _coerce_preset_value(key, raw.get(key))
            if val is not None:
                payload[key] = val
    boolean_keys = ("ignore_eos", "skip_special_tokens", "spaces_between_special_tokens", "include_stop_str_in_output")
    for key in boolean_keys:
        if key in raw:
            payload[key] = bool(raw.get(key))
    if "stop" in raw:
        stop_val = raw.get("stop")
        if isinstance(stop_val, str):
            stops = [x.strip() for x in stop_val.replace("\r", "").split("\n") if x.strip()]
            if len(stops) == 1 and "," in stops[0]:
                stops = [x.strip() for x in stops[0].split(",") if x.strip()]
            if stops:
                payload["stop"] = stops if len(stops) > 1 else stops[0]
        elif isinstance(stop_val, list):
            stops = [str(x) for x in stop_val if str(x)]
            if stops:
                payload["stop"] = stops
    ctk = {}
    if "enable_thinking" in raw:
        ctk["enable_thinking"] = bool(raw.get("enable_thinking"))
    if "preserve_thinking" in raw:
        ctk["preserve_thinking"] = bool(raw.get("preserve_thinking"))
        if ctk["preserve_thinking"]:
            ctk["enable_thinking"] = True
    if ctk:
        payload["chat_template_kwargs"] = ctk
    desc = str(raw.get("description") or "").strip()
    system_prompt = str(raw.get("system_prompt") or "").strip()
    return {"params": payload, "description": desc, "system_prompt": system_prompt}

def read_custom_presets():
    try:
        with open(CUSTOM_PRESETS_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
        if not isinstance(data, dict):
            return {}
        clean = {}
        for name, preset in data.items():
            try:
                clean_name = _safe_preset_name(name)
            except Exception:
                continue
            if isinstance(preset, dict) and "params" in preset:
                params = preset.get("params") if isinstance(preset.get("params"), dict) else {}
                desc = str(preset.get("description") or "")
                system_prompt = str(preset.get("system_prompt") or "")
            elif isinstance(preset, dict):
                params = preset
                desc = ""
                system_prompt = ""
            else:
                continue
            clean[clean_name] = {"params": params, "description": desc, "system_prompt": system_prompt}
        return clean
    except Exception:
        return {}

def write_custom_presets(data):
    write_json_atomic_if_changed(CUSTOM_PRESETS_FILE, data, indent=2, sort_keys=True)
    return data

def get_all_presets():
    all_presets = {k: dict(v) for k, v in PRESETS.items()}
    for name, item in read_custom_presets().items():
        params = item.get("params") if isinstance(item, dict) else None
        if isinstance(params, dict):
            all_presets[name] = params
    return all_presets

def preset_system_prompt(name):
    key = str(name or "").strip()
    if not key:
        return ""
    if key in PRESETS:
        return ""
    item = read_custom_presets().get(key) or {}
    return str(item.get("system_prompt") or "")

def preset_catalog():
    defaults = []
    for name in PRESETS:
        defaults.append({"name": name, "endpoint": f"/v1/{name}", "endpoint_alt": f"/{name}", "locked": True, "params": PRESETS[name], "description": DEFAULT_PRESET_DESCRIPTIONS.get(name, "Default preset"), "system_prompt": ""})
    customs = []
    for name, item in sorted(read_custom_presets().items()):
        customs.append({"name": name, "endpoint": f"/v1/{name}", "endpoint_alt": f"/{name}", "locked": False, "params": item.get("params", {}), "description": item.get("description", ""), "system_prompt": item.get("system_prompt", "")})
    return {"defaults": defaults, "custom": customs, "length_prefixes": LENGTH_PREFIXES}

def save_custom_preset(name, preset_data):
    name = _safe_preset_name(name)
    custom = read_custom_presets()
    custom[name] = sanitize_custom_preset(preset_data)
    write_custom_presets(custom)
    log_control(f"PRESET saved name={name}")
    return preset_catalog()

def delete_custom_preset(name):
    name = _safe_preset_name(name)
    custom = read_custom_presets()
    if name not in custom:
        raise ValueError("Custom preset not found")
    del custom[name]
    write_custom_presets(custom)
    log_control(f"PRESET deleted name={name}")
    return preset_catalog()

def compose_cmd():
    try:
        return shlex.split(COMPOSE_BIN)
    except Exception:
        return ["docker", "compose"]

def detect_gpu_count_runtime(force=False, max_age=15):
    now = time.time()
    with slow_cache_lock:
        cached_value = int(gpu_count_cache.get("value") or 0)
        cached_time = float(gpu_count_cache.get("time") or 0.0)
    if not force and cached_time and now - cached_time < max(1.0, float(max_age or 15)):
        return cached_value
    if not shutil.which("nvidia-smi"):
        return cached_value
    value = cached_value
    try:
        out = subprocess.check_output(["nvidia-smi", "--query-gpu=index", "--format=csv,noheader,nounits"], text=True, stderr=subprocess.DEVNULL, timeout=1.5)
        value = sum(1 for line in out.splitlines() if line.strip())
    except Exception:
        try:
            out = subprocess.check_output(["nvidia-smi", "-L"], text=True, stderr=subprocess.DEVNULL, timeout=1.5)
            value = sum(1 for line in out.splitlines() if line.strip().startswith("GPU "))
        except Exception:
            return cached_value
    with slow_cache_lock:
        gpu_count_cache["value"] = int(value)
        gpu_count_cache["time"] = time.time()
    return int(value)

def gpu_pairing_default_enabled(gpu_count=None):
    try:
        count = int(gpu_count if gpu_count is not None else detect_gpu_count_runtime())
    except Exception:
        count = 0
    return count != 2

def gpu_pairing_enabled(cfg=None, gpu_count=None):
    config = cfg if isinstance(cfg, dict) else read_server_config()
    try:
        count = int(gpu_count if gpu_count is not None else detect_gpu_count_runtime())
    except Exception:
        count = 0
    if isinstance(config, dict) and "gpu_pairing_enabled" in config:
        return bool(config.get("gpu_pairing_enabled"))
    return gpu_pairing_default_enabled(count)

def default_instances_config():
    load_runtime_inventory()
    count = detect_gpu_count_runtime()
    rows = []
    single_mode = default_single_mode_selector()
    dual_mode = default_dual_mode_selector()
    for gpu_idx in range(count):
        rows.append({
            "id": f"GPU{gpu_idx}",
            "kind": "single",
            "gpu_indices": [gpu_idx],
            "mode": single_mode,
            "enabled": gpu_idx == 0 and single_mode in SINGLE_GPU_MODES,
            "port": INSTANCE_PORT_BASE + gpu_idx,
        })
    if count == 2 and gpu_pairing_enabled(gpu_count=count):
        rows.append({
            "id": "PAIR0_1",
            "kind": "dual",
            "gpu_indices": [0, 1],
            "mode": dual_mode,
            "enabled": dual_mode in DUAL_GPU_MODES,
            "port": PAIR_INSTANCE_PORT_BASE,
        })
    return rows

def normalize_pair_indices(value):
    if not isinstance(value, (list, tuple)):
        return None
    try:
        items = sorted({int(x) for x in value})
    except Exception:
        return None
    if len(items) != 2 or any(x < 0 for x in items):
        return None
    return items

def pair_instance_id(indices):
    pair = normalize_pair_indices(indices)
    if not pair:
        raise ValueError("Dual preset pairs must contain exactly two distinct GPU indices")
    return f"PAIR{pair[0]}_{pair[1]}"

def parse_instance_identifier(instance_id):
    raw = str(instance_id or "").strip().upper()
    if re.fullmatch(r"GPU[0-9]+", raw):
        idx = int(raw[3:])
        return {"id": raw, "kind": "single", "gpu_indices": [idx], "gpu_index": idx}
    match = re.fullmatch(r"PAIR([0-9]+)_([0-9]+)", raw)
    if match:
        pair = normalize_pair_indices([int(match.group(1)), int(match.group(2))])
        if not pair:
            return None
        return {"id": pair_instance_id(pair), "kind": "dual", "gpu_indices": pair, "gpu_index": pair[0]}
    return None

def instance_default_port(kind, gpu_indices):
    if kind == "dual":
        pair = normalize_pair_indices(gpu_indices)
        if not pair:
            return PAIR_INSTANCE_PORT_BASE
        return PAIR_INSTANCE_PORT_BASE + (pair[0] * 100) + pair[1]
    idx = int((gpu_indices or [0])[0])
    return INSTANCE_PORT_BASE + idx

def normalize_instance(raw, used_ids=None, used_ports=None, substitutions=None):
    load_runtime_inventory()
    used_ids = used_ids if isinstance(used_ids, set) else set()
    used_ports = used_ports if isinstance(used_ports, set) else set()
    substitutions = substitutions if isinstance(substitutions, list) else None
    if not isinstance(raw, dict):
        return None
    parsed = parse_instance_identifier(raw.get("id"))
    if not parsed:
        gpu_indices = normalize_pair_indices(raw.get("gpu_indices"))
        if gpu_indices:
            parsed = parse_instance_identifier(pair_instance_id(gpu_indices))
        elif raw.get("gpu_index") not in ("", None, False):
            try:
                parsed = parse_instance_identifier(f"GPU{int(raw.get('gpu_index'))}")
            except Exception:
                parsed = None
    if not parsed:
        return None
    instance_id = parsed["id"]
    kind = parsed["kind"]
    gpu_indices = list(parsed["gpu_indices"])
    gpu_index = int(gpu_indices[0])
    raw_mode = str(raw.get("mode") or (default_dual_mode_selector() if kind == "dual" else default_single_mode_selector())).strip()
    mode = canonical_mode_selector(raw_mode)
    valid_modes = DUAL_GPU_MODES if kind == "dual" else SINGLE_GPU_MODES
    if mode not in valid_modes or not resolve_variant_spec(mode):
        preferred_model = ""
        preferred_spec = resolve_variant_spec(raw_mode)
        if preferred_spec:
            preferred_model = str(preferred_spec.get("model_id") or "")
        fallback_variant = _choose_fallback_variant(kind, preferred_model_id=preferred_model, category=("dual" if kind == "dual" else "single"))
        fallback_mode = _mode_selector_for_variant(fallback_variant) if fallback_variant else (default_dual_mode_selector() if kind == "dual" else default_single_mode_selector())
        if substitutions is not None and raw_mode and raw_mode != fallback_mode:
            substitutions.append({
                "instance_id": instance_id,
                "from_mode": raw_mode,
                "to_mode": fallback_mode,
            })
        mode = fallback_mode
    try:
        port = int(raw.get("port"))
    except Exception:
        port = instance_default_port(kind, gpu_indices)
    if port < 1024:
        port = instance_default_port(kind, gpu_indices)
    if instance_id in used_ids:
        return None
    if port in used_ports:
        port = instance_default_port(kind, gpu_indices)
        while port in used_ports:
            port += 1
    used_ids.add(instance_id)
    used_ports.add(port)
    return {
        "id": instance_id,
        "kind": kind,
        "gpu_indices": gpu_indices,
        "gpu_index": gpu_index,
        "mode": mode,
        "enabled": bool(raw.get("enabled", False)),
        "port": port,
    }

def normalize_instances(rows, substitutions=None):
    if not isinstance(rows, list):
        rows = []
    used_ids = set()
    used_ports = set()
    clean = []
    for row in rows:
        inst = normalize_instance(row, used_ids, used_ports, substitutions=substitutions)
        if inst is not None:
            clean.append(inst)
    count = detect_gpu_count_runtime()
    existing_ids = {inst["id"] for inst in clean}
    for gpu_idx in range(count):
        iid = f"GPU{gpu_idx}"
        if iid in existing_ids:
            continue
        inst = normalize_instance({"id": iid, "kind": "single", "gpu_indices": [gpu_idx], "mode": default_single_mode_selector(), "enabled": False, "port": INSTANCE_PORT_BASE + gpu_idx}, used_ids, used_ports, substitutions=substitutions)
        if inst is not None:
            clean.append(inst)
            existing_ids.add(inst["id"])
    if count == 2 and gpu_pairing_enabled(gpu_count=count) and "PAIR0_1" not in existing_ids:
        default_dual_mode = default_dual_mode_selector()
        inst = normalize_instance({"id": "PAIR0_1", "kind": "dual", "gpu_indices": [0, 1], "mode": default_dual_mode, "enabled": default_dual_mode in DUAL_GPU_MODES, "port": PAIR_INSTANCE_PORT_BASE}, used_ids, used_ports, substitutions=substitutions)
        if inst is not None:
            clean.append(inst)
    if not clean:
        clean = default_instances_config()
    clean.sort(key=lambda d: (d.get("gpu_index", 9999), d.get("id", "")))
    return clean

def read_instances_config():
    load_runtime_inventory()
    substitutions = []
    try:
        with open(INSTANCES_CONFIG_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
        rows = normalize_instances(data, substitutions=substitutions)
    except Exception:
        rows = normalize_instances([], substitutions=substitutions)
    count = detect_gpu_count_runtime()
    changed = bool(substitutions)
    if count == 2 and not gpu_pairing_enabled(gpu_count=count):
        filtered = [row for row in rows if row.get("kind") != "dual"]
        changed = len(filtered) != len(rows)
        rows = filtered
    if changed or not os.path.exists(INSTANCES_CONFIG_FILE):
        write_instances_config(rows)
    for item in substitutions:
        log_audit(
            "instance_mode_substituted",
            instance=item.get("instance_id"),
            from_mode=item.get("from_mode"),
            to_mode=item.get("to_mode"),
        )
    return rows

def write_instances_config(rows):
    rows = normalize_instances(rows)
    write_json_atomic_if_changed(INSTANCES_CONFIG_FILE, rows, indent=2)
    return rows

def instance_container_name(instance):
    return f"club3090-{instance['id'].lower()}-{instance['mode'].replace('/', '-')}"

def instance_project_name(instance):
    return f"club3090-{instance['id'].lower()}"

def instance_paths(instance):
    base = os.path.join(INSTANCES_DIR, instance["id"])
    return {
        "dir": base,
        "env": os.path.join(base, ".env"),
        "override": os.path.join(base, "docker-compose.override.generated.yml"),
    }

def get_instance(instance_id):
    iid = str(instance_id or "").strip().upper()
    for inst in read_instances_config():
        if inst["id"] == iid:
            return inst
    return None

def instance_ready_url(instance):
    return f"http://127.0.0.1:{int(instance['port'])}/v1/models"

def instance_variant_spec(instance):
    spec = resolve_variant_spec(instance["mode"])
    if not spec:
        raise ValueError(f"Unsupported instance mode: {instance['mode']}")
    return spec

def write_instance_artifacts(instance):
    spec = instance_variant_spec(instance)
    paths = instance_paths(instance)
    os.makedirs(paths["dir"], exist_ok=True)
    os.makedirs(os.path.join(paths["dir"], "cache"), exist_ok=True)
    visible_devices = ",".join(str(int(idx)) for idx in (instance.get("gpu_indices") or [instance["gpu_index"]]))
    cache_root = os.path.join(paths["dir"], "cache")
    repo_env = _load_repo_env_map()
    with open(paths["env"], "w", encoding="utf-8") as f:
        for key in sorted(repo_env):
            if key in {"PORT", "CUDA_VISIBLE_DEVICES", "NVIDIA_VISIBLE_DEVICES", "MODEL_DIR"}:
                continue
            value = str(repo_env.get(key) or "").replace("\r", " ").replace("\n", " ")
            f.write(f"{key}={value}\n")
        f.write(f"MODEL_DIR={_resolve_variant_model_dir_root(spec)}\n")
        f.write(f"PORT={int(instance['port'])}\n")
        f.write(f"CUDA_VISIBLE_DEVICES={visible_devices}\n")
        f.write(f"NVIDIA_VISIBLE_DEVICES={visible_devices}\n")
    override = (
        "services:\n"
        f"  {spec['service_name']}:\n"
        f"    container_name: {instance_container_name(instance)}\n"
        "    environment:\n"
        f"      CUDA_VISIBLE_DEVICES: \"{visible_devices}\"\n"
        f"      NVIDIA_VISIBLE_DEVICES: \"{visible_devices}\"\n"
        "      VLLM_CACHE_ROOT: /root/.cache/club3090-instance/vllm\n"
        "      TORCHINDUCTOR_CACHE_DIR: /root/.cache/club3090-instance/torchinductor\n"
        "      TRITON_CACHE_DIR: /root/.cache/club3090-instance/triton\n"
        "    volumes:\n"
        f"      - {cache_root}:/root/.cache/club3090-instance\n"
        "    labels:\n"
        f"      club3090.instance_id: \"{instance['id']}\"\n"
        f"      club3090.kind: \"{instance['kind']}\"\n"
        f"      club3090.mode: \"{canonical_mode_selector(instance['mode'])}\"\n"
        f"      club3090.mode_selector: \"{canonical_mode_selector(instance['mode'])}\"\n"
        f"      club3090.variant_id: \"{spec['variant_id']}\"\n"
        f"      club3090.model_id: \"{spec['model_id']}\"\n"
        f"      club3090.gpu_indices: \"{','.join(str(int(idx)) for idx in instance.get('gpu_indices') or [instance['gpu_index']])}\"\n"
    )
    with open(paths["override"], "w", encoding="utf-8") as f:
        f.write(override)
    return paths

def instance_compose_args(instance):
    spec = instance_variant_spec(instance)
    paths = write_instance_artifacts(instance)
    compose_file = str(spec.get("compose_abs_path") or "").strip()
    compose_project_dir = str(spec.get("compose_project_dir_abs_path") or "").strip() or os.path.dirname(compose_file)
    if not os.path.exists(compose_file):
        raise RuntimeError(f"Compose file missing for {instance['mode']}: {compose_file}")
    return compose_cmd() + ["--project-directory", compose_project_dir, "-p", instance_project_name(instance), "--env-file", paths["env"], "-f", compose_file, "-f", paths["override"]]


def instance_compose_project_dir(instance):
    spec = instance_variant_spec(instance)
    compose_file = str(spec.get("compose_abs_path") or "").strip()
    return str(spec.get("compose_project_dir_abs_path") or "").strip() or os.path.dirname(compose_file) or CLUB3090_DIR


def instance_subprocess_env(instance):
    spec = instance_variant_spec(instance)
    env = _repo_subprocess_env()
    visible_devices = ",".join(str(int(idx)) for idx in (instance.get("gpu_indices") or [instance["gpu_index"]]))
    env["MODEL_DIR"] = _resolve_variant_model_dir_root(spec)
    env["PORT"] = str(int(instance["port"]))
    env["CUDA_VISIBLE_DEVICES"] = visible_devices
    env["NVIDIA_VISIBLE_DEVICES"] = visible_devices
    env["COMPOSE_BIN"] = COMPOSE_BIN
    return env

def start_instance(instance_id, track_switch_job=True):
    instance = get_instance(instance_id)
    if not instance:
        raise ValueError(f"Unknown instance: {instance_id}")
    try:
        spec = instance_variant_spec(instance)
        ensure_variant_install_ready(spec)
        if track_switch_job:
            _set_switch_job(
                active=True,
                status="booting",
                mode=str(instance.get("mode") or ""),
                target=str(instance.get("id") or ""),
                started_at=int(time.time()),
                finished_at=0,
                error="",
            )
        cmd = instance_compose_args(instance) + ["up", "-d"]
        rc, out = run_cmd(cmd, timeout=1800, cwd=instance_compose_project_dir(instance), env=instance_subprocess_env(instance))
        log_control(f"INSTANCE start {instance['id']} mode={instance['mode']} rc={rc}: {out[-4000:]}")
        if rc != 0:
            raise RuntimeError(out or f"docker compose up failed for {instance['id']}")
        wait_for_runtime_ready(
            instance_container_name(instance),
            instance_ready_url(instance),
            timeout=900,
        )
        clear_switch_failure(instance["mode"])
        if track_switch_job:
            _set_switch_job(
                active=False,
                status="success",
                mode=str(instance.get("mode") or ""),
                target=str(instance.get("id") or ""),
                finished_at=int(time.time()),
                error="",
            )
        return {"instance": instance, "output": out[-4000:]}
    except Exception as e:
        write_switch_failure(instance["mode"], e)
        if track_switch_job:
            _set_switch_job(
                active=False,
                status="failed",
                mode=str(instance.get("mode") or ""),
                target=str(instance.get("id") or ""),
                finished_at=int(time.time()),
                error=str(e)[-12000:],
            )
        raise

def stop_instance(instance_id):
    instance = get_instance(instance_id)
    if not instance:
        raise ValueError(f"Unknown instance: {instance_id}")
    cmd = instance_compose_args(instance) + ["down"]
    rc, out = run_cmd(cmd, timeout=600, cwd=instance_compose_project_dir(instance), env=instance_subprocess_env(instance))
    if rc != 0:
        rc2, out2 = run_cmd(["docker", "rm", "-f", instance_container_name(instance)], timeout=120)
        out = (out or "") + f"\nmanual rm rc={rc2} {out2}"
    log_control(f"INSTANCE stop {instance['id']} rc={rc}: {out[-4000:]}")
    return rc, out[-4000:]


def _configured_scope_targets_for_mode(instance_id="", mode=""):
    selector = canonical_mode_selector(mode) if mode else ""
    target_id = str(instance_id or "").strip().upper()
    if not selector or target_id != "GLOBAL":
        return []
    spec = resolve_variant_spec(selector) or {}
    scope_kind = str(spec.get("scope_kind") or "")
    rows = read_instances_config()
    if scope_kind == "single":
        return [dict(row) for row in rows if row.get("kind") == "single" and canonical_mode_selector(row.get("mode")) == selector]
    if scope_kind == "dual":
        gpu_count = detect_gpu_count_runtime()
        if gpu_count == 2 and not gpu_pairing_enabled(gpu_count=gpu_count):
            return [{"id": "GLOBAL", "kind": "dual", "mode": selector}]
        return [dict(row) for row in rows if row.get("kind") == "dual" and canonical_mode_selector(row.get("mode")) == selector]
    if scope_kind in {"multi", "global_only"}:
        return [{"id": "GLOBAL", "kind": "global", "mode": selector}]
    return []


def stop_runtime_scope(instance_id=None, mode=None):
    selector = canonical_mode_selector(mode) if mode else ""
    target_id = str(instance_id or "").strip().upper()
    if is_legacy_global_instance_id(target_id):
        return stop_legacy_global_instance()
    if target_id and target_id != "GLOBAL":
        return stop_instance(target_id)
    matching = []
    if selector:
        matching = [
            dict(row)
            for row in running_runtime_rows(instances_snapshot(), legacy_global_instance_snapshot())
            if canonical_mode_selector(row.get("mode")) == selector
        ]
    elif target_id == "GLOBAL":
        matching = [dict(row) for row in running_runtime_rows(instances_snapshot(), legacy_global_instance_snapshot())]
    if not matching:
        matching = _configured_scope_targets_for_mode(target_id, selector)
    outputs = []
    rc = 0
    seen = set()
    for row in matching:
        row_id = str(row.get("id") or "").strip().upper()
        if not row_id or row_id in seen:
            continue
        seen.add(row_id)
        if is_legacy_global_instance_id(row_id):
            item_rc, item_out = stop_legacy_global_instance()
        elif row_id == "GLOBAL":
            item_rc, item_out = stop_global_mode()
        else:
            item_rc, item_out = stop_instance(row_id)
        rc = max(rc, int(item_rc or 0))
        outputs.append(f"{row_id}: {str(item_out or '').strip()}")
    if not outputs:
        return 0, "No matching runtime containers were active."
    return rc, "\n".join([line for line in outputs if line]).strip()[-12000:]

def update_instance(instance_id, mode=None, enabled=None):
    rows = read_instances_config()
    updated = None
    for row in rows:
        if row["id"] != str(instance_id or "").strip().upper():
            continue
        if mode is not None:
            mode = canonical_mode_selector(mode)
            valid_modes = DUAL_GPU_MODES if row.get("kind") == "dual" else SINGLE_GPU_MODES
            if mode not in valid_modes:
                raise ValueError("Selected preset type does not match this instance")
            row["mode"] = mode
        if enabled is not None:
            row["enabled"] = bool(enabled)
        updated = dict(row)
        break
    if updated is None:
        raise ValueError(f"Unknown instance: {instance_id}")
    write_instances_config(rows)
    return get_instance(updated["id"])

def save_pair_instance(gpu_indices, mode=None, enabled=None):
    if not gpu_pairing_enabled(gpu_count=detect_gpu_count_runtime()):
        raise ValueError("Enable GPU pairing before creating pair groups")
    pair = normalize_pair_indices(gpu_indices)
    if not pair:
        raise ValueError("Select exactly two distinct GPUs for a dual preset pair")
    pair_id = pair_instance_id(pair)
    rows = read_instances_config()
    existing = None
    for row in rows:
        if row["id"] == pair_id:
            existing = row
            break
    if existing is None:
        selected_mode = canonical_mode_selector(mode) if mode else default_dual_mode_selector()
        rows.append({
            "id": pair_id,
            "kind": "dual",
            "gpu_indices": pair,
            "mode": selected_mode if selected_mode in DUAL_GPU_MODES else default_dual_mode_selector(),
            "enabled": bool(enabled),
            "port": instance_default_port("dual", pair),
        })
    else:
        if mode is not None:
            mode = canonical_mode_selector(mode)
            if mode not in DUAL_GPU_MODES:
                raise ValueError("Dual GPU pairs must use a dual preset")
            existing["mode"] = mode
        if enabled is not None:
            existing["enabled"] = bool(enabled)
    write_instances_config(rows)
    return get_instance(pair_id)

def delete_pair_instance(instance_id):
    parsed = parse_instance_identifier(instance_id)
    if not parsed or parsed.get("kind") != "dual":
        raise ValueError("Only dual GPU pair groups can be removed")
    rows = read_instances_config()
    remaining = [row for row in rows if row["id"] != parsed["id"]]
    if len(remaining) == len(rows):
        raise ValueError("Pair group not found")
    try:
        stop_instance(parsed["id"])
    except Exception:
        pass
    write_instances_config(remaining)
    return instances_snapshot()

def mode_default_port(mode, default=0):
    spec = resolve_variant_spec(mode)
    try:
        port = int((spec or {}).get("default_port") or 0)
    except Exception:
        port = 0
    return port or int(default or 0)


def detect_legacy_dual_mode():
    load_runtime_inventory()
    if detect_gpu_count_runtime() != 2:
        return None
    file_mode = None
    try:
        file_mode = canonical_mode_selector(open(ACTIVE_MODE_FILE, "r", encoding="utf-8").read().strip())
    except Exception:
        file_mode = None
    if file_mode in DUAL_GPU_MODES and port_open(mode_default_port(file_mode, PAIR_INSTANCE_PORT_BASE), timeout=0.08):
        return file_mode
    open_dual = [mode for mode in dict.fromkeys(DUAL_GPU_MODES) if port_open(mode_default_port(mode, PAIR_INSTANCE_PORT_BASE), timeout=0.08)]
    if len(open_dual) == 1:
        return open_dual[0]
    return None

def instance_uses_legacy_dual_runtime(instance):
    return bool(
        instance
        and instance.get("kind") == "dual"
        and instance.get("id") == "PAIR0_1"
        and detect_gpu_count_runtime() == 2
        and not gpu_pairing_enabled(gpu_count=2)
    )

def visible_instances(rows=None):
    items = list(rows if isinstance(rows, list) else read_instances_config())
    if gpu_pairing_enabled(gpu_count=detect_gpu_count_runtime()):
        return items
    return [inst for inst in items if inst.get("kind") != "dual"]

def instance_runtime_mode(instance):
    mode = str((instance or {}).get("mode") or "")
    if instance_uses_legacy_dual_runtime(instance):
        legacy_mode = detect_legacy_dual_mode()
        if legacy_mode in DUAL_GPU_MODES:
            return legacy_mode
    return mode

def instance_runtime_port(instance):
    if instance_uses_legacy_dual_runtime(instance):
        mode = instance_runtime_mode(instance)
        return int(mode_default_port(mode, (instance or {}).get("port") or PAIR_INSTANCE_PORT_BASE))
    return int((instance or {}).get("port") or 0)

def instance_running(instance):
    return port_open(instance_runtime_port(instance), timeout=0.08)

def legacy_runtime_container_name():
    names = vllm_container_names(all_containers=False)
    if not names:
        return ""
    active_spec = resolve_variant_spec(active_mode())
    active_name = str((active_spec or {}).get("container_name") or "")
    if active_name and active_name in names:
        return active_name
    preferred = [name for name in names if "pair0_1" not in name.lower()]
    return preferred[0] if preferred else names[0]

def instance_runtime_container_name(instance):
    if instance_uses_legacy_dual_runtime(instance):
        return legacy_runtime_container_name()
    return instance_container_name(instance)

def legacy_global_target_mode():
    legacy_mode = detect_legacy_dual_mode()
    if legacy_mode in DUAL_GPU_MODES:
        return legacy_mode
    for candidate in (
        read_active_mode_file(),
        read_last_good_mode_file(),
        DEFAULT_MODE,
        default_dual_mode_selector(),
    ):
        if candidate in DUAL_GPU_MODES:
            return canonical_mode_selector(candidate)
    return default_dual_mode_selector()

def legacy_global_disable_mode():
    for row in read_instances_config():
        if row.get("kind") != "single":
            continue
        mode = str(row.get("mode") or "")
        if row.get("enabled") and mode in SINGLE_GPU_MODES:
            return mode
    return default_single_mode_selector()

def legacy_global_enabled():
    file_mode = read_active_mode_file()
    legacy_mode = detect_legacy_dual_mode()
    if file_mode:
        return file_mode in DUAL_GPU_MODES
    return legacy_mode in DUAL_GPU_MODES

def is_legacy_global_instance_id(instance_id):
    return (
        detect_gpu_count_runtime() == 2
        and not gpu_pairing_enabled(gpu_count=2)
        and str(instance_id or "").strip().upper() == "GLOBAL"
    )

def start_legacy_global_instance():
    mode = legacy_global_target_mode()
    output = run_switch(mode)
    return {"instance": legacy_global_instance_snapshot(), "output": output[-4000:]}

def stop_legacy_global_instance():
    out = cleanup_vllm_containers()
    log_control(f"INSTANCE legacy global stop rc=0: {out}")
    return 0, str(out or "")[-4000:]

def set_legacy_global_enabled(enabled):
    if bool(enabled):
        write_active_mode(legacy_global_target_mode())
    else:
        write_active_mode(legacy_global_disable_mode())
    return legacy_global_instance_snapshot()

def primary_instance():
    rows = visible_instances(read_instances_config())
    if not rows:
        return None
    if detect_gpu_count_runtime() == 2 and not gpu_pairing_enabled(gpu_count=2) and detect_legacy_dual_mode():
        return None
    running = [inst for inst in rows if instance_running(inst)]
    if running:
        return sorted(running, key=lambda d: (len(d.get("gpu_indices") or [d["gpu_index"]]), d["gpu_index"], d["id"]))[0]
    enabled = [inst for inst in rows if inst.get("enabled")]
    if enabled:
        return sorted(enabled, key=lambda d: (len(d.get("gpu_indices") or [d["gpu_index"]]), d["gpu_index"], d["id"]))[0]
    return None

def boot_enabled_instances():
    outputs = []
    rows = visible_instances(read_instances_config())
    file_mode = read_active_mode_file()
    if detect_gpu_count_runtime() == 2 and not gpu_pairing_enabled(gpu_count=2):
        if file_mode in DUAL_GPU_MODES:
            try:
                result = start_legacy_global_instance()
                outputs.append(f"legacy dual started from active mode {file_mode}: {(result.get('output') or '')[-800:]}")
                log_control("BOOT instances: " + " || ".join(outputs))
                return outputs
            except Exception as e:
                outputs.append(f"legacy dual fallback failed: {e}")
    for inst in rows:
        if not inst.get("enabled"):
            continue
        try:
            result = start_instance(inst["id"])
            outputs.append(f"{inst['id']} started: {(result.get('output') or '')[-800:]}")
        except Exception as e:
            outputs.append(f"{inst['id']} failed: {e}")
    if not outputs and file_mode:
        spec = resolve_variant_spec(file_mode)
        if spec and str(spec.get("scope_kind") or "") in {"multi", "global_only"}:
            try:
                result = run_switch(file_mode)
                outputs.append(f"global runtime started from active mode {file_mode}: {result[-800:]}")
            except Exception as e:
                outputs.append(f"global runtime failed: {e}")
    log_control("BOOT instances: " + " || ".join(outputs))
    return outputs

def mode_gpu_indices(mode, gpu_count=None):
    if mode not in DUAL_GPU_MODES:
        return []
    try:
        count = int(gpu_count if gpu_count is not None else detect_gpu_count_runtime())
    except Exception:
        count = 0
    return [idx for idx in range(max(count, 0))][:2]

def running_dual_mode():
    rows = running_dual_instances()
    if not rows:
        return None
    rows.sort(key=lambda d: (d["gpu_indices"], d["id"]))
    return rows[0]["mode"]

def running_dual_instances():
    rows = []
    legacy = legacy_global_instance_snapshot()
    if legacy and legacy.get("running"):
        rows.append(dict(legacy))
    for inst in visible_instances(read_instances_config()):
        if inst.get("kind") != "dual" or not instance_running(inst):
            continue
        row = dict(inst)
        row["mode"] = instance_runtime_mode(inst)
        rows.append(row)
    rows.sort(key=lambda d: (d.get("gpu_indices") or [], d["id"]))
    return rows

def running_dual_instance_snapshots():
    snaps = []
    for inst in running_dual_instances():
        snaps.append(dict(inst) if "proxy_prefix" in inst else instance_snapshot(inst))
    return snaps

def stop_overlapping_instances(indices, exclude_ids=None):
    wanted = {int(idx) for idx in (indices or [])}
    excluded = {str(x or "").strip().upper() for x in (exclude_ids or [])}
    results = []
    legacy = legacy_global_instance_snapshot()
    if legacy and legacy.get("running") and legacy.get("id") not in excluded:
        legacy_indices = {int(idx) for idx in (legacy.get("gpu_indices") or [])}
        if wanted.intersection(legacy_indices):
            rc, out = stop_legacy_global_instance()
            results.append({"id": legacy["id"], "rc": rc, "output": out[-1200:]})
    for inst in read_instances_config():
        if inst["id"] in excluded:
            continue
        inst_indices = {int(idx) for idx in (inst.get("gpu_indices") or [inst.get("gpu_index", -1)])}
        if not wanted.intersection(inst_indices):
            continue
        if not instance_running(inst):
            continue
        rc, out = stop_instance(inst["id"])
        results.append({"id": inst["id"], "rc": rc, "output": out[-1200:]})
    return results

def stop_global_mode():
    stopped = stop_overlapping_instances([idx for inst in running_dual_instances() for idx in inst.get("gpu_indices") or []])
    return 0, "\n".join((row.get("output") or "") for row in stopped)[-4000:]

def stop_instances_for_gpu_indices(indices):
    return stop_overlapping_instances(indices)

def instance_assignment(instance, dual_mode=None):
    gpu_indices = [int(idx) for idx in (instance.get("gpu_indices") or [instance.get("gpu_index", -1)])]
    if instance.get("kind") == "dual":
        runtime_mode = instance_runtime_mode(instance)
        if instance_running(instance):
            return {
                "scope": "pair",
                "mode": runtime_mode,
                "text": f"GPUs {', '.join(str(idx) for idx in gpu_indices)} are running the dual preset {runtime_mode}",
                "override": False,
            }
        return {
            "scope": "pair",
            "mode": runtime_mode,
            "text": f"GPUs {', '.join(str(idx) for idx in gpu_indices)} are reserved for dual preset {runtime_mode}",
            "override": False,
        }
    for pair in running_dual_instances():
        pair_indices = {int(idx) for idx in pair.get("gpu_indices") or []}
        if set(gpu_indices).intersection(pair_indices):
            return {
                "scope": "pair",
                "mode": pair["mode"],
                "text": f"GPU {gpu_indices[0]} is currently occupied by dual pair {pair['id']} running {pair['mode']}",
                "override": True,
            }
    mode = str(instance.get("mode") or "vllm/default")
    return {
        "scope": "per-gpu",
        "mode": mode,
        "text": f"GPU {gpu_indices[0]} is assigned to the per-GPU preset {mode}",
        "override": False,
    }

def instance_snapshot(instance):
    container = instance_runtime_container_name(instance)
    runtime_mode = instance_runtime_mode(instance)
    runtime_port = instance_runtime_port(instance)
    running = port_open(runtime_port, timeout=0.1)
    assigned = instance_assignment(instance)
    return {
        "id": instance["id"],
        "kind": instance.get("kind", "single"),
        "gpu_index": instance["gpu_index"],
        "gpu_indices": list(instance.get("gpu_indices") or [instance["gpu_index"]]),
        "mode": runtime_mode,
        "enabled": bool(instance.get("enabled")),
        "port": runtime_port,
        "container": container,
        "running": running,
        "ready_url": f"http://127.0.0.1:{runtime_port}/v1/models",
        "proxy_prefix": f"/{instance['id']}",
        "display_name": instance["id"] if instance.get("kind") != "dual" else f"Pair {', '.join(str(idx) for idx in instance.get('gpu_indices') or [])}",
        "assignment_scope": assigned["scope"],
        "assignment_mode": assigned["mode"],
        "assignment_text": assigned["text"],
        "overrides_dual_mode": bool(assigned["override"]),
    }

def instances_snapshot():
    return [instance_snapshot(inst) for inst in visible_instances(read_instances_config())]

def legacy_global_instance_snapshot():
    if detect_gpu_count_runtime() != 2 or gpu_pairing_enabled(gpu_count=2):
        return None
    mode = legacy_global_target_mode()
    running_mode = detect_legacy_dual_mode()
    runtime_mode = running_mode if running_mode in DUAL_GPU_MODES else mode
    runtime_port = int(mode_default_port(runtime_mode, PAIR_INSTANCE_PORT_BASE))
    running = bool(running_mode in DUAL_GPU_MODES and port_open(runtime_port, timeout=0.08))
    return {
        "id": "GLOBAL",
        "kind": "dual",
        "gpu_index": 0,
        "gpu_indices": [0, 1],
        "mode": runtime_mode,
        "enabled": legacy_global_enabled(),
        "port": runtime_port,
        "container": legacy_runtime_container_name() if running else "",
        "running": running,
        "ready_url": f"http://127.0.0.1:{runtime_port}/v1/models",
        "proxy_prefix": "/v1",
        "display_name": "Global Dual",
        "assignment_scope": "global",
        "assignment_mode": runtime_mode,
        "assignment_text": f"Global dual runtime uses GPUs 0, 1 with preset {runtime_mode}",
        "overrides_dual_mode": False,
    }

def ready_url_for_mode(mode):
    return f"http://localhost:{mode_default_port(mode, PROXY_PORT)}/v1/models"

def write_active_mode(mode):
    selector = canonical_mode_selector(mode)
    os.makedirs(os.path.dirname(ACTIVE_MODE_FILE), exist_ok=True)
    with open(ACTIVE_MODE_FILE, "w", encoding="utf-8") as f:
        f.write(selector)


def clear_active_mode():
    try:
        os.remove(ACTIVE_MODE_FILE)
    except FileNotFoundError:
        pass
    except Exception:
        pass

def read_active_mode_file():
    try:
        mode = canonical_mode_selector(open(ACTIVE_MODE_FILE, "r", encoding="utf-8").read().strip())
        return mode if resolve_variant_spec(mode) else None
    except Exception:
        return None

def write_last_good_mode(mode):
    selector = canonical_mode_selector(mode)
    if resolve_variant_spec(selector):
        try:
            with open(LAST_GOOD_MODE_FILE, "w", encoding="utf-8") as f:
                f.write(selector)
        except Exception:
            pass

def read_last_good_mode_file():
    try:
        mode = canonical_mode_selector(open(LAST_GOOD_MODE_FILE, "r", encoding="utf-8").read().strip())
        return mode if resolve_variant_spec(mode) else None
    except Exception:
        return None

def port_open(port, timeout=0.25):
    # TCP-only readiness check. Do not call /health here; vLLM logs those.
    try:
        with socket.create_connection(("127.0.0.1", int(port)), timeout=timeout):
            return True
    except Exception:
        return False

def detected_mode():
    load_runtime_inventory()
    primary = primary_instance()
    if primary:
        return primary["mode"]
    # Source of truth is the mode selected by this controller/switch.sh.
    # If the file is stale, use a TCP-only port scan as a fallback. Never call /health.
    file_mode = read_active_mode_file()
    known_modes = list(dict.fromkeys(list(SINGLE_GPU_MODES) + list(DUAL_GPU_MODES)))
    if file_mode and resolve_variant_spec(file_mode):
        if port_open(mode_default_port(file_mode, PROXY_PORT), timeout=0.08):
            return file_mode
        # During startup/switching the port may not be listening yet; keep the
        # intended mode unless another known mode is definitely listening.
        open_modes = [m for m in known_modes if port_open(mode_default_port(m, PROXY_PORT), timeout=0.08)]
        if len(open_modes) == 1:
            write_active_mode(open_modes[0])
            return open_modes[0]
        failed = read_switch_failure()
        if str(failed.get("mode") or "") == file_mode:
            fallback = read_last_good_mode_file()
            if fallback and fallback != file_mode:
                return fallback
        return file_mode
    open_modes = [m for m in known_modes if port_open(mode_default_port(m, PROXY_PORT), timeout=0.08)]
    if len(open_modes) == 1:
        write_active_mode(open_modes[0])
        return open_modes[0]
    fallback = read_last_good_mode_file() or canonical_mode_selector(DEFAULT_MODE)
    if fallback not in known_modes:
        fallback = default_single_mode_selector()
    write_active_mode(fallback)
    return fallback

def active_mode():
    return detected_mode()

def active_port():
    primary = primary_instance()
    if primary:
        return int(primary["port"])
    return mode_default_port(active_mode(), 8020)

def password_ok(username, password):
    if not username or not password or not shutil.which("pamtester"):
        return False
    key = (username, password)
    now = time.time()
    if key in auth_cache and now - auth_cache[key] < AUTH_CACHE_SECONDS:
        return True
    try:
        p = subprocess.run(["pamtester", "login", username, "authenticate"], input=password+"\n", stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, text=True, timeout=8)
        ok = p.returncode == 0
        if ok:
            auth_cache[key] = now
        return ok
    except Exception:
        return False

def check_basic_auth(header):
    if not header or not header.startswith("Basic "):
        return False
    try:
        decoded = base64.b64decode(header.split(" ",1)[1], validate=True).decode("utf-8")
        username, password = decoded.split(":", 1)
        return password_ok(username, password)
    except Exception:
        return False


def parse_cookie_header(header):
    values = {}
    for chunk in str(header or "").split(";"):
        if "=" not in chunk:
            continue
        key, value = chunk.split("=", 1)
        key = key.strip()
        if not key:
            continue
        values[key] = value.strip()
    return values


def _prune_admin_sessions(now=None):
    current = float(now or time.time())
    with admin_session_lock:
        expired = [token for token, info in admin_sessions.items() if float((info or {}).get("expires_at") or 0.0) <= current]
        for token in expired:
            admin_sessions.pop(token, None)


def create_admin_session(client_ip=""):
    now = time.time()
    token = secrets.token_urlsafe(32)
    with admin_session_lock:
        admin_sessions[token] = {
            "client": str(client_ip or ""),
            "expires_at": now + max(300, int(ADMIN_SESSION_TTL_SECONDS or 86400)),
        }
    return token


def build_admin_session_cookie(token):
    ttl = max(300, int(ADMIN_SESSION_TTL_SECONDS or 86400))
    return f"{ADMIN_SESSION_COOKIE_NAME}={token}; Path=/; HttpOnly; SameSite=Strict; Max-Age={ttl}"


def expired_admin_session_cookie():
    return f"{ADMIN_SESSION_COOKIE_NAME}=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0"


def admin_session_ok(headers, client_ip=""):
    _prune_admin_sessions()
    token = parse_cookie_header(headers.get("Cookie", "")).get(ADMIN_SESSION_COOKIE_NAME, "")
    if not token:
        return False
    now = time.time()
    with admin_session_lock:
        info = dict(admin_sessions.get(token) or {})
        if not info:
            return False
        if float(info.get("expires_at") or 0.0) <= now:
            admin_sessions.pop(token, None)
            return False
        bound_client = str(info.get("client") or "")
        if bound_client and client_ip and bound_client != client_ip:
            return False
        info["expires_at"] = now + max(300, int(ADMIN_SESSION_TTL_SECONDS or 86400))
        admin_sessions[token] = info
        return True


def should_log_admin_auth_denial(client_ip, path):
    now = time.time()
    key = (str(client_ip or ""), str(path or ""))
    with admin_auth_denial_lock:
        last = float(admin_auth_denial_state.get(key) or 0.0)
        admin_auth_denial_state[key] = now
        stale_before = now - max(60.0, float(ADMIN_AUTH_DENIAL_LOG_WINDOW_SECONDS or 30) * 4.0)
        for existing_key, existing_time in list(admin_auth_denial_state.items()):
            if float(existing_time or 0.0) < stale_before:
                admin_auth_denial_state.pop(existing_key, None)
    return now - last >= max(1.0, float(ADMIN_AUTH_DENIAL_LOG_WINDOW_SECONDS or 30))

def docker_names(all_containers=False, force=False, max_age=2.0, timeout=1.5):
    cache_key = "all" if all_containers else "running"
    now = time.time()
    with slow_cache_lock:
        cached = dict(docker_names_cache.get(cache_key) or {})
        cached_value = list(cached.get("value") or [])
        cached_time = float(cached.get("time") or 0.0)
    if not force and cached_time and now - cached_time < max(0.5, float(max_age or 2.0)):
        return cached_value
    try:
        args = ["docker", "ps"]
        if all_containers:
            args.append("-a")
        args += ["--format", "{{.Names}}"]
        out = subprocess.check_output(args, text=True, stderr=subprocess.STDOUT, timeout=max(0.5, float(timeout or 1.5)))
        names = [x.strip() for x in out.splitlines() if x.strip()]
        with slow_cache_lock:
            docker_names_cache[cache_key] = {"value": list(names), "time": time.time()}
        return names
    except Exception:
        return cached_value

def is_runtime_container_name(name):
    load_runtime_inventory()
    text = str(name or "").strip()
    lowered = text.lower()
    if not text:
        return False
    if lowered.startswith("club3090-"):
        return True
    if text in VARIANT_BY_CONTAINER or text in VARIANT_BY_SERVICE:
        return True
    return False

def vllm_container_names(all_containers=False, force=False, max_age=2.0, timeout=1.5):
    return [n for n in docker_names(all_containers=all_containers, force=force, max_age=max_age, timeout=timeout) if is_runtime_container_name(n)]

def current_container():
    primary = primary_instance()
    if primary and instance_running(primary):
        return instance_runtime_container_name(primary)
    if detect_gpu_count_runtime() == 2 and not gpu_pairing_enabled(gpu_count=2) and detect_legacy_dual_mode():
        legacy_name = legacy_runtime_container_name()
        if legacy_name:
            return legacy_name
    names = vllm_container_names(all_containers=False)
    active_spec = resolve_variant_spec(active_mode())
    active_name = str((active_spec or {}).get("container_name") or "")
    if active_name and active_name in names:
        return active_name
    return names[0] if names else ""


def sequential_global_gpu_pairs(gpu_count=None):
    try:
        count = int(gpu_count if gpu_count is not None else detect_gpu_count_runtime())
    except Exception:
        count = 0
    pairs = []
    for first in range(0, max(count - 1, 0), 2):
        second = first + 1
        if second < count:
            pairs.append([first, second])
    return pairs


def running_runtime_rows(instances=None, legacy_instance=None):
    rows = []
    if legacy_instance and legacy_instance.get("running"):
        rows.append(dict(legacy_instance))
    for row in instances or []:
        if row.get("running"):
            rows.append(dict(row))
    rows.sort(key=lambda item: ((item.get("gpu_indices") or [item.get("gpu_index", 9999)]), str(item.get("id") or "")))
    return rows


def runtime_mode_list(rows, fallback_mode=""):
    values = []
    seen = set()
    for row in rows or []:
        mode = str(row.get("mode") or "").strip()
        if mode and mode not in seen:
            seen.add(mode)
            values.append(mode)
    fallback_mode = str(fallback_mode or "").strip()
    if not values and fallback_mode:
        values.append(fallback_mode)
    return values


def runtime_container_list(rows, fallback_container=""):
    values = []
    seen = set()
    for row in rows or []:
        container = str(row.get("container") or "").strip()
        if container and container not in seen:
            seen.add(container)
            values.append(container)
    fallback_container = str(fallback_container or "").strip()
    if not values and fallback_container:
        values.append(fallback_container)
    return values

def parse_admin_query_params(parsed):
    if not parsed or not parsed.query:
        return {}
    try:
        return {k: v[0] for k, v in parse_qs(parsed.query).items() if v}
    except Exception:
        return {}

def parse_tail_lines_param(params, default=250):
    raw = params.get("tail") if isinstance(params, dict) else None
    try:
        return max(0, min(1000, int(raw)))
    except Exception:
        return int(default)

def resolve_runtime_log_container(requested_instance_id=""):
    requested = str(requested_instance_id or "").strip().upper()
    if is_legacy_global_instance_id(requested):
        return None, current_container()
    instance = get_instance(requested) if requested else primary_instance()
    container = instance_runtime_container_name(instance) if instance else current_container()
    return instance, container


def split_timestamped_docker_log_line(raw):
    text = str(raw or "").rstrip("\n")
    head, sep, tail = text.partition(" ")
    if sep and re.match(r"^\d{4}-\d{2}-\d{2}T", head):
        return head, tail
    return "", text


class RuntimeLogWatcher:
    def __init__(self, container_name):
        self.container_name = str(container_name or "").strip()
        self.lock = threading.Lock()
        self.cond = threading.Condition(self.lock)
        self.generation = 0
        self.seq = 0
        self.status_message = ""
        self.bootstrap_lines = []
        self.bootstrap_done = False
        self.tail_lines = collections.deque()
        self.tail_bytes = 0
        self.events = collections.deque(maxlen=4096)
        self.last_timestamp = ""
        self.last_line = ""
        self.thread = threading.Thread(target=self._run, name=f"club3090-log-{self.container_name}", daemon=True)
        self.thread.start()

    def _reset_locked(self, status=""):
        self.generation += 1
        self.seq = 0
        self.status_message = str(status or "")
        self.bootstrap_lines = []
        self.bootstrap_done = False
        self.tail_lines = collections.deque()
        self.tail_bytes = 0
        self.events = collections.deque(maxlen=4096)
        self.last_timestamp = ""
        self.last_line = ""
        self.cond.notify_all()

    def _set_status(self, status):
        with self.cond:
            self.status_message = str(status or "")
            self.cond.notify_all()

    def _snapshot_text_locked(self):
        if self.bootstrap_lines or self.tail_lines:
            text = "\n".join(self.bootstrap_lines + list(self.tail_lines))
            if text and not text.endswith("\n"):
                text += "\n"
            return text
        return ((self.status_message or "waiting for logs...").rstrip("\n") + "\n")

    def snapshot(self):
        with self.cond:
            return {"generation": self.generation, "seq": self.seq, "text": self._snapshot_text_locked()}

    def wait_for_change(self, generation, seq, timeout=15):
        deadline = time.time() + max(1.0, float(timeout or 15))
        with self.cond:
            while self.generation == generation and self.seq == seq:
                remaining = deadline - time.time()
                if remaining <= 0:
                    return False
                self.cond.wait(remaining)
            return True

    def collect_updates_since(self, generation, seq):
        with self.cond:
            if self.generation != generation:
                return {"reset": True, "generation": self.generation, "seq": self.seq, "text": self._snapshot_text_locked()}
            if seq >= self.seq:
                return {"reset": False, "generation": self.generation, "seq": self.seq, "text": ""}
            if self.events:
                first_seq = self.events[0][0]
                if seq < first_seq - 1:
                    return {"reset": True, "generation": self.generation, "seq": self.seq, "text": self._snapshot_text_locked()}
            text = "".join(chunk for event_seq, chunk in self.events if event_seq > seq)
            return {"reset": False, "generation": self.generation, "seq": self.seq, "text": text}

    def _append_line(self, line, timestamp=""):
        clean = str(line or "").rstrip("\n")
        if not clean or "GET /health HTTP/1.1" in clean:
            return
        encoded_len = len((clean + "\n").encode("utf-8", errors="replace"))
        with self.cond:
            if timestamp and timestamp == self.last_timestamp and clean == self.last_line:
                return
            self.last_timestamp = timestamp or self.last_timestamp
            self.last_line = clean
            if not self.bootstrap_done:
                self.bootstrap_lines.append(clean)
                if LOG_BOOTSTRAP_MARKER in clean:
                    self.bootstrap_done = True
            else:
                self.tail_lines.append(clean)
                self.tail_bytes += encoded_len
                while self.tail_lines and self.tail_bytes > LOG_TAIL_MAX_BYTES:
                    dropped = self.tail_lines.popleft()
                    self.tail_bytes -= len((dropped + "\n").encode("utf-8", errors="replace"))
            self.status_message = f"following {self.container_name}"
            self.seq += 1
            self.events.append((self.seq, clean + "\n"))
            self.cond.notify_all()

    def _load_initial_snapshot(self):
        try:
            p = subprocess.run(
                ["docker", "logs", "--timestamps", self.container_name],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                timeout=60,
            )
            output = p.stdout or ""
        except Exception as e:
            self._set_status(f"could not load docker logs for {self.container_name}: {e}")
            return "", ""
        last_timestamp = ""
        last_line = ""
        for raw in output.splitlines():
            timestamp, clean = split_timestamped_docker_log_line(raw)
            self._append_line(clean, timestamp=timestamp)
            if clean:
                last_timestamp = timestamp or last_timestamp
                last_line = clean
        if not output.strip():
            self._set_status(f"waiting for first log lines from {self.container_name}...")
        return last_timestamp, last_line

    def _run(self):
        while True:
            try:
                if self.container_name not in docker_names(all_containers=False):
                    self._set_status(f"{self.container_name} is not running; waiting...")
                    time.sleep(2)
                    continue
                with self.cond:
                    self._reset_locked(f"loading logs for {self.container_name}...")
                last_timestamp, last_line = self._load_initial_snapshot()
                cmd = ["docker", "logs", "--timestamps", "-f"]
                if last_timestamp:
                    cmd += ["--since", last_timestamp]
                else:
                    cmd += ["--tail", "0"]
                cmd.append(self.container_name)
                p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
                try:
                    if p.stdout is not None:
                        for raw in p.stdout:
                            timestamp, clean = split_timestamped_docker_log_line(raw)
                            if timestamp == last_timestamp and clean == last_line:
                                continue
                            self._append_line(clean, timestamp=timestamp)
                            if clean:
                                last_timestamp = timestamp or last_timestamp
                                last_line = clean
                finally:
                    try:
                        p.terminate()
                    except Exception:
                        pass
                self._set_status(f"log stream for {self.container_name} ended; reconnecting...")
            except Exception as e:
                self._set_status(f"log watcher error for {self.container_name}: {e}")
            time.sleep(2)


def get_runtime_log_watcher(container_name):
    key = str(container_name or "").strip()
    if not key:
        return None
    with runtime_log_watchers_lock:
        watcher = runtime_log_watchers.get(key)
        if watcher is None:
            watcher = RuntimeLogWatcher(key)
            runtime_log_watchers[key] = watcher
        return watcher

def cleanup_vllm_containers():
    results = []
    for inst in read_instances_config():
        try:
            rc, out = stop_instance(inst["id"])
            results.append(f"{inst['id']} down rc={rc} {out[-500:]}")
        except Exception as e:
            results.append(f"{inst['id']} down error {e}")
    names = vllm_container_names(all_containers=True, force=True, timeout=5)
    for name in names:
        if name in [instance_container_name(inst) for inst in read_instances_config()]:
            continue
        rc, out = run_cmd(["docker", "rm", "-f", name], timeout=60)
        results.append(f"docker rm -f {name}: rc={rc} {out[-500:]}")
    if not results:
        return "no club-3090 runtime containers to clean"
    msg = " || ".join(results)
    log_control("CLEANUP " + msg)
    return msg

def service_status(name):
    cache_key = str(name or "").strip()
    now = time.time()
    with slow_cache_lock:
        cached = dict(service_status_cache.get(cache_key) or {})
        cached_value = str(cached.get("value") or "")
        cached_time = float(cached.get("time") or 0.0)
    if cached_time and now - cached_time < 3.0:
        return cached_value or "unknown"
    value = cached_value or "unknown"
    try:
        value = subprocess.check_output(["systemctl","is-active",cache_key], text=True, stderr=subprocess.DEVNULL, timeout=1.0).strip() or "inactive"
    except subprocess.CalledProcessError as e:
        value = (e.output or "inactive").strip() or "inactive"
    except Exception:
        value = cached_value or "unknown"
    with slow_cache_lock:
        service_status_cache[cache_key] = {"value": value, "time": time.time()}
    return value


def compose_variant_metadata(mode):
    cache_key = str(mode or "").strip()
    default = {
        "ctx_size_tokens": None,
        "speculative_method": None,
        "drafted_tokens": None,
    }
    if not cache_key:
        return dict(default)
    with slow_cache_lock:
        cached = compose_metadata_cache.get(cache_key)
        if isinstance(cached, dict):
            return dict(cached)
    spec = resolve_variant_spec(cache_key) or {}
    meta = {
        "ctx_size_tokens": spec.get("max_model_len"),
        "speculative_method": spec.get("speculative_method"),
        "drafted_tokens": spec.get("drafted_tokens"),
    }
    for key, value in default.items():
        if meta.get(key) in ("", None, False):
            meta[key] = value
    with slow_cache_lock:
        compose_metadata_cache[cache_key] = dict(meta)
    return dict(meta)


def _normalize_ratio_percent(value):
    number = safe_float(value)
    if number <= 1.0:
        number *= 100.0
    return round(number, 2)


def clear_gpu_session_peaks():
    with metrics_lock:
        gpu_session_peaks.clear()
    log_control("GPU session peaks reset")
    return {"cleared": True}


def parse_runtime_log_metrics(text):
    metrics_out = {
        "prompt_tps": None,
        "generation_tps": None,
        "running_requests": None,
        "waiting_requests": None,
        "pending_requests": None,
        "swapped_requests": None,
        "gpu_kv_cache_usage_pct": None,
        "cpu_kv_cache_usage_pct": None,
        "prefix_cache_hit_rate_pct": None,
        "speculative": {},
    }
    lines = [str(line or "").strip() for line in str(text or "").splitlines()]
    lines = [line for line in lines if line]
    for line in reversed(lines):
        if metrics_out["prompt_tps"] is None and ("Avg prompt throughput:" in line or "GPU KV cache usage:" in line):
            prompt_match = re.search(r"Avg prompt throughput:\s*([0-9.]+)\s*tokens/s", line)
            gen_match = re.search(r"Avg generation throughput:\s*([0-9.]+)\s*tokens/s", line)
            running_match = re.search(r"Running:\s*([0-9]+)\s*reqs", line)
            waiting_match = re.search(r"Waiting:\s*([0-9]+)\s*reqs", line)
            pending_match = re.search(r"Pending:\s*([0-9]+)\s*reqs", line)
            swapped_match = re.search(r"Swapped:\s*([0-9]+)\s*reqs", line)
            gpu_kv_match = re.search(r"GPU KV cache usage:\s*([0-9.]+)\s*%", line)
            cpu_kv_match = re.search(r"CPU KV cache usage:\s*([0-9.]+)\s*%", line)
            prefix_match = re.search(r"Prefix cache hit rate:\s*(?:GPU:\s*)?([0-9.]+)%", line)
            if prompt_match:
                metrics_out["prompt_tps"] = round(safe_float(prompt_match.group(1)), 2)
            if gen_match:
                metrics_out["generation_tps"] = round(safe_float(gen_match.group(1)), 2)
            if running_match:
                metrics_out["running_requests"] = int(running_match.group(1))
            if waiting_match:
                metrics_out["waiting_requests"] = int(waiting_match.group(1))
            if pending_match:
                metrics_out["pending_requests"] = int(pending_match.group(1))
            if swapped_match:
                metrics_out["swapped_requests"] = int(swapped_match.group(1))
            if gpu_kv_match:
                metrics_out["gpu_kv_cache_usage_pct"] = round(safe_float(gpu_kv_match.group(1)), 2)
            if cpu_kv_match:
                metrics_out["cpu_kv_cache_usage_pct"] = round(safe_float(cpu_kv_match.group(1)), 2)
            if prefix_match:
                metrics_out["prefix_cache_hit_rate_pct"] = round(safe_float(prefix_match.group(1)), 2)
        if not metrics_out["speculative"] and ("Speculative metrics:" in line or "SpecDecoding metrics:" in line):
            spec = {}
            drafted_match = re.search(r"Number of speculative tokens:\s*([0-9]+)", line)
            accepted_match = re.search(r"(?:Number of accepted tokens|Accepted):\s*([0-9]+)", line)
            draft_tokens_match = re.search(r"(?:Number of draft tokens|Drafted):\s*([0-9]+)", line)
            emitted_match = re.search(r"Number of emitted tokens:\s*([0-9]+)", line)
            accept_rate_match = re.search(r"(?:Draft acceptance rate|Avg Draft acceptance rate):\s*([0-9.]+)%?", line)
            efficiency_match = re.search(r"System efficiency:\s*([0-9.]+)", line)
            mean_accept_match = re.search(r"Mean acceptance length:\s*([0-9.]+)", line)
            if drafted_match:
                spec["drafted_tokens"] = int(drafted_match.group(1))
            if accepted_match:
                spec["accepted_tokens"] = int(accepted_match.group(1))
            if draft_tokens_match:
                spec["draft_tokens"] = int(draft_tokens_match.group(1))
            if emitted_match:
                spec["emitted_tokens"] = int(emitted_match.group(1))
            if accept_rate_match:
                spec["accept_rate_pct"] = _normalize_ratio_percent(accept_rate_match.group(1))
            if efficiency_match:
                spec["system_efficiency_pct"] = _normalize_ratio_percent(efficiency_match.group(1))
            if mean_accept_match:
                spec["mean_acceptance_length"] = round(safe_float(mean_accept_match.group(1)), 2)
            if spec:
                metrics_out["speculative"] = spec
        if metrics_out["prompt_tps"] is not None and metrics_out["speculative"]:
            break
    return metrics_out


def runtime_log_metrics_for_container(container_name, force=False, max_age=1.0):
    cache_key = str(container_name or "").strip()
    if not cache_key:
        return {}
    now = time.time()
    with slow_cache_lock:
        cached = dict(runtime_log_metrics_cache.get(cache_key) or {})
        cached_value = dict(cached.get("value") or {})
        cached_time = float(cached.get("time") or 0.0)
    if not force and cached_time and now - cached_time < max(0.5, float(max_age or 1.0)):
        return cached_value
    watcher = get_runtime_log_watcher(cache_key)
    if watcher is None:
        return cached_value
    snapshot = watcher.snapshot()
    parsed = parse_runtime_log_metrics(snapshot.get("text") or "")
    active_now = any(int(parsed.get(key) or 0) > 0 for key in ("running_requests", "waiting_requests", "pending_requests", "swapped_requests"))
    with slow_cache_lock:
        remembered = dict(runtime_log_metric_memory.get(cache_key) or {})
    if parsed.get("prompt_tps") not in (None, "", 0, 0.0):
        remembered["prompt_tps"] = parsed.get("prompt_tps")
    elif remembered.get("prompt_tps") not in (None, ""):
        parsed["prompt_tps"] = remembered.get("prompt_tps")
    if parsed.get("generation_tps") not in (None, "", 0, 0.0):
        remembered["generation_tps"] = parsed.get("generation_tps")
    elif remembered.get("generation_tps") not in (None, ""):
        parsed["generation_tps"] = remembered.get("generation_tps")
    if parsed.get("gpu_kv_cache_usage_pct") not in (None, "", 0, 0.0):
        remembered["gpu_kv_cache_usage_pct"] = parsed.get("gpu_kv_cache_usage_pct")
    elif not active_now and remembered.get("gpu_kv_cache_usage_pct") not in (None, ""):
        parsed["gpu_kv_cache_usage_pct"] = remembered.get("gpu_kv_cache_usage_pct")
    if parsed.get("cpu_kv_cache_usage_pct") not in (None, "", 0, 0.0):
        remembered["cpu_kv_cache_usage_pct"] = parsed.get("cpu_kv_cache_usage_pct")
    elif not active_now and remembered.get("cpu_kv_cache_usage_pct") not in (None, ""):
        parsed["cpu_kv_cache_usage_pct"] = remembered.get("cpu_kv_cache_usage_pct")
    with slow_cache_lock:
        runtime_log_metric_memory[cache_key] = dict(remembered)
    with slow_cache_lock:
        runtime_log_metrics_cache[cache_key] = {"value": dict(parsed), "time": time.time()}
    return parsed


def gpu_vendors_by_index():
    vendors = []
    try:
        out = subprocess.check_output(["lspci", "-v", "-m"], text=True, stderr=subprocess.DEVNULL, timeout=4)
        block = []
        for line in out.splitlines() + [""]:
            if line.strip():
                block.append(line)
                continue
            if not block:
                continue
            rec = {}
            for b in block:
                if ":" in b:
                    k, v = b.split(":", 1)
                    rec[k.strip()] = v.strip().strip('"')
            cls = rec.get("Class", "")
            vendor = rec.get("SVendor", "")
            if ("VGA" in cls or "3D" in cls) and vendor:
                first = vendor.split()[0]
                if first and first.lower() not in ("nvidia", "corporation"):
                    vendors.append(first)
            block = []
    except Exception:
        pass
    return {str(i): v for i, v in enumerate(vendors)}

def gpu_stats():
    if not shutil.which("nvidia-smi"):
        return []
    vendor_map = gpu_vendors_by_index()
    fields = "index,name,temperature.gpu,utilization.gpu,memory.used,memory.total,power.draw,power.limit,fan.speed,clocks.current.graphics,clocks.current.memory"
    try:
        out = subprocess.check_output(["nvidia-smi", f"--query-gpu={fields}", "--format=csv,noheader,nounits"], text=True, stderr=subprocess.STDOUT, timeout=4)
    except Exception as e:
        return [{"error": str(e)}]
    rows = []
    for line in out.splitlines():
        parts = [x.strip() for x in line.split(",")]
        try:
            if len(parts) >= 11:
                idx,name,temp_core,util,mem_used,mem_total,power,power_limit,fan,gfx_clk,mem_clk = parts[:11]
            elif len(parts) >= 9:
                idx,name,temp_core,util,mem_used,mem_total,power,power_limit,fan = parts[:9]
                gfx_clk = mem_clk = "N/A"
            else:
                continue
            used = safe_float(mem_used); total = safe_float(mem_total)
            temp_now = None if str(temp_core).strip() in {"", "N/A", "[Not Supported]"} else safe_float(temp_core)
            power_now = None if str(power).strip() in {"", "N/A", "[Not Supported]"} else safe_float(power)
            core_clock_now = None if str(gfx_clk).strip() in {"", "N/A", "[Not Supported]"} else safe_float(gfx_clk)
            mem_clock_now = None if str(mem_clk).strip() in {"", "N/A", "[Not Supported]"} else safe_float(mem_clk)
            peak_key = str(idx)
            with metrics_lock:
                peak_row = gpu_session_peaks.setdefault(peak_key, {})
                if temp_now is not None:
                    peak_row["temp_c"] = round(max(temp_now, safe_float(peak_row.get("temp_c"))), 2)
                if power_now is not None:
                    peak_row["power_w"] = round(max(power_now, safe_float(peak_row.get("power_w"))), 2)
                if core_clock_now is not None:
                    peak_row["core_clock_mhz"] = round(max(core_clock_now, safe_float(peak_row.get("core_clock_mhz"))), 2)
                if mem_clock_now is not None:
                    peak_row["mem_clock_mhz"] = round(max(mem_clock_now, safe_float(peak_row.get("mem_clock_mhz"))), 2)
                peak_temp = peak_row.get("temp_c")
                peak_power = peak_row.get("power_w")
                peak_core = peak_row.get("core_clock_mhz")
                peak_mem = peak_row.get("mem_clock_mhz")
            rows.append({
                "index":idx,
                "name":name,
                "vendor":vendor_map.get(str(idx), ""),
                "temp_c":temp_core,
                "temp_peak_c":peak_temp,
                "util_pct":util,
                "mem_used_mib":mem_used,
                "mem_total_mib":mem_total,
                "mem_free_mib":round(max(total-used,0),1) if total else 0,
                "mem_pct":round((used/total*100),1) if total else 0,
                "power_w":power,
                "power_peak_w":peak_power,
                "power_limit_w":power_limit,
                "fan_pct":fan,
                "core_clock_mhz":gfx_clk,
                "core_clock_peak_mhz":peak_core,
                "mem_clock_mhz":mem_clk,
                "mem_clock_peak_mhz":peak_mem,
            })
        except Exception as e:
            rows.append({"error": f"parse gpu stat failed: {e}"})
    return rows

def safe_float(value):
    try:
        return float(str(value).replace("N/A", "0").replace("[Not Supported]", "0").strip())
    except Exception:
        return 0.0

_cpu_prev = None

def memory_stats():
    data = {}
    try:
        with open('/proc/meminfo', 'r', encoding='utf-8') as f:
            for line in f:
                k, v = line.split(':', 1)
                data[k] = safe_float(v.split()[0]) / 1024.0
        total = data.get('MemTotal', 0); avail = data.get('MemAvailable', 0); used = max(total-avail,0)
        return {"total_mib":round(total,1),"used_mib":round(used,1),"free_mib":round(avail,1),"used_pct":round((used/total*100),1) if total else 0}
    except Exception as e:
        return {"error": str(e)}

def _read_cpu_times():
    rows=[]
    try:
        with open('/proc/stat','r',encoding='utf-8') as f:
            for line in f:
                if not line.startswith('cpu'):
                    break
                parts=line.split()
                if parts[0]=='cpu': name='total'
                elif parts[0][3:].isdigit(): name=parts[0][3:]
                else: continue
                vals=[int(x) for x in parts[1:]]; idle=vals[3]+(vals[4] if len(vals)>4 else 0); total=sum(vals)
                rows.append((name,idle,total))
    except Exception:
        pass
    return rows

def cpu_stats():
    global _cpu_prev
    cur=_read_cpu_times()
    if not cur: return {"total_pct":0,"cores":[]}
    prev=_cpu_prev; _cpu_prev={n:(i,t) for n,i,t in cur}
    cores=[]; total_pct=0
    for name,idle,total in cur:
        pct=0.0
        if prev and name in prev:
            pi,pt=prev[name]; dt=max(total-pt,1); di=max(idle-pi,0); pct=max(0.0,min(100.0,(1-di/dt)*100))
        if name=='total': total_pct=round(pct,1)
        else: cores.append({"core":name,"usage_pct":round(pct,1)})
    return {"total_pct":total_pct,"cores":cores}

def _fmt_gib(num_bytes):
    try:
        return round(float(num_bytes) / (1024**3), 2)
    except Exception:
        return 0.0



def disk_stats():
    """Return physical disks and volumes with best-effort real filesystem
    usage. Mounted filesystems use shutil.disk_usage; unmounted ext* filesystems
    use dumpe2fs when available; lsblk FSUSED/FSAVAIL is used when populated.
    Physical disks aggregate child volume usage where real usage is known, and
    otherwise fall back to partition allocation without pretending it is FS free.
    """
    def norm_mounts(val):
        if isinstance(val, list):
            return [m for m in val if m and m != '[SWAP]']
        return [m for m in str(val or '').replace('\\x0a','\n').splitlines() if m and m != '[SWAP]']

    def walk(nodes, parent=''):
        out=[]
        for n in nodes or []:
            n=dict(n)
            n['_parent']=parent
            out.append(n)
            out.extend(walk(n.get('children') or [], n.get('name') or parent))
        return out

    def ext_usage(path):
        """Best-effort usage for unmounted ext filesystems via dumpe2fs."""
        if not path or not shutil.which('dumpe2fs'):
            return None
        try:
            p=subprocess.run(['dumpe2fs','-h',path], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=8)
            if p.returncode != 0:
                return None
            vals={}
            for line in p.stdout.splitlines():
                if ':' in line:
                    k,v=line.split(':',1)
                    vals[k.strip().lower()]=v.strip().split()[0]
            block_count=int(float(vals.get('block count','0')))
            free_blocks=int(float(vals.get('free blocks','0')))
            block_size=int(float(vals.get('block size','0')))
            if block_count > 0 and block_size > 0:
                total=block_count*block_size
                free=max(0, free_blocks*block_size)
                used=max(0, total-free)
                return total, used, free, 'ext filesystem'
        except Exception:
            return None
        return None

    def _first_number(text):
        import re
        m=re.search(r'([0-9][0-9,]*)', str(text or ''))
        return int(m.group(1).replace(',','')) if m else None

    def ntfs_usage(path):
        """Best-effort usage for unmounted NTFS via ntfsinfo. If the
        installed ntfsinfo does not expose free clusters/bytes, return None so
        the UI shows Unknown instead of fake Free=0/Used=Total.
        """
        if not path or not shutil.which('ntfsinfo'):
            return None
        text_parts=[]
        for args in (['ntfsinfo','-m',path], ['ntfsinfo',path]):
            try:
                p=subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=10)
                if p.stdout:
                    text_parts.append(p.stdout)
            except Exception:
                pass
        text='\n'.join(text_parts)
        if not text:
            return None
        vals={}
        for line in text.splitlines():
            if ':' in line:
                k,v=line.split(':',1)
                vals[k.strip().lower()]=v.strip()
        def get(*keys):
            for k in keys:
                if k in vals:
                    n=_first_number(vals[k])
                    if n is not None:
                        return n
            return None
        cluster=get('cluster size','bytes per cluster','bytes/cluster')
        total_clusters=get('volume size in clusters','number of clusters','total clusters','clusters')
        free_clusters=get('free clusters')
        total_bytes=get('volume size','current volume size')
        free_bytes=get('free space','free bytes')
        if total_bytes and free_bytes is not None:
            total=total_bytes; free=max(0, free_bytes); used=max(0, total-free)
            return total, used, free, 'ntfs filesystem'
        if cluster and total_clusters and free_clusters is not None:
            total=cluster*total_clusters; free=max(0, cluster*free_clusters); used=max(0, total-free)
            return total, used, free, 'ntfs filesystem'
        return None

    rows=[]
    try:
        out=subprocess.check_output([
            'lsblk','-b','-J','-a','-o',
            'NAME,PATH,PKNAME,TYPE,FSTYPE,LABEL,PARTLABEL,PARTTYPENAME,PARTTYPE,MOUNTPOINTS,SIZE,MODEL,TRAN,FSUSED,FSAVAIL,FSSIZE'
        ], text=True, stderr=subprocess.DEVNULL, timeout=8)
        data=json.loads(out or '{}')
        flat=walk(data.get('blockdevices') or [])
        by_parent={}
        for rec in flat:
            parent=rec.get('pkname') or rec.get('_parent') or ''
            by_parent.setdefault(parent,[]).append(rec)

        usage_by_name={}
        pending_disks=[]
        for rec in flat:
            typ=(rec.get('type') or '').strip()
            if typ not in ('disk','part','crypt','lvm','raid0','raid1','raid5','raid6','raid10','md'):
                continue
            path=rec.get('path') or ('/dev/'+rec.get('name',''))
            name=rec.get('name') or path
            size=int(safe_float(rec.get('size')))
            mounts=norm_mounts(rec.get('mountpoints'))
            mount=mounts[0] if mounts else ''
            mounted=bool(mount)
            total=size; used=0; free=0; used_pct=0.0
            real_usage=False; usage_basis='allocation'

            if typ == 'disk':
                pending_disks.append(rec)
                continue

            if mounted:
                try:
                    usage=shutil.disk_usage(mount)
                    total=usage.total; used=usage.used; free=usage.free
                    used_pct=round((used/total*100),1) if total else 0.0
                    real_usage=True; usage_basis='mounted filesystem'
                except Exception:
                    mounted=False
            if not real_usage:
                fsused=int(safe_float(rec.get('fsused')))
                fsavail=int(safe_float(rec.get('fsavail')))
                fssize=int(safe_float(rec.get('fssize')))
                if fssize > 0 and (fsused > 0 or fsavail > 0):
                    total=fssize; used=fsused; free=fsavail
                    used_pct=round((used/total*100),1) if total else 0.0
                    real_usage=True; usage_basis='lsblk filesystem'
            fstype_lower=(rec.get('fstype') or '').lower()
            if not real_usage and fstype_lower.startswith('ext'):
                ext=ext_usage(path)
                if ext:
                    total, used, free, usage_basis = ext
                    used_pct=round((used/total*100),1) if total else 0.0
                    real_usage=True
            if not real_usage and fstype_lower in ('ntfs','ntfs3'):
                ntfs=ntfs_usage(path)
                if ntfs:
                    total, used, free, usage_basis = ntfs
                    used_pct=round((used/total*100),1) if total else 0.0
                    real_usage=True
                else:
                    usage_basis='ntfs unmounted; free/used unknown'
            if not real_usage:
                total=size; used=None; free=None; used_pct=None
                if usage_basis == 'allocation':
                    usage_basis='unknown filesystem usage'

            usage_by_name[name]={'total':total,'used':used,'free':free,'real':real_usage,'size':size}
            label=rec.get('label') or rec.get('partlabel') or ''
            part_type=(rec.get('parttypename') or rec.get('parttype') or typ or '').strip()
            fs=(rec.get('fstype') or 'unknown').strip()
            user_facing = bool(
                typ in ('part','crypt','lvm','md') and
                fs.lower() not in ('swap',) and
                not any(x in (mount or '').lower() for x in ('/boot', '/efi')) and
                not any(x in (label or '').lower() for x in ('recovery','reserved','swap','efi','boot')) and
                not any(x in part_type.lower() for x in ('efi','reserved','recovery','bios boot','swap'))
            )
            rows.append({
                'name': name, 'path': path, 'source': path, 'type': typ,
                'kind': 'volume', 'partition_type': part_type or typ,
                'fs': fs, 'label': label, 'mount': mount, 'mounted': mounted,
                'model': (rec.get('model') or '').strip(), 'transport': rec.get('tran') or '',
                'total_gib': _fmt_gib(total) if total is not None else None, 'used_gib': _fmt_gib(used) if used is not None else None, 'free_gib': _fmt_gib(free) if free is not None else None,
                'size': f"{_fmt_gib(total)}G" if total is not None else 'unknown', 'used': f"{_fmt_gib(used)}G" if used is not None else 'unknown', 'avail': f"{_fmt_gib(free)}G" if free is not None else 'unknown',
                'used_pct': used_pct, 'user_facing': user_facing,
                'usage_basis': usage_basis
            })

        for rec in pending_disks:
            name=rec.get('name') or rec.get('path') or ''
            path=rec.get('path') or ('/dev/'+name)
            size=int(safe_float(rec.get('size')))
            children=by_parent.get(name, [])
            allocated=sum(int(safe_float(c.get('size'))) for c in children if (c.get('type') or '') in ('part','crypt','lvm','md','raid0','raid1','raid5','raid6','raid10'))
            real_children=[]
            for c in children:
                u=usage_by_name.get(c.get('name') or '')
                if u and u.get('real'):
                    real_children.append(u)
            if real_children:
                used=sum(int(u.get('used',0)) for u in real_children)
                free=sum(int(u.get('free',0)) for u in real_children)
                total=sum(int(u.get('total',0)) for u in real_children) or size
                basis='child filesystems'
            else:
                used=max(0, min(size, allocated)); free=max(0, size-used); total=size
                basis='partition allocation'
            used_pct=round((used/total*100),1) if total else 0.0
            rows.append({
                'name': name, 'path': path, 'source': path, 'type': 'disk', 'kind': 'disk',
                'partition_type': 'disk', 'fs': 'disk', 'label': '', 'mount': '', 'mounted': False,
                'model': (rec.get('model') or '').strip(), 'transport': rec.get('tran') or '',
                'total_gib': _fmt_gib(total) if total is not None else None, 'used_gib': _fmt_gib(used) if used is not None else None, 'free_gib': _fmt_gib(free) if free is not None else None,
                'size': f"{_fmt_gib(total)}G" if total is not None else 'unknown', 'used': f"{_fmt_gib(used)}G" if used is not None else 'unknown', 'avail': f"{_fmt_gib(free)}G" if free is not None else 'unknown',
                'used_pct': used_pct, 'user_facing': False, 'usage_basis': basis
            })

        order={'disk':0,'part':1,'crypt':2,'lvm':3,'md':4,'raid0':4,'raid1':4,'raid5':4,'raid6':4,'raid10':4}
        rows.sort(key=lambda d:(order.get(d.get('type'),9), d.get('path') or d.get('name') or ''))
    except Exception as e:
        rows.append({'error':str(e)})
    return rows[:128]


def system_info(gpu_rows=None):
    def read_first(path):
        try:
            return open(path, 'r', encoding='utf-8', errors='ignore').read().strip()
        except Exception:
            return ''
    os_name='unknown'
    try:
        vals={}
        with open('/etc/os-release','r',encoding='utf-8',errors='ignore') as f:
            for line in f:
                if '=' in line:
                    k,v=line.rstrip().split('=',1); vals[k]=v.strip('"')
        os_name=vals.get('PRETTY_NAME') or vals.get('NAME') or os_name
    except Exception:
        pass
    cpu_model='unknown'
    try:
        out=subprocess.check_output(['lscpu'], text=True, stderr=subprocess.DEVNULL, timeout=3)
        for line in out.splitlines():
            if line.startswith('Model name:'):
                cpu_model=line.split(':',1)[1].strip(); break
    except Exception:
        pass
    gpu_names=[]
    try:
        source_rows = gpu_rows if gpu_rows is not None else gpu_stats()
        gpu_names=[g.get('name') for g in source_rows if isinstance(g,dict) and g.get('name')]
    except Exception:
        pass
    return {
        'os': os_name,
        'kernel': platform.release(),
        'hostname': socket.gethostname(),
        'username': os.environ.get('USER') or os.environ.get('LOGNAME') or 'unknown',
        'machine': platform.machine(),
        'cpu_model': cpu_model,
        'board': read_first('/sys/devices/virtual/dmi/id/board_name'),
        'product': read_first('/sys/devices/virtual/dmi/id/product_name'),
        'bios': read_first('/sys/devices/virtual/dmi/id/bios_version'),
        'gpus': ', '.join(gpu_names) if gpu_names else 'unknown',
    }

_net_prev = None
_public_ip_cache = {'value':'unknown','time':0}


def _read_net_bytes():
    rows={}
    try:
        with open('/proc/net/dev','r',encoding='utf-8') as f:
            for line in f.readlines()[2:]:
                if ':' not in line:
                    continue
                iface, rest = line.split(':',1)
                iface=iface.strip()
                if iface == 'lo':
                    continue
                vals=rest.split()
                if len(vals) >= 16:
                    rows[iface]={'rx':int(vals[0]),'tx':int(vals[8])}
    except Exception:
        pass
    return rows


def local_ip():
    try:
        s=socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(0.2)
        s.connect(('8.8.8.8',80))
        ip=s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        try:
            return socket.gethostbyname(socket.gethostname())
        except Exception:
            return 'unknown'


def public_ip():
    now=time.time()
    # Avoid blocking the status endpoint every few seconds if public IP lookup
    # is unavailable. Successful lookups are cached longer than failures.
    cache_age = now - _public_ip_cache.get('time', 0)
    if _public_ip_cache.get('value') != 'unknown' and cache_age < 900:
        return _public_ip_cache['value']
    if _public_ip_cache.get('value') == 'unknown' and cache_age < 120:
        return 'unknown'
    for url in ('https://ifconfig.me/ip','https://api.ipify.org'):
        try:
            req=urllib.request.Request(url, headers={'User-Agent':'club3090-control'})
            with urllib.request.urlopen(req, timeout=1.5) as r:
                val=r.read(80).decode('utf-8','ignore').strip()
                if val:
                    _public_ip_cache.update({'value':val,'time':now})
                    return val
        except Exception:
            pass
    _public_ip_cache.update({'value':'unknown','time':now})
    return 'unknown'


def network_stats():
    global _net_prev
    now=time.time(); cur=_read_net_bytes(); prev=_net_prev; _net_prev=(now,cur)
    ifaces=[]; total_rx=total_tx=0.0
    for iface, vals in cur.items():
        rx_kbps=tx_kbps=0.0
        if prev and iface in prev[1]:
            dt=max(now-prev[0],0.001)
            rx_kbps=max(0.0,(vals['rx']-prev[1][iface]['rx'])*8/1000/dt)
            tx_kbps=max(0.0,(vals['tx']-prev[1][iface]['tx'])*8/1000/dt)
        total_rx += rx_kbps; total_tx += tx_kbps
        ifaces.append({'iface':iface,'rx_kbps':round(rx_kbps,1),'tx_kbps':round(tx_kbps,1),'rx_mb':round(vals['rx']/1024/1024,1),'tx_mb':round(vals['tx']/1024/1024,1)})
    return {'local_ip':local_ip(),'public_ip':public_ip(),'rx_kbps':round(total_rx,1),'tx_kbps':round(total_tx,1),'interfaces':ifaces}


def cached_disk_stats(max_age=15):
    now = time.time()
    cached = disk_stats_cache
    if cached.get("value") and now - float(cached.get("time", 0) or 0) < max(1.0, float(max_age or 15)):
        return cached.get("value") or []
    value = disk_stats()
    disk_stats_cache["value"] = value
    disk_stats_cache["time"] = now
    return value


def cached_system_info(gpu_rows=None, max_age=30):
    now = time.time()
    cached = system_info_cache
    cached_value = cached.get("value") if isinstance(cached.get("value"), dict) else {}
    gpu_names = ", ".join([g.get("name") for g in (gpu_rows or []) if isinstance(g, dict) and g.get("name")])
    if cached_value and now - float(cached.get("time", 0) or 0) < max(1.0, float(max_age or 30)):
        return {**cached_value, "gpus": gpu_names or cached_value.get("gpus", "unknown")}
    value = system_info(gpu_rows=gpu_rows)
    system_info_cache["value"] = value
    system_info_cache["time"] = now
    return value


def system_stats(gpu_rows=None):
    return {'memory':memory_stats(),'cpu':cpu_stats(),'disks':cached_disk_stats(),'network':network_stats(),'info':cached_system_info(gpu_rows)}

def estimate_tokens_from_stream_bytes(raw):
    text = raw.decode("utf-8", errors="ignore") if isinstance(raw, (bytes, bytearray)) else str(raw)
    chars = 0
    for line in text.splitlines():
        if not line.startswith("data:"):
            continue
        data = line[5:].strip()
        if not data or data == "[DONE]":
            continue
        try:
            obj = json.loads(data)
            for choice in obj.get("choices", []):
                delta = choice.get("delta") or {}
                chars += len(delta.get("content") or choice.get("text") or "")
        except Exception:
            pass
    return max(0, int(chars / 4)) if chars else (max(1, len(text)//4) if text else 0)

def build_series_point():
    global latest_gpu_rows, latest_system_snapshot, latest_metrics_collected_at
    gpus = gpu_stats(); sysinfo = system_stats(gpu_rows=gpus)
    util=[]; mem=[]; temps=[]; watts=[]; gpu_points=[]
    for g in gpus:
        if "error" in g: continue
        util_v=safe_float(g.get("util_pct")); mem_v=safe_float(g.get("mem_pct")); temp_v=safe_float(g.get("temp_c")); watt_v=safe_float(g.get("power_w")); fan_v=safe_float(g.get("fan_pct"))
        util.append(util_v); mem.append(mem_v); temps.append(temp_v); watts.append(watt_v)
        gpu_points.append({"index":g.get("index"),"util":util_v,"mem_pct":mem_v,"temp":temp_v,"power":watt_v,"fan":fan_v})
    ram_pct=safe_float((sysinfo.get('memory') or {}).get('used_pct')); cpu_pct=safe_float((sysinfo.get('cpu') or {}).get('total_pct'))
    disks=sysinfo.get('disks') or []; disk_pct=max([safe_float(d.get('used_pct')) for d in disks if isinstance(d,dict)] or [0])
    net=sysinfo.get('network') or {}; rx_kbps=safe_float(net.get('rx_kbps')); tx_kbps=safe_float(net.get('tx_kbps'))
    with metrics_lock:
        point={"t":int(time.time()),"gpu_util":round(sum(util)/len(util),1) if util else 0,"mem_pct":round(sum(mem)/len(mem),1) if mem else 0,"temp_c":round(max(temps),1) if temps else 0,"power_w":round(sum(watts),1) if watts else 0,"ram_pct":round(ram_pct,1),"cpu_pct":round(cpu_pct,1),"disk_pct":round(disk_pct,1),"system_util_pct":round((cpu_pct+ram_pct+(sum(util)/len(util) if util else 0))/3,1),"net_rx_kbps":round(rx_kbps,1),"net_tx_kbps":round(tx_kbps,1),"gpus":gpu_points,"cpu_cores":(sysinfo.get('cpu') or {}).get('cores',[]),"active_requests":metrics.get("active_requests",0),"latency_s":metrics.get("last_latency_s") or 0,"ttft_s":metrics.get("last_ttft_s") or 0,"tps":metrics.get("last_tokens_per_second") or 0}
        series_points.append(point)
        latest_gpu_rows = gpus
        latest_system_snapshot = sysinfo
        latest_metrics_collected_at = time.time()
    return point

def metrics_collector():
    while True:
        try:
            build_series_point()
        except Exception as e:
            log_control(f"metrics collector error: {e}")
        time.sleep(1)


def get_latest_runtime_snapshot(force_refresh=False):
    with metrics_lock:
        gpus = latest_gpu_rows
        system = latest_system_snapshot
        collected_at = latest_metrics_collected_at
    if force_refresh or not collected_at:
        build_series_point()
        with metrics_lock:
            gpus = latest_gpu_rows
            system = latest_system_snapshot
            collected_at = latest_metrics_collected_at
    return gpus, system, collected_at


def build_instance_runtime_metrics_entry(instance, target_metrics_snapshot=None):
    row = dict(instance or {})
    target_metrics_snapshot = target_metrics_snapshot if isinstance(target_metrics_snapshot, dict) else {}
    request_key = str(row.get("id") or "").strip().upper()
    if request_key == "GLOBAL" and "LEGACY" in target_metrics_snapshot:
        request_key = "LEGACY"
    request_metrics = dict(target_metrics_snapshot.get(request_key) or default_target_request_metrics())
    spec = resolve_variant_spec(row.get("mode")) or {}
    runtime_meta = compose_variant_metadata(row.get("mode"))
    log_metrics = runtime_log_metrics_for_container(row.get("container")) if row.get("running") and row.get("container") else {}
    speculative = dict(log_metrics.get("speculative") or {})
    if speculative.get("drafted_tokens") in (None, "") and runtime_meta.get("drafted_tokens") not in (None, ""):
        speculative["drafted_tokens"] = runtime_meta.get("drafted_tokens")
    prompt_tps = log_metrics.get("prompt_tps")
    input_tokens = first_defined(request_metrics.get("last_input_tokens"), request_metrics.get("last_total_tokens"))
    estimated_prefill_s = None
    try:
        if prompt_tps not in (None, "", 0, 0.0) and input_tokens not in (None, "", 0, 0.0):
            estimated_prefill_s = round(float(input_tokens) / max(float(prompt_tps), 0.001), 3)
    except Exception:
        estimated_prefill_s = None
    return {
        "id": row.get("id"),
        "instance_id": row.get("id"),
        "display_name": row.get("display_name") or row.get("id"),
        "kind": row.get("kind"),
        "mode": row.get("mode"),
        "selector": str(spec.get("selector") or row.get("mode") or ""),
        "model_id": str(spec.get("model_id") or ""),
        "engine": str(spec.get("engine") or ""),
        "served_model_name": str(spec.get("served_model_name") or ""),
        "vision": str(spec.get("vision") or ""),
        "container": row.get("container") or "",
        "port": row.get("port"),
        "running": bool(row.get("running")),
        "gpu_indices": list(row.get("gpu_indices") or []),
        "ctx_size_tokens": runtime_meta.get("ctx_size_tokens"),
        "speculative_method": runtime_meta.get("speculative_method"),
        "prompt_tps": prompt_tps,
        "generation_tps": log_metrics.get("generation_tps"),
        "running_requests": log_metrics.get("running_requests"),
        "waiting_requests": first_defined(log_metrics.get("waiting_requests"), log_metrics.get("pending_requests")),
        "pending_requests": log_metrics.get("pending_requests"),
        "swapped_requests": log_metrics.get("swapped_requests"),
        "gpu_kv_cache_usage_pct": log_metrics.get("gpu_kv_cache_usage_pct"),
        "cpu_kv_cache_usage_pct": log_metrics.get("cpu_kv_cache_usage_pct"),
        "prefix_cache_hit_rate_pct": log_metrics.get("prefix_cache_hit_rate_pct"),
        "speculative": speculative,
        "last_status": request_metrics.get("last_status"),
        "last_latency_s": request_metrics.get("last_latency_s"),
        "last_ttft_s": request_metrics.get("last_ttft_s"),
        "last_prefill_s": estimated_prefill_s,
        "last_tokens_per_second": request_metrics.get("last_tokens_per_second"),
        "last_estimated_tokens": request_metrics.get("last_estimated_tokens"),
        "last_input_tokens": request_metrics.get("last_input_tokens"),
        "last_output_tokens": request_metrics.get("last_output_tokens"),
        "last_total_tokens": request_metrics.get("last_total_tokens"),
        "last_tool_calls": request_metrics.get("last_tool_calls"),
        "last_preset": request_metrics.get("last_preset"),
        "last_path": request_metrics.get("last_path"),
        "last_request_at": request_metrics.get("last_request_at"),
    }


def build_instance_runtime_metrics_snapshot(instances, legacy_instance, target_metrics_snapshot=None):
    rows = {}
    if legacy_instance:
        rows[str(legacy_instance.get("id") or "").strip().upper()] = build_instance_runtime_metrics_entry(legacy_instance, target_metrics_snapshot)
    for instance in instances or []:
        rows[str(instance.get("id") or "").strip().upper()] = build_instance_runtime_metrics_entry(instance, target_metrics_snapshot)
    return rows


def build_global_runtime_metrics_entry(mode, port, container, metrics_snapshot, gpu_count=None):
    selector = canonical_mode_selector(mode)
    spec = resolve_variant_spec(selector) or {}
    resolved_gpu_count = int(gpu_count if gpu_count is not None else detect_gpu_count_runtime() or 0)
    scope_kind = str(spec.get("scope_kind") or "")
    runtime_gpu_indices = (
        list(range(max(resolved_gpu_count, 0)))
        if scope_kind in {"multi", "global_only"}
        else mode_gpu_indices(selector, gpu_count=resolved_gpu_count)
    )
    log_metrics = runtime_log_metrics_for_container(container) if container else {}
    speculative = dict(log_metrics.get("speculative") or {})
    if speculative.get("drafted_tokens") in (None, "") and spec.get("drafted_tokens") not in (None, ""):
        speculative["drafted_tokens"] = spec.get("drafted_tokens")
    prompt_tps = log_metrics.get("prompt_tps")
    input_tokens = first_defined(metrics_snapshot.get("last_input_tokens"), metrics_snapshot.get("last_total_tokens"))
    estimated_prefill_s = None
    try:
        if prompt_tps not in (None, "", 0, 0.0) and input_tokens not in (None, "", 0, 0.0):
            estimated_prefill_s = round(float(input_tokens) / max(float(prompt_tps), 0.001), 3)
    except Exception:
        estimated_prefill_s = None
    return {
        "id": "GLOBAL",
        "instance_id": "GLOBAL",
        "display_name": "Global Runtime",
        "kind": "global",
        "mode": selector,
        "selector": str(spec.get("selector") or selector or ""),
        "model_id": str(spec.get("model_id") or ""),
        "engine": str(spec.get("engine") or ""),
        "served_model_name": str(spec.get("served_model_name") or ""),
        "vision": str(spec.get("vision") or ""),
        "container": str(container or ""),
        "port": int(port or 0),
        "running": True,
        "gpu_indices": runtime_gpu_indices,
        "ctx_size_tokens": spec.get("ctx_size_tokens"),
        "speculative_method": spec.get("speculative_method"),
        "prompt_tps": prompt_tps,
        "generation_tps": log_metrics.get("generation_tps"),
        "running_requests": log_metrics.get("running_requests"),
        "waiting_requests": first_defined(log_metrics.get("waiting_requests"), log_metrics.get("pending_requests")),
        "pending_requests": log_metrics.get("pending_requests"),
        "swapped_requests": log_metrics.get("swapped_requests"),
        "gpu_kv_cache_usage_pct": log_metrics.get("gpu_kv_cache_usage_pct"),
        "cpu_kv_cache_usage_pct": log_metrics.get("cpu_kv_cache_usage_pct"),
        "prefix_cache_hit_rate_pct": log_metrics.get("prefix_cache_hit_rate_pct"),
        "speculative": speculative,
        "last_status": metrics_snapshot.get("last_status"),
        "last_latency_s": metrics_snapshot.get("last_latency_s"),
        "last_ttft_s": metrics_snapshot.get("last_ttft_s"),
        "last_prefill_s": estimated_prefill_s,
        "last_tokens_per_second": metrics_snapshot.get("last_tokens_per_second"),
        "last_estimated_tokens": metrics_snapshot.get("last_estimated_tokens"),
        "last_input_tokens": metrics_snapshot.get("last_input_tokens"),
        "last_output_tokens": metrics_snapshot.get("last_output_tokens"),
        "last_total_tokens": metrics_snapshot.get("last_total_tokens"),
        "last_tool_calls": metrics_snapshot.get("last_tool_calls"),
        "last_preset": metrics_snapshot.get("last_preset"),
        "last_path": metrics_snapshot.get("last_path"),
        "last_request_at": metrics_snapshot.get("last_request_at"),
    }


def build_status_snapshot():
    with metrics_lock:
        m = dict(metrics)
        recent = list(recent_requests)
        series = list(series_points)
    runtime_inventory = load_runtime_inventory()
    current_mode = active_mode()
    ap = active_port()
    current_container_name = current_container()
    cfg = read_server_config()
    gpu_count = detect_gpu_count_runtime()
    instances = instances_snapshot()
    legacy_instance = legacy_global_instance_snapshot()
    target_metrics_snapshot = snapshot_target_request_metrics()
    instance_runtime_metrics = build_instance_runtime_metrics_snapshot(instances, legacy_instance, target_metrics_snapshot)
    runtime_rows = running_runtime_rows(instances, legacy_instance)
    scope_kind = str((resolve_variant_spec(current_mode) or {}).get("scope_kind") or "")
    if not runtime_rows and current_container_name and scope_kind in {"multi", "global_only"} and port_open(ap, timeout=0.08):
        instance_runtime_metrics["GLOBAL"] = build_global_runtime_metrics_entry(
            current_mode,
            ap,
            current_container_name,
            m,
            gpu_count=gpu_count,
        )
        runtime_rows = [{
            "id": "GLOBAL",
            "kind": "global",
            "gpu_indices": list(range(max(gpu_count, 0))),
            "mode": current_mode,
            "container": current_container_name,
            "port": ap,
            "running": True,
        }]
    dual_rows = [dict(row) for row in runtime_rows if row.get("kind") == "dual"]
    dual_rows.sort(key=lambda d: (d.get("gpu_indices") or [], d.get("id") or ""))
    legacy_dual_mode = legacy_instance.get("mode") if legacy_instance and legacy_instance.get("running") else None
    failed_mode = str(read_switch_failure().get("mode") or "")
    active_modes = [mode for mode in runtime_mode_list(runtime_rows, "") if mode and mode != failed_mode]
    containers = runtime_container_list(runtime_rows, "")
    reported_active_mode = ""
    if current_mode in active_modes:
        reported_active_mode = current_mode
    elif len(active_modes) == 1:
        reported_active_mode = active_modes[0]
    reported_active_port = 0
    if runtime_rows:
        if reported_active_mode:
            matching_row = next((row for row in runtime_rows if str(row.get("mode") or "") == reported_active_mode), None)
            if matching_row:
                reported_active_port = int(matching_row.get("port") or 0)
        if reported_active_port <= 0 and len(runtime_rows) == 1:
            reported_active_port = int(runtime_rows[0].get("port") or 0)
    gpus_snapshot, system_snapshot, _ = get_latest_runtime_snapshot()
    return {
        "active_mode": reported_active_mode,
        "active_modes": active_modes,
        "active_port": reported_active_port,
        "container": (containers[0] if containers else ""),
        "containers": containers,
        "club3090_dir": CLUB3090_DIR,
        "script_version": SCRIPT_VERSION,
        "uptime_seconds": int(time.time() - startup_time),
        "vllm_service": service_status("club3090-vllm.service"),
        "control_service": service_status("club3090-control.service"),
        "caddy_service": service_status("club3090-caddy.service") if cfg.get("https_enabled", False) else "disabled",
        "console_service": service_status("club3090-console-log.service"),
        "metrics": m,
        "recent_requests": recent,
        "gpus": gpus_snapshot,
        "power": power_status(),
        "system": system_snapshot,
        "series": series,
        "ui_config": read_ui_config(),
        "presets": preset_catalog(),
        "gpu_count": gpu_count,
        "instances": instances,
        "legacy_global_instance": legacy_instance,
        "runtime_inventory": runtime_inventory,
        "models": list(runtime_inventory.get("models") or []),
        "variants": list(runtime_inventory.get("variants") or []),
        "model_install_job": model_install_job_snapshot(),
        "admin_task_job": admin_task_job_snapshot(),
        "single_gpu_modes": list(SINGLE_GPU_MODES),
        "dual_gpu_modes": list(DUAL_GPU_MODES),
        "running_dual_mode": (dual_rows[0]["mode"] if dual_rows else legacy_dual_mode),
        "running_dual_gpu_indices": (dual_rows[0]["gpu_indices"] if dual_rows else ([0, 1] if legacy_dual_mode else [])),
        "running_dual_instances": dual_rows,
        "running_runtimes": [instance_runtime_metrics.get(str(row.get("id") or "").strip().upper()) for row in runtime_rows if instance_runtime_metrics.get(str(row.get("id") or "").strip().upper())],
        "instance_runtime_metrics": instance_runtime_metrics,
        "switch_failure": read_switch_failure(),
        "switch_job": switch_job_snapshot(),
        "users": list_users_public(),
        "groups": list_groups_public(),
        "server_config": cfg,
        "local_api": {"enabled": cfg.get("local_api_enabled", False), "port": cfg.get("local_api_port", LOCAL_API_PORT)},
        "admin_port": ADMIN_PORT,
        "proxy_port": PROXY_PORT,
    }


def refresh_status_snapshot():
    global status_snapshot_cache, status_snapshot_updated_at
    snapshot = build_status_snapshot()
    with status_snapshot_lock:
        status_snapshot_cache = snapshot
        status_snapshot_updated_at = time.time()
    return snapshot


def get_status_snapshot(force=False):
    with status_snapshot_lock:
        snapshot = status_snapshot_cache
        updated_at = status_snapshot_updated_at
    if force or not snapshot or not updated_at:
        return refresh_status_snapshot()
    return snapshot


def _tail_text_lines(path, max_lines=4000):
    try:
        max_lines = max(1, int(max_lines or 4000))
    except Exception:
        max_lines = 4000
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            return "".join(f.readlines()[-max_lines:])
    except Exception:
        return ""


def _upload_multipart_text(url, text, filename="club3090-log.txt", field_name="file", extra_fields=None):
    payload = str(text or "")
    if not payload.strip():
        raise ValueError("No log text available to export")
    body_bytes = payload.encode("utf-8", errors="replace")
    boundary = "----club3090" + secrets.token_hex(12)
    parts = []

    def add_field(name, value):
        parts.append(f"--{boundary}\r\n".encode("utf-8"))
        parts.append(f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode("utf-8"))
        parts.append(str(value).encode("utf-8"))
        parts.append(b"\r\n")

    def add_file(name, upload_name, data, content_type="text/plain; charset=utf-8"):
        parts.append(f"--{boundary}\r\n".encode("utf-8"))
        parts.append(
            f'Content-Disposition: form-data; name="{name}"; filename="{upload_name}"\r\n'.encode("utf-8")
        )
        parts.append(f"Content-Type: {content_type}\r\n\r\n".encode("utf-8"))
        parts.append(data)
        parts.append(b"\r\n")

    for key, value in (extra_fields or {}).items():
        add_field(key, value)
    add_file(field_name, filename, body_bytes)
    parts.append(f"--{boundary}--\r\n".encode("utf-8"))
    request = urllib.request.Request(
        url,
        data=b"".join(parts),
        headers={
            "Content-Type": f"multipart/form-data; boundary={boundary}",
            "Accept": "text/plain, application/json",
            "User-Agent": script_user_agent(),
        },
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        body = response.read().decode("utf-8", errors="replace").strip()
    if not body:
        raise RuntimeError("Empty upload response")
    if body.startswith("{"):
        try:
            parsed = json.loads(body)
        except Exception:
            parsed = None
        if isinstance(parsed, dict):
            for key in ("url", "link"):
                candidate = str(parsed.get(key) or "").strip()
                if re.match(r"^https?://\S+$", candidate):
                    return candidate
    match = re.search(r"https?://[^\s\"'<>]+", body)
    if not match:
        raise RuntimeError(f"Unexpected upload response: {body[:300]}")
    return match.group(0)


def upload_text_to_share_host(text, filename="club3090-log.txt"):
    attempts = []
    providers = [
        {
            "name": "temp.sh",
            "url": "https://temp.sh/upload",
            "field_name": "file",
            "extra_fields": {},
        },
        {
            "name": "1c3.ir",
            "url": "https://1c3.ir",
            "field_name": "file",
            "extra_fields": {},
        },
    ]
    for provider in providers:
        try:
            url = _upload_multipart_text(
                provider["url"],
                text,
                filename=filename,
                field_name=provider.get("field_name") or "file",
                extra_fields=provider.get("extra_fields") or {},
            )
            return {"provider": provider["name"], "url": url}
        except Exception as e:
            attempts.append(f"{provider['name']}: {e}")
    raise RuntimeError("Log upload failed: " + " | ".join(attempts))


def _docker_logs_text(container_name, tail_lines=4000):
    key = str(container_name or "").strip()
    if not key:
        return ""
    try:
        p = subprocess.run(
            ["docker", "logs", "--timestamps", "--tail", str(max(1, int(tail_lines or 4000))), key],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=60,
        )
        return str(p.stdout or "")
    except Exception:
        return ""


def _runtime_log_export_candidates(instance_id=""):
    requested = str(instance_id or "").strip().upper()
    seen = set()
    candidates = []

    def add(instance, container):
        key = str(container or "").strip()
        if not key or key in seen:
            return
        seen.add(key)
        candidates.append((instance, key))

    resolved_instance, resolved_container = resolve_runtime_log_container(requested)
    add(resolved_instance, resolved_container)
    legacy = legacy_global_instance_snapshot()
    if legacy and legacy.get("running"):
        add(legacy, legacy.get("container"))
    primary = primary_instance()
    if primary and instance_running(primary):
        add(instance_snapshot(primary), instance_runtime_container_name(primary))
    for row in running_dual_instance_snapshots():
        add(row, row.get("container"))
    current = current_container()
    add(None, current)
    for name in vllm_container_names(all_containers=False, force=True, timeout=3):
        add(None, name)
    return candidates


def export_selected_log(source="docker", instance_id=""):
    source_name = str(source or "docker").strip().lower()
    exported_at = time.strftime("%Y-%m-%d %H:%M:%S")
    if source_name == "audit":
        raw_text = _tail_text_lines(AUDIT_LOG_FILE, max_lines=4000)
        if not raw_text.strip():
            raise ValueError("Audit log is empty")
        file_name = f"club3090-audit-{time.strftime('%Y%m%d-%H%M%S')}.log"
        header = (
            "# club-3090 log export\n"
            f"source: audit\n"
            f"exported_at: {exported_at}\n"
            f"script_version: {SCRIPT_VERSION}\n"
            f"path: {AUDIT_LOG_FILE}\n\n"
        )
        return {
            "source": "audit",
            "instance_id": None,
            "container": "",
            "file_name": file_name,
            "text": header + raw_text,
        }
    selected_instance = None
    container = ""
    raw_text = ""
    for candidate_instance, candidate_container in _runtime_log_export_candidates(instance_id):
        candidate_text = _docker_logs_text(candidate_container, tail_lines=4000)
        if candidate_text.strip():
            selected_instance = candidate_instance
            container = candidate_container
            raw_text = candidate_text
            break
    if not container:
        raise ValueError("No runtime log source selected")
    if not raw_text.strip():
        raise ValueError("Selected runtime log is empty")
    label = (selected_instance.get("id") if selected_instance else (str(instance_id or "").strip().upper() or "primary"))
    file_name = f"club3090-{label.lower()}-{time.strftime('%Y%m%d-%H%M%S')}.log"
    header = (
        "# club-3090 log export\n"
        f"source: docker\n"
        f"instance: {label}\n"
        f"container: {container}\n"
        f"exported_at: {exported_at}\n"
        f"script_version: {SCRIPT_VERSION}\n\n"
    )
    return {
        "source": "docker",
        "instance_id": label,
        "container": container,
        "file_name": file_name,
        "text": header + raw_text,
    }


def status_snapshot_collector():
    while True:
        try:
            refresh_status_snapshot()
        except Exception as e:
            log_control(f"status snapshot error: {e}")
        time.sleep(1)

def wake_on_lan(mac=None, broadcast=None):
    mac = (mac or WOL_MAC or "").replace("-", ":").strip()
    broadcast = broadcast or WOL_BROADCAST
    if not mac:
        raise ValueError("No MAC address configured or provided")
    hexmac = mac.replace(":", "")
    if len(hexmac) != 12:
        raise ValueError("Invalid MAC address")
    packet = bytes.fromhex("FF" * 6 + hexmac * 16)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    try:
        sock.sendto(packet, (broadcast, 9))
    finally:
        sock.close()
    log_control(f"WOL sent mac={mac} broadcast={broadcast}")
    return {"mac": mac, "broadcast": broadcast}

def apply_performance_profile(name):
    global current_profile, GPU_ACTIVE_POWER_LIMIT_W, GPU_IDLE_POWER_LIMIT_W, GPU_IDLE_LOCK_CLOCKS, CPU_ACTIVE_GOVERNOR, CPU_IDLE_GOVERNOR, POWER_IDLE_AFTER_SECONDS, CONTAINER_STOP_AFTER_SECONDS
    if name not in PERFORMANCE_PROFILES:
        raise ValueError("Invalid performance profile")
    log_control(f"PROFILE requested name={name}")
    cfg = PERFORMANCE_PROFILES[name]
    GPU_ACTIVE_POWER_LIMIT_W = int(cfg["gpu_active"]); GPU_IDLE_POWER_LIMIT_W = int(cfg["gpu_idle"]); GPU_IDLE_LOCK_CLOCKS = str(cfg["idle_clocks"])
    CPU_ACTIVE_GOVERNOR = str(cfg["cpu_active"]); CPU_IDLE_GOVERNOR = str(cfg["cpu_idle"])
    POWER_IDLE_AFTER_SECONDS = int(cfg["idle_after"]); CONTAINER_STOP_AFTER_SECONDS = int(cfg["stop_after"])
    current_profile = name
    clear_gpu_session_peaks()
    result = {"cpu": apply_cpu_active_power(), "gpu": apply_gpu_active_power(), "profile": name}
    log_control(f"PROFILE applied name={name} cpu={result.get('cpu')} gpu={result.get('gpu')}")
    return result



def nvidia_settings_available():
    return shutil.which("nvidia-settings") is not None


def parse_gpu_temps():
    temps = []
    if not shutil.which("nvidia-smi"):
        return temps
    rc, out = run_cmd(["nvidia-smi", "--query-gpu=index,temperature.gpu", "--format=csv,noheader,nounits"], timeout=6)
    if rc != 0:
        return temps
    for line in out.splitlines():
        parts = [p.strip() for p in line.split(",")]
        if len(parts) >= 2:
            try:
                temps.append((int(parts[0]), int(float(parts[1]))))
            except Exception:
                pass
    return temps


def gpu_indices():
    vals = [idx for idx, _ in parse_gpu_temps()]
    if vals:
        return vals
    if not shutil.which("nvidia-smi"):
        return [0, 1]
    rc, out = run_cmd(["nvidia-smi", "--query-gpu=index", "--format=csv,noheader,nounits"], timeout=6)
    if rc == 0:
        found = []
        for line in out.splitlines():
            try:
                found.append(int(line.strip()))
            except Exception:
                pass
        if found:
            return found
    return [0, 1]


def parse_gpu_fan_speeds():
    speeds = {}
    if not shutil.which("nvidia-smi"):
        return speeds
    rc, out = run_cmd(["nvidia-smi", "--query-gpu=index,fan.speed", "--format=csv,noheader,nounits"], timeout=6)
    if rc != 0:
        return speeds
    for line in out.splitlines():
        parts = [p.strip() for p in line.split(",")]
        if len(parts) < 2:
            continue
        try:
            idx = int(parts[0])
        except Exception:
            continue
        raw_speed = parts[1].split()[0]
        if not raw_speed or raw_speed.upper() == "N/A":
            continue
        try:
            speeds[idx] = int(float(raw_speed))
        except Exception:
            continue
    return speeds


def fan_speed_for_temp(temp_c):
    for threshold, speed in FAN_CURVE:
        if temp_c < threshold:
            return max(FAN_MIN_SAFE_SPEED, int(speed))
    return max(FAN_MIN_SAFE_SPEED, 100)


def fan_targets_from_temps():
    temps = parse_gpu_temps()
    if not temps:
        return {idx: 70 for idx in gpu_indices()}
    return {idx: fan_speed_for_temp(temp) for idx, temp in temps}


def fan_targets_from_temps_for_indices(indices=None):
    available_indices = gpu_indices()
    if indices is None:
        target_indices = list(available_indices)
    else:
        target_indices = []
        for idx in indices:
            try:
                target_indices.append(int(idx))
            except Exception:
                pass
        target_indices = [idx for idx in target_indices if idx in available_indices]
    if not target_indices:
        return {}
    wanted = set(target_indices)
    temps = [(idx, temp) for idx, temp in parse_gpu_temps() if idx in wanted]
    if not temps:
        return {idx: 70 for idx in target_indices}
    return {idx: fan_speed_for_temp(temp) for idx, temp in temps}


def wait_for_nvidia_display(display=":99", timeout=10, explicit_display=True):
    deadline = time.time() + timeout
    env = os.environ.copy()
    env["DISPLAY"] = display
    env.pop("XAUTHORITY", None)
    last = "display not ready"
    while time.time() < deadline:
        try:
            cmd = ["nvidia-settings"]
            if explicit_display:
                cmd += ["-c", display]
            cmd += ["-q", "gpus"]
            p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=3, env=env)
            last = (p.stdout or "").strip()
            if p.returncode == 0:
                return True, last
        except Exception as e:
            last = str(e)
        time.sleep(0.5)
    return False, last


def tail_text_file(path, max_lines=40):
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            lines = f.readlines()
        return "".join(lines[-max_lines:]).strip()
    except Exception:
        return ""


def start_headless_x_direct(display=":99"):
    display_num = str(display).lstrip(":") or "99"
    log_file = "/var/log/club3090-headless-xorg.log"
    config_file = "/etc/X11/club3090-headless-xorg.conf"
    run_cmd(["systemctl", "stop", "club3090-headless-x.service"], timeout=10)
    try:
        subprocess.Popen(
            [
                "/usr/bin/Xorg",
                f":{display_num}",
                "-config", config_file,
                "-noreset",
                "-nolisten", "tcp",
                "-ac",
                "-novtswitch",
                "-sharevts",
                "+extension", "GLX",
                "+extension", "RANDR",
                "+extension", "RENDER",
                "-logfile", log_file,
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL,
            close_fds=True,
        )
        return True, f"started direct Xorg on :{display_num}"
    except Exception as e:
        return False, str(e)


def ensure_headless_x_running(explicit_display=True):
    # Manual NVIDIA fan control needs an NVIDIA X control display. This service
    # starts a private headless Xorg on :99 with CoolBits enabled and no TCP listener.
    if not nvidia_settings_available():
        return False, "nvidia-settings not found"
    display = os.environ.get("CLUB3090_FAN_DISPLAY", ":99")
    ok, msg = wait_for_nvidia_display(display, timeout=1, explicit_display=explicit_display)
    if ok:
        return True, "headless X already ready"
    if shutil.which("systemctl"):
        rc, out = run_cmd(["systemctl", "start", "club3090-headless-x.service"], timeout=20)
        ok, msg = wait_for_nvidia_display(display, timeout=12, explicit_display=explicit_display)
        if ok:
            return True, "started club3090-headless-x.service"
        direct_ok, direct_msg = start_headless_x_direct(display)
        if direct_ok:
            ok, msg = wait_for_nvidia_display(display, timeout=12, explicit_display=explicit_display)
            if ok:
                return True, "started direct Xorg fallback after systemd path failed"
        xlog = tail_text_file("/var/log/club3090-headless-xorg.log", max_lines=60)
        return False, f"headless X not ready after start rc={rc}: {out[-800:]} / {msg} / direct={direct_msg} / xlog={xlog[-2000:]}"
    return False, "systemctl unavailable; cannot start headless X"


def run_nvidia_settings(args, explicit_display=True):
    if not nvidia_settings_available():
        return 127, "nvidia-settings not found"
    display = os.environ.get("CLUB3090_FAN_DISPLAY", ":99")
    ok, msg = ensure_headless_x_running(explicit_display=explicit_display)
    if not ok:
        return 126, msg
    env = os.environ.copy()
    env["DISPLAY"] = display
    # Xorg is started with -ac by our private service, so no XAUTHORITY is needed.
    env.pop("XAUTHORITY", None)
    try:
        cmd = ["nvidia-settings"]
        if explicit_display:
            cmd += ["-c", display]
        p = subprocess.run(cmd + args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=15, env=env)
        return p.returncode, (p.stdout or "").strip()
    except Exception as e:
        return 999, str(e)


def discover_nvidia_fan_indices():
    if not nvidia_settings_available():
        return []
    rc, out = run_nvidia_settings(["-q", "fans"])
    if rc != 0:
        return []
    found = []
    for match in re.finditer(r"\[fan:(\d+)\]", out or "", re.IGNORECASE):
        idx = int(match.group(1))
        if idx not in found:
            found.append(idx)
    return found


def fan_indices_for_gpu_targets(target_gpu_indices, available_gpu_indices=None, fan_indices=None):
    fan_list = sorted({int(idx) for idx in (fan_indices or [])})
    if not fan_list:
        return []
    gpu_list = [int(idx) for idx in (available_gpu_indices or gpu_indices())]
    if not gpu_list:
        return fan_list
    target_list = [int(idx) for idx in (target_gpu_indices or []) if int(idx) in gpu_list]
    if not target_list or len(target_list) >= len(gpu_list):
        return fan_list
    chunk = max(1, (len(fan_list) + len(gpu_list) - 1) // len(gpu_list))
    mapping = {}
    cursor = 0
    for pos, gpu_idx in enumerate(gpu_list):
        remaining_gpus = len(gpu_list) - pos
        remaining_fans = len(fan_list) - cursor
        if remaining_fans <= 0:
            mapping[gpu_idx] = []
            continue
        take = remaining_fans if remaining_gpus == 1 else min(chunk, remaining_fans)
        mapping[gpu_idx] = fan_list[cursor:cursor + take]
        cursor += take
    selected = []
    for gpu_idx in target_list:
        selected.extend(mapping.get(gpu_idx, []))
    return selected


def run_nvidia_assignments(assignments):
    results = []
    success = 0
    for assignment in assignments:
        rc, out = run_nvidia_settings(["-a", assignment])
        text = (out or "").strip()
        if rc == 0:
            success += 1
        results.append(f"{assignment}: rc={rc} {text[-500:]}")
    return success, results


def run_nvidia_assignment_batch(assignments):
    if not assignments:
        return 0, []
    args = []
    for assignment in assignments:
        args += ["-a", assignment]
    rc, out = run_nvidia_settings(args)
    text = (out or "").strip()
    return rc, [f"batch rc={rc} assignments={assignments}: {text[-1500:]}"]


def restore_gpu_fans_auto(indices=None):
    available_indices = gpu_indices()
    if indices is None:
        indices = list(available_indices)
    else:
        indices = [int(idx) for idx in indices if int(idx) in available_indices]
    if not indices:
        return ["no GPU targets selected for auto restore"]
    assignments = [f"[gpu:{gpu_idx}]/GPUFanControlState=0" for gpu_idx in indices]
    batch_rc, batch_results = run_nvidia_assignment_batch(assignments)
    if batch_rc == 0:
        return batch_results
    success, retry_results = run_nvidia_assignments(assignments)
    return batch_results + retry_results + [f"auto restore success={success}/{len(assignments)}"]


def verify_manual_fan_target(target_gpu_indices, target_speed, timeout=3.0):
    if target_speed is None:
        return False, {}
    wanted = {int(idx) for idx in (target_gpu_indices or [])}
    if not wanted:
        return False, {}
    deadline = time.time() + float(timeout)
    last = {}
    threshold = max(0, int(target_speed) - 15)
    while time.time() < deadline:
        speeds = parse_gpu_fan_speeds()
        last = {idx: speeds.get(idx) for idx in wanted if idx in speeds}
        if last and all(speed is not None and int(speed) >= threshold for speed in last.values()):
            return True, last
        time.sleep(0.4)
    return False, last


def set_gpu_fans(speed=None, auto=False, indices=None):
    # Canonical scoped fan-control path using the working private headless-X / nvidia-settings flow.
    results = []
    available_indices = gpu_indices()
    if indices is None:
        indices = list(available_indices)
    else:
        clean = []
        for idx in indices:
            try:
                clean.append(int(idx))
            except Exception:
                pass
        indices = [idx for idx in clean if idx in available_indices]
    if not indices:
        return ["no GPU targets selected"]
    fan_objects = discover_nvidia_fan_indices()
    if auto:
        assignments = [f"[gpu:{gpu_idx}]/GPUFanControlState=0" for gpu_idx in indices]
        batch_rc, batch_results = run_nvidia_assignment_batch(assignments)
        results.extend(batch_results)
        success, retry_results = run_nvidia_assignments(assignments) if batch_rc != 0 else (len(assignments), [])
        results.extend(retry_results)
        ok = (batch_rc == 0) or (success == len(assignments))
        with metrics_lock:
            power_state["fans"] = "auto" if ok else "auto_failed"
            power_state["last_action"] = "fans_auto"
            power_state["last_error"] = "" if ok else " | ".join([r for r in results if "rc=0" not in r])[-1000:]
        log_control("FANS auto: " + " || ".join(results))
        return results

    if speed is None:
        targets = fan_targets_from_temps_for_indices(indices)
        # Be deliberately aggressive: use the hottest-card target for all detected
        # fan controllers. This avoids ambiguous fan<->GPU mapping issues on dual
        # 3090 cards and matches the cooling priority.
        target = max(targets.values()) if targets else 70
        mode_label = "manual_curve"
    else:
        targets = {idx: int(speed) for idx in indices}
        target = int(speed)
        mode_label = "manual_max" if target >= FAN_MAX_SPEED else "manual_fixed"

    target = max(FAN_MIN_SAFE_SPEED, min(100, int(target)))
    mapped_fans = fan_indices_for_gpu_targets(indices, available_gpu_indices=available_indices, fan_indices=fan_objects)
    if not mapped_fans:
        guessed_fans = fan_objects or list(range(0, max(2, min(8, len(available_indices) * 2))))
        mapped_fans = fan_indices_for_gpu_targets(indices, available_gpu_indices=available_indices, fan_indices=guessed_fans)
        if not mapped_fans and len(indices) >= len(available_indices):
            mapped_fans = guessed_fans
    enable_assignments = [f"[gpu:{gpu_idx}]/GPUFanControlState=1" for gpu_idx in indices]
    direct_assignments = [f"[gpu:{gpu_idx}]/GPUTargetFanSpeed={target}" for gpu_idx in indices]
    fan_assignments = [f"[fan:{fan_idx}]/GPUTargetFanSpeed={target}" for fan_idx in mapped_fans]
    batch_assignments = list(enable_assignments)
    if direct_assignments:
        batch_assignments.extend(direct_assignments)
    if fan_assignments:
        batch_assignments.extend(fan_assignments)
    batch_rc, batch_results = run_nvidia_assignment_batch(batch_assignments)
    results.extend(batch_results)

    enable_success, enable_results = run_nvidia_assignments(enable_assignments) if batch_rc != 0 else (len(enable_assignments), [])
    results.extend(enable_results)

    direct_success, direct_results = run_nvidia_assignments(direct_assignments) if batch_rc != 0 else (len(direct_assignments), [])
    results.extend(direct_results)

    fan_success = 0
    if fan_assignments and batch_rc != 0:
        fan_success, fan_results = run_nvidia_assignments(fan_assignments)
        results.extend(fan_results)
    elif fan_assignments:
        fan_success = len(fan_assignments)

    verified, observed = verify_manual_fan_target(indices, target)
    results.append(f"fan verify target={target} observed={observed}: rc={0 if verified else 1}")
    ok = (batch_rc == 0 or enable_success == len(enable_assignments)) and (direct_success > 0 or fan_success > 0 or verified)
    if not ok:
        legacy_fan_assignments = [f"[fan:{fan_idx}]/GPUTargetFanSpeed={target}" for fan_idx in range(0, 8)]
        legacy_batch_assignments = list(enable_assignments) + legacy_fan_assignments
        legacy_batch_rc, legacy_batch_results = run_nvidia_assignment_batch(legacy_batch_assignments)
        results.extend(legacy_batch_results)
        legacy_fan_success = 0
        if legacy_batch_rc != 0:
            legacy_fan_success, legacy_fan_results = run_nvidia_assignments(legacy_fan_assignments)
            results.extend(legacy_fan_results)
        else:
            legacy_fan_success = len(legacy_fan_assignments)
        legacy_verified, legacy_observed = verify_manual_fan_target(indices, target, timeout=4.0)
        results.append(f"fan legacy verify target={target} observed={legacy_observed}: rc={0 if legacy_verified else 1}")
        ok = (legacy_batch_rc == 0 or legacy_fan_success > 0 or legacy_verified)
    if not ok:
        failover_results = restore_gpu_fans_auto(indices)
        results.extend([f"manual failover -> {line}" for line in failover_results])
    with metrics_lock:
        power_state["fans"] = mode_label if ok else "manual_failed"
        power_state["last_action"] = "fans_set"
        power_state["last_error"] = "" if ok else " | ".join([r for r in results if "rc=0" not in r])[-1200:]
    log_control("FANS set: " + " || ".join(results))
    return results

def apply_fan_curve_once():
    if fan_manual_override or not power_optimizations_enabled:
        return []
    if time.time() < fan_curve_pause_until:
        return [f"fan curve paused for {int(fan_curve_pause_until-time.time())}s"]
    target_indices = fan_target_gpu_indices(cooling_scope_instance_id)
    if not target_indices:
        return ["no GPU targets selected for fan curve"]
    return set_gpu_fans(speed=None, auto=False, indices=target_indices)

def run_cmd(cmd, timeout=15, cwd=None, env=None):
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=timeout, cwd=cwd, env=env)
        return p.returncode, (p.stdout or "").strip()
    except Exception as e:
        return 999, str(e)


def set_cpu_governor(governor):
    if not governor:
        return []
    results = []
    if shutil.which("cpupower"):
        rc, out = run_cmd(["cpupower", "frequency-set", "-g", governor], timeout=20)
        results.append(f"cpupower governor {governor}: rc={rc} {out[-500:]}")
        if rc == 0:
            return results
    base = "/sys/devices/system/cpu"
    try:
        for name in os.listdir(base):
            if not name.startswith("cpu") or not name[3:].isdigit():
                continue
            path = os.path.join(base, name, "cpufreq", "scaling_governor")
            if os.path.exists(path):
                try:
                    with open(path, "w", encoding="utf-8") as f:
                        f.write(governor)
                except Exception as e:
                    results.append(f"{path}: {e}")
    except Exception as e:
        results.append(str(e))
    return results


def apply_gpu_idle_power(skip_fans=False):
    if not power_optimizations_enabled:
        return ["power optimizations disabled"]
    results = []
    if not shutil.which("nvidia-smi"):
        return ["nvidia-smi not found"]
    for cmd in (["nvidia-smi", "-pm", "1"], ["nvidia-smi", "-pl", str(GPU_IDLE_POWER_LIMIT_W)], ["nvidia-smi", "-lgc", GPU_IDLE_LOCK_CLOCKS]):
        rc, out = run_cmd(cmd, timeout=20)
        results.append(f"{' '.join(cmd)}: rc={rc} {out[-500:]}")
    if not skip_fans:
        results += apply_fan_curve_once()
    with metrics_lock:
        power_state["gpu"] = "idle"
        power_state["last_action"] = "gpu_idle"
        power_state["last_error"] = " | ".join([r for r in results if "rc=0" not in r and "disabled" not in r])[-1000:]
    log_control("POWER gpu idle: " + " || ".join(results))
    return results


def apply_gpu_active_power(skip_fans=False):
    if not power_optimizations_enabled:
        return ["power optimizations disabled"]
    results = []
    if not shutil.which("nvidia-smi"):
        return ["nvidia-smi not found"]
    cmds = [["nvidia-smi", "-pm", "1"], ["nvidia-smi", "-rgc"], ["nvidia-smi", "-pl", str(GPU_ACTIVE_POWER_LIMIT_W)]]
    if GPU_ACTIVE_LOCK_CLOCKS:
        cmds.append(["nvidia-smi", "-lgc", GPU_ACTIVE_LOCK_CLOCKS])
    for cmd in cmds:
        rc, out = run_cmd(cmd, timeout=20)
        results.append(f"{' '.join(cmd)}: rc={rc} {out[-500:]}")
    if not skip_fans:
        results += apply_fan_curve_once()
    with metrics_lock:
        power_state["gpu"] = "active"
        power_state["last_action"] = "gpu_active"
        power_state["last_error"] = " | ".join([r for r in results if "rc=0" not in r and "disabled" not in r])[-1000:]
    log_control("POWER gpu active: " + " || ".join(results))
    return results


def apply_cpu_idle_power():
    results = set_cpu_governor(CPU_IDLE_GOVERNOR)
    with metrics_lock:
        power_state["cpu"] = "idle"
        power_state["last_action"] = "cpu_idle"
    log_control("POWER cpu idle: " + " || ".join(results))
    return results


def apply_cpu_active_power():
    results = set_cpu_governor(CPU_ACTIVE_GOVERNOR)
    with metrics_lock:
        power_state["cpu"] = "active"
        power_state["last_action"] = "cpu_active"
    log_control("POWER cpu active: " + " || ".join(results))
    return results


def stop_vllm_container(reason="idle", instance_id=None):
    with switch_lock:
        target = get_instance(instance_id) if instance_id else primary_instance()
        if target is None:
            log_control(f"POWER legacy stop requested reason={reason}")
            out = cleanup_vllm_containers()
            return 0, str(out or "")[-4000:]
        log_control(f"POWER stop container requested reason={reason} instance={target['id']}")
        rc, out = stop_instance(target["id"])
        with metrics_lock:
            power_state["container"] = "stopped" if rc == 0 else "stop_failed"
            power_state["last_action"] = "container_stop"
            power_state["last_error"] = out if rc != 0 else ""
        log_control(f"POWER stop container rc={rc}: {out}")
        return rc, out


def ensure_vllm_running_for_request(instance_id=None):
    global last_inference_time
    with metrics_lock:
        last_inference_time = time.time()
    apply_cpu_active_power()
    apply_gpu_active_power(skip_fans=True)
    target = get_instance(instance_id) if instance_id else primary_instance()
    if target is None:
        mode = active_mode()
        port = mode_default_port(mode, 8020)
        if port_open(port, timeout=0.25):
            with metrics_lock:
                power_state["container"] = "running"
            return
        log_control(f"POWER auto-starting legacy default mode={mode}")
        run_switch(mode)
        with metrics_lock:
            power_state["container"] = "running"
        return
    port = int(target["port"])
    if port_open(port, timeout=0.25):
        with metrics_lock:
            power_state["container"] = "running"
        return
    log_control(f"POWER auto-starting container for request instance={target['id']} mode={target['mode']}")
    start_instance(target["id"])
    with metrics_lock:
        power_state["container"] = "running"


def idle_watchdog():
    idle_power_applied = False
    while True:
        try:
            now = time.time()
            with metrics_lock:
                active = metrics.get("active_requests", 0)
                booting = switch_job_active()
                idle_for = 0 if active > 0 or booting else max(0.0, now - last_request_finished_at)
            if active == 0 and not booting and idle_for >= POWER_IDLE_AFTER_SECONDS and not idle_power_applied:
                apply_cpu_idle_power()
                apply_gpu_idle_power()
                idle_power_applied = True
            if active > 0 or booting or idle_for < POWER_IDLE_AFTER_SECONDS:
                idle_power_applied = False
            if power_optimizations_enabled and not fan_manual_override:
                # Refresh manual fan curve periodically even while idle; Linux/NVIDIA
                # auto fan behavior can leave 3090 fans off until temps are too high.
                apply_fan_curve_once()
        except Exception as e:
            log_control(f"POWER watchdog error: {e}")
        time.sleep(15)



def reset_gpu_power_defaults():
    results = []
    if not shutil.which("nvidia-smi"):
        return ["nvidia-smi not found"]
    for cmd in (["nvidia-smi", "-rgc"], ["nvidia-smi", "-pm", "0"]):
        rc, out = run_cmd(cmd, timeout=20)
        results.append(f"{' '.join(cmd)}: rc={rc} {out[-700:]}")
    # Reset fans to automatic too; disabling optimizations should put the system
    # back under default NVIDIA control as much as Linux allows.
    results += set_gpu_fans(auto=True)
    with metrics_lock:
        power_state["gpu"] = "default"
        power_state["fans"] = "auto"
        power_state["last_action"] = "power_defaults"
        power_state["last_error"] = " | ".join([r for r in results if "rc=0" not in r])[-1000:]
    log_control("POWER defaults: " + " || ".join(results))
    return results


def cancel_pending_fan_curve_resume():
    global fan_curve_resume_token
    fan_curve_resume_token += 1
    return fan_curve_resume_token


def schedule_fan_curve_resume(indices=None, delay=1.0):
    target_indices = [int(idx) for idx in (indices or [])]
    token = cancel_pending_fan_curve_resume()
    def worker():
        global fan_curve_pause_until
        time.sleep(max(0.0, float(delay or 0.0)))
        if token != fan_curve_resume_token:
            return
        if fan_manual_override or not power_optimizations_enabled:
            return
        fan_curve_pause_until = 0.0
        resume_targets = target_indices or fan_target_gpu_indices(cooling_scope_instance_id)
        if not resume_targets:
            log_control("FANS auto-resume skipped: no GPU targets selected")
            return
        results = set_gpu_fans(speed=None, auto=False, indices=resume_targets)
        log_control("FANS auto-resume: " + " || ".join(results))
    threading.Thread(target=worker, name="club3090-fan-resume", daemon=True).start()


def set_power_optimizations(enabled, instance_id=None):
    global power_optimizations_enabled, fan_curve_pause_until, cooling_scope_instance_id
    if instance_id is not None:
        cooling_scope_instance_id = str(instance_id or "GLOBAL").strip().upper() or "GLOBAL"
    cancel_pending_fan_curve_resume()
    power_optimizations_enabled = bool(enabled)
    with metrics_lock:
        power_state["power_optimizations"] = "enabled" if power_optimizations_enabled else "disabled"
    if power_optimizations_enabled:
        fan_curve_pause_until = 0.0
        return {"cpu": apply_cpu_active_power(), "gpu": apply_gpu_active_power(skip_fans=True), "fans": apply_fan_curve_once()}
    fan_curve_pause_until = time.time() + 10**9
    return {"cpu": set_cpu_governor("performance"), "gpu": reset_gpu_power_defaults()}


def fan_target_gpu_indices(instance_id=None):
    raw = str(instance_id or "").strip().upper()
    if raw in ("", "GLOBAL"):
        return gpu_indices()
    instance = get_instance(raw)
    if instance:
        return [int(idx) for idx in (instance.get("gpu_indices") or [instance.get("gpu_index", 0)])]
    parsed = parse_instance_identifier(raw)
    if parsed:
        return [int(idx) for idx in (parsed.get("gpu_indices") or [])]
    return gpu_indices()

def set_fan_max_toggle(enable, instance_id=None):
    global fan_manual_override, fan_curve_pause_until, cooling_scope_instance_id
    if instance_id is not None:
        cooling_scope_instance_id = str(instance_id or "GLOBAL").strip().upper() or "GLOBAL"
    target_indices = fan_target_gpu_indices(instance_id)
    cancel_pending_fan_curve_resume()
    fan_manual_override = bool(enable)
    if fan_manual_override:
        fan_curve_pause_until = 0.0
        return set_gpu_fans(speed=FAN_MAX_SPEED, auto=False, indices=target_indices)
    fan_curve_pause_until = time.time() + (1 if power_optimizations_enabled else 0)
    results = set_gpu_fans(auto=True, indices=target_indices)
    if power_optimizations_enabled:
        schedule_fan_curve_resume(indices=target_indices, delay=1.0)
    else:
        fan_curve_pause_until = 0.0
    return results

def power_status():
    with metrics_lock:
        active = int(metrics.get("active_requests", 0) or 0)
        booting = switch_job_active()
        idle_for = 0 if active > 0 or booting else int(max(0.0, time.time() - last_request_finished_at))
        fan_curve_text = ", ".join([f"<{temp}C={speed}%" for temp, speed in FAN_CURVE]) + ", >=65C=100%"
        return {**power_state, "profile": current_profile, "idle_for_seconds": idle_for, "idle_power_after_seconds": POWER_IDLE_AFTER_SECONDS, "container_stop_after_seconds": 0, "container_auto_stop_enabled": CONTAINER_AUTO_STOP_ENABLED, "gpu_active_power_limit_w": GPU_ACTIVE_POWER_LIMIT_W, "gpu_idle_power_limit_w": GPU_IDLE_POWER_LIMIT_W, "gpu_idle_lock_clocks": GPU_IDLE_LOCK_CLOCKS, "cpu_active_governor": CPU_ACTIVE_GOVERNOR, "cpu_idle_governor": CPU_IDLE_GOVERNOR, "optimizations_enabled": power_optimizations_enabled, "fan_manual_override": fan_manual_override, "fan_curve": fan_curve_text, "fan_min_safe_speed": FAN_MIN_SAFE_SPEED}

def _docker_inspect_state(container_name):
    name = str(container_name or "").strip()
    if not name:
        return {"exists": False, "running": False, "exit_code": None, "status": ""}
    try:
        payload = subprocess.check_output(
            [
                "docker",
                "inspect",
                "--format",
                "{{.State.Status}}|{{.State.Running}}|{{.State.ExitCode}}",
                name,
            ],
            text=True,
            stderr=subprocess.DEVNULL,
            timeout=5,
        ).strip()
    except Exception:
        return {"exists": False, "running": False, "exit_code": None, "status": ""}
    parts = payload.split("|")
    status = str(parts[0] if len(parts) > 0 else "").strip().lower()
    running = str(parts[1] if len(parts) > 1 else "").strip().lower() == "true"
    try:
        exit_code = int(str(parts[2] if len(parts) > 2 else "").strip())
    except Exception:
        exit_code = None
    return {
        "exists": True,
        "running": running,
        "exit_code": exit_code,
        "status": status,
    }


def _docker_logs_tail(container_name, lines=80):
    name = str(container_name or "").strip()
    if not name:
        return ""
    try:
        return subprocess.check_output(
            ["docker", "logs", "--tail", str(max(1, int(lines))), name],
            text=True,
            stderr=subprocess.STDOUT,
            timeout=10,
        )
    except Exception:
        return ""


def _container_bootstrap_complete(container_name):
    logs = _docker_logs_tail(container_name, lines=200)
    if not logs:
        return False
    marker = str(LOG_BOOTSTRAP_MARKER or "").strip()
    if marker and marker in logs:
        return True
    return "Application startup complete" in logs


def _ready_url_responding(url):
    target = str(url or "").strip()
    if not target:
        return False
    try:
        with urllib.request.urlopen(target, timeout=3) as response:
            return int(getattr(response, "status", 200) or 200) < 500
    except Exception:
        return False


def wait_for_runtime_ready(container_name, ready_url, timeout=900):
    name = str(container_name or "").strip()
    target_url = str(ready_url or "").strip()
    deadline = time.time() + max(5, int(timeout))
    seen_container = False
    while time.time() < deadline:
        state = _docker_inspect_state(name) if name else {"exists": False, "running": False, "exit_code": None, "status": ""}
        if state.get("exists"):
            seen_container = True
            if not state.get("running"):
                logs = _docker_logs_tail(name, lines=80)
                raise RuntimeError(
                    f"Container {name} stopped during boot "
                    f"(status={state.get('status') or 'unknown'}, exit={state.get('exit_code')}).\n"
                    + (logs[-12000:] if logs else "No docker logs were captured before exit.")
                )
        elif seen_container:
            raise RuntimeError(f"Container {name} disappeared before reaching ready state.")
        if _ready_url_responding(target_url) and (not name or _container_bootstrap_complete(name)):
            return True
        time.sleep(1)
    if name and not seen_container:
        raise RuntimeError(f"Container {name} never appeared after compose launch.")
    logs = _docker_logs_tail(name, lines=120) if name else ""
    if logs:
        raise RuntimeError(
            f"Timed out waiting for runtime readiness at {target_url}.\n{logs[-12000:]}"
        )
    raise RuntimeError(f"Timed out waiting for runtime readiness at {target_url}.")

def run_switch(mode):
    selector = canonical_mode_selector(mode)
    spec = resolve_variant_spec(selector)
    if not spec:
        raise ValueError(f"Invalid mode: {mode}")

    def attempt(target_mode, label):
        target_spec = resolve_variant_spec(target_mode)
        if not target_spec:
            raise RuntimeError(f"Unknown target mode: {target_mode}")
        ensure_variant_install_ready(target_spec)
        target_port = mode_default_port(target_mode, 8020)
        env = _repo_subprocess_env()
        env["READY_URL"] = ready_url_for_mode(target_mode)
        env["PORT"] = str(int(target_port))
        env["MODEL_DIR"] = _resolve_variant_model_dir_root(target_spec)
        env["COMPOSE_BIN"] = COMPOSE_BIN
        apply_cpu_active_power()
        apply_gpu_active_power(skip_fans=True)
        log_control(f"SWITCH {label} cleanup before mode={target_mode}")
        cleanup_msg = cleanup_vllm_containers()
        log_control(f"SWITCH {label} start mode={target_mode} port={env['PORT']} ready_url={env['READY_URL']}")
        output = ""
        rc = 0
        upstream_tag = str(target_spec.get("upstream_tag") or "").strip()
        switch_path = os.path.join(CLUB3090_DIR, "scripts", "switch.sh")
        if upstream_tag and os.path.exists(switch_path):
            p = subprocess.run(["bash", "scripts/switch.sh", upstream_tag, "--no-wait"], cwd=CLUB3090_DIR, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=1800)
            rc = int(p.returncode)
            output = p.stdout or ""
        else:
            compose_file = str(target_spec.get("compose_abs_path") or "").strip()
            compose_project_dir = str(target_spec.get("compose_project_dir_abs_path") or "").strip() or os.path.dirname(compose_file) or CLUB3090_DIR
            cmd = compose_cmd() + ["--project-directory", compose_project_dir, "-f", compose_file, "up", "-d"]
            p = subprocess.run(
                cmd,
                cwd=compose_project_dir,
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                timeout=1800,
            )
            rc = int(p.returncode)
            output = p.stdout or ""
        if rc != 0:
            log_control(f"SWITCH {label} failed mode={target_mode} rc={rc}")
            cleanup_vllm_containers()
            raise RuntimeError((output[-12000:] or f"launch exited with {rc}") + f"\ncleanup={cleanup_msg}")
        wait_for_runtime_ready(
            str(target_spec.get("container_name") or ""),
            env["READY_URL"],
            timeout=900,
        )
        write_active_mode(target_mode)
        write_last_good_mode(target_mode)
        clear_switch_failure(target_mode)
        _set_switch_job(
            active=False,
            status="success",
            mode=target_mode,
            target="GLOBAL",
            finished_at=int(time.time()),
            error="",
        )
        with metrics_lock:
            power_state["container"] = "running"
            power_state["last_action"] = f"switch_{target_mode}"
            power_state["last_error"] = ""
        log_control(f"SWITCH {label} complete mode={target_mode}")
        return output[-12000:]

    with switch_lock:
        _set_switch_job(
            active=True,
            status="booting",
            mode=selector,
            target="GLOBAL",
            started_at=int(time.time()),
            finished_at=0,
            error="",
        )
        try:
            return attempt(selector, "primary")
        except Exception as first_error:
            write_switch_failure(selector, first_error)
            if read_active_mode_file() == selector:
                clear_active_mode()
            _set_switch_job(
                active=False,
                status="failed",
                mode=selector,
                target="GLOBAL",
                finished_at=int(time.time()),
                error=str(first_error)[-12000:],
            )
            with metrics_lock:
                power_state["container"] = "stopped"
                power_state["last_action"] = f"switch_failed_{selector}"
                power_state["last_error"] = str(first_error)[-1000:]
            raise

def parse_preset_path(path):
    parsed = urlsplit(path)
    clean = parsed.path
    suffix = ("?" + parsed.query) if parsed.query else ""
    parts = [p for p in clean.split("/") if p]
    if not parts:
        return path, None, None

    # Supported raw/preset URL forms:
    #   /v1/chat/completions
    #   /chat/completions            (normalize to /v1/chat/completions)
    #   /v1/completions
    #   /completions                 (normalize to /v1/completions)
    #   /v1/models
    #   /models                      (normalize to /v1/models)
    #   /v1/<preset>/chat/completions
    #   /v1/<preset>/v1/chat/completions   (clients that append /v1/...)
    #   /<preset>/chat/completions
    #   /<preset>/v1/chat/completions      (clients with base URL :8009/<preset>)
    # This preserves raw OpenAI paths like /v1/chat/completions.
    if len(parts) >= 3 and parts[0] == "v1" and parts[1] == "chat" and parts[2] == "completions":
        return path, None, None
    if len(parts) >= 2 and parts[0] == "chat" and parts[1] == "completions":
        return "/v1/chat/completions" + (("/" + "/".join(parts[2:])) if len(parts) > 2 else "") + suffix, None, None
    if parts and parts[0] == "completions":
        return "/v1/completions" + (("/" + "/".join(parts[1:])) if len(parts) > 1 else "") + suffix, None, None
    if parts == ["models"]:
        return "/v1/models" + suffix, None, None

    all_presets = get_all_presets()

    def split_candidate(raw):
        cap = None
        candidate = raw
        for prefix, value in LENGTH_PREFIXES.items():
            if candidate.startswith(prefix):
                candidate = candidate[len(prefix):]
                cap = value
                break
        if candidate in all_presets:
            return candidate, cap
        return None, None

    def upstream_from_rest(rest):
        # If a client appended /v1/... to a preset base URL, remove that nested v1.
        if rest and rest[0] == "v1":
            rest = rest[1:]
        if not rest:
            return "/v1"
        if rest == ["models"]:
            return "/v1/models"
        if rest[:2] == ["chat", "completions"]:
            return "/v1/chat/completions" + (("/" + "/".join(rest[2:])) if len(rest) > 2 else "")
        if rest[0] == "completions":
            return "/v1/completions" + (("/" + "/".join(rest[1:])) if len(rest) > 1 else "")
        return "/v1/" + "/".join(rest)

    # Normal current style: /v1/<preset>/...
    if parts[0] == "v1" and len(parts) >= 2:
        candidate, cap = split_candidate(parts[1])
        if candidate:
            return upstream_from_rest(parts[2:]) + suffix, candidate, cap
        return path, None, None

    # Compatibility style: /<preset>/... so clients can safely append /v1/...
    candidate, cap = split_candidate(parts[0])
    if candidate:
        return upstream_from_rest(parts[1:]) + suffix, candidate, cap

    return path, None, None

def merge_preset_params(payload, preset):
    merged = dict(payload or {})
    for key, value in dict(preset or {}).items():
        if key == "chat_template_kwargs" and isinstance(value, dict):
            current = merged.get("chat_template_kwargs")
            if not isinstance(current, dict):
                current = {}
            merged["chat_template_kwargs"] = {**current, **value}
        else:
            merged[key] = value
    return merged

def merge_system_prompt_text(primary, secondary):
    first = str(primary or "").strip()
    second = str(secondary or "").strip()
    if first and second:
        return first + "\n\n" + second
    return first or second

def inject_system_prompt_into_messages(messages, system_prompt):
    prompt = str(system_prompt or "").strip()
    if not prompt:
        return messages
    rows = list(messages or [])
    for item in rows:
        if not isinstance(item, dict):
            continue
        if str(item.get("role") or "").strip().lower() != "system":
            continue
        content = item.get("content")
        if isinstance(content, str):
            item["content"] = merge_system_prompt_text(prompt, content)
        elif isinstance(content, list):
            parts = [{"type": "text", "text": prompt}]
            parts.extend([part for part in content if isinstance(part, dict)])
            item["content"] = parts
        else:
            item["content"] = prompt
        return rows
    rows.insert(0, {"role": "system", "content": prompt})
    return rows

def inject_system_prompt_into_payload(payload, system_prompt):
    prompt = str(system_prompt or "").strip()
    if not prompt or not isinstance(payload, dict):
        return payload
    updated = dict(payload)
    if isinstance(updated.get("messages"), list):
        updated["messages"] = inject_system_prompt_into_messages(updated.get("messages"), prompt)
        return updated
    if isinstance(updated.get("instructions"), str):
        updated["instructions"] = merge_system_prompt_text(prompt, updated.get("instructions"))
        return updated
    if isinstance(updated.get("prompt"), str):
        updated["prompt"] = merge_system_prompt_text(prompt, updated.get("prompt"))
        return updated
    if isinstance(updated.get("input"), str):
        updated["input"] = merge_system_prompt_text(prompt, updated.get("input"))
        return updated
    return updated

def apply_preset(body, preset_name, max_token_cap):
    try:
        data = json.loads(body or b"{}")
    except Exception:
        return body
    preset = get_all_presets().get(preset_name)
    if not preset:
        return body
    data = merge_preset_params(dict(data), preset)
    data = inject_system_prompt_into_payload(data, preset_system_prompt(preset_name))
    if max_token_cap is not None:
        capped_any = False
        for token_key in ("max_tokens", "max_completion_tokens"):
            if token_key in data:
                try:
                    data[token_key] = min(int(data[token_key]), max_token_cap)
                except Exception:
                    data[token_key] = max_token_cap
                capped_any = True
        if not capped_any:
            data["max_tokens"] = max_token_cap
    return json.dumps(data, separators=(",", ":")).encode("utf-8")

def parse_instance_path(path):
    parsed = urlsplit(path)
    parts = [p for p in parsed.path.split("/") if p]
    if parts and parse_instance_identifier(parts[0]):
        instance_id = parse_instance_identifier(parts[0])["id"]
        trimmed = "/" + "/".join(parts[1:]) if len(parts) > 1 else "/"
        if parsed.query:
            trimmed += "?" + parsed.query
        return instance_id, trimmed
    return None, path


def runtime_supports_vision(spec):
    text = str((spec or {}).get("vision") or "").strip().lower()
    return text not in {"", "none", "no", "false", "blocked", "disabled", "n/a"}


def resolve_admin_chat_target(instance_id="", mode=""):
    target_id = str(instance_id or "").strip().upper()
    selector = canonical_mode_selector(mode) if mode else ""
    runtime_rows = running_runtime_rows(instances_snapshot(), legacy_global_instance_snapshot())
    if target_id:
        match = next((dict(row) for row in runtime_rows if str(row.get("id") or "").strip().upper() == target_id), None)
        if match:
            return match, resolve_variant_spec(match.get("mode")) or {}
        if is_legacy_global_instance_id(target_id):
            legacy = legacy_global_instance_snapshot()
            if legacy and legacy.get("running"):
                return dict(legacy), resolve_variant_spec(legacy.get("mode")) or {}
    if selector:
        match = next((dict(row) for row in runtime_rows if canonical_mode_selector(row.get("mode")) == selector), None)
        if match:
            return match, resolve_variant_spec(match.get("mode")) or {}
        if current_container() and canonical_mode_selector(active_mode()) == selector:
            spec = resolve_variant_spec(selector) or {}
            return {
                "id": "GLOBAL",
                "kind": "global",
                "mode": selector,
                "container": current_container(),
                "port": active_port(),
                "running": True,
                "gpu_indices": mode_gpu_indices(selector, gpu_count=detect_gpu_count_runtime()),
            }, spec
    primary = primary_instance()
    if primary and primary.get("running"):
        return dict(primary), resolve_variant_spec(primary.get("mode")) or {}
    mode_now = active_mode()
    spec = resolve_variant_spec(mode_now) or {}
    container = current_container()
    if container and port_open(active_port(), timeout=0.08):
        return {
            "id": "GLOBAL",
            "kind": "global",
            "mode": mode_now,
            "container": container,
            "port": active_port(),
            "running": True,
            "gpu_indices": mode_gpu_indices(mode_now, gpu_count=detect_gpu_count_runtime()),
        }, spec
    raise RuntimeError("No active runtime is available for chat.")


def normalize_admin_chat_messages(messages, allow_images=False):
    normalized = []
    if not isinstance(messages, list):
        raise ValueError("messages must be a list")
    for item in messages:
        if not isinstance(item, dict):
            continue
        role = str(item.get("role") or "").strip().lower()
        if role not in {"system", "user", "assistant"}:
            continue
        content = item.get("content")
        if isinstance(content, list):
            parts = []
            for part in content:
                if not isinstance(part, dict):
                    continue
                part_type = str(part.get("type") or "").strip().lower()
                if part_type == "text":
                    text = str(part.get("text") or "")
                    if text:
                        parts.append({"type": "text", "text": text})
                elif allow_images and part_type == "image_url":
                    image_url = part.get("image_url")
                    if isinstance(image_url, dict):
                        url = str(image_url.get("url") or "").strip()
                    else:
                        url = str(image_url or "").strip()
                    if url:
                        parts.append({"type": "image_url", "image_url": {"url": chat_attachment_data_url(url)}})
            reasoning_text = extract_reasoning_text(item)
            if parts or (role == "assistant" and reasoning_text):
                row = {"role": role, "content": parts if parts else ""}
                if role == "assistant" and reasoning_text:
                    row["reasoning_content"] = reasoning_text
                normalized.append(row)
            continue
        text = str(content or "")
        reasoning_text = extract_reasoning_text(item)
        if text or (role == "assistant" and reasoning_text):
            row = {"role": role, "content": text}
            if role == "assistant" and reasoning_text:
                row["reasoning_content"] = reasoning_text
            normalized.append(row)
    if not normalized:
        raise ValueError("At least one chat message is required")
    return normalized


def apply_admin_chat_params(payload, params):
    params = params if isinstance(params, dict) else {}
    allowed_scalars = (
        "temperature",
        "top_p",
        "top_k",
        "min_p",
        "presence_penalty",
        "frequency_penalty",
        "repetition_penalty",
        "max_tokens",
        "max_completion_tokens",
        "truncate_prompt_tokens",
        "seed",
        "min_tokens",
        "logprobs",
        "top_logprobs",
        "length_penalty",
    )
    allowed_bools = (
        "ignore_eos",
        "skip_special_tokens",
        "include_stop_str_in_output",
    )
    for key in allowed_scalars:
        if params.get(key) not in (None, ""):
            payload[key] = params.get(key)
    for key in allowed_bools:
        if key in params:
            payload[key] = bool(params.get(key))
    stop = params.get("stop")
    if isinstance(stop, list):
        cleaned = [str(item) for item in stop if str(item)]
        if cleaned:
            payload["stop"] = cleaned
    elif isinstance(stop, str) and stop.strip():
        payload["stop"] = stop.strip()
    chat_template_kwargs = {}
    if "enable_thinking" in params:
        chat_template_kwargs["enable_thinking"] = bool(params.get("enable_thinking"))
    if "preserve_thinking" in params:
        chat_template_kwargs["preserve_thinking"] = bool(params.get("preserve_thinking"))
    if chat_template_kwargs:
        payload["chat_template_kwargs"] = {**dict(payload.get("chat_template_kwargs") or {}), **chat_template_kwargs}
    return payload

def build_admin_chat_payload(data, spec, stream=False):
    payload = {
        "messages": normalize_admin_chat_messages(data.get("messages") or [], allow_images=runtime_supports_vision(spec)),
        "stream": bool(stream),
    }
    model_name = str(data.get("model") or spec.get("served_model_name") or spec.get("model_id") or "").strip()
    if model_name:
        payload["model"] = model_name
    preset_name = str(data.get("api_preset") or "").strip()
    if preset_name:
        preset = get_all_presets().get(preset_name)
        if not preset:
            raise ValueError(f"Unknown API preset: {preset_name}")
        payload = merge_preset_params(payload, preset)
        payload = inject_system_prompt_into_payload(payload, preset_system_prompt(preset_name))
    else:
        payload = apply_admin_chat_params(payload, data.get("params"))
        payload = inject_system_prompt_into_payload(payload, (data.get("params") or {}).get("system_prompt"))
    if stream:
        payload["stream_options"] = {"include_usage": True}
    return payload


def chat_backend_request(port, payload):
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}/v1/chat/completions",
        data=json.dumps(payload, separators=(",", ":")).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=None) as response:
            raw = response.read()
            return json.loads(raw.decode("utf-8", errors="ignore") or "{}")
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="ignore")
        raise RuntimeError(body or f"Runtime returned HTTP {e.code}")
    except Exception as e:
        raise RuntimeError(str(e))

def open_chat_backend_stream(port, payload):
    attempts = []
    primary = dict(payload or {})
    attempts.append(primary)
    if "stream_options" in primary:
        fallback = dict(primary)
        fallback.pop("stream_options", None)
        attempts.append(fallback)
    last_error = None
    for index, attempt in enumerate(attempts):
        req = urllib.request.Request(
            f"http://127.0.0.1:{port}/v1/chat/completions",
            data=json.dumps(attempt, separators=(",", ":")).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            return urllib.request.urlopen(req, timeout=None), attempt
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8", errors="ignore")
            last_error = RuntimeError(body or f"Runtime returned HTTP {e.code}")
            if index == 0 and "stream_options" in attempt and ("stream_options" in body.lower() or "include_usage" in body.lower()):
                continue
            raise last_error
        except Exception as e:
            last_error = RuntimeError(str(e))
            raise last_error
    raise last_error or RuntimeError("Unable to open chat stream")

def iter_sse_events(response):
    buffer = ""
    decoder = codecs.getincrementaldecoder("utf-8")()
    while True:
        chunk = response.read1(8192) if hasattr(response, "read1") else response.read(8192)
        if not chunk:
            break
        text = decoder.decode(chunk).replace("\r\n", "\n").replace("\r", "\n")
        buffer += text
        while "\n\n" in buffer:
            raw_event, buffer = buffer.split("\n\n", 1)
            yield raw_event
    tail = decoder.decode(b"", final=True).replace("\r\n", "\n").replace("\r", "\n")
    buffer += tail
    if buffer.strip():
        yield buffer

def merge_stream_tool_call_delta(store, delta_list):
    for item in delta_list or []:
        if not isinstance(item, dict):
            continue
        try:
            index = int(item.get("index") or 0)
        except Exception:
            index = 0
        current = dict(store.get(index) or {"id": "", "type": "function", "function": {"name": "", "arguments": ""}})
        if item.get("id"):
            current["id"] = str(item.get("id"))
        if item.get("type"):
            current["type"] = str(item.get("type"))
        function = item.get("function") if isinstance(item.get("function"), dict) else {}
        current_function = dict(current.get("function") or {"name": "", "arguments": ""})
        if function.get("name"):
            current_function["name"] = str(function.get("name"))
        if function.get("arguments") not in (None, ""):
            current_function["arguments"] = str(current_function.get("arguments") or "") + str(function.get("arguments") or "")
        current["function"] = current_function
        store[index] = current

def finalize_stream_tool_calls(store):
    rows = []
    for index in sorted(store.keys()):
        item = dict(store.get(index) or {})
        function = dict(item.get("function") or {})
        rows.append({
            "id": str(item.get("id") or secrets.token_hex(6)),
            "type": str(item.get("type") or "function"),
            "function": {
                "name": str(function.get("name") or ""),
                "arguments": str(function.get("arguments") or ""),
            },
        })
    return rows

def extract_reasoning_text(payload):
    if not isinstance(payload, dict):
        return ""
    for key in ("reasoning_content", "reasoning"):
        value = payload.get(key)
        if isinstance(value, str) and value:
            return value
    return ""

def stream_admin_chat_request(handler, data):
    global last_request_finished_at
    data = data if isinstance(data, dict) else {}
    target = None
    target_id = "GLOBAL"
    target_key = "GLOBAL"
    preset_name = str(data.get("api_preset") or "").strip() or "direct"
    start = time.time()
    first_chunk_at = None
    status_code = 200
    metrics_started = False
    stream_opened = False
    response_usage = {"tokens": 0, "input_tokens": 0, "output_tokens": 0, "tool_calls": 0}
    request_usage = {}
    try:
        target, spec = resolve_admin_chat_target(
            instance_id=data.get("instance_id") or "",
            mode=data.get("mode") or "",
        )
        target_id = str(target.get("id") or "GLOBAL")
        target_key = str(target_id or "").strip().upper() or "GLOBAL"
        port = int(target.get("port") or active_port() or 0)
        if port <= 0:
            raise RuntimeError("The selected runtime does not expose a valid port.")
        payload = build_admin_chat_payload(data, spec, stream=True)
        tools, tool_map = build_enabled_mcp_tools()
        if tools:
            payload["tools"] = tools
            payload["tool_choice"] = "auto"
        request_seed = {
            "messages": payload.get("messages") or [],
            "max_tokens": payload.get("max_tokens"),
            "max_completion_tokens": payload.get("max_completion_tokens"),
            "tool_choice": payload.get("tool_choice"),
            "max_tool_calls": payload.get("max_tool_calls"),
            "max_parallel_tool_calls": payload.get("max_parallel_tool_calls"),
        }
        request_usage = extract_request_usage(
            json.dumps(request_seed, separators=(",", ":")).encode("utf-8")
        )
        with metrics_lock:
            metrics["total_requests"] += 1
            metrics["active_requests"] += 1
            metrics["last_preset"] = preset_name
            metrics["last_path"] = "/admin/chat-stream"
            target_request_metrics.setdefault(target_key, default_target_request_metrics())
        metrics_started = True

        handler.close_connection = False
        handler.send_response(200)
        handler.send_header("Content-Type", "text/event-stream")
        handler.send_header("Cache-Control", "no-cache")
        handler.send_header("Connection", "keep-alive")
        handler.emit_pending_headers()
        handler.end_headers()
        stream_opened = True

        assistant_text = ""
        current_payload = dict(payload)
        for _ in range(6):
            stream_response, current_payload = open_chat_backend_stream(port, current_payload)
            pass_text_parts = []
            pass_reasoning_parts = []
            tool_delta_store = {}
            with stream_response as response:
                for raw_event in iter_sse_events(response):
                    data_lines = []
                    for raw_line in str(raw_event or "").split("\n"):
                        if raw_line.startswith("data:"):
                            data_lines.append(raw_line[5:].lstrip())
                    if not data_lines:
                        continue
                    data_text = "\n".join(data_lines).strip()
                    if not data_text or data_text == "[DONE]":
                        continue
                    try:
                        event_obj = json.loads(data_text)
                    except Exception:
                        continue
                    if first_chunk_at is None:
                        first_chunk_at = time.time()
                    usage_block = event_obj.get("usage") if isinstance(event_obj.get("usage"), dict) else {}
                    if usage_block:
                        response_usage["input_tokens"] = max(
                            int(response_usage.get("input_tokens") or 0),
                            int(first_defined(usage_block.get("prompt_tokens"), usage_block.get("input_tokens"), 0) or 0),
                        )
                        response_usage["output_tokens"] = max(
                            int(response_usage.get("output_tokens") or 0),
                            int(first_defined(usage_block.get("completion_tokens"), usage_block.get("output_tokens"), 0) or 0),
                        )
                        response_usage["tokens"] = max(
                            int(response_usage.get("tokens") or 0),
                            int(usage_block.get("total_tokens") or 0),
                        )
                    for choice in event_obj.get("choices") or []:
                        if not isinstance(choice, dict):
                            continue
                        delta = choice.get("delta") if isinstance(choice.get("delta"), dict) else {}
                        reasoning_chunk = extract_reasoning_text(delta) or extract_reasoning_text(choice)
                        if reasoning_chunk:
                            pass_reasoning_parts.append(reasoning_chunk)
                            handler.send_sse_event("reasoning", {"text": reasoning_chunk})
                        content_chunk = str(delta.get("content") or choice.get("text") or "")
                        if content_chunk:
                            assistant_text += content_chunk
                            pass_text_parts.append(content_chunk)
                            handler.send_sse_event("delta", {"text": content_chunk})
                        merge_stream_tool_call_delta(tool_delta_store, delta.get("tool_calls") or [])
            tool_calls = finalize_stream_tool_calls(tool_delta_store)
            if not tool_calls:
                break
            payload_messages = list(current_payload.get("messages") or [])
            assistant_message = {
                "role": "assistant",
                "content": "".join(pass_text_parts),
                "tool_calls": tool_calls,
            }
            pass_reasoning_text = "".join(pass_reasoning_parts)
            if pass_reasoning_text:
                assistant_message["reasoning_content"] = pass_reasoning_text
            payload_messages.append(assistant_message)
            for tool_call in tool_calls:
                call_id = str(tool_call.get("id") or secrets.token_hex(6))
                function = dict(tool_call.get("function") or {})
                tool_name = str(function.get("name") or "")
                handler.send_sse_event("tool", {"name": tool_name, "message": f"Running tool {tool_name}..."})
                try:
                    arguments = json.loads(function.get("arguments") or "{}")
                except Exception:
                    arguments = {}
                tool_result = call_enabled_mcp_tool(tool_name, arguments, tool_map)
                payload_messages.append({
                    "role": "tool",
                    "tool_call_id": call_id,
                    "content": tool_result,
                })
                response_usage["tool_calls"] = int(response_usage.get("tool_calls") or 0) + 1
            current_payload["messages"] = payload_messages

        if int(response_usage.get("output_tokens") or 0) <= 0 and assistant_text.strip():
            response_usage["output_tokens"] = estimate_text_tokens(assistant_text)
        if int(response_usage.get("input_tokens") or 0) <= 0:
            response_usage["input_tokens"] = int(request_usage.get("input_tokens") or 0)
        if int(response_usage.get("tokens") or 0) <= 0:
            response_usage["tokens"] = int(response_usage.get("input_tokens") or 0) + int(response_usage.get("output_tokens") or 0)

        log_metrics = runtime_log_metrics_for_container(target.get("container"), force=True) if target and target.get("container") else {}
        ttft = round(first_chunk_at - start, 3) if first_chunk_at else None
        generation_tps = first_defined(log_metrics.get("generation_tps"), None)
        if generation_tps in (None, "", 0, 0.0) and first_chunk_at and int(response_usage.get("output_tokens") or 0) > 0:
            generation_tps = round(
                float(response_usage.get("output_tokens") or 0) / max(time.time() - first_chunk_at, 0.001),
                2,
            )
        else:
            generation_tps = round(float(generation_tps), 2) if generation_tps not in (None, "", 0, 0.0) else None

        handler.send_sse_event("done", {
            "ok": True,
            "instance_id": target_id,
            "mode": str(target.get("mode") or ""),
            "model": str(current_payload.get("model") or ""),
            "usage": response_usage,
            "generation_tps": generation_tps,
            "prompt_tps": log_metrics.get("prompt_tps"),
            "ttft_s": ttft,
        })
        handler.close_connection = True
    except Exception as e:
        status_code = 500
        if stream_opened:
            try:
                handler.send_sse_event("error", {"error": str(e)})
            except Exception:
                pass
            handler.close_connection = True
        else:
            handler.send_json({"ok": False, "error": str(e)}, 500)
    finally:
        if metrics_started:
            latency = round(time.time() - start, 3)
            prompt_tokens = max(int(request_usage.get("input_tokens") or 0), int(response_usage.get("input_tokens") or 0))
            output_tokens = max(int(response_usage.get("output_tokens") or 0), max(0, int(response_usage.get("tokens") or 0) - int(prompt_tokens)))
            total_tokens = max(int(response_usage.get("tokens") or 0), int(prompt_tokens) + int(output_tokens))
            log_metrics = runtime_log_metrics_for_container(target.get("container"), force=True) if target and target.get("container") else {}
            ttft = round(first_chunk_at - start, 3) if first_chunk_at else None
            display_tps = first_defined(log_metrics.get("generation_tps"), None)
            if display_tps in (None, "", 0, 0.0) and first_chunk_at and output_tokens > 0:
                display_tps = round(float(output_tokens) / max(time.time() - first_chunk_at, 0.001), 2)
            elif display_tps not in (None, "", 0, 0.0):
                display_tps = round(float(display_tps), 2)
            else:
                display_tps = None
            with metrics_lock:
                metrics["active_requests"] = max(0, metrics["active_requests"] - 1)
                if metrics["active_requests"] <= 0:
                    last_request_finished_at = time.time()
                metrics["completed_requests"] += 1
                if status_code >= 400:
                    metrics["failed_requests"] += 1
                metrics["last_latency_s"] = latency
                metrics["last_status"] = status_code
                if ttft is not None:
                    metrics["last_ttft_s"] = ttft
                if display_tps not in (None, "", 0, 0.0):
                    metrics["last_tokens_per_second"] = display_tps
                metrics["last_estimated_tokens"] = output_tokens or None
                recent_requests.appendleft({
                    "time": time.strftime("%H:%M:%S"),
                    "status": status_code,
                    "latency_s": latency,
                    "preset": preset_name,
                    "path": "/admin/chat-stream",
                    "upstream": "/v1/chat/completions",
                    "instance": target_id,
                    "user": "admin",
                })
                target_row = dict(target_request_metrics.get(target_key) or default_target_request_metrics())
                target_row["last_status"] = status_code
                target_row["last_latency_s"] = latency
                if ttft is not None:
                    target_row["last_ttft_s"] = ttft
                if display_tps not in (None, "", 0, 0.0):
                    target_row["last_tokens_per_second"] = display_tps
                target_row["last_estimated_tokens"] = output_tokens or None
                target_row["last_input_tokens"] = prompt_tokens
                target_row["last_output_tokens"] = output_tokens
                target_row["last_total_tokens"] = total_tokens
                target_row["last_tool_calls"] = int(response_usage.get("tool_calls") or 0)
                target_row["last_preset"] = preset_name
                target_row["last_path"] = "/admin/chat-stream"
                target_row["last_request_at"] = int(time.time())
                target_request_metrics[target_key] = target_row


def run_admin_chat_request(data):
    data = data if isinstance(data, dict) else {}
    target, spec = resolve_admin_chat_target(
        instance_id=data.get("instance_id") or "",
        mode=data.get("mode") or "",
    )
    port = int(target.get("port") or active_port() or 0)
    if port <= 0:
        raise RuntimeError("The selected runtime does not expose a valid port.")
    payload = build_admin_chat_payload(data, spec)
    tools, tool_map = build_enabled_mcp_tools()
    if tools:
        payload["tools"] = tools
        payload["tool_choice"] = "auto"
    parsed = {}
    for _ in range(6):
        parsed = chat_backend_request(port, payload)
        choice = (parsed.get("choices") or [{}])[0] if isinstance(parsed, dict) else {}
        message = choice.get("message") if isinstance(choice, dict) else {}
        tool_calls = list(message.get("tool_calls") or []) if isinstance(message, dict) else []
        if not tool_calls:
            break
        payload_messages = list(payload.get("messages") or [])
        assistant_message = {
            "role": "assistant",
            "content": message.get("content") or "",
            "tool_calls": tool_calls,
        }
        reasoning_text = extract_reasoning_text(message)
        if reasoning_text:
            assistant_message["reasoning_content"] = reasoning_text
        payload_messages.append(assistant_message)
        for tool_call in tool_calls:
            call_id = str(tool_call.get("id") or secrets.token_hex(6))
            function = dict(tool_call.get("function") or {})
            tool_name = str(function.get("name") or "")
            try:
                arguments = json.loads(function.get("arguments") or "{}")
            except Exception:
                arguments = {}
            tool_result = call_enabled_mcp_tool(tool_name, arguments, tool_map)
            payload_messages.append({
                "role": "tool",
                "tool_call_id": call_id,
                "content": tool_result,
            })
        payload["messages"] = payload_messages
    usage = extract_response_usage(json.dumps(parsed, separators=(",", ":")).encode("utf-8"))
    return {
        "ok": True,
        "instance_id": str(target.get("id") or ""),
        "mode": str(target.get("mode") or ""),
        "model": str(payload.get("model") or ""),
        "engine": str(spec.get("engine") or ""),
        "supports_vision": runtime_supports_vision(spec),
        "tools_enabled": len(tools),
        "response": parsed,
        "usage": usage,
    }

HTML = "<!doctype html><html><head><meta charset=\"utf-8\" /><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\" /><title>club-3090 Control</title><style>:root{color-scheme:dark;--bg:#0b0f14;--panel:#121923;--line:#273243;--text:#e8eef7;--muted:#9dafc3;--blue:#72c7ff;--green:#2fc46b;--red:#ff5b6c;--amber:#ffcb6b;--orange:#ff8a2a;--field:#081018;--cyan:#7dd3fc;--turquoise:#26d6c6}*{box-sizing:border-box}body,html{min-height:100%;margin:0}body{font-family:system-ui,-apple-system,Segoe UI,Arial,sans-serif;background:var(--bg);color:var(--text);overflow-y:auto;overflow-x:hidden}header{position:sticky;top:0;z-index:10;padding:10px 12px;background:#111925f7;backdrop-filter:blur(8px);border-bottom:1px solid var(--line)}.top{display:flex;justify-content:space-between;align-items:center;gap:8px}.top-main{min-width:0;width:100%}.header-row{display:flex;align-items:stretch;gap:8px;margin-top:4px}.brand{font-size:18px;font-weight:800}.pill{flex:1 1 auto;min-width:0;color:var(--muted);font-size:12px;border:1px solid var(--line);border-radius:999px;padding:4px 8px;background:#0a1119;margin-top:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.header-chat-btn{flex:0 0 auto;background:linear-gradient(180deg,#285784,#1a3b5b);border-color:#4a83bb;box-shadow:inset 0 0 0 1px rgba(150,217,255,.18),0 0 0 1px rgba(114,199,255,.08)}.header-chat-btn svg{width:18px;height:18px}.header-chat-btn.active{border-color:#72c7ff;box-shadow:inset 0 0 0 1px rgba(150,217,255,.18),0 0 0 1px rgba(114,199,255,.12)}.subtabs,.tabs{display:flex;gap:6px;overflow-x:auto}.tabs{padding-top:10px}.subtabs{margin-bottom:10px}.btn,.subtab,.tab{border:1px solid #34445a;background:#1b2635;color:#eef4ff;border-radius:10px;padding:9px 11px;font-size:13px;cursor:pointer;white-space:nowrap}.subtab.active,.tab.active{background:#203149;border-color:#3d6fa3}.btn:disabled{opacity:.5;cursor:not-allowed}.green{background:#113d25;border-color:#2c8a54}.turquoise{background:#079c9c;border-color:#4df5e8;color:#041316}.red{background:#4a1118;border-color:#8a2b35}.rose{background:#6b2430;border-color:#ff8fa1;color:#fff1f4}.amber{background:#4a3511;border-color:#8a652b}.orange{background:#c45512;border-color:#ffae42;color:#fff}.blue{background:#12314d;border-color:#2a72a8}.purple{background:#4b1f75;border-color:#9460df;color:#fff}.default-profile{background:#1d5f96;border-color:#78c7ff;color:#fff}.container{display:flex;flex-direction:column;gap:10px;padding:10px}.panel{background:var(--panel);border:1px solid var(--line);border-radius:14px;padding:12px;box-shadow:0 8px 30px #0004;margin-bottom:10px}.panel h2{font-size:14px;margin:0 0 10px}.chartgrid+.panel{margin-top:10px}.grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:8px}.stat{background:#0b1119;border:1px solid #222d3c;border-radius:10px;padding:8px}.label{color:var(--muted);font-size:11px}label.label{display:inline-flex;align-items:center;gap:8px}label.label input[type=checkbox]{margin:0;flex:0 0 auto}.value{font-weight:700;font-size:13px;overflow-wrap:anywhere}.value-subline{display:block;margin-top:4px;color:var(--muted);font-size:12px;font-weight:600;line-height:1.35}.actions{display:flex;gap:7px;flex-wrap:wrap}.hidden{display:none!important}.tabpane{display:none}.tabpane.active{display:block}.metricpane{display:none}.metricpane.active{display:block}.logs{min-height:0;display:flex;flex-direction:column;margin-bottom:0}.loghead{display:flex;justify-content:space-between;align-items:center;padding-bottom:7px;gap:10px}.loghead h2{white-space:nowrap}.logheadchecks{display:flex;align-items:center;gap:12px;white-space:nowrap}.log{width:100%;height:clamp(360px,calc(100dvh - 430px),560px);min-height:320px;resize:vertical;white-space:pre-wrap;overflow-wrap:anywhere;background:#030608;color:#a5ffa5;border:1px solid #26313f;border-radius:12px;padding:12px;font-family:Consolas,monospace;font-size:12px;line-height:1.35}.log-card-hidden{display:none!important}.logs-tab .container{min-height:calc(100dvh - 108px)}.logs-tab .logs.panel{height:calc(100dvh - 252px);min-height:500px;margin-bottom:0}.logs-tab .log{height:auto;min-height:0;flex:1;resize:none}.logs-tab .content-tab{display:none!important}.logtools{display:none}.audit-tab .logtools,.logs-tab .logtools{display:block;margin-bottom:10px}.logtools h2{display:block;margin:0 0 10px}.logtools .searchbox{display:flex}.searchbox{display:flex;align-items:center;gap:6px;flex-wrap:nowrap;width:100%}.searchbox input{flex:1 1 auto;min-width:80px;background:var(--field);color:var(--text);border:1px solid #2c3a4f;border-radius:9px;padding:9px}.chartgrid{display:grid;grid-template-columns:1fr 1fr;gap:10px}.gpu-chartgrid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:10px}.chart{height:145px;background:#081018;border:1px solid #213044;border-radius:12px;padding:8px}.chart.tall{height:220px}canvas{width:100%;height:100%}.msg{color:var(--amber);font-size:12px;min-height:18px;padding-top:6px}.msg.msg-error{color:var(--red)}.msg.msg-warning{color:var(--amber)}.msg.msg-success{color:var(--green)}.smallgap{margin-bottom:5px}#auditSummary{margin-top:10px}.gpu-cards{display:grid;grid-template-columns:1fr;gap:10px}.gpu-card{background:#101722;border:1px solid #26313f;border-radius:14px;padding:12px}.gpu-title{font-weight:800;color:#d9ecff;margin-bottom:10px;border-bottom:1px solid #26313f;padding-bottom:7px}.gpu-grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:12px}.gpu-section-title{color:#9dafc3;font-size:12px;text-transform:uppercase;letter-spacing:.04em;margin-bottom:4px}.gpu-line{display:flex;justify-content:space-between;gap:8px;font-size:13px;padding:2px 0}.meter{height:7px;background:#081018;border-radius:99px;overflow:hidden;margin-top:5px}.meter span{display:block;height:100%;background:#2fc46b}.coregrid{display:grid;grid-template-columns:repeat(auto-fill,minmax(90px,1fr));gap:6px}.storage-list{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:10px}.storage-section{display:flex;flex-direction:column;gap:10px}.storage-card.user-facing{background:#10243a;border-color:#2a72a8}.storage-card{background:#0b1119;border:1px solid #243144;border-radius:12px;padding:10px;min-width:0}.storage-title{font-weight:800;color:#d9ecff;margin-bottom:6px;overflow-wrap:anywhere}.storage-meta{color:#9dafc3;font-size:12px;margin-bottom:6px;overflow-wrap:anywhere}.storage-sizes{display:grid;grid-template-columns:minmax(85px,0.8fr) minmax(85px,0.8fr) minmax(95px,0.9fr);gap:6px;margin-bottom:8px}.storage-sizes .stat{padding:6px}.diskbar{height:8px;background:#081018;border-radius:99px;overflow:hidden;width:100%;margin-bottom:3px;margin-top:3px}.diskbar span{display:block;height:100%;background:#72c7ff}.netgrid{display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:8px}.temp-blue{color:#60a5fa}.temp-green{color:#2fc46b}.temp-yellow{color:#ffde59}.temp-orange{color:#ff8a2a}.temp-red{color:#ff5b6c}.temp-crimson{color:#dc143c;font-weight:900}.machine-row{margin-top:7px}.api-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(230px,1fr));gap:8px}.api-card{background:#0b1119;border:1px solid #243144;border-radius:12px;padding:10px}.api-card h3{font-size:13px;margin:0 0 6px;color:#d9ecff}.api-card p{margin:0;color:var(--muted);font-size:12px;line-height:1.35}.api-card-head{display:flex;align-items:center;justify-content:space-between;gap:8px}.preset-actions{display:flex;gap:4px}.iconbtn{border:1px solid #34445a;background:#182231;color:#eef4ff;border-radius:8px;padding:5px 7px;cursor:pointer;display:inline-flex;align-items:center;justify-content:center;width:32px;height:32px}.iconbtn svg{width:16px;height:16px;stroke:currentColor;stroke-width:2;stroke-linecap:round;stroke-linejoin:round}.preset-editor{display:none}.preset-editor.open{display:block}.formgrid{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:8px}.formgrid label{display:flex;flex-direction:column;gap:4px;color:var(--muted);font-size:12px}.formgrid input,.formgrid select,.formgrid textarea{background-color:var(--field);color:var(--text);border:1px solid #2c3a4f;border-radius:9px;padding:8px}.chat-conversation-select,.chat-settings-grid select,.chat-toolbar select,.formgrid select{appearance:none;-webkit-appearance:none;background-image:url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'%3E%3Cpath d='m6 9 6 6 6-6' fill='none' stroke='%239dafc3' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E\");background-position:calc(100% - 14px) 50%;background-repeat:no-repeat;background-size:12px 12px;padding-right:32px}.formgrid textarea{min-height:120px;resize:vertical}.preset-form-span-2{grid-column:1/-1}.preset-help{color:var(--muted);font-size:12px;line-height:1.35;margin-bottom:10px}.profile-balanced{background:#0faeb0;border-color:#5ff5e8;color:#031516}.panel-head{display:flex;align-items:center;justify-content:space-between;gap:8px;margin-bottom:10px}.panel-head h2{margin:0}.add-preset-btn{width:30px;height:30px;border-radius:999px;border:1px solid #55ee91;background:#128a45;color:#fff;display:inline-flex;align-items:center;justify-content:center;padding:0;box-shadow:none}.add-preset-btn:hover{background:#18a957}.add-preset-btn svg{width:15px;height:15px;stroke:#fff;stroke-width:3;stroke-linecap:round}.preset-form-actions{display:flex;justify-content:center;gap:18px;margin-top:14px}.preset-intro{color:var(--muted);font-size:13px;line-height:1.45;margin:4px 0 2px}.preset-intro.hidden{display:none}.scope-strip{display:flex;flex-wrap:wrap;align-items:center;gap:8px;margin:0 0 10px}.scope-strip .subtabs{margin:0}.club-modal{position:fixed;inset:0;background:rgba(2,7,14,.82);display:flex;align-items:center;justify-content:center;padding:16px;z-index:1000}.club-modal-card{width:min(720px,100%);background:#101824;border:1px solid #31455f;border-radius:14px;box-shadow:0 20px 70px rgba(0,0,0,.45);padding:14px}.chat-settings-modal-card{width:min(880px,calc(100vw - 32px));max-height:min(90dvh,780px);overflow:auto}.conversation-modal-card{width:min(560px,100%)}.modal-keybox{width:100%;min-height:120px;resize:vertical;border:1px solid #31455f;border-radius:10px;background:#07101a;color:#d9ecff;padding:10px;font:600 13px/1.45 ui-monospace,SFMono-Regular,Consolas,monospace;white-space:pre-wrap;overflow-wrap:anywhere;word-break:break-word;overflow:auto;scrollbar-gutter:stable}.preset-section-label{color:#d9ecff;font-size:12px;font-weight:800;letter-spacing:.04em;text-transform:uppercase;margin:10px 0 6px}.busy-note{display:flex;align-items:center;gap:8px;color:var(--muted);font-size:12px;line-height:1.35}.spinner{width:12px;height:12px;border:2px solid #34445a;border-top-color:var(--blue);border-radius:999px;animation:club3090-spin .8s linear infinite;flex:0 0 auto}.instance-panel-busy{border-color:#35506d}.instance-panel-busy .actions,.instance-panel-busy .subtabs,.instance-panel-busy .value{opacity:.82}.model-grid{display:grid;grid-template-columns:1fr;gap:12px;margin-top:12px}.model-card{background:#0b1119;border:1px solid #243144;border-radius:14px;padding:12px}.selected-model-card{background:#101823}.model-card-active-family{border-color:#5ff5e8;box-shadow:0 0 0 1px #5ff5e84a}.collapsed-model-card{opacity:.92}.model-card-head{display:flex;justify-content:space-between;align-items:flex-start;gap:12px;margin-bottom:10px}.model-card-head h3{margin:0;font-size:16px;color:#d9ecff}.model-summary{color:var(--muted);font-size:12px;line-height:1.45;margin-top:6px}.badge-row{display:flex;gap:6px;flex-wrap:wrap}.state-badge,.status-badge{display:inline-flex;align-items:center;border-radius:999px;padding:4px 8px;font-size:11px;font-weight:700;border:1px solid transparent}.state-ready{background:#113d25;border-color:#2c8a54;color:#d8ffe7}.state-active{background:#173c63;border-color:#72c7ff;color:#e0f3ff}.state-booting{background:#4a3511;border-color:#d7a63d;color:#ffe8b4}.state-error{background:#4a1118;border-color:#8a2b35;color:#ffd7dc}.status-production{background:#12314d;border-color:#2a72a8;color:#d7ecff}.status-active{background:#113d25;border-color:#2c8a54;color:#d8ffe7}.status-booting{background:#4a3511;border-color:#8a652b;color:#ffe8b4}.state-partial,.status-production_caveat{background:#4a3511;border-color:#8a652b;color:#ffe8b4}.state-requires_download{background:#10353a;border-color:#1ea6b8;color:#c9fbff}.state-missing,.status-preview,.status-upstream_gated{background:#12314d;border-color:#2a72a8;color:#d7ecff}.state-unavailable,.state-unsupported,.status-deprecated,.status-error,.status-experimental,.status-unknown{background:#4a1118;border-color:#8a2b35;color:#ffd7dc}.error-note{color:#ffd7dc}.variant-groups{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:10px}.variant-group{background:#101722;border:1px solid #26313f;border-radius:12px;padding:10px}.variant-group h4{margin:0 0 8px;font-size:13px;color:#d9ecff}.variant-grid{display:grid;grid-template-columns:1fr;gap:8px}.variant-card{background:#09101a;border:1px solid #213044;border-radius:12px;padding:10px}.variant-card.active-variant{border-color:#5ff5e8;box-shadow:0 0 0 1px #5ff5e84a}.variant-card-head{display:flex;justify-content:space-between;align-items:flex-start;gap:8px;margin-bottom:6px}.variant-card-title{font-weight:800;color:#eef4ff;font-size:13px}.variant-caveat,.variant-install-note,.variant-meta{color:var(--muted);font-size:12px;line-height:1.4}.variant-meta strong{color:#d9ecff;font-weight:700}.variant-actions{display:flex;gap:8px;flex-wrap:wrap;margin-top:10px}.variant-footer{display:flex;justify-content:flex-end;align-items:center;min-height:18px;margin-top:8px}.variant-launch-time{color:#9ecdf3;font-size:11px;text-align:right}.model-active-summary{color:#d9ecff;font-size:12px;line-height:1.45;margin-top:8px}.summary-action-bar{display:flex;justify-content:flex-end;margin:0 0 12px}.summary-preset-card{background:#0c141e;border:1px solid #243144;border-radius:12px;padding:10px;margin-top:10px}.summary-preset-card-inactive{opacity:.72;border-color:#364150}.summary-preset-head{display:flex;justify-content:space-between;align-items:flex-start;gap:8px}.summary-preset-title{font-weight:800;color:#eef4ff;font-size:13px}.summary-preset-meta{color:var(--muted);font-size:12px;line-height:1.4;margin-top:8px}.state-summary-inactive{background:#18202b;border-color:#465464;color:#c3cfda}.state-badge[role=button]{cursor:pointer}.empty-variant-note{color:var(--muted);font-size:12px}.chat-panel{overflow:hidden}.chat-panel-head{align-items:center}.chat-head-actions{display:flex;align-items:center;justify-content:flex-end;gap:8px;min-width:0}.chat-conversation-strip{display:flex;align-items:center;gap:6px;flex:1 1 auto;min-width:0;max-width:100%}.chat-conversation-select{flex:1 1 auto;min-width:0;max-width:100%;background-color:var(--field);color:var(--text);border:1px solid #2c3a4f;border-radius:10px;padding:8px 10px;font-size:13px}.chat-head-separator{color:#4d6077;font-size:18px;line-height:1;padding:0 2px}.chat-head-menu{position:relative;flex:0 0 auto}.danger-iconbtn{background:0 0;border-color:transparent;color:#ff6878;box-shadow:none}.danger-iconbtn:focus-visible,.danger-iconbtn:hover{background:rgba(255,91,108,.08);border-color:transparent;color:#ff8793}.chat-options-menu{position:absolute;right:0;top:calc(100% + 8px);display:flex;flex-direction:column;gap:6px;padding:10px;background:#0b1119;border:1px solid #243144;border-radius:12px;box-shadow:0 12px 30px rgba(0,0,0,.35);z-index:20}.chat-options-menu.hidden{display:none!important}.chat-shell{display:block}.chat-main{display:flex;flex-direction:column;gap:0}.chat-toolbar{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:8px;margin-bottom:2px}.chat-settings-grid label,.chat-toolbar label{display:flex;flex-direction:column;gap:4px;color:var(--muted);font-size:12px}.chat-settings-grid input,.chat-settings-grid select,.chat-settings-grid textarea,.chat-toolbar input,.chat-toolbar select{background-color:var(--field);color:var(--text);border:1px solid #2c3a4f;border-radius:9px;padding:8px}.chat-toolbar select{font-size:13px}.hidden-file-input{display:none!important}.chat-inline-images{display:flex;gap:8px;flex-wrap:wrap}.chat-attachment-rail{flex:1 1 auto;min-width:0;display:flex;align-items:center;gap:8px;overflow-x:auto;padding-bottom:2px;scrollbar-width:thin}.chat-attachment-pill,.chat-message-attachment{display:inline-flex;align-items:center;gap:8px;min-width:0;padding:6px 10px;border:1px solid #2c3a4f;border-radius:999px;background:#081018;color:#dce8f6;font-size:12px;white-space:nowrap}.chat-attachment-name{overflow:hidden;text-overflow:ellipsis}.chat-attachment-remove{appearance:none;border:0;background:0 0;color:var(--red);cursor:pointer;padding:0;font-size:13px;font-weight:800;line-height:1}.chat-attachment-pill.chat-attachment-image::after{content:\"image\";color:var(--muted);font-size:11px}.chat-attachment-pill.chat-attachment-text::after,.chat-message-attachment.chat-attachment-text::after{content:\"file\";color:var(--muted);font-size:11px}.chat-inline-images img,.chat-markdown-image{max-width:100%;border-radius:10px}.chat-markdown-media{width:100%;max-width:100%;border-radius:10px;border:1px solid #243144;background:#050a10}.chat-transcript{min-height:400px;max-height:72dvh;overflow:auto;background:#081018;border:1px solid #243144;border-radius:12px;padding:12px}.chat-turn+.chat-turn{margin-top:14px}.chat-turn-divider{display:flex;align-items:center;gap:10px;margin:0 0 12px;color:var(--muted);font-size:11px;font-weight:700;text-transform:uppercase;letter-spacing:.04em}.chat-turn-divider::before{content:\"\";flex:1 1 auto;height:1px;background:#243144}.chat-turn-label{flex:0 0 auto;color:#9ecdf3}.chat-message+.chat-message{margin-top:10px}.chat-message-title{font-size:12px;font-weight:800;color:#d9ecff;margin-bottom:6px}.chat-user .chat-message-title{color:#bde3ff}.chat-assistant .chat-message-title{color:#dfffb5}.chat-message-body{color:#e8eef7;font-size:13px;line-height:1.5;overflow-wrap:anywhere}.chat-message-body>:first-child{margin-top:0}.chat-message-body>:last-child{margin-bottom:0}.chat-message-body h1,.chat-message-body h2,.chat-message-body h3,.chat-message-body h4,.chat-message-body h5,.chat-message-body h6{margin:.9em 0 .45em;line-height:1.25;color:#f2f7ff}.chat-message-body h1{font-size:1.55em}.chat-message-body h2{font-size:1.35em}.chat-message-body h3{font-size:1.18em}.chat-message-body blockquote,.chat-message-body details,.chat-message-body hr,.chat-message-body ol,.chat-message-body p,.chat-message-body pre,.chat-message-body table,.chat-message-body ul{margin:.65em 0}.chat-message-body ol,.chat-message-body ul{padding-left:1.4em}.chat-message-body li+li{margin-top:.3em}.chat-message-body hr{border:0;border-top:1px solid #243144}.chat-message-body blockquote{margin-left:0;padding:.2em 0 .2em .9em;border-left:3px solid #35506d;color:#c5d6ea;background:rgba(23,35,51,.4)}.chat-message-body a{color:var(--blue)}.chat-message-body table{width:100%;border-collapse:collapse;overflow:hidden;border:1px solid #243144;border-radius:10px}.chat-message-body td,.chat-message-body th{border:1px solid #243144;padding:8px 10px;vertical-align:top}.chat-message-body th{color:#f2f7ff;background:rgba(25,40,57,.92);text-align:left}.chat-message-body tbody tr:nth-child(2n){background:rgba(10,16,24,.65)}.chat-message-body code,.chat-message-body kbd{font-family:ui-monospace,SFMono-Regular,Consolas,monospace}.chat-message-body :not(pre)>code{padding:.12em .42em;border-radius:6px;background:rgba(12,19,29,.95);border:1px solid #223044}.chat-message-body kbd{padding:.1em .4em;border-radius:6px;border:1px solid #34445a;background:#121b28}.chat-message-body mark{background:rgba(255,203,107,.24);color:#fff0ca;padding:0 .2em}.chat-message-attachments{display:flex;flex-wrap:wrap;gap:8px;margin-top:10px}.chat-thinking-card{margin:0 0 10px;border:1px solid #2b5d86;border-radius:12px;background:linear-gradient(180deg,rgba(18,49,77,.96),rgba(9,23,37,.96));overflow:hidden;box-shadow:inset 0 0 0 1px rgba(114,199,255,.08)}.chat-thinking-card.thinking-live{border-color:#3d79a9;box-shadow:inset 0 0 0 1px rgba(114,199,255,.14),0 0 0 1px rgba(114,199,255,.04)}.chat-thinking-toggle{width:100%;display:flex;align-items:center;justify-content:space-between;gap:10px;padding:12px 14px;border:0;background:0 0;color:#eef7ff;cursor:pointer;text-align:left}.chat-thinking-copy{min-width:0;display:flex;flex-direction:column;gap:3px}.chat-thinking-title{font-size:13px;font-weight:800;line-height:1.25}.chat-thinking-subtitle{color:#b7cde2;font-size:11px;line-height:1.35}.chat-thinking-chevron{flex:0 0 auto;display:inline-flex;align-items:center;color:#d7ecff}.chat-thinking-chevron svg{width:18px;height:18px}.chat-thinking-body{padding:0 14px 14px;border-top:1px solid rgba(114,199,255,.12)}.chat-thinking-body>:first-child{margin-top:12px}.chat-thinking-body>:last-child{margin-bottom:0}.chat-plain{white-space:pre-wrap;overflow-wrap:anywhere}.chat-code{margin:10px 0;background:#030608;border:1px solid #243144;border-radius:10px;overflow:auto}.chat-code-lang{color:var(--muted);font-size:11px;padding:6px 10px 0}.chat-code code{display:block;padding:10px;white-space:pre}.chat-rich-embed{margin-top:10px}.chat-status-msg{min-height:16px;padding-top:0;margin:0 0 2px}.chat-input-wrap{display:flex;flex-direction:column;gap:6px;margin-top:10px}.chat-composer-row{display:flex;align-items:stretch;gap:6px;min-width:0}#chatInput{flex:1 1 auto;width:auto;min-width:0;min-height:88px;max-height:176px;resize:none;background:#030608;color:#eef4ff;border:1px solid #26313f;border-radius:12px;padding:12px;font-family:inherit;font-size:14px;line-height:1.5}.chat-action-stack{flex:0 0 44px;display:grid;grid-template-rows:repeat(3,minmax(0,1fr));gap:6px}.chat-action-btn{width:100%;height:100%;min-height:0;border-radius:11px;padding:0}.chat-action-btn svg{width:21px;height:21px}.chat-send-btn svg{transform:scaleX(-1)}.chat-send-btn{background:#12314d;border-color:#2a72a8}.chat-send-btn.is-stop{background:#4a1118;border-color:#a83c48}.chat-send-btn.is-stop svg{fill:currentColor;stroke:none}#chatMicBtn.recording{background:#41131a;border-color:#a83c48;color:#ffe6ea}.chat-runtime-stats .generation-card{margin-top:0}.chat-stats-card{background:#0b1119;border:1px solid #243144;border-radius:12px;padding:12px;margin-top:5px}.chat-stats-head{display:flex;align-items:center;justify-content:space-between;gap:10px}.chat-stats-title{color:#d9ecff;font-size:12px;font-weight:800}.chat-stats-toggle{width:30px;height:30px;padding:0}.chat-stats-card.collapsed .chat-runtime-stats{display:none}.chat-runtime-stats{margin-top:8px}.chat-settings-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:8px}.chat-settings-span-2{grid-column:1/-1}.chat-settings-template-row,.chat-settings-toggle-row,.chat-threshold-row{display:flex;align-items:center;gap:8px;flex-wrap:wrap}.chat-settings-template-row{display:grid;grid-template-columns:minmax(0,1fr) 152px;align-items:start;gap:8px}.chat-settings-template-name{min-width:0}.chat-settings-template-select{min-width:0}.chat-settings-template-actions{display:flex;align-items:center;gap:8px;flex-wrap:wrap;grid-column:1/-1}.chat-settings-grid textarea{min-height:112px;resize:vertical}.chat-settings-note{color:var(--muted);font-size:12px;line-height:1.4}.chat-settings-template-note{margin-top:8px}.chat-settings-rule{border:0;border-top:1px solid #243144;margin:10px 0 0}.chat-settings-compact-block{display:flex;flex-direction:column;gap:8px;min-width:0;margin-top:12px}.chat-settings-compact-description,.chat-settings-toggle-row,.chat-threshold-row{font-size:12px}.chat-settings-compact-title{color:#eef4ff;font-weight:700;line-height:1.35}.chat-settings-compact-threshold-label{color:#d9ecff;font-weight:700}.chat-settings-compact-block input[type=range]{flex:1 1 60px;min-width:0;margin-top:-9px}.chat-settings-compact-description{margin:0}.chat-threshold-row output{min-width:0;color:#d9ecff;font-weight:800}.toggle-switch{display:inline-flex;align-items:center;gap:8px}.toggle-switch input{position:absolute;opacity:0;pointer-events:none}.toggle-switch-track{position:relative;width:42px;height:24px;border-radius:999px;background:#182231;border:1px solid #34445a;transition:background .18s ease,border-color .18s ease}.toggle-switch-track::after{content:\"\";position:absolute;top:2px;left:2px;width:18px;height:18px;border-radius:999px;background:#eef4ff;transition:transform .18s ease}.toggle-switch input:checked+.toggle-switch-track{background:#113d25;border-color:#2c8a54}.toggle-switch input:checked+.toggle-switch-track::after{transform:translateX(18px)}.mcp-server-row{display:flex;align-items:flex-start;justify-content:space-between;gap:10px}.mcp-server-meta{display:flex;align-items:center;gap:8px;flex-wrap:wrap}.generation-card{background:#0b1119;border:1px solid #243144;border-radius:12px;padding:10px;margin-top:10px}.generation-card-head{display:flex;justify-content:space-between;align-items:flex-start;gap:10px;margin-bottom:8px}.generation-card-head h3{margin:0;font-size:14px;color:#d9ecff}.generation-card-meta{color:var(--muted);font-size:12px;line-height:1.4}.generation-card-body .value-subline{margin-top:6px}@keyframes club3090-spin{to{transform:rotate(360deg)}}@media (max-width:900px){.chartgrid{grid-template-columns:1fr}.gpu-chartgrid{grid-template-columns:repeat(2,minmax(0,1fr));gap:6px}.grid{grid-template-columns:1fr 1fr}.gpu-grid{grid-template-columns:1fr}.variant-groups{grid-template-columns:1fr}.header-row{align-items:center}.chat-head-actions{width:100%;justify-content:flex-end}.chat-conversation-strip{width:100%;min-width:0}.chat-toolbar{grid-template-columns:repeat(2,minmax(0,1fr))}.chat-composer-row{align-items:stretch}.chat-settings-toggle-row,.chat-threshold-row{align-items:flex-start}.chat-settings-template-select{min-width:0}.log{height:clamp(320px,calc(100dvh - 410px),520px)}.logs-tab .logs.panel{height:calc(100dvh - 250px);min-height:500px}.logs-tab .log{height:auto;min-height:0}}</style></head><body><header><div class=\"top\"><div class=\"top-main\"><div class=\"brand\">club-3090 Control &bull; __SCRIPT_VERSION__</div><div class=\"header-row\"><div class=\"pill\" id=\"summary\">loading...</div><button class=\"iconbtn header-chat-btn\" id=\"chatLaunchBtn\" title=\"Open chat\" aria-label=\"Open chat\" onclick=\"openChatTab()\" ><svg viewBox=\"0 0 24 24\" aria-hidden=\"true\"><path d=\"M5 18V6h14v9H8l-3 3Zm3-7h8m-8 3h5\" fill=\"none\" /></svg></button></div></div></div><div class=\"tabs\"><button class=\"tab active\" onclick=\"tab(event, 'overview')\">Main</button ><button class=\"tab\" onclick=\"tab(event, 'system')\">System</button ><button class=\"tab\" onclick=\"tab(event, 'presets')\">Presets</button ><button class=\"tab\" id=\"usersTabBtn\" onclick=\"tab(event, 'users')\"> Users</button ><button class=\"tab\" onclick=\"tab(event, 'metrics')\">Metrics</button ><button class=\"tab\" onclick=\"tab(event, 'logs')\">Logs</button></div></header><main class=\"container\"><section id=\"overview\" class=\"tabpane content-tab active\"><div class=\"panel\"><h2>Status</h2><div class=\"grid\"><div class=\"stat\"><div class=\"label\">Mode</div><div class=\"value\" id=\"mode\">-</div></div><div class=\"stat\"><div class=\"label\">Containers</div><div class=\"value\" id=\"container\">-</div></div><div class=\"stat\"><div class=\"label\">Requests</div><div class=\"value\" id=\"req\">-</div></div><div class=\"stat\"><div class=\"label\">Uptime</div><div class=\"value\" id=\"uptime\">-</div></div><div class=\"stat\"><div class=\"label\">Power</div><div class=\"value\" id=\"powerbox\">-</div></div><div class=\"stat\"><div class=\"label\">Users</div><div class=\"value\" id=\"last\">-</div></div></div><div class=\"msg\" id=\"msg\"></div></div><div class=\"panel\"><h2>Generation Stats</h2><div id=\"generationStatsContent\" class=\"value\">-</div></div><div id=\"gpuCards\" class=\"gpu-cards\"></div></section><section id=\"system\" class=\"tabpane content-tab\"><div class=\"panel\"><h2>Services</h2><div class=\"value\" id=\"services\">-</div></div><div class=\"panel\"><h2>Audit Overview</h2><div class=\"grid\"><div class=\"stat\"><div class=\"label\">Admin UI</div><div class=\"value\" id=\"auditAdminEndpoint\">-</div></div><div class=\"stat\"><div class=\"label\">Proxy</div><div class=\"value\" id=\"auditProxyEndpoint\">-</div></div><div class=\"stat\"><div class=\"label\">Exposure</div><div class=\"value\" id=\"auditExposure\">-</div></div><div class=\"stat\"><div class=\"label\">Local Automation</div><div class=\"value\" id=\"auditLocalApi\">-</div></div></div><div class=\"value smallgap\" id=\"auditSummary\">-</div><div class=\"msg\" id=\"auditMsg\"></div></div><div class=\"panel\"><h2>Access Policy</h2><div class=\"actions\" id=\"accessPolicyRow\"><label class=\"label\" ><input type=\"checkbox\" id=\"auditAllowAnonymousProxy\" onchange=\"mirrorAuthToggles(this.checked)\" /> allow requests without per-user API keys</label ><button class=\"btn blue\" onclick=\"saveAuthSettings()\"> Save Policy </button></div><div class=\"value smallgap\" style=\"margin-top: 10px\" id=\"auditPolicyText\" > - </div></div><div class=\"panel\"><h2>System</h2><div class=\"actions\" id=\"systemUtilityRow\"><button class=\"btn blue\" onclick=\"promptBenchmarkRun()\"> Benchmark</button ><button class=\"btn blue\" onclick=\"promptReportRun()\"> Run Report</button ><button class=\"btn blue\" onclick=\"promptUpdateRun()\"> Update</button></div><div class=\"actions machine-row\"><button class=\"btn amber\" onclick=\"wol()\">Wake-on-LAN</button ><button class=\"btn red\" onclick=\"machineAction('reboot')\"> Restart Machine</button ><button class=\"btn red\" onclick=\"machineAction('shutdown')\"> Shutdown Machine </button></div></div><div class=\"panel\"><h2>Instances</h2><div class=\"subtabs\" id=\"instanceTabs\"></div><div class=\"value smallgap\" id=\"instanceSummary\">-</div><div class=\"actions\" id=\"instanceActionRow\"><button class=\"btn blue\" onclick=\"instanceAction('start_instance')\"> Start</button ><button class=\"btn amber\" onclick=\"instanceAction('restart_instance')\" > Restart</button ><button class=\"btn red\" onclick=\"instanceAction('stop_container')\"> Stop</button ><button class=\"btn green\" id=\"instanceEnableBtn\" onclick=\"toggleInstanceEnabled()\" > Disable Boot Autostart </button></div><div class=\"panel\" style=\"margin-top:12px\"><h2>Power Profiles</h2><div class=\"actions\" id=\"profileActionRow\"><button class=\"btn green\" onclick=\"profile('eco')\">Eco</button ><button class=\"btn profile-balanced\" onclick=\"profile('balanced')\" > Balanced</button ><button class=\"btn default-profile\" onclick=\"profile('default')\" > Default</button ><button class=\"btn orange\" onclick=\"profile('turbo')\"> Turbo </button></div></div><div class=\"panel\"><h2>Optimizations + Cooling</h2><div class=\"actions\" id=\"powerCoolingActionRow\"><button class=\"btn green\" id=\"optToggle\" onclick=\"togglePowerOptimizations()\" > Disable Power Optimizations</button ><button class=\"btn green\" id=\"fanToggle\" onclick=\"toggleFansMax()\" > Set Fans to Max </button></div></div><div class=\"msg\" id=\"instanceMsg\"></div></div></section><section id=\"presets\" class=\"tabpane content-tab\"><div class=\"panel\"><div class=\"panel-head\"><h2>Dynamic Model Presets</h2><button class=\"btn green\" onclick=\"promptRuntimeInventoryRebuild()\" > Rebuild Dynamic Model DB </button></div><div class=\"preset-help\"> Discovered presets are rendered directly from the local <code>/opt/ai/club-3090</code> clone. Global applies single-GPU presets across every GPU, dual presets across every two-GPU pair, and multi-GPU presets to the shared runtime. </div><div class=\"preset-section-label\">Scope</div><div class=\"subtabs\" id=\"presetScopeTabs\"></div><div class=\"value smallgap\" id=\"presetScopeSummary\">-</div><div class=\"preset-section-label\">Models</div><div class=\"subtabs\" id=\"presetModelSelector\"></div><div class=\"value smallgap\" id=\"presetJobSummary\">-</div><div id=\"modelPresetGrid\" class=\"model-grid\"></div></div><div class=\"panel\"><h2>API Presets</h2><div class=\"preset-help\"> Default presets are locked. Custom presets are exposed as <code>:8009/v1/&lt;name&gt;</code> and <code>:8009/&lt;name&gt;</code>. Both forms work with <code>short-</code> and <code>concise-</code> prefixes. </div><div id=\"apiPresetGrid\" class=\"api-grid\"></div></div><div class=\"panel\"><div class=\"panel-head\"><h2>Custom Preset Templates</h2><button class=\"add-preset-btn\" title=\"Create preset\" aria-label=\"Create preset\" onclick=\"openPresetEditor()\" ><svg viewBox=\"0 0 24 24\" aria-hidden=\"true\"><path d=\"M12 5v14M5 12h14\" fill=\"none\" /></svg></button></div><div id=\"presetIntro\" class=\"preset-intro\"> Create custom endpoint templates for different workloads or clients. Each preset saves generation parameters like temperature, sampling, thinking mode, penalties, and token limits, then exposes them as custom OpenAI-compatible endpoints such as <code>:8009/v1/my_preset</code> and <code>:8009/my_preset</code>. Short and concise prefixes work with custom presets too. </div><div id=\"presetEditor\" class=\"preset-editor\"><div class=\"formgrid\"><label >Endpoint name<input id=\"presetName\" placeholder=\"my_coding\" /></label ><label >Description<input id=\"presetDescription\" placeholder=\"What this preset is for\" /></label ><label class=\"preset-form-span-2\" >System Prompt<textarea id=\"presetSystemPrompt\" placeholder=\"Optional preset system prompt\" ></textarea></label ><label >Temperature<input id=\"presetTemperature\" type=\"number\" step=\"0.01\" placeholder=\"0.7\" /></label ><label >Top P<input id=\"presetTopP\" type=\"number\" step=\"0.01\" placeholder=\"0.95\" /></label ><label >Top K<input id=\"presetTopK\" type=\"number\" step=\"1\" placeholder=\"20\" /></label ><label >Min P<input id=\"presetMinP\" type=\"number\" step=\"0.01\" placeholder=\"0\" /></label ><label >Thinking<select id=\"presetThinking\"><option value=\"false\">Disabled</option><option value=\"true\">Enabled</option></select></label ><label >Preserve Thinking<select id=\"presetPreserveThinking\"><option value=\"false\">No</option><option value=\"true\">Yes</option></select></label ><label >Repetition penalty<input id=\"presetRepetitionPenalty\" type=\"number\" step=\"0.01\" placeholder=\"1.0\" /></label ><label >Presence penalty<input id=\"presetPresencePenalty\" type=\"number\" step=\"0.01\" placeholder=\"0\" /></label ><label >Frequency penalty<input id=\"presetFrequencyPenalty\" type=\"number\" step=\"0.01\" placeholder=\"0\" /></label ><label >Max context / prompt tokens<input id=\"presetMaxCtx\" type=\"number\" step=\"1\" placeholder=\"truncate_prompt_tokens\" /></label ><label >Max reply tokens<input id=\"presetMaxTokens\" type=\"number\" step=\"1\" placeholder=\"max_tokens\" /></label ><label >Min reply tokens<input id=\"presetMinTokens\" type=\"number\" step=\"1\" placeholder=\"min_tokens\" /></label ><label >Logprobs<input id=\"presetLogprobs\" type=\"number\" step=\"1\" placeholder=\"optional\" /></label ><label >Top logprobs<input id=\"presetTopLogprobs\" type=\"number\" step=\"1\" placeholder=\"optional\" /></label ><label >Length penalty<input id=\"presetLengthPenalty\" type=\"number\" step=\"0.01\" placeholder=\"optional\" /></label ><label >Ignore EOS<select id=\"presetIgnoreEos\"><option value=\"\">Default</option><option value=\"false\">No</option><option value=\"true\">Yes</option></select></label ><label >Skip special tokens<select id=\"presetSkipSpecial\"><option value=\"\">Default</option><option value=\"true\">Yes</option><option value=\"false\">No</option></select></label ><label >Include stop text<select id=\"presetIncludeStop\"><option value=\"\">Default</option><option value=\"false\">No</option><option value=\"true\">Yes</option></select></label ><label >Stop strings<input id=\"presetStop\" placeholder=\"one per line or comma-separated\" /></label></div><div class=\"preset-form-actions\"><button id=\"presetSaveBtn\" class=\"btn green\" onclick=\"savePresetFromForm()\" > 💾 Save</button ><button class=\"btn red\" onclick=\"closePresetEditor()\"> ❌ Cancel </button></div></div></div></section><section id=\"users\" class=\"tabpane content-tab\"></section><section id=\"chat\" class=\"tabpane content-tab\"><div class=\"panel chat-panel\"><div class=\"panel-head chat-panel-head\"><h2>Chat</h2><div class=\"chat-head-actions\"><div class=\"chat-conversation-strip\"><select id=\"chatConversationSelect\" class=\"chat-conversation-select\" aria-label=\"Conversation\" onchange=\"selectChatConversation(this.value)\" ></select><button class=\"iconbtn\" id=\"chatConversationNewBtn\" title=\"New conversation\" aria-label=\"New conversation\" onclick=\"createNewConversation()\" ><svg viewBox=\"0 0 24 24\" aria-hidden=\"true\"><path d=\"M12 5v14M5 12h14\" fill=\"none\" /></svg></button><button class=\"iconbtn\" id=\"chatConversationEditBtn\" title=\"Rename or move conversation\" aria-label=\"Rename or move conversation\" onclick=\"openConversationEditorModal()\" ><svg viewBox=\"0 0 24 24\" aria-hidden=\"true\"><path d=\"M4 20h4l10-10-4-4L4 16v4zM14 6l4 4\" fill=\"none\" /></svg></button><button class=\"iconbtn\" id=\"chatConversationDeleteBtn\" title=\"Delete conversation\" aria-label=\"Delete conversation\" onclick=\"deleteActiveConversation()\" ><svg viewBox=\"0 0 24 24\" aria-hidden=\"true\"><path d=\"M5 7h14M9 7V5h6v2m-7 3v7m4-7v7m4-7v7M7 7l1 12h8l1-12\" fill=\"none\" /></svg></button><span class=\"chat-head-separator\" aria-hidden=\"true\">|</span><div class=\"chat-head-menu\"><button class=\"iconbtn\" id=\"chatSettingsToggle\" title=\"Chat options\" aria-label=\"Chat options\" onclick=\"toggleChatOptionsMenu()\" ><svg viewBox=\"0 0 24 24\" aria-hidden=\"true\"><path d=\"M12 8.5a3.5 3.5 0 1 0 0 7a3.5 3.5 0 0 0 0-7Zm8 3.5l-2.1.8a6.9 6.9 0 0 1-.6 1.4l.9 2l-2.1 2.1l-2-.9a6.9 6.9 0 0 1-1.4.6L12 20l-1.1-2.1a6.9 6.9 0 0 1-1.4-.6l-2 .9l-2.1-2.1l.9-2a6.9 6.9 0 0 1-.6-1.4L4 12l2.1-1.1a6.9 6.9 0 0 1 .6-1.4l-.9-2l2.1-2.1l2 .9a6.9 6.9 0 0 1 1.4-.6L12 4l1.1 2.1a6.9 6.9 0 0 1 1.4.6l2-.9l2.1 2.1l-.9 2a6.9 6.9 0 0 1 .6 1.4L20 12Z\" fill=\"none\" /></svg></button><div class=\"chat-options-menu hidden\" id=\"chatOptionsMenu\"><button class=\"btn blue\" onclick=\"openChatSettingsPanel()\"> Chat Settings </button><button class=\"btn blue\" onclick=\"openMcpManagerModal()\"> MCP Servers </button></div></div></div></div></div><div class=\"chat-shell\"><div class=\"chat-main\"><div class=\"chat-toolbar\"><label >Container <select id=\"chatPresetSelect\" onchange=\"selectChatPreset(this.value)\"></select></label><label >API Preset <select id=\"chatApiPresetSelect\" onchange=\"selectChatApiPreset(this.value)\"></select></label></div><div class=\"msg chat-status-msg\" id=\"chatMsg\"></div><div class=\"chat-transcript\" id=\"chatTranscript\"></div><div class=\"chat-input-wrap\"><div class=\"chat-composer-row\"><textarea id=\"chatInput\" rows=\"4\" placeholder=\"Send a test message to the selected active preset...\" oninput=\"handleChatInputChange()\" onkeydown=\"handleChatInputKeydown(event)\" onpaste=\"handleChatPaste(event)\" ></textarea><div class=\"chat-action-stack\"><button class=\"iconbtn chat-action-btn chat-send-btn\" onclick=\"sendChatMessage()\" id=\"chatSendBtn\" title=\"Send message\" aria-label=\"Send message\" ><svg viewBox=\"0 0 24 24\" aria-hidden=\"true\"><path d=\"M4 12 19 5l-3.8 5.4L19 12l-3.8 1.6L19 19 4 12Z\" fill=\"currentColor\" stroke=\"none\" /></svg></button><button class=\"iconbtn chat-action-btn chat-mic-btn\" onclick=\"toggleChatDictation()\" id=\"chatMicBtn\" title=\"Voice dictation\" aria-label=\"Voice dictation\" ><svg viewBox=\"0 0 24 24\" aria-hidden=\"true\"><path d=\"M12 15a3 3 0 0 0 3-3V7a3 3 0 1 0-6 0v5a3 3 0 0 0 3 3Zm0 0v4m-4-4a4 4 0 0 0 8 0\" fill=\"none\" /></svg></button><button class=\"iconbtn chat-action-btn chat-attach-btn\" onclick=\"openChatAttachmentPicker()\" id=\"chatAttachBtn\" title=\"Attach files or images\" aria-label=\"Attach files or images\" ><svg viewBox=\"-3 0 28 28\" aria-hidden=\"true\"><path d=\"M8 12.5 14.5 6a3.5 3.5 0 1 1 5 5L10.5 20a5 5 0 1 1-7-7L13 3.5\" fill=\"none\" /></svg></button></div></div><input id=\"chatAttachmentInput\" type=\"file\" multiple class=\"hidden-file-input\" accept=\"image/*,.txt,.md,.markdown,.json,.jsonl,.csv,.tsv,.yaml,.yml,.xml,.html,.css,.js,.mjs,.cjs,.ts,.tsx,.jsx,.py,.sh,.bash,.zsh,.log,.ini,.cfg,.conf\" onchange=\"handleChatAttachmentSelect(event)\" /><div class=\"chat-attachment-rail\" id=\"chatAttachmentRow\"></div></div><div class=\"chat-stats-card\" id=\"chatStatsCard\"><div class=\"chat-stats-head\"><div class=\"chat-stats-title\">Generation Stats</div><button class=\"iconbtn chat-stats-toggle\" id=\"chatStatsToggleBtn\" title=\"Collapse generation stats\" aria-label=\"Collapse generation stats\" onclick=\"toggleChatStatsCollapsed()\" ><svg viewBox=\"0 0 24 24\" aria-hidden=\"true\"><path d=\"m6 15 6-6 6 6\" fill=\"none\" /></svg></button></div><div class=\"chat-runtime-stats\" id=\"chatRuntimeStats\">-</div></div></div></div></div></section><section id=\"metrics\" class=\"tabpane content-tab\"><div class=\"panel\"><h2>Metrics</h2><div class=\"subtabs\"><button class=\"subtab active\" onclick=\"metricTab(event, 'mMain')\"> Main</button ><button class=\"subtab\" onclick=\"metricTab(event, 'mGpu')\"> GPUs</button ><button class=\"subtab\" onclick=\"metricTab(event, 'mRam')\"> RAM</button ><button class=\"subtab\" onclick=\"metricTab(event, 'mCpu')\"> CPU</button ><button class=\"subtab\" onclick=\"metricTab(event, 'mSystem')\"> System</button ><button class=\"subtab\" onclick=\"metricTab(event, 'mNetwork')\"> Network </button></div><div id=\"mMain\" class=\"metricpane active\"><div class=\"chartgrid\"><div class=\"chart\"><canvas id=\"cGpu\"></canvas></div><div class=\"chart\"><canvas id=\"cMem\"></canvas></div><div class=\"chart\"><canvas id=\"cLatency\"></canvas></div><div class=\"chart\"><canvas id=\"cTps\"></canvas></div></div></div><div id=\"mGpu\" class=\"metricpane\"><div id=\"gpuMetricCharts\" class=\"gpu-chartgrid\"></div></div><div id=\"mRam\" class=\"metricpane\"><div id=\"ramInfo\" class=\"value smallgap\"></div><div class=\"chartgrid\"><div class=\"chart tall\"><canvas id=\"cRam\"></canvas></div></div></div><div id=\"mCpu\" class=\"metricpane\"><div class=\"chartgrid\"><div class=\"chart\"><canvas id=\"cCpu\"></canvas></div></div><div id=\"cpuCores\" class=\"coregrid\"></div></div><div id=\"mSystem\" class=\"metricpane\"><div class=\"chartgrid\"><div class=\"chart\"><canvas id=\"cSystemUtil\"></canvas></div></div><div class=\"panel\"><h2>System Information</h2><div id=\"systemInfo\" class=\"value\"></div></div><div class=\"panel\"><h2>Storage</h2><div id=\"diskInfo\"></div></div></div><div id=\"mNetwork\" class=\"metricpane\"><div id=\"netInfo\" class=\"netgrid\"></div><div class=\"chartgrid\"><div class=\"chart\"><canvas id=\"cNetDown\"></canvas></div><div class=\"chart\"><canvas id=\"cNetUp\"></canvas></div></div></div></div></section><section id=\"logs\" class=\"tabpane\"></section><section class=\"panel logtools\"><h2>Log Management</h2><div class=\"searchbox\"><button class=\"btn\" id=\"searchPrev\" onclick=\"previousMatch()\" disabled > ⏪</button ><input id=\"searchQuery\" placeholder=\"Search log text\" onkeydown=\"if (event.key === 'Enter') runSearchOrNext();\" /><button class=\"btn\" id=\"searchNext\" onclick=\"runSearchOrNext()\"> 🔍</button ><span style=\"border-left: 1px solid #34445a; height: 28px\"></span ><button class=\"btn\" id=\"refreshBtn\" onclick=\"refreshStatus()\"> ♻️</button ><button class=\"btn\" id=\"clearBtn\" onclick=\"clearOrCancelLog()\"> 🗑️ </button></div></section><section class=\"logs panel\"><div class=\"loghead\"><h2 id=\"logTitle\">Docker Logs</h2><div class=\"logheadchecks\"><span class=\"label\" id=\"logInstanceLabel\">instance: primary</span ><label class=\"label\" ><input type=\"checkbox\" id=\"showGlobalLogs\" checked onchange=\"setShowGlobalLogs(this.checked)\" /> show globally</label ><label class=\"label\" ><input type=\"checkbox\" id=\"autoscroll\" checked /> auto-scroll</label ></div></div><textarea id=\"log\" class=\"log\" readonly wrap=\"soft\"> Connecting...</textarea ></section></main><script>const searchState={active:!1,query:\"\",matches:[],index:-1,prevAutoscroll:!0};let lastStatus=null,activeTabName=\"overview\",showGlobalLogs=!0,lastWindowFocused=\"function\"!=typeof document.hasFocus||document.hasFocus(),lastSwitchNotificationKey=\"\";function $(id){return document.getElementById(id)}function setMsg(t){$(\"msg\").textContent=t||\"\"}function setElementMsg(id,text,tone=\"warning\"){const node=$(id);if(!node)return;const nextText=String(text||\"\");if(node.textContent=nextText,node.classList.remove(\"msg-error\",\"msg-warning\",\"msg-success\"),!nextText)return;const nextTone=String(tone||\"warning\").trim().toLowerCase();\"error\"!==nextTone&&\"success\"!==nextTone&&\"warning\"!==nextTone||node.classList.add(`msg-${nextTone}`)}function windowIsFocused(){return!!lastWindowFocused&&!document.hidden}async function ensureNotificationPermission(){if(\"undefined\"==typeof Notification)return\"unsupported\";if(\"granted\"===Notification.permission)return\"granted\";if(\"denied\"===Notification.permission)return\"denied\";try{return await Notification.requestPermission()}catch(e){return\"error\"}}async function showBrowserNotification(title,body){const heading=String(title||\"Club-3090\"),message=String(body||\"\").trim(),permission=await ensureNotificationPermission();if(\"granted\"===permission&&\"undefined\"!=typeof Notification)try{return void new Notification(heading,{body:message,tag:\"club3090-runtime\"})}catch(e){}\"unsupported\"===permission&&window.alert(`${heading}\\n\\n${message}`)}function clearLog(){const signature=currentLogSignature||logStreamConfig().signature,entry=logCacheEntry(signature);entry.text=\"\",entry.loaded=!0,renderCurrentLog(signature)}function appendLog(t){appendLogChunk(currentLogSignature||logStreamConfig().signature,`${t}\\n`)}function clearOrCancelLog(){searchState.active?cancelSearch():clearLog()}function recalculateMatches(keepIndex=!0){const q=$(\"searchQuery\").value;if(!searchState.active||!q)return;const text=$(\"log\").value.toLowerCase(),needle=q.toLowerCase();let pos=0,m=[];for(;needle;){const i=text.indexOf(needle,pos);if(i<0)break;m.push(i),pos=i+needle.length}searchState.matches=m,m.length?searchState.index=keepIndex?Math.min(Math.max(searchState.index,0),m.length-1):0:searchState.index=-1,updateSearchUI(!1)}function runSearchOrNext(){if(searchState.active&&searchState.matches.length)return void nextMatch();$(\"searchQuery\").value&&(searchState.prevAutoscroll=$(\"autoscroll\").checked,searchState.active=!0,$(\"autoscroll\").checked=!1,$(\"autoscroll\").disabled=!0,recalculateMatches(!1),searchState.matches.length?gotoMatch(0):updateSearchUI(!1))}function gotoMatch(i){if(!searchState.matches.length)return;searchState.index=(i+searchState.matches.length)%searchState.matches.length;const start=searchState.matches[searchState.index],end=start+searchState.query.length,log=$(\"log\");log.focus(),log.setSelectionRange(start,end);const before=log.value.slice(0,start).split(\"\\n\").length-1;log.scrollTop=Math.max(0,16*before-log.clientHeight/2),updateSearchUI(!1)}function nextMatch(){searchState.active&&searchState.matches.length&&gotoMatch(searchState.index+1)}function previousMatch(){searchState.active&&searchState.matches.length&&gotoMatch(searchState.index-1)}function cancelSearch(){searchState.active=!1,searchState.query=\"\",searchState.matches=[],searchState.index=-1,$(\"searchQuery\").value=\"\",$(\"autoscroll\").disabled=!1,$(\"autoscroll\").checked=searchState.prevAutoscroll,$(\"log\").setSelectionRange($(\"log\").selectionStart,$(\"log\").selectionStart),updateSearchUI(!0)}function updateSearchUI(reset){searchState.active?(searchState.query=$(\"searchQuery\").value,$(\"searchPrev\").disabled=searchState.matches.length<2,$(\"searchNext\").textContent=searchState.matches.length>1?\"⏩\":\"🔍\",$(\"refreshBtn\").disabled=!0,$(\"refreshBtn\").textContent=searchState.matches.length?`${searchState.index+1}/${searchState.matches.length}`:\"0/0\",$(\"clearBtn\").textContent=\"❌\"):($(\"searchPrev\").disabled=!0,$(\"searchNext\").textContent=\"🔍\",$(\"refreshBtn\").disabled=!1,$(\"refreshBtn\").textContent=\"♻️\",$(\"clearBtn\").textContent=\"🗑️\")}function fmtUptime(s){return s=Number(s||0),Math.floor(s/3600)+\"h \"+Math.floor(s%3600/60)+\"m\"}function mibToGiB(v){return(Number(v||0)/1024).toFixed(2)}function inferGpuStatus(g){const u=Number(g.util_pct||0);return lastStatus&&lastStatus.metrics&&lastStatus.metrics.active_requests>0?u>20?\"Token Generation\":\"Prompt Processing\":u>5?\"Active\":\"Idle\"}function tempClass(t){return(t=Number(t||0))<35?\"temp-blue\":t<50?\"temp-green\":t<60?\"temp-yellow\":t<70?\"temp-orange\":t<80?\"temp-red\":\"temp-crimson\"}function trimFormattedNumber(text){return String(text||\"\").replace(/(\\.\\d*?[1-9])0+$|\\.0+$/,\"$1\")}function formatTempWithPeak(current,peak){const currentText=formatMaybeNumber(current,0);if(!currentText)return\"N/A\";const currentWarn=Number(current||0)>=80?\" ⚠️\":\"\",peakText=formatMaybeNumber(peak,0);if(!peakText)return`<span class=\"${tempClass(current)}\">${currentText}°C${currentWarn}</span>`;const peakWarn=Number(peak||0)>=80?\" ⚠️\":\"\";return`<span class=\"${tempClass(current)}\">${currentText}°C${currentWarn}</span> <span class=\"${tempClass(peak)}\">( ${peakText}°↑ C${peakWarn})</span>`}window.addEventListener(\"focus\",()=>{lastWindowFocused=!0}),window.addEventListener(\"blur\",()=>{lastWindowFocused=!1}),document.addEventListener(\"visibilitychange\",()=>{lastWindowFocused=\"function\"==typeof document.hasFocus?document.hasFocus():!document.hidden});const gpuStatusHistoryByIndex={},runtimeStatusHistoryById={};function formatMaybeNumber(value,digits=2){const num=Number(value);if(Number.isFinite(num))return trimFormattedNumber(num.toFixed(digits));const raw=String(value??\"\").trim();return raw&&\"N/A\"!==raw&&\"[Not Supported]\"!==raw?raw:\"\"}function formatGpuMetricWithPeak(current,peak,unit,digits=2){const currentText=formatMaybeNumber(current,digits);if(!currentText)return\"N/A\";const peakText=formatMaybeNumber(peak,digits);return`${currentText} ${unit}${peakText?` ( ${peakText}&uarr; ${unit})`:\"\"}`}function updateStatusHistory(store,key,nextStatus){const normalizedKey=String(key||\"\").trim(),status=String(nextStatus||\"\").trim();if(!normalizedKey||!status)return{current:status,previous:\"\"};const existing=store[normalizedKey]||{current:\"\",previous:\"\"};existing.current&&existing.current!==status?store[normalizedKey]={current:status,previous:existing.current}:existing.current||(store[normalizedKey]={current:status,previous:existing.previous||\"\"});const resolved=store[normalizedKey]||{current:status,previous:\"\"};return{current:status,previous:resolved.previous&&resolved.previous!==status?resolved.previous:\"\"}}function runtimeActivityStatus(runtime){const running=Number(runtime?.running_requests||0),waiting=Number(runtime?.waiting_requests||0),pending=Number(runtime?.pending_requests||0),swapped=Number(runtime?.swapped_requests||0),generationTps=Number(runtime?.generation_tps||0),lastTps=Number(runtime?.last_tokens_per_second||0);return(running>0||waiting>0||pending>0||swapped>0)&&(generationTps>.1||lastTps>.1)?\"Generation\":running>0||waiting>0||pending>0||swapped>0?\"Prompt Processing\":\"Idle\"}function renderGpuCards(gs){gs&&gs.length?$(\"gpuCards\").innerHTML=gs.map(g=>g.error?`<div class=\"gpu-card\">${g.error}</div>`:(()=>{const statusHistory=updateStatusHistory(gpuStatusHistoryByIndex,g.index,inferGpuStatus(g)),currentStatus=statusHistory.current,previousStatus=statusHistory.previous;return`<div class=\"gpu-card\"><div class=\"gpu-title\">GPU ${g.index} - ${g.name||\"RTX 3090\"}${g.vendor?\" (\"+g.vendor+\")\":\"\"}</div><div class=\"gpu-grid\"><div><div class=\"gpu-section-title\">Temperature</div><div class=\"gpu-line\"><span>Core</span><b>${formatTempWithPeak(g.temp_c,g.temp_peak_c)}</b></div></div><div><div class=\"gpu-section-title\">VRAM</div><div class=\"gpu-line\"><span>Free</span><b>${mibToGiB(g.mem_free_mib)} GB</b></div><div class=\"gpu-line\"><span>Used</span><b>${mibToGiB(g.mem_used_mib)} GB</b></div><div class=\"gpu-line\"><span>Max</span><b>${mibToGiB(g.mem_total_mib)} GB</b></div><div class=\"meter\"><span style=\"width:${Number(g.mem_pct||0)}%\"></span></div></div><div><div class=\"gpu-section-title\">Power</div><div class=\"gpu-line\"><span>Draw</span><b>${formatGpuMetricWithPeak(g.power_w,g.power_peak_w,\"W\",2)}</b></div><div class=\"gpu-line\"><span>Max Power</span><b>${g.power_limit_w||\"N/A\"} W</b></div></div><div><div class=\"gpu-section-title\">Fans</div><div class=\"gpu-line\"><span>Speed</span><b>${g.fan_pct||\"N/A\"}%</b></div></div><div><div class=\"gpu-section-title\">Clocks</div><div class=\"gpu-line\"><span>Core</span><b>${formatGpuMetricWithPeak(g.core_clock_mhz,g.core_clock_peak_mhz,\"MHz\",0)}</b></div><div class=\"gpu-line\"><span>Mem</span><b>${formatGpuMetricWithPeak(g.mem_clock_mhz,g.mem_clock_peak_mhz,\"MHz\",0)}</b></div></div><div><div class=\"gpu-section-title\">Usage</div><div class=\"gpu-line\"><span>Load</span><b>${g.util_pct||\"N/A\"}%</b></div><div class=\"gpu-line\"><span>Status</span><b>${currentStatus}${previousStatus?` (Previous: ${previousStatus})`:\"\"}</b></div></div></div></div>`})()).join(\"\"):$(\"gpuCards\").innerHTML='<div class=\"panel\">No GPU data</div>'}let editingPresetName=null;function presetParamSummary(params){params=params||{};const bits=[];if([\"temperature\",\"top_p\",\"top_k\",\"min_p\",\"presence_penalty\",\"frequency_penalty\",\"repetition_penalty\",\"length_penalty\",\"max_tokens\",\"max_completion_tokens\",\"min_tokens\",\"truncate_prompt_tokens\",\"logprobs\",\"top_logprobs\"].forEach(k=>{void 0!==params[k]&&null!==params[k]&&\"\"!==params[k]&&bits.push(`${k}: ${params[k]}`)}),void 0!==params.ignore_eos&&bits.push(\"ignore_eos: \"+(params.ignore_eos?\"on\":\"off\")),void 0!==params.skip_special_tokens&&bits.push(\"skip special: \"+(params.skip_special_tokens?\"on\":\"off\")),void 0!==params.include_stop_str_in_output&&bits.push(\"include stop: \"+(params.include_stop_str_in_output?\"on\":\"off\")),void 0!==params.stop&&bits.push(`stop: ${Array.isArray(params.stop)?params.stop.join(\"|\"):params.stop}`),params.chat_template_kwargs){const c=params.chat_template_kwargs;void 0!==c.enable_thinking&&bits.push(\"thinking: \"+(c.enable_thinking?\"on\":\"off\")),c.preserve_thinking&&bits.push(\"preserve thinking: on\")}return bits.join(\", \")||\"No explicit parameters\"}function renderPresetCatalog(catalog){const grid=$(\"apiPresetGrid\");if(!grid||!catalog)return;const items=[...catalog.defaults||[],...catalog.custom||[]];grid.innerHTML=items.map(p=>{const locked=p.locked;return`<div class=\"api-card\"><div class=\"api-card-head\"><h3>${p.endpoint}<br><span class=\"label\">${p.endpoint_alt||\"/\"+p.name}</span></h3>${locked?'<span class=\"label\">default</span>':`<span class=\"preset-actions\"><button class=\"iconbtn\" title=\"Edit\" onclick=\"editPreset('${p.name}')\">✏️</button><button class=\"iconbtn\" title=\"Delete\" onclick=\"deletePreset('${p.name}')\">❌</button></span>`}</div><p>${p.description||\"\"}</p><p class=\"label\">${presetParamSummary(p.params)}</p></div>`}).join(\"\")+'<div class=\"api-card\"><h3>/v1/short-* / /short-* and /v1/concise-* / /concise-*</h3><p>Prefix any default or custom preset to cap replies: short = 4096 tokens, concise = 512 tokens. Presets work both under /v1/name and /name for clients that append /v1 automatically.</p></div>'}function openPresetEditor(data){editingPresetName=data&&data.name?data.name:null,$(\"presetEditor\").classList.add(\"open\"),$(\"presetIntro\")&&$(\"presetIntro\").classList.add(\"hidden\"),$(\"presetSaveBtn\").textContent=editingPresetName?\"💾 Save changes\":\"💾 Save\",$(\"presetName\").disabled=!!editingPresetName,$(\"presetName\").value=data?.name||\"\",$(\"presetDescription\").value=data?.description||\"\",$(\"presetSystemPrompt\").value=data?.system_prompt||\"\";const p=data?.params||{},c=p.chat_template_kwargs||{};$(\"presetTemperature\").value=p.temperature??\"\",$(\"presetTopP\").value=p.top_p??\"\",$(\"presetTopK\").value=p.top_k??\"\",$(\"presetMinP\").value=p.min_p??\"\",$(\"presetThinking\").value=String(!!c.enable_thinking),$(\"presetPreserveThinking\").value=String(!!c.preserve_thinking),$(\"presetRepetitionPenalty\").value=p.repetition_penalty??\"\",$(\"presetPresencePenalty\").value=p.presence_penalty??\"\",$(\"presetFrequencyPenalty\").value=p.frequency_penalty??\"\",$(\"presetMaxCtx\").value=p.truncate_prompt_tokens??\"\",$(\"presetMaxTokens\").value=p.max_tokens??\"\",$(\"presetMinTokens\").value=p.min_tokens??\"\",$(\"presetLogprobs\").value=p.logprobs??\"\",$(\"presetTopLogprobs\").value=p.top_logprobs??\"\",$(\"presetLengthPenalty\").value=p.length_penalty??\"\",$(\"presetIgnoreEos\").value=void 0===p.ignore_eos?\"\":String(!!p.ignore_eos),$(\"presetSkipSpecial\").value=void 0===p.skip_special_tokens?\"\":String(!!p.skip_special_tokens),$(\"presetIncludeStop\").value=void 0===p.include_stop_str_in_output?\"\":String(!!p.include_stop_str_in_output),$(\"presetStop\").value=Array.isArray(p.stop)?p.stop.join(\"\\n\"):p.stop??\"\",$(\"presetEditor\").scrollIntoView({behavior:\"smooth\",block:\"center\"})}function closePresetEditor(){editingPresetName=null,$(\"presetEditor\").classList.remove(\"open\"),$(\"presetIntro\")&&$(\"presetIntro\").classList.remove(\"hidden\")}function collectPresetForm(){function val(id){return $(id).value.trim()}const preset={description:val(\"presetDescription\"),system_prompt:$(\"presetSystemPrompt\").value,enable_thinking:\"true\"===$(\"presetThinking\").value,preserve_thinking:\"true\"===$(\"presetPreserveThinking\").value};[[\"temperature\",\"presetTemperature\"],[\"top_p\",\"presetTopP\"],[\"top_k\",\"presetTopK\"],[\"min_p\",\"presetMinP\"],[\"repetition_penalty\",\"presetRepetitionPenalty\"],[\"presence_penalty\",\"presetPresencePenalty\"],[\"frequency_penalty\",\"presetFrequencyPenalty\"],[\"truncate_prompt_tokens\",\"presetMaxCtx\"],[\"max_tokens\",\"presetMaxTokens\"],[\"min_tokens\",\"presetMinTokens\"],[\"logprobs\",\"presetLogprobs\"],[\"top_logprobs\",\"presetTopLogprobs\"],[\"length_penalty\",\"presetLengthPenalty\"]].forEach(([k,id])=>{const n=function(id){const v=val(id);return\"\"===v?void 0:Number(v)}(id);Number.isFinite(n)&&(preset[k]=n)}),[[\"ignore_eos\",\"presetIgnoreEos\"],[\"skip_special_tokens\",\"presetSkipSpecial\"],[\"include_stop_str_in_output\",\"presetIncludeStop\"]].forEach(([k,id])=>{const v=val(id);\"\"!==v&&(preset[k]=\"true\"===v)});const stop=val(\"presetStop\");return stop&&(preset.stop=stop),preset}async function savePresetFromForm(){const name=editingPresetName||$(\"presetName\").value.trim();try{const r=await fetch(\"/admin/presets\",{method:\"POST\",headers:{\"Content-Type\":\"application/json\"},body:JSON.stringify({action:\"save\",name,preset:collectPresetForm()})}),j=await r.json();if(!r.ok||!j.ok)throw new Error(j.error||\"save failed\");renderPresetCatalog(j.presets),closePresetEditor(),setMsg(\"Saved preset \"+name),await refreshStatus()}catch(e){alert(\"Preset save failed: \"+e)}}function editPreset(name){const p=(lastStatus?.presets?.custom||[]).find(x=>x.name===name);p&&openPresetEditor(p)}async function deletePreset(name){if(confirm(\"Delete custom preset \"+name+\"?\"))try{const r=await fetch(\"/admin/presets\",{method:\"POST\",headers:{\"Content-Type\":\"application/json\"},body:JSON.stringify({action:\"delete\",name})}),j=await r.json();if(!r.ok||!j.ok)throw new Error(j.error||\"delete failed\");renderPresetCatalog(j.presets),setMsg(\"Deleted preset \"+name),await refreshStatus()}catch(e){alert(\"Preset delete failed: \"+e)}}function draw(id,data,key,label,color){const c=$(id);if(!c)return;const ctx=c.getContext(\"2d\"),dpr=devicePixelRatio||1,w=c.width=c.clientWidth*dpr,h=c.height=c.clientHeight*dpr;if(ctx.clearRect(0,0,w,h),ctx.fillStyle=color||\"#9dafc3\",ctx.font=11*dpr+\"px system-ui\",ctx.fillText(label,8*dpr,14*dpr),!data.length)return;const vals=data.map(x=>Number(x[key]||0)),max=1.1*Math.max(1,...vals);ctx.strokeStyle=color,ctx.lineWidth=2*dpr,ctx.beginPath(),vals.forEach((v,i)=>{const x=i/(vals.length-1||1)*w,y=h-v/max*(h-24*dpr)-4*dpr;i?ctx.lineTo(x,y):ctx.moveTo(x,y)}),ctx.stroke(),ctx.fillStyle=\"#e8eef7\",ctx.fillText(String(vals[vals.length-1]||0),w-62*dpr,14*dpr)}function drawGpuSeries(id,series,index,key,label,color){draw(id,series.map(p=>{const g=(p.gpus||[]).find(x=>String(x.index)===String(index));return{[key]:g?Number(g[key]||0):0}}),key,label,color)}function renderMetrics(j){const s=j.series||[];draw(\"cGpu\",s,\"gpu_util\",\"GPU util %\",\"#72c7ff\"),draw(\"cMem\",s,\"mem_pct\",\"VRAM %\",\"#2fc46b\"),draw(\"cLatency\",s,\"latency_s\",\"Latency s\",\"#ffcb6b\"),draw(\"cTps\",s,\"tps\",\"TPS est\",\"#ff5b6c\"),draw(\"cRam\",s,\"ram_pct\",\"System RAM %\",\"#2fc46b\"),draw(\"cCpu\",s,\"cpu_pct\",\"CPU total %\",\"#72c7ff\"),draw(\"cSystemUtil\",s,\"system_util_pct\",\"System utilization %\",\"#a78bfa\"),draw(\"cNetDown\",s,\"net_rx_kbps\",\"Download kbps\",\"#2fc46b\"),draw(\"cNetUp\",s,\"net_tx_kbps\",\"Upload kbps\",\"#72c7ff\"),$(\"ramInfo\")&&($(\"ramInfo\").textContent=j.system&&j.system.memory?`Used ${mibToGiB(j.system.memory.used_mib)} / ${mibToGiB(j.system.memory.total_mib)} GB (${j.system.memory.used_pct}%)`:\"\");const cores=j.system&&j.system.cpu&&j.system.cpu.cores||[];$(\"cpuCores\")&&($(\"cpuCores\").innerHTML=cores.map(c=>`<div class=\"stat\"><div class=\"label\">Core ${c.core}</div><div class=\"value\">${c.usage_pct}%</div><div class=\"meter\"><span style=\"width:${c.usage_pct}%\"></span></div></div>`).join(\"\"));const disks=j.system&&j.system.disks||[];function storageCard(d){if(d.error)return`<div class=\"storage-card\"><div class=\"storage-title\">Error</div><div class=\"value\">${d.error}</div></div>`;const title=`${d.path||d.source||d.name||\"disk\"}${d.label?\" — \"+d.label:\"\"}`,meta=`${d.model||\"\"} ${d.transport?\"· \"+d.transport:\"\"} · ${d.type||\"-\"} / ${d.partition_type||\"-\"} · ${d.fs||\"-\"} · ${d.mount||\"not mounted\"}${d.usage_basis?\" · \"+d.usage_basis:\"\"}`,sizeText=v=>null==v?\"Unknown\":`${v} GB`,free=sizeText(d.free_gib),used=sizeText(d.used_gib),total=sizeText(d.total_gib),pct=null===d.used_pct||void 0===d.used_pct?0:Number(d.used_pct||0),pctLabel=null===d.used_pct||void 0===d.used_pct?\"usage unknown\":`${pct}% used`;return`<div class=\"${d.user_facing?\"storage-card user-facing\":\"storage-card\"}\"><div class=\"storage-title\">${title}</div><div class=\"storage-meta\">${meta}</div><div class=\"storage-sizes\"><div class=\"stat\"><div class=\"label\">Free</div><div class=\"value\">${free}</div></div><div class=\"stat\"><div class=\"label\">Used</div><div class=\"value\">${used}</div></div><div class=\"stat\"><div class=\"label\">Total</div><div class=\"value\">${total}</div></div></div><div class=\"diskbar\"><span style=\"width:${pct}%\"></span></div><div class=\"label\">${pctLabel}</div></div>`}if($(\"diskInfo\")){const physical=disks.filter(d=>\"disk\"===d.kind||\"disk\"===d.type),volumes=disks.filter(d=>!(\"disk\"===d.kind||\"disk\"===d.type));$(\"diskInfo\").innerHTML=`<div class=\"storage-section\"><div class=\"panel\"><h2>Disks</h2><div class=\"storage-list\">${physical.map(storageCard).join(\"\")||'<div class=\"value\">No physical disks found</div>'}</div></div><div class=\"panel\"><h2>Volumes</h2><div class=\"storage-list\">${volumes.map(storageCard).join(\"\")||'<div class=\"value\">No volumes found</div>'}</div></div></div>`}const net=j.system&&j.system.network||{};$(\"netInfo\")&&($(\"netInfo\").innerHTML=`<div class=\"stat\"><div class=\"label\">Local IP</div><div class=\"value\">${net.local_ip||\"unknown\"}</div></div><div class=\"stat\"><div class=\"label\">Internet IP</div><div class=\"value\">${net.public_ip||\"unknown\"}</div></div><div class=\"stat\"><div class=\"label\">Download</div><div class=\"value\">${net.rx_kbps||0} kbps</div></div><div class=\"stat\"><div class=\"label\">Upload</div><div class=\"value\">${net.tx_kbps||0} kbps</div></div>`);const info=j.system&&j.system.info||{};$(\"systemInfo\")&&($(\"systemInfo\").innerHTML=`OS: ${info.os||\"unknown\"}<br>Kernel: ${info.kernel||\"unknown\"}<br>Host: ${info.hostname||\"unknown\"}<br>User: ${info.username||\"unknown\"}<br>Machine: ${info.machine||\"unknown\"}<br>CPU: ${info.cpu_model||\"unknown\"}<br>Board/Product: ${info.board||\"-\"} / ${info.product||\"-\"}<br>BIOS: ${info.bios||\"-\"}<br>GPUs: ${info.gpus||\"unknown\"}`);const holder=$(\"gpuMetricCharts\");if(holder&&j.gpus){const cats=[{key:\"util\",suffix:\"Util\",label:\"util %\",color:\"#72c7ff\"},{key:\"mem_pct\",suffix:\"Mem\",label:\"VRAM %\",color:\"#2fc46b\"},{key:\"temp\",suffix:\"Temp\",label:\"core temp °C\",color:\"#ffde59\"},{key:\"power\",suffix:\"Power\",label:\"power W\",color:\"#ff5b6c\"}];holder.innerHTML=cats.map(cat=>j.gpus.map(g=>`<div class=\"chart\"><canvas id=\"cGpu${g.index}${cat.suffix}\"></canvas></div>`).join(\"\")).join(\"\"),cats.forEach(cat=>j.gpus.forEach(g=>{const color=cat.color,label=`GPU${g.index} ${cat.label}`;drawGpuSeries(`cGpu${g.index}${cat.suffix}`,s,g.index,cat.key,label,color)}))}}let selectedInstance=\"GPU0\",logEs=null,selectedUserName=\"\",selectedOverviewInstanceId=\"\",selectedLogInstanceId=\"\",selectedPresetModelId=\"\",selectedPresetModelHydrated=!1,pendingLogJump=null;const SUMMARY_CACHE_KEY=\"club3090-preset-summary-v520\",CHAT_STATE_KEY=\"club3090-chat-state-v527\",LEGACY_CHAT_STATE_KEY=\"club3090-chat-state-v520\",LEGACY_CHAT_STATE_KEY_V516=\"club3090-chat-state-v516\",CHAT_UNTITLED_TITLE=\"Untitled conversation\",CHAT_MIN_COMPACTION_THRESHOLD=50,CHAT_MAX_COMPACTION_THRESHOLD=95,CHAT_THINKING_RENDER_INTERVAL_MS=250,CHAT_CONVERSATION_FOLDER_RE=/^[A-Za-z0-9 _-]*$/;let presetSummaryCache={persistent:{},transient:{},restartTargets:[],lastSeenUptime:0},chatStateServerReady=!1,chatStateSaveTimer=null,lastQueuedChatStateJson=\"\";function defaultChatParams(){return{temperature:\"\",top_p:\"\",top_k:\"\",min_p:\"\",repetition_penalty:\"\",presence_penalty:\"\",frequency_penalty:\"\",max_tokens:\"\",seed:\"\",enable_thinking:!1,preserve_thinking:!1}}function clampChatCompactionThreshold(value){const numeric=Number(value);return Number.isFinite(numeric)?Math.max(50,Math.min(95,Math.round(numeric))):95}function normalizeConversationFolder(value){return String(value||\"\").replace(/[^A-Za-z0-9 _-]+/g,\"\").replace(/\\s+/g,\" \").trim()}function isValidConversationFolder(value){return CHAT_CONVERSATION_FOLDER_RE.test(String(value||\"\"))}function cloneChatParams(params={}){return{...defaultChatParams(),...params&&\"object\"==typeof params?params:{},enable_thinking:!!params?.enable_thinking,preserve_thinking:!!params?.preserve_thinking}}function cloneChatAttachment(attachment={}){const kind=\"image\"===attachment?.kind?\"image\":\"text\",row={id:String(attachment?.id||\"\"),kind,name:String(attachment?.name||(\"image\"===kind?\"image\":\"attachment\")),mime:String(attachment?.mime||\"\"),source:String(attachment?.source||\"\")};return\"image\"===kind?(row.url=String(attachment?.url||\"\"),void 0!==attachment?.size_bytes&&(row.size_bytes=attachment.size_bytes)):row.text=String(attachment?.text||\"\"),row}function cloneChatMessage(message={}){return{...message,role:String(message?.role||\"user\"),text:String(message?.text||\"\"),attachments:Array.isArray(message?.attachments)?message.attachments.map(cloneChatAttachment):[],reasoningText:String(message?.reasoningText||\"\"),reasoning_content:String(message?.reasoning_content||\"\"),reasoning:String(message?.reasoning||\"\"),modelLabel:String(message?.modelLabel||\"\")}}function cloneChatMessages(messages=[]){return Array.isArray(messages)?messages.map(cloneChatMessage):[]}function currentChatStatePayload(){return{activeConversationId:chatState.activeConversationId,conversations:Array.isArray(chatState.conversations)?chatState.conversations.map(conversation=>({...conversation,folder:normalizeConversationFolder(conversation?.folder||\"\"),title:String(conversation?.title||\"\").trim()||CHAT_UNTITLED_TITLE,summary:String(conversation?.summary||\"\"),presetId:String(conversation?.presetId||\"\"),apiPresetName:String(conversation?.apiPresetName||\"\"),params:cloneChatParams(conversation?.params),systemPrompt:String(conversation?.systemPrompt||\"\"),autoCompactEnabled:!1!==conversation?.autoCompactEnabled,autoCompactThresholdPct:clampChatCompactionThreshold(conversation?.autoCompactThresholdPct),messages:cloneChatMessages(conversation?.messages),attachments:Array.isArray(conversation?.attachments)?conversation.attachments.map(cloneChatAttachment):[],draftText:String(conversation?.draftText||\"\"),compactedFromId:String(conversation?.compactedFromId||\"\"),compactionSequence:Math.max(1,Number(conversation?.compactionSequence||1)||1),lastInputTokens:void 0!==conversation?.lastInputTokens?conversation.lastInputTokens:void 0,lastOutputTokens:void 0!==conversation?.lastOutputTokens?conversation.lastOutputTokens:void 0,lastTotalTokens:void 0!==conversation?.lastTotalTokens?conversation.lastTotalTokens:void 0,lastCtxSizeTokens:void 0!==conversation?.lastCtxSizeTokens?conversation.lastCtxSizeTokens:void 0,lastKvCacheUsagePct:void 0!==conversation?.lastKvCacheUsagePct?conversation.lastKvCacheUsagePct:void 0,lastRuntimeRequestAt:void 0!==conversation?.lastRuntimeRequestAt?conversation.lastRuntimeRequestAt:void 0})):[],promptTemplates:Array.isArray(chatState.promptTemplates)?chatState.promptTemplates.map(template=>({id:String(template?.id||chatConversationId()),name:String(template?.name||\"\").trim(),text:String(template?.text||\"\")})):[]}}function queueServerChatStateSave(payload=currentChatStatePayload()){if(!chatStateServerReady)return;const nextJson=JSON.stringify(payload||{});nextJson!==lastQueuedChatStateJson&&(lastQueuedChatStateJson=nextJson,chatStateSaveTimer&&clearTimeout(chatStateSaveTimer),chatStateSaveTimer=setTimeout(async()=>{try{await fetch(\"/admin/chat-state\",{method:\"POST\",headers:{\"Content-Type\":\"application/json\"},body:nextJson})}catch(e){}},120))}function chatConversationId(){return`chat-${Date.now()}-${Math.random().toString(36).slice(2,8)}`}function isUntitledConversationTitle(title){return!String(title||\"\").trim()||String(title||\"\").trim()===CHAT_UNTITLED_TITLE}function createChatConversation(seed={},inheritFrom=null){const base=inheritFrom&&\"object\"==typeof inheritFrom?inheritFrom:{},createdAt=Number(seed.createdAt||Date.now());return{id:String(seed.id||chatConversationId()),title:String(seed.title||CHAT_UNTITLED_TITLE).trim()||CHAT_UNTITLED_TITLE,folder:void 0!==seed.folder?normalizeConversationFolder(seed.folder):normalizeConversationFolder(base.folder||\"\"),summary:String(seed.summary||\"\"),autoNamed:void 0!==seed.autoNamed?!!seed.autoNamed:!isUntitledConversationTitle(seed.title||\"\"),createdAt,updatedAt:Number(seed.updatedAt||createdAt),lastUsedAt:Number(seed.lastUsedAt||seed.updatedAt||createdAt),statsCollapsed:void 0!==seed.statsCollapsed?!!seed.statsCollapsed:!!base.statsCollapsed,presetId:void 0!==seed.presetId?String(seed.presetId||\"\"):String(base.presetId||\"\"),apiPresetName:void 0!==seed.apiPresetName?String(seed.apiPresetName||\"\"):String(base.apiPresetName||\"\"),params:void 0!==seed.params?cloneChatParams(seed.params):cloneChatParams(base.params),systemPrompt:void 0!==seed.systemPrompt?String(seed.systemPrompt||\"\"):String(base.systemPrompt||\"\"),autoCompactEnabled:void 0!==seed.autoCompactEnabled?!!seed.autoCompactEnabled:!1!==base.autoCompactEnabled,autoCompactThresholdPct:clampChatCompactionThreshold(void 0!==seed.autoCompactThresholdPct?seed.autoCompactThresholdPct:base.autoCompactThresholdPct),messages:cloneChatMessages(seed.messages),attachments:Array.isArray(seed.attachments)?seed.attachments.map(cloneChatAttachment):[],draftText:String(seed.draftText||\"\"),compactedFromId:String(seed.compactedFromId||\"\"),compactionSequence:Math.max(1,Number(void 0!==seed.compactionSequence?seed.compactionSequence:base.compactionSequence||1)||1),lastInputTokens:void 0!==seed.lastInputTokens?Number(seed.lastInputTokens||0):void 0,lastOutputTokens:void 0!==seed.lastOutputTokens?Number(seed.lastOutputTokens||0):void 0,lastTotalTokens:void 0!==seed.lastTotalTokens?Number(seed.lastTotalTokens||0):void 0,lastCtxSizeTokens:void 0!==seed.lastCtxSizeTokens?Number(seed.lastCtxSizeTokens||0):void 0,lastKvCacheUsagePct:void 0!==seed.lastKvCacheUsagePct?Number(seed.lastKvCacheUsagePct||0):void 0,lastRuntimeRequestAt:void 0!==seed.lastRuntimeRequestAt?Number(seed.lastRuntimeRequestAt||0):void 0}}let chatState={activeConversationId:\"\",conversations:[],presetId:\"\",apiPresetName:\"\",messages:[],attachments:[],busy:!1,params:defaultChatParams(),systemPrompt:\"\",autoCompactEnabled:!0,autoCompactThresholdPct:95,statsCollapsed:!1,promptTemplates:[]},chatOptionsMenuOpen=!1,mcpManagerState={servers:[],editingId:\"\"},chatSettingsDraft=null,chatRecognition=null,chatTranscriptAutoFollow=!0,chatRequestController=null,chatAutoTitleGenerationId=0,chatThinkingTicker=null;function escapeHtml(value){return String(value??\"\").replaceAll(\"&\",\"&amp;\").replaceAll(\"<\",\"&lt;\").replaceAll(\">\",\"&gt;\").replaceAll('\"',\"&quot;\").replaceAll(\"'\",\"&#39;\")}function svgIcon(name){return\"edit\"===name?'<svg viewBox=\"0 0 24 24\" aria-hidden=\"true\"><path d=\"M4 20h4l10-10-4-4L4 16v4zM14 6l4 4\" fill=\"none\"/></svg>':\"key\"===name?'<svg viewBox=\"0 0 24 24\" aria-hidden=\"true\"><path d=\"M14 7a4 4 0 1 0 0 8a4 4 0 0 0 0-8Zm0 0h6m-2 0v3m-3 0h6\" fill=\"none\"/></svg>':\"reset\"===name?'<svg viewBox=\"0 0 24 24\" aria-hidden=\"true\"><path d=\"M20 12a8 8 0 1 1-2.34-5.66M20 4v6h-6\" fill=\"none\"/></svg>':\"delete\"===name?'<svg viewBox=\"0 0 24 24\" aria-hidden=\"true\"><path d=\"M5 7h14M9 7V5h6v2m-7 3v7m4-7v7m4-7v7M7 7l1 12h8l1-12\" fill=\"none\"/></svg>':\"copy\"===name?'<svg viewBox=\"0 0 24 24\" aria-hidden=\"true\"><path d=\"M9 9h10v10H9zM5 15H4V5h10v1\" fill=\"none\"/></svg>':\"upload\"===name?'<svg viewBox=\"0 0 24 24\" aria-hidden=\"true\"><path d=\"M12 16V4m0 0l-4 4m4-4l4 4M5 20h14\" fill=\"none\"/></svg>':\"send\"===name?'<svg viewBox=\"0 0 24 24\" aria-hidden=\"true\"><path d=\"M4 12 19 5l-3.8 5.4L19 12l-3.8 1.6L19 19 4 12Z\" fill=\"currentColor\" stroke=\"none\"/></svg>':\"stop\"===name?'<svg viewBox=\"0 0 24 24\" aria-hidden=\"true\"><path d=\"M7 7h10v10H7z\" fill=\"currentColor\" stroke=\"none\"/></svg>':\"close\"===name?'<svg viewBox=\"0 0 24 24\" aria-hidden=\"true\"><path d=\"m6 6 12 12M18 6 6 18\" fill=\"none\"/></svg>':\"plus\"===name?'<svg viewBox=\"0 0 24 24\" aria-hidden=\"true\"><path d=\"M12 5v14M5 12h14\" fill=\"none\"/></svg>':\"chat\"===name?'<svg viewBox=\"0 0 24 24\" aria-hidden=\"true\"><path d=\"M5 18V6h14v9H8l-3 3Zm3-7h8m-8 3h5\" fill=\"none\"/></svg>':\"gear\"===name?'<svg viewBox=\"0 0 24 24\" aria-hidden=\"true\"><path d=\"M12 8.5a3.5 3.5 0 1 0 0 7a3.5 3.5 0 0 0 0-7Zm8 3.5l-2.1.8a6.9 6.9 0 0 1-.6 1.4l.9 2l-2.1 2.1l-2-.9a6.9 6.9 0 0 1-1.4.6L12 20l-1.1-2.1a6.9 6.9 0 0 1-1.4-.6l-2 .9l-2.1-2.1l.9-2a6.9 6.9 0 0 1-.6-1.4L4 12l2.1-1.1a6.9 6.9 0 0 1 .6-1.4l-.9-2l2.1-2.1l2 .9a6.9 6.9 0 0 1 1.4-.6L12 4l1.1 2.1a6.9 6.9 0 0 1 1.4.6l2-.9l2.1 2.1l-.9 2a6.9 6.9 0 0 1 .6 1.4L20 12Z\" fill=\"none\"/></svg>':\"chevron-up\"===name?'<svg viewBox=\"0 0 24 24\" aria-hidden=\"true\"><path d=\"m6 15 6-6 6 6\" fill=\"none\"/></svg>':\"chevron-down\"===name?'<svg viewBox=\"0 0 24 24\" aria-hidden=\"true\"><path d=\"m6 9 6 6 6-6\" fill=\"none\"/></svg>':\"chevron-right\"===name?'<svg viewBox=\"0 0 24 24\" aria-hidden=\"true\"><path d=\"m9 6 6 6-6 6\" fill=\"none\"/></svg>':\"\"}function renderIconButton({title,action,icon,className=\"\"}){return`<button class=\"${`iconbtn ${className}`.trim()}\" title=\"${escapeHtml(title)}\" aria-label=\"${escapeHtml(title)}\" onclick=\"${action}\">${svgIcon(icon)}</button>`}async function copyTextValue(value){const text=String(value||\"\");if(!text)return!1;if(navigator.clipboard&&navigator.clipboard.writeText)try{return await navigator.clipboard.writeText(text),!0}catch(e){}const temp=document.createElement(\"textarea\");temp.value=text,temp.setAttribute(\"readonly\",\"readonly\"),temp.style.position=\"fixed\",temp.style.opacity=\"0\",document.body.appendChild(temp),temp.focus(),temp.select();let copied=!1;try{copied=document.execCommand(\"copy\")}catch(e){copied=!1}return temp.remove(),copied}function ensureApiKeyModal(){if($(\"apiKeyModal\"))return;const modal=document.createElement(\"div\");modal.id=\"apiKeyModal\",modal.className=\"club-modal hidden\",modal.innerHTML=`<div class=\"club-modal-card\" role=\"dialog\" aria-modal=\"true\" aria-labelledby=\"apiKeyModalTitle\"><div class=\"panel-head\"><h2 id=\"apiKeyModalTitle\">API Key</h2><button class=\"iconbtn\" id=\"apiKeyModalTopClose\" title=\"Close\" aria-label=\"Close\" onclick=\"closeApiKeyModal()\">${svgIcon(\"delete\")}</button></div><div class=\"preset-help\" id=\"apiKeyModalHint\">Use Copy to place the key on the clipboard.</div><textarea id=\"apiKeyModalValue\" class=\"modal-keybox\" readonly wrap=\"off\"></textarea><div class=\"preset-form-actions\"><button class=\"btn amber\" onclick=\"copyApiKeyModalValue()\">Copy</button><button class=\"btn blue\" onclick=\"closeApiKeyModal()\">Close</button></div><div class=\"msg\" id=\"apiKeyModalMsg\"></div></div>`,modal.addEventListener(\"click\",event=>{event.target===modal&&closeApiKeyModal()}),document.body.appendChild(modal)}let apiKeyModalOptions={copySuccessText:\"Copied API key to clipboard.\",showTopClose:!0};function openApiKeyModal(title,value,hint=\"\",options={}){ensureApiKeyModal(),apiKeyModalOptions={copySuccessText:\"Copied API key to clipboard.\",showTopClose:!0,...options},$(\"apiKeyModalTitle\").textContent=title||\"API Key\",$(\"apiKeyModalHint\").textContent=hint||\"Use Copy to place the key on the clipboard.\",$(\"apiKeyModalValue\").value=value||\"\",$(\"apiKeyModalMsg\").textContent=\"\",$(\"apiKeyModalTopClose\")&&$(\"apiKeyModalTopClose\").classList.toggle(\"hidden\",!apiKeyModalOptions.showTopClose),$(\"apiKeyModal\").classList.remove(\"hidden\")}function closeApiKeyModal(){ensureApiKeyModal(),$(\"apiKeyModal\").classList.add(\"hidden\")}async function copyApiKeyModalValue(){ensureApiKeyModal();const ok=await copyTextValue($(\"apiKeyModalValue\").value||\"\");$(\"apiKeyModalMsg\").textContent=ok?apiKeyModalOptions.copySuccessText||\"Copied API key to clipboard.\":\"Copy failed on this browser.\"}function setInstanceMsg(t){$(\"instanceMsg\")&&($(\"instanceMsg\").textContent=t||\"\")}function getInstanceList(){return lastStatus&&lastStatus.instances||[]}function setUsersMsg(t){$(\"usersMsg\")&&($(\"usersMsg\").textContent=t||\"\")}async function saveUserForm(){try{const r=await fetch(\"/admin/users\",{method:\"POST\",headers:{\"Content-Type\":\"application/json\"},body:JSON.stringify({action:\"save\",user:collectUserForm()})}),j=await r.json();if(!r.ok||!j.ok)throw new Error(j.error||\"save failed\");j.api_key&&openApiKeyModal(\"API key for \"+j.user.name,j.api_key,\"This key is now stored so it can be viewed again from the user card.\"),resetUserForm(),setUsersMsg(\"Saved user \"+j.user.name),await refreshStatus()}catch(e){alert(\"User save failed: \"+e)}}async function showUserApiKey(name){try{const r=await fetch(\"/admin/users\",{method:\"POST\",headers:{\"Content-Type\":\"application/json\"},body:JSON.stringify({action:\"show_key\",name})}),j=await r.json();if(!r.ok||!j.ok)throw new Error(j.error||\"show failed\");openApiKeyModal(\"API key for \"+name,j.api_key,\"Use Copy to place the current key on the clipboard.\")}catch(e){alert(\"API key lookup failed: \"+e)}}async function resetUserKey(name){if(confirm(\"Reset API key for \"+name+\"?\"))try{const r=await fetch(\"/admin/users\",{method:\"POST\",headers:{\"Content-Type\":\"application/json\"},body:JSON.stringify({action:\"reset_key\",name})}),j=await r.json();if(!r.ok||!j.ok)throw new Error(j.error||\"reset failed\");openApiKeyModal(\"New API key for \"+name,j.api_key,\"The previous key is no longer valid. Use Copy if you need to share the replacement key.\"),setUsersMsg(\"Reset API key for \"+name),await refreshStatus()}catch(e){alert(\"API key reset failed: \"+e)}}async function deleteUserByName(name){if(confirm(\"Delete user \"+name+\"?\"))try{const r=await fetch(\"/admin/users\",{method:\"POST\",headers:{\"Content-Type\":\"application/json\"},body:JSON.stringify({action:\"delete\",name})}),j=await r.json();if(!r.ok||!j.ok)throw new Error(j.error||\"delete failed\");selectedUserName===name&&resetUserForm(),setUsersMsg(\"Deleted user \"+name),await refreshStatus()}catch(e){alert(\"User delete failed: \"+e)}}let currentLogSource=\"docker\";function setAuditMsg(t){$(\"auditMsg\")&&($(\"auditMsg\").textContent=t||\"\")}function mirrorAuthToggles(v){$(\"auditAllowAnonymousProxy\")&&($(\"auditAllowAnonymousProxy\").checked=!!v)}let selectedGroupName=\"\";function setGroupsMsg(t){$(\"groupsMsg\")&&($(\"groupsMsg\").textContent=t||\"\")}function findPanelByHeading(sectionId,heading){return[...document.querySelectorAll(`#${sectionId} .panel`)].find(panel=>{const title=panel.querySelector(\".panel-head h2,h2\");return(title&&title.textContent||\"\").trim()===heading})||null}let selectedScope=\"GPU0\";function currentScope(){return selectedScope||selectedInstance||\"GPU0\"}function scopeIsGlobal(){return\"GLOBAL\"===currentScope()}function ensureV413Layout(){const tabs=document.querySelector(\".tabs\"),auditBtn=tabs&&tabs.querySelector('.tab[onclick*=\"audit\"]'),logsBtn=tabs&&tabs.querySelector('.tab[onclick*=\"logs\"]');auditBtn&&auditBtn.remove(),tabs&&logsBtn&&tabs.appendChild(logsBtn);const system=$(\"system\"),logs=($(\"presets\"),$(\"logs\")),audit=$(\"audit\");if(system&&audit){const accessPolicy=findPanelByHeading(\"audit\",\"Access Policy\");accessPolicy&&!accessPolicy.dataset.v413Moved&&(accessPolicy.dataset.v413Moved=\"1\",system.insertBefore(accessPolicy,system.children[1]||null));const overview=findPanelByHeading(\"audit\",\"Audit Overview\");overview&&logs&&!overview.dataset.v413Moved&&(overview.dataset.v413Moved=\"1\",logs.insertBefore(overview,logs.firstChild||null));const globalControls=findPanelByHeading(\"audit\",\"Global Controls\");globalControls&&globalControls.remove();const auditStream=findPanelByHeading(\"audit\",\"Audit Stream\");auditStream&&auditStream.remove(),0!==audit.childElementCount&&audit.querySelector(\".panel\")||audit.remove()}const accessCard=findPanelByHeading(\"system\",\"Access Policy\");if(accessCard){const openUsers=[...accessCard.querySelectorAll(\"button\")].find(btn=>(btn.textContent||\"\").includes(\"Open Users Management\"));openUsers&&openUsers.remove()}const singleCard=[...document.querySelectorAll(\"#presets .panel\")].find(panel=>{const h=panel.querySelector(\".panel-head h2,h2\");return h&&((h.textContent||\"\").includes(\"Per-Instance Docker Presets\")||(h.textContent||\"\").includes(\"Single GPU Docker Presets\"))});if(singleCard){singleCard.id=\"singlePresetCard\";const title=singleCard.querySelector(\"h2\");title&&(title.textContent=\"Dynamic Model Presets\")}const customTitle=[...document.querySelectorAll(\"#presets .panel .panel-head h2\")].find(h=>\"Custom Preset Templates\"===(h.textContent||\"\").trim());if(customTitle&&(customTitle.textContent=\"Custom Configuration Endpoints\"),$(\"presetScopePanel\")&&$(\"presetScopePanel\").remove(),$(\"dualPresetCard\")&&$(\"dualPresetCard\").remove(),logs&&!$(\"logsSourcePanel\")){const panel=document.createElement(\"div\");panel.className=\"panel\",panel.id=\"logsSourcePanel\",panel.innerHTML=`<div class=\"panel-head\"><h2>Log Sources</h2><div class=\"preset-actions\">${renderIconButton({title:\"Export Logs\",action:\"exportCurrentLog()\",icon:\"upload\"})}</div></div><div class=\"subtabs\"><button class=\"subtab\" id=\"logSourceDocker\" onclick=\"setCurrentLogSource('docker')\">Docker Logs</button><button class=\"subtab\" id=\"logSourceAudit\" onclick=\"setCurrentLogSource('audit')\">Audit Logs</button></div><div class=\"value smallgap\" id=\"logsSourceSummary\">-</div>`,logs.appendChild(panel)}const profiles=findPanelByHeading(\"system\",\"Power Profiles\");if(profiles&&!$(\"profileScopeNote\")){const note=document.createElement(\"div\");note.className=\"preset-help\",note.id=\"profileScopeNote\",profiles.insertBefore(note,profiles.querySelector(\".actions\")||profiles.firstChild)}const power=findPanelByHeading(\"system\",\"Optimizations + Cooling\");if(power&&!$(\"powerScopeNote\")){const note=document.createElement(\"div\");note.className=\"preset-help\",note.id=\"powerScopeNote\",power.insertBefore(note,power.querySelector(\".actions\")||power.firstChild)}}function quotaLimitText(v,suffix=\"\"){return null==v||\"\"===v?\"unlimited\":`${v}${suffix}`}function quotaWeightText(v){return null==v||\"\"===v?\"default\":trimFormattedNumber(Number(v).toFixed(3))}function quotaWindowText(windowData){return`${(windowData=windowData||{}).requests||0} msgs · score ${Number(windowData.score||0).toFixed(1)} · in ${windowData.input_tokens||0} · out ${windowData.output_tokens||0} · tools ${windowData.tool_calls||0} · thinking ${Number(windowData.thinking_seconds||0).toFixed(1)}s`}function quotaWeightLine(limits){return`in ${quotaWeightText((limits=limits||{}).input_token_weight)} · out ${quotaWeightText(limits.output_token_weight)} · tools ${quotaWeightText(limits.tool_call_weight)} · thinking ${quotaWeightText(limits.thinking_second_weight)}`}function quotaBudgetLine(limits){return`5h ${quotaLimitText((limits=limits||{}).score_per_5h)} · week ${quotaLimitText(limits.score_per_week)} · /msg tokens ${quotaLimitText(limits.max_tokens_per_message)} · /msg tools ${quotaLimitText(limits.max_tool_calls_per_message)}`}function parseQuotaNumber(id){const el=$(id);if(!el)return null;const v=el.value.trim();return\"\"===v?null:Number(v)}function scopeItems(){const items=getInstanceList().slice();return items.sort((a,b)=>{const ak=\"dual\"===a.kind?1:0,bk=\"dual\"===b.kind?1:0;if(ak!==bk)return ak-bk;return((a.gpu_indices||[a.gpu_index])[0]||0)-((b.gpu_indices||[b.gpu_index])[0]||0)||String(a.id).localeCompare(String(b.id))}),items}function singleScopeItems(){return scopeItems().filter(x=>\"dual\"!==x.kind)}function pairScopeItems(){return pairingEnabled()?scopeItems().filter(x=>\"dual\"===x.kind):[]}function gpuCount(){return Number(lastStatus&&lastStatus.gpu_count||0)}function canonicalPairId(a,b){const nums=[Number(a),Number(b)].filter(x=>Number.isInteger(x)&&x>=0).sort((x,y)=>x-y);return 2!==nums.length||nums[0]===nums[1]?\"\":`PAIR${nums[0]}_${nums[1]}`}function exactTwoPairTarget(){return 2===gpuCount()&&scopeItems().find(x=>\"PAIR0_1\"===x.id)||null}function currentScopeInstance(strict=!1){return\"GLOBAL\"===currentScope()?legacyGlobalDualScope()?strict?null:legacyGlobalPair():pairingEnabled()&&2===gpuCount()?strict?null:exactTwoPairTarget():null:scopeItems().find(x=>x.id===currentScope())||singleScopeItems()[0]||pairScopeItems()[0]||null}function dockerLogTarget(){if(\"audit\"===currentLogSource)return null;const legacy=legacyGlobalPair(),cur=currentScopeInstance(!1)||scopeItems()[0]||null;return scopeIsGlobal()&&legacyGlobalDualScope()||legacyGlobalDualScope()&&legacy&&legacy.running&&cur&&\"dual\"!==cur.kind&&(\"pair\"===cur.assignment_scope||cur.overrides_dual_mode||!cur.running)?null:cur}function scopeLabel(inst){return inst?\"GLOBAL\"===inst.id?\"Global Dual\":\"dual\"===inst.kind?`Pair ${(inst.gpu_indices||[]).join(\" + \")}`:inst.id:legacyGlobalDualScope()?\"Global Dual\":\"Global\"}function runtimeTrackingItems(){const rows=Object.values(lastStatus&&lastStatus.instance_runtime_metrics||{}).filter(row=>row&&row.running);return rows.sort((a,b)=>{const ag=Array.isArray(a.gpu_indices)?a.gpu_indices:[],bg=Array.isArray(b.gpu_indices)?b.gpu_indices:[];return(ag[0]??999)-(bg[0]??999)||ag.length-bg.length||String(a.id||a.instance_id||\"\").localeCompare(String(b.id||b.instance_id||\"\"))}),rows}function normalizeTrackedRuntimeId(value){const rows=runtimeTrackingItems();if(!rows.length)return\"\";const candidate=String(value||\"\").trim().toUpperCase();if(candidate){const exact=rows.find(row=>String(row.id||row.instance_id).toUpperCase()===candidate);if(exact)return String(exact.id||exact.instance_id)}return String(rows[0].id||rows[0].instance_id)}function trackedOverviewRuntime(){const id=normalizeTrackedRuntimeId(selectedOverviewInstanceId);return id?(selectedOverviewInstanceId=id,runtimeTrackingItems().find(row=>String(row.id||row.instance_id)===String(id))||null):null}function trackedLogRuntime(){const id=normalizeTrackedRuntimeId(selectedLogInstanceId);return id?(selectedLogInstanceId=id,runtimeTrackingItems().find(row=>String(row.id||row.instance_id)===String(id))||null):null}function setOverviewTrackedInstance(id){selectedOverviewInstanceId=normalizeTrackedRuntimeId(id),renderOverviewTracker(),lastStatus&&renderOverviewStatus(lastStatus)}function setLogTrackedInstance(id){selectedLogInstanceId=normalizeTrackedRuntimeId(id),renderLogTracker(),applyLogVisibility(),connectLogs(!0)}function formatCtxTokens(value){const num=Number(value||0);return!Number.isFinite(num)||num<=0?\"-\":num>=1e6?`${trimFormattedNumber((num/1e6).toFixed(2))}M`:num>=1e3?`${trimFormattedNumber((num/1e3).toFixed(num>=1e5?0:1))}K`:String(Math.round(num))}function formatNumber(value,digits=2){const num=Number(value);return Number.isFinite(num)?trimFormattedNumber(num.toFixed(digits)):\"-\"}function formatCompactInt(value){const num=Number(value);if(!Number.isFinite(num))return\"-\";const abs=Math.abs(num);return abs>=1e9?`${trimFormattedNumber((num/1e9).toFixed(abs>=1e10?0:1))}B`:abs>=1e6?`${trimFormattedNumber((num/1e6).toFixed(abs>=1e7?0:1))}M`:abs>=1e3?`${trimFormattedNumber((num/1e3).toFixed(abs>=1e5?0:1))}K`:String(Math.round(num))}function formatElapsedLaunch(seconds){const total=Math.max(0,Math.round(Number(seconds||0))),mins=Math.floor(total/60),secs=total%60;return mins>0?`${mins} min, ${secs} s to launch`:`${secs} s to launch`}function formatMaybeTimestamp(ts){const num=Number(ts||0);if(!Number.isFinite(num)||num<=0)return\"-\";try{return new Date(1e3*num).toLocaleTimeString([],{hour:\"2-digit\",minute:\"2-digit\",second:\"2-digit\"})}catch(e){return\"-\"}}function runtimeStatsRows(j){return Array.isArray(j?.running_runtimes)?j.running_runtimes.filter(Boolean):[]}function formatRuntimeModeValue(j,runtime){if(runtime)return`${runtime.mode||\"-\"} / ${runtime.port||\"-\"}`;const modes=Array.isArray(j?.active_modes)?j.active_modes.filter(Boolean):[],port=j?.active_port||\"-\";return modes.length>1?`${modes.join(\", \")} / multiple`:`${modes[0]||j?.active_mode||\"-\"} / ${port}`}function formatRuntimeContainerValue(j,runtime){if(runtime)return runtime.container||\"none\";const containers=Array.isArray(j?.containers)?j.containers.filter(Boolean):[];return containers.length?containers.join(\", \"):\"none\"}function formatUsersValue(j){const userCount=Array.isArray(j?.users)?j.users.length:0,groupNames=Array.isArray(j?.groups)?j.groups.map(group=>String(group?.name||\"\").trim()).filter(Boolean):[];return`<div>${userCount} registered user${1===userCount?\"\":\"s\"}</div><div class=\"value-subline\">groups: ${groupNames.length?escapeHtml(groupNames.join(\", \")):\"none configured\"}</div>`}function formatLastStatusCard(runtime,metrics){const target=runtime||{},rawStatus=target.last_status??metrics.last_status,statusNum=Number(rawStatus),head=[Number.isFinite(statusNum)?`HTTP ${Math.trunc(statusNum)}`:null!=rawStatus&&\"\"!==rawStatus?String(rawStatus):\"-\"],latency=target.last_latency_s??metrics.last_latency_s,ttft=target.last_ttft_s??metrics.last_ttft_s,tps=[target.last_tokens_per_second,target.generation_tps,metrics.last_tokens_per_second].find(value=>Number(value)>0);null!=latency&&head.push(`latency=${formatNumber(latency,3)}s`),null!=ttft&&head.push(`ttft=${formatNumber(ttft,3)}s`),null!==target.last_prefill_s&&void 0!==target.last_prefill_s&&head.push(`prefill~=${formatNumber(target.last_prefill_s,3)}s`),null!=tps&&head.push(`tk/s=${formatNumber(tps,2)}`);const detail=[];if(null!==target.gpu_kv_cache_usage_pct&&void 0!==target.gpu_kv_cache_usage_pct){const ctxText=formatCtxTokens(target.ctx_size_tokens);detail.push(\"-\"!==ctxText?`KV ${formatNumber(target.gpu_kv_cache_usage_pct,1)}% | ${ctxText} ctx`:`KV ${formatNumber(target.gpu_kv_cache_usage_pct,1)}%`)}else target.ctx_size_tokens&&detail.push(`${formatCtxTokens(target.ctx_size_tokens)} ctx`);const spec=target.speculative||{},specBits=[];null!==spec.drafted_tokens&&void 0!==spec.drafted_tokens&&specBits.push(`drafted=${spec.drafted_tokens}`),null!==spec.accept_rate_pct&&void 0!==spec.accept_rate_pct&&specBits.push(`accept=${formatNumber(spec.accept_rate_pct,1)}%`),null!==spec.accepted_tokens&&void 0!==spec.accepted_tokens&&null!==spec.draft_tokens&&void 0!==spec.draft_tokens&&specBits.push(`accepted=${spec.accepted_tokens}/${spec.draft_tokens}`),null!==spec.mean_acceptance_length&&void 0!==spec.mean_acceptance_length&&specBits.push(`avg=${formatNumber(spec.mean_acceptance_length,2)}`),null!==spec.system_efficiency_pct&&void 0!==spec.system_efficiency_pct&&specBits.push(`eff=${formatNumber(spec.system_efficiency_pct,1)}%`);const lines=[`<div>${head.join(\" &middot; \")}</div>`];return detail.length&&lines.push(`<div class=\"value-subline\">${detail.join(\" &middot; \")}</div>`),specBits.length&&lines.push(`<div class=\"value-subline\">spec ${specBits.join(\" &middot; \")}</div>`),lines.join(\"\")}function formatGenerationRuntimeCard(runtime){if(!runtime)return\"\";const statusHistory=updateStatusHistory(runtimeStatusHistoryById,runtime.id||runtime.instance_id,runtimeActivityStatus(runtime)),statusBits=[`status ${statusHistory.current}`,statusHistory.previous?`previous ${statusHistory.previous}`:\"\"].filter(Boolean),queueBits=[];Number(runtime.waiting_requests||0)>0&&queueBits.push(`waiting ${runtime.waiting_requests}`),Number(runtime.pending_requests||0)>0&&queueBits.push(`pending ${runtime.pending_requests}`),Number(runtime.swapped_requests||0)>0&&queueBits.push(`swapped ${runtime.swapped_requests}`);const perfBits=[];null!==runtime.prompt_tps&&void 0!==runtime.prompt_tps&&perfBits.push(`prompt ${formatNumber(runtime.prompt_tps,2)} tk/s`),null!==runtime.generation_tps&&void 0!==runtime.generation_tps&&perfBits.push(`generation ${formatNumber(runtime.generation_tps,2)} tk/s`),null!==runtime.prefix_cache_hit_rate_pct&&void 0!==runtime.prefix_cache_hit_rate_pct&&perfBits.push(`prefix hit ${formatNumber(runtime.prefix_cache_hit_rate_pct,1)}%`),null!==runtime.cpu_kv_cache_usage_pct&&void 0!==runtime.cpu_kv_cache_usage_pct&&perfBits.push(`CPU KV ${formatNumber(runtime.cpu_kv_cache_usage_pct,1)}%`);const tokenBits=[];null!==runtime.last_input_tokens&&void 0!==runtime.last_input_tokens&&tokenBits.push(`input ${formatCompactInt(runtime.last_input_tokens)}`),null!==runtime.last_output_tokens&&void 0!==runtime.last_output_tokens&&tokenBits.push(`output ${formatCompactInt(runtime.last_output_tokens)}`),null!==runtime.last_total_tokens&&void 0!==runtime.last_total_tokens&&tokenBits.push(`total ${formatCompactInt(runtime.last_total_tokens)}`),null!==runtime.last_tool_calls&&void 0!==runtime.last_tool_calls&&tokenBits.push(`tools ${runtime.last_tool_calls}`);const meta=[runtime.mode||\"-\",runtime.container||\"no container\",Array.isArray(runtime.gpu_indices)&&runtime.gpu_indices.length?`GPUs ${runtime.gpu_indices.join(\", \")}`:\"GPU mapping unavailable\"],pathText=runtime.last_path?escapeHtml(runtime.last_path):\"No request path recorded yet.\";return`<div class=\"generation-card\"><div class=\"generation-card-head\"><div><h3>${escapeHtml(runtime.display_name||runtime.id||\"Runtime\")}</h3><div class=\"generation-card-meta\">${escapeHtml(meta.join(\" · \"))}</div></div></div><div class=\"generation-card-body\">${formatLastStatusCard(runtime,{})}<div class=\"value-subline\">${escapeHtml(statusBits.join(\" · \"))}</div>${queueBits.length?`<div class=\"value-subline\">${escapeHtml(queueBits.join(\" · \"))}</div>`:\"\"}${perfBits.length?`<div class=\"value-subline\">${escapeHtml(perfBits.join(\" · \"))}</div>`:\"\"}${tokenBits.length?`<div class=\"value-subline\">${escapeHtml(tokenBits.join(\" · \"))}</div>`:\"\"}<div class=\"value-subline\">last path: ${pathText}</div><div class=\"value-subline\">last request: ${escapeHtml(formatMaybeTimestamp(runtime.last_request_at))}</div></div></div>`}function renderGenerationStats(j){const host=$(\"generationStatsContent\");if(!host)return;const rows=runtimeStatsRows(j),started=rows.filter(row=>[row?.last_status,row?.last_latency_s,row?.last_ttft_s,row?.last_tokens_per_second,row?.last_total_tokens,row?.last_output_tokens,row?.last_request_at,row?.prompt_tps,row?.generation_tps,row?.gpu_kv_cache_usage_pct].some(value=>null!=value&&\"\"!==value&&0!==value));rows.length?started.length?host.innerHTML=started.map(formatGenerationRuntimeCard).join(\"\"):host.innerHTML='<div class=\"empty-variant-note\">Runtime containers are online and waiting for inference. The first completed generation will populate per-instance latency, throughput, KV-cache, and token counters here so you can compare all active backends at a glance.</div>':host.innerHTML='<div class=\"empty-variant-note\">No runtime containers are active yet. Once a backend is online, this card will summarize live queue pressure, throughput, cache usage, and the latest request details for every running instance in one place.</div>'}function formatRequestCard(runtime,metrics){return`total=${metrics.total_requests??0}, active=${metrics.active_requests??0}, fail=${metrics.failed_requests??0}, queue=${metrics.queued_requests??0}`}function renderOverviewTracker(){const panel=findPanelByHeading(\"overview\",\"Status\");if(!panel)return;let row=$(\"overviewTrackerRow\");if(!row){row=document.createElement(\"div\"),row.id=\"overviewTrackerRow\",row.className=\"scope-strip\";const grid=panel.querySelector(\".grid\");panel.insertBefore(row,grid||panel.querySelector(\".msg\")||null)}const rows=runtimeTrackingItems();if(rows.length<=1)return row.innerHTML=\"\",void row.classList.add(\"hidden\");row.classList.remove(\"hidden\");const current=normalizeTrackedRuntimeId(selectedOverviewInstanceId);selectedOverviewInstanceId=current,row.innerHTML=`<span class=\"label\">Track instance</span><div class=\"subtabs\">${rows.map(item=>`<button class=\"subtab ${String(item.id||item.instance_id)===current?\"active\":\"\"}\" onclick=\"setOverviewTrackedInstance('${String(item.id||item.instance_id)}')\">${escapeHtml(String(item.id||item.instance_id))}</button>`).join(\"\")}</div>`}function renderLogTracker(){const card=document.querySelector(\".logs.panel\");if(!card)return;let row=$(\"logTrackerRow\");row||(row=document.createElement(\"div\"),row.id=\"logTrackerRow\",row.className=\"scope-strip\",card.insertBefore(row,$(\"log\")||card.lastChild||null));const rows=runtimeTrackingItems();if(\"audit\"===currentLogSource||rows.length<=1)return row.innerHTML=\"\",void row.classList.add(\"hidden\");row.classList.remove(\"hidden\");const current=normalizeTrackedRuntimeId(selectedLogInstanceId);selectedLogInstanceId=current,row.innerHTML=`<span class=\"label\">Track instance</span><div class=\"subtabs\">${rows.map(item=>`<button class=\"subtab ${String(item.id||item.instance_id)===current?\"active\":\"\"}\" onclick=\"setLogTrackedInstance('${String(item.id||item.instance_id)}')\">${escapeHtml(String(item.id||item.instance_id))}</button>`).join(\"\")}</div>`}function renderOverviewStatus(j){const metrics=j&&j.metrics||{},power=j&&j.power||{},runtime=trackedOverviewRuntime(),containers=Array.isArray(j?.containers)?j.containers.filter(Boolean):[],modes=Array.isArray(j?.active_modes)?j.active_modes.filter(Boolean):[];$(\"summary\")&&($(\"summary\").textContent=runtime?`${runtime.id||runtime.instance_id} | ${runtime.mode||j.active_mode} | ${runtime.container||\"no container\"} | ${power.profile||\"balanced\"} | GPUs ${j.gpu_count??0}`:`${modes[0]||j.active_mode||\"-\"} | ${containers[0]||j.container||\"no container\"} | ${power.profile||\"balanced\"} | GPUs ${j.gpu_count??0}`),$(\"mode\")&&($(\"mode\").textContent=formatRuntimeModeValue(j,runtime)),$(\"container\")&&($(\"container\").textContent=formatRuntimeContainerValue(j,runtime)),$(\"req\")&&($(\"req\").innerHTML=formatRequestCard(runtime,metrics)),$(\"last\")&&($(\"last\").innerHTML=formatUsersValue(j)),$(\"uptime\")&&($(\"uptime\").textContent=fmtUptime(j.uptime_seconds)),$(\"powerbox\")&&($(\"powerbox\").textContent=`profile=${power.profile||\"-\"}, GPU=${power.gpu||\"-\"}, CPU=${power.cpu||\"-\"}, fans=${power.fans||\"-\"}, container=${power.container||\"-\"}, idle=${power.idle_for_seconds??0}s`),renderGenerationStats(j),renderOverviewTracker()}function setEditorState(editorId,introId,open){const ed=$(editorId),intro=$(introId);ed&&ed.classList.toggle(\"open\",!!open),intro&&intro.classList.toggle(\"hidden\",!!open)}function openUserEditor(){ensureUsersUi(),setEditorState(\"userEditor\",\"userIntro\",!0)}function openGroupEditor(){ensureGroupUi(),setEditorState(\"groupEditor\",\"groupIntro\",!0)}async function createPairGroup(first=null,second=null){if(gpuCount()<2)return void alert(\"At least two GPUs are required to create a dual pair.\");let a=first,b=second;if(null===a||null===b){if(a=prompt(`First GPU index (0-${Math.max(gpuCount()-1,0)}):`,\"0\"),null===a)return;if(b=prompt(`Second GPU index (0-${Math.max(gpuCount()-1,0)}):`,\"1\"),null===b)return}const id=canonicalPairId(a,b);if(id)try{const r=await fetch(\"/admin/instances\",{method:\"POST\",headers:{\"Content-Type\":\"application/json\"},body:JSON.stringify({action:\"save_pair\",gpu_indices:[Number(a),Number(b)],mode:\"vllm/dual\",enabled:!1})}),j=await r.json();if(!r.ok||!j.ok)throw new Error(j.error||\"pair save failed\");setInstanceMsg(`Saved pair group ${id}`),await refreshStatus(),setScope(id,!1)}catch(e){alert(\"Pair group failed: \"+e)}else alert(\"Select two distinct GPU indices.\")}async function deleteCurrentPairGroup(){const cur=currentScopeInstance(!0);if(cur&&\"dual\"===cur.kind){if(confirm(`Delete pair group ${cur.id}?`))try{const r=await fetch(\"/admin/instances\",{method:\"POST\",headers:{\"Content-Type\":\"application/json\"},body:JSON.stringify({action:\"delete_pair\",instance_id:cur.id})}),j=await r.json();if(!r.ok||!j.ok)throw new Error(j.error||\"pair delete failed\");setInstanceMsg(`Deleted pair group ${cur.id}`),await refreshStatus(),setScope(\"GLOBAL\",!1)}catch(e){alert(\"Pair delete failed: \"+e)}}else alert(\"Select a dual pair scope first.\")}async function switchDualMode(m){const cur=currentScopeInstance(!1);if(cur&&\"dual\"===cur.kind){if(confirm(`Apply dual preset ${m} to ${cur.id} on GPUs ${(cur.gpu_indices||[]).join(\", \")}? This will stop overlapping runtimes that already use those GPUs.`))try{await post(\"/admin/switch\",{instance_id:cur.id,mode:m})}catch(e){alert(e)}}else alert(\"Choose a dual pair tab, or use Global on an exactly-two-GPU server, before applying a dual preset.\")}function profileDescription(p){return{eco:\"Eco profile: lower GPU power limits, lower idle clocks, powersave CPU governor, faster idle/container stop timers.\",balanced:\"Balanced profile: normal server profile with 280W active GPU cap, idle downclocking after 10 minutes, and container stop after 1 hour.\",default:\"Default profile: keeps the 280W safety GPU cap but removes idle clock locking, uses schedutil CPU while active, and keeps standard idle timers.\",turbo:\"Turbo profile: higher GPU power allowance, performance CPU governor, relaxed idle timers, and minimal downclocking. Use when performance matters more than power.\"}[p]||\"Apply profile?\"}function applyDirectoryPayload(j){lastStatus||(lastStatus={}),Array.isArray(j.users)&&(lastStatus.users=j.users,renderUsers(j.users)),Array.isArray(j.groups)&&(lastStatus.groups=j.groups,renderGroups(j.groups)),j.server_config&&(lastStatus.server_config=j.server_config,renderAudit(j.server_config))}ensureUsersUi=function(){const tabs=document.querySelector(\".tabs\");if(tabs&&!document.getElementById(\"usersTabBtn\")){const b=document.createElement(\"button\");b.className=\"tab\",b.id=\"usersTabBtn\",b.textContent=\"Users\",b.onclick=ev=>tab(ev,\"users\"),tabs.insertBefore(b,tabs.querySelector('.tab[onclick*=\"metrics\"]')||null)}const main=document.querySelector(\"main.container\");if(!main)return;let section=$(\"users\");section||(section=document.createElement(\"section\"),section.id=\"users\",section.className=\"tabpane content-tab\",main.insertBefore(section,document.getElementById(\"metrics\"))),\"1\"!==section.dataset.v414Users&&(section.dataset.v414Users=\"1\",section.innerHTML='<div class=\"panel\"><div class=\"panel-head\"><h2>User Accounts</h2><button class=\"add-preset-btn\" title=\"New user\" aria-label=\"New user\" onclick=\"resetUserForm(false)\"><svg viewBox=\"0 0 24 24\" aria-hidden=\"true\"><path d=\"M12 5v14M5 12h14\" fill=\"none\"/></svg></button></div><div class=\"preset-intro\" id=\"userIntro\">Manage per-user API keys, access scopes, and Codex-style scored budgets. The configured list stays visible while the editor is collapsed.</div><div class=\"preset-editor\" id=\"userEditor\"><div class=\"formgrid\"><label>User name<input id=\"userName\" placeholder=\"client_a\" /></label><label>Allowed targets<input id=\"userTargets\" placeholder=\"*, legacy, GPU0, GPU1\" /></label><label>Groups<input id=\"userGroups\" placeholder=\"starter, premium\" /></label><label>5h score budget<input id=\"userScore5h\" type=\"number\" step=\"0.1\" placeholder=\"unlimited\" /></label><label>Weekly score budget<input id=\"userScoreWeek\" type=\"number\" step=\"0.1\" placeholder=\"unlimited\" /></label><label>Max tokens / message<input id=\"userMaxTokensMsg\" type=\"number\" step=\"1\" placeholder=\"unlimited\" /></label><label>Max tool calls / message<input id=\"userMaxToolsMsg\" type=\"number\" step=\"1\" placeholder=\"unlimited\" /></label><label>Input token weight<input id=\"userInputTokenWeight\" type=\"number\" step=\"0.001\" placeholder=\"default\" /></label><label>Output token weight<input id=\"userOutputTokenWeight\" type=\"number\" step=\"0.001\" placeholder=\"default\" /></label><label>Tool-call weight<input id=\"userToolCallWeight\" type=\"number\" step=\"0.001\" placeholder=\"default\" /></label><label>Thinking-second weight<input id=\"userThinkingSecondWeight\" type=\"number\" step=\"0.001\" placeholder=\"default\" /></label><label>Enabled<select id=\"userEnabled\"><option value=\"true\">Enabled</option><option value=\"false\">Disabled</option></select></label></div><div class=\"preset-form-actions\"><button class=\"btn green\" onclick=\"saveUserForm()\">Save User</button><button class=\"btn red\" onclick=\"resetUserForm(true)\">Cancel</button></div></div><div class=\"msg\" id=\"usersMsg\"></div><div class=\"panel\" style=\"margin-top:12px\"><h2>Configured Users</h2><div id=\"usersGrid\" class=\"api-grid\"></div></div></div>')},resetUserForm=function(collapse=!0){ensureUsersUi(),selectedUserName=\"\",$(\"userName\").disabled=!1,$(\"userName\").value=\"\",$(\"userTargets\").value=\"*\",$(\"userGroups\").value=\"\",$(\"userScore5h\").value=\"\",$(\"userScoreWeek\").value=\"\",$(\"userMaxTokensMsg\").value=\"\",$(\"userMaxToolsMsg\").value=\"\",$(\"userInputTokenWeight\").value=\"\",$(\"userOutputTokenWeight\").value=\"\",$(\"userToolCallWeight\").value=\"\",$(\"userThinkingSecondWeight\").value=\"\",$(\"userEnabled\").value=\"true\",setEditorState(\"userEditor\",\"userIntro\",!collapse),setUsersMsg(\"\")},collectUserForm=function(){function val(id){return($(id)&&$(id).value||\"\").trim()}return{name:val(\"userName\"),allowed_targets:val(\"userTargets\").split(\",\").map(x=>x.trim()).filter(Boolean),groups:val(\"userGroups\").split(\",\").map(x=>x.trim()).filter(Boolean),enabled:\"true\"===$(\"userEnabled\").value,generate_api_key:!selectedUserName,limits:{score_per_5h:parseQuotaNumber(\"userScore5h\"),score_per_week:parseQuotaNumber(\"userScoreWeek\"),max_tokens_per_message:parseQuotaNumber(\"userMaxTokensMsg\"),max_tool_calls_per_message:parseQuotaNumber(\"userMaxToolsMsg\"),input_token_weight:parseQuotaNumber(\"userInputTokenWeight\"),output_token_weight:parseQuotaNumber(\"userOutputTokenWeight\"),tool_call_weight:parseQuotaNumber(\"userToolCallWeight\"),thinking_second_weight:parseQuotaNumber(\"userThinkingSecondWeight\")}}},editUser=function(name){const user=(lastStatus&&lastStatus.users||[]).find(u=>u.name===name);user&&(ensureUsersUi(),selectedUserName=name,$(\"userName\").disabled=!0,$(\"userName\").value=user.name,$(\"userTargets\").value=(user.allowed_targets||[]).join(\", \"),$(\"userGroups\").value=(user.groups||[]).join(\", \"),$(\"userScore5h\").value=user.limits.score_per_5h??\"\",$(\"userScoreWeek\").value=user.limits.score_per_week??\"\",$(\"userMaxTokensMsg\").value=user.limits.max_tokens_per_message??\"\",$(\"userMaxToolsMsg\").value=user.limits.max_tool_calls_per_message??\"\",$(\"userInputTokenWeight\").value=user.limits.input_token_weight??\"\",$(\"userOutputTokenWeight\").value=user.limits.output_token_weight??\"\",$(\"userToolCallWeight\").value=user.limits.tool_call_weight??\"\",$(\"userThinkingSecondWeight\").value=user.limits.thinking_second_weight??\"\",$(\"userEnabled\").value=String(!!user.enabled),openUserEditor())},renderUsers=function(users){ensureUsersUi();const grid=$(\"usersGrid\");grid&&(users=users||[],selectedUserName&&!users.some(u=>u.name===selectedUserName)&&(selectedUserName=\"\"),grid.innerHTML=users.map(u=>{const actions=[renderIconButton({title:\"Edit\",action:`editUser('${u.name}')`,icon:\"edit\"}),renderIconButton({title:u.api_key_available?\"Show API key\":\"Show API key unavailable\",action:`showUserApiKey('${u.name}')`,icon:\"key\"}),renderIconButton({title:\"Reset API key\",action:`resetUserKey('${u.name}')`,icon:\"reset\"}),renderIconButton({title:\"Delete\",action:`deleteUserByName('${u.name}')`,icon:\"delete\"})].join(\"\");return`<div class=\"api-card\"><div class=\"api-card-head\"><h3>${u.name}<br><span class=\"label\">${u.enabled?\"enabled\":\"disabled\"} &middot; access ${(u.effective_allowed_targets||u.allowed_targets||[]).join(\", \")||\"*\"}</span></h3><span class=\"preset-actions\">${actions}</span></div><p>Groups: ${(u.groups||[]).join(\", \")||\"none\"}</p><p>API key: ${u.has_api_key?u.api_key_available?\"stored and viewable\":\"legacy key, reset once to store it\":\"not issued yet\"}</p><p>Last 5h: ${quotaWindowText((u.usage||{}).window_5h)}</p><p>Last week: ${quotaWindowText((u.usage||{}).window_week)}</p><p class=\"label\">Direct budgets &middot; ${quotaBudgetLine(u.limits||{})}</p><p class=\"label\">Direct weights &middot; ${quotaWeightLine(u.limits||{})}</p><p class=\"label\">Effective budgets &middot; ${quotaBudgetLine(u.effective_limits||{})}</p><p class=\"label\">Effective weights &middot; ${quotaWeightLine(u.effective_limits||{})}</p></div>`}).join(\"\")||'<div class=\"value\">No API users configured yet.</div>')},ensureGroupUi=function(){ensureUsersUi();const users=$(\"users\");if(!users)return;let panel=$(\"groupsPanel\");panel||(panel=document.createElement(\"div\"),panel.className=\"panel\",panel.id=\"groupsPanel\",users.appendChild(panel)),\"1\"!==panel.dataset.v414Groups&&(panel.dataset.v414Groups=\"1\",panel.innerHTML='<div class=\"panel-head\"><h2>User Groups / Plans</h2><button class=\"add-preset-btn\" title=\"New group\" aria-label=\"New group\" onclick=\"resetGroupForm(false)\"><svg viewBox=\"0 0 24 24\" aria-hidden=\"true\"><path d=\"M12 5v14M5 12h14\" fill=\"none\"/></svg></button></div><div class=\"preset-intro\" id=\"groupIntro\">Define reusable plans that carry scored budgets, per-message caps, and access scopes. The configured list stays visible while the editor is collapsed.</div><div class=\"preset-editor\" id=\"groupEditor\"><div class=\"formgrid\"><label>Group name<input id=\"groupName\" placeholder=\"starter\" /></label><label>Description<input id=\"groupDescription\" placeholder=\"Shared plan description\" /></label><label>Allowed targets<input id=\"groupTargets\" placeholder=\"*, legacy, GPU0, GPU1\" /></label><label>5h score budget<input id=\"groupScore5h\" type=\"number\" step=\"0.1\" placeholder=\"unlimited\" /></label><label>Weekly score budget<input id=\"groupScoreWeek\" type=\"number\" step=\"0.1\" placeholder=\"unlimited\" /></label><label>Max tokens / message<input id=\"groupMaxTokensMsg\" type=\"number\" step=\"1\" placeholder=\"unlimited\" /></label><label>Max tool calls / message<input id=\"groupMaxToolsMsg\" type=\"number\" step=\"1\" placeholder=\"unlimited\" /></label><label>Input token weight<input id=\"groupInputTokenWeight\" type=\"number\" step=\"0.001\" placeholder=\"default\" /></label><label>Output token weight<input id=\"groupOutputTokenWeight\" type=\"number\" step=\"0.001\" placeholder=\"default\" /></label><label>Tool-call weight<input id=\"groupToolCallWeight\" type=\"number\" step=\"0.001\" placeholder=\"default\" /></label><label>Thinking-second weight<input id=\"groupThinkingSecondWeight\" type=\"number\" step=\"0.001\" placeholder=\"default\" /></label><label>Enabled<select id=\"groupEnabled\"><option value=\"true\">Enabled</option><option value=\"false\">Disabled</option></select></label></div><div class=\"preset-form-actions\"><button class=\"btn green\" onclick=\"saveGroupForm()\">Save Group</button><button class=\"btn red\" onclick=\"resetGroupForm(true)\">Cancel</button></div></div><div class=\"msg\" id=\"groupsMsg\"></div><div class=\"panel\" style=\"margin-top:12px\"><h2>Configured Groups</h2><div id=\"groupsGrid\" class=\"api-grid\"></div></div>')},resetGroupForm=function(collapse=!0){ensureGroupUi(),selectedGroupName=\"\",$(\"groupName\").disabled=!1,$(\"groupName\").value=\"\",$(\"groupDescription\").value=\"\",$(\"groupTargets\").value=\"*\",$(\"groupScore5h\").value=\"\",$(\"groupScoreWeek\").value=\"\",$(\"groupMaxTokensMsg\").value=\"\",$(\"groupMaxToolsMsg\").value=\"\",$(\"groupInputTokenWeight\").value=\"\",$(\"groupOutputTokenWeight\").value=\"\",$(\"groupToolCallWeight\").value=\"\",$(\"groupThinkingSecondWeight\").value=\"\",$(\"groupEnabled\").value=\"true\",setEditorState(\"groupEditor\",\"groupIntro\",!collapse),setGroupsMsg(\"\")},collectGroupForm=function(){function val(id){return($(id)&&$(id).value||\"\").trim()}return{name:val(\"groupName\"),description:val(\"groupDescription\"),allowed_targets:val(\"groupTargets\").split(\",\").map(x=>x.trim()).filter(Boolean),enabled:\"true\"===$(\"groupEnabled\").value,limits:{score_per_5h:parseQuotaNumber(\"groupScore5h\"),score_per_week:parseQuotaNumber(\"groupScoreWeek\"),max_tokens_per_message:parseQuotaNumber(\"groupMaxTokensMsg\"),max_tool_calls_per_message:parseQuotaNumber(\"groupMaxToolsMsg\"),input_token_weight:parseQuotaNumber(\"groupInputTokenWeight\"),output_token_weight:parseQuotaNumber(\"groupOutputTokenWeight\"),tool_call_weight:parseQuotaNumber(\"groupToolCallWeight\"),thinking_second_weight:parseQuotaNumber(\"groupThinkingSecondWeight\")}}},editGroup=function(name){const group=(lastStatus&&lastStatus.groups||[]).find(g=>g.name===name);group&&(ensureGroupUi(),selectedGroupName=name,$(\"groupName\").disabled=!0,$(\"groupName\").value=group.name,$(\"groupDescription\").value=group.description||\"\",$(\"groupTargets\").value=(group.allowed_targets||[]).join(\", \"),$(\"groupScore5h\").value=group.limits.score_per_5h??\"\",$(\"groupScoreWeek\").value=group.limits.score_per_week??\"\",$(\"groupMaxTokensMsg\").value=group.limits.max_tokens_per_message??\"\",$(\"groupMaxToolsMsg\").value=group.limits.max_tool_calls_per_message??\"\",$(\"groupInputTokenWeight\").value=group.limits.input_token_weight??\"\",$(\"groupOutputTokenWeight\").value=group.limits.output_token_weight??\"\",$(\"groupToolCallWeight\").value=group.limits.tool_call_weight??\"\",$(\"groupThinkingSecondWeight\").value=group.limits.thinking_second_weight??\"\",$(\"groupEnabled\").value=String(!!group.enabled),openGroupEditor())},renderGroups=function(groups){ensureGroupUi();const grid=$(\"groupsGrid\");grid&&(groups=groups||[],selectedGroupName&&!groups.some(g=>g.name===selectedGroupName)&&(selectedGroupName=\"\"),grid.innerHTML=groups.map(g=>`<div class=\"api-card\"><div class=\"api-card-head\"><h3>${g.name}<br><span class=\"label\">${g.enabled?\"enabled\":\"disabled\"} · access ${(g.allowed_targets||[]).join(\", \")||\"*\"}</span></h3><span class=\"preset-actions\"><button class=\"iconbtn\" title=\"Edit\" onclick=\"editGroup('${g.name}')\">✏️</button><button class=\"iconbtn\" title=\"Delete\" onclick=\"deleteGroupByName('${g.name}')\">❌</button></span></div><p>${g.description||\"No description\"}</p><p class=\"label\">Configured budgets · ${quotaBudgetLine(g.limits||{})}</p><p class=\"label\">Configured weights · ${quotaWeightLine(g.limits||{})}</p><p class=\"label\">Resolved budgets · ${quotaBudgetLine(g.resolved_limits||g.limits||{})}</p><p class=\"label\">Resolved weights · ${quotaWeightLine(g.resolved_limits||g.limits||{})}</p></div>`).join(\"\")||'<div class=\"value\">No groups configured yet.</div>')},renderAudit=function(cfg){cfg=cfg||{},ensureV414Layout();const adminPort=lastStatus&&lastStatus.admin_port||8008,proxyPort=lastStatus&&lastStatus.proxy_port||8009,adminPath=cfg.admin_path||\"/admin\",online=!!cfg.online_enabled,authOptional=!!cfg.allow_proxy_without_api_key,localEnabled=!!cfg.local_api_enabled,localPort=cfg.local_api_port||10881;$(\"auditAdminEndpoint\")&&($(\"auditAdminEndpoint\").innerHTML=`:${adminPort}${adminPath}`),$(\"auditProxyEndpoint\")&&($(\"auditProxyEndpoint\").innerHTML=`:${proxyPort}`),$(\"auditExposure\")&&($(\"auditExposure\").textContent=online?\"online through proxy/admin only\":\"local/private only\"),$(\"auditLocalApi\")&&($(\"auditLocalApi\").textContent=localEnabled?`127.0.0.1:${localPort}`:\"disabled\"),$(\"auditSummary\")&&($(\"auditSummary\").innerHTML=\"Audit entries capture admin actions, proxy authentication outcomes, quota denials, API usage, group changes, and user-management events. Use the shared log viewer below to inspect either Docker runtime logs or the audit log stream.\"),$(\"auditPolicyText\")&&($(\"auditPolicyText\").innerHTML=`Proxy API keys are currently <b>${authOptional?\"optional\":\"required\"}</b>. Admin UI remains under <code>:${adminPort}${adminPath}</code>.`),mirrorAuthToggles(authOptional)},saveAuthSettings=async function(){const allow=!(!$(\"auditAllowAnonymousProxy\")||!$(\"auditAllowAnonymousProxy\").checked);mirrorAuthToggles(allow);try{const r=await fetch(\"/admin/users\",{method:\"POST\",headers:{\"Content-Type\":\"application/json\"},body:JSON.stringify({action:\"save_server_config\",allow_proxy_without_api_key:allow})}),j=await r.json();if(!r.ok||!j.ok)throw new Error(j.error||\"config failed\");j.server_config&&renderAudit(j.server_config),setAuditMsg(\"Saved access policy\"),await refreshStatus()}catch(e){alert(\"Access policy failed: \"+e)}},renderInstances=function(instances){ensureV414Layout();const tabs=$(\"instanceTabs\"),summary=$(\"instanceSummary\"),btn=$(\"instanceEnableBtn\"),panel=findPanelByHeading(\"system\",\"Instances\");if(!tabs||!summary||!panel)return;instances=scopeItems(),selectedScope&&(\"GLOBAL\"===selectedScope||instances.some(x=>x.id===selectedScope))||(selectedScope=singleScopeItems()[0]?.id||pairScopeItems()[0]?.id||\"GLOBAL\");const tabsHtml=singleScopeItems().map(x=>`<button class=\"subtab ${x.id===currentScope()?\"active\":\"\"}\" onclick=\"setScope('${x.id}')\">${x.id}${x.running?\" • on\":\" • off\"}</button>`).join(\"\")+pairScopeItems().map(x=>`<button class=\"subtab ${x.id===currentScope()?\"active\":\"\"}\" onclick=\"setScope('${x.id}')\">Pair ${(x.gpu_indices||[]).join(\"+\")}${x.running?\" • on\":\" • off\"}</button>`).join(\"\")+`<button class=\"subtab ${scopeIsGlobal()?\"active\":\"\"}\" onclick=\"setScope('GLOBAL')\">Global</button>`;tabs.innerHTML=tabsHtml,ensurePairManager();const target=currentScopeInstance(!1),actionButtons=[...panel.querySelectorAll(\"#instanceActionRow .btn\")||[]];scopeIsGlobal()&&target&&2===gpuCount()?(summary.innerHTML=`Global scope controls the only dual pair <code>${target.id}</code> on GPUs ${(target.gpu_indices||[]).join(\", \")} · mode ${target.mode} · port ${target.port} · proxy <code>${target.proxy_prefix}/</code>`,btn&&(btn.disabled=!1,btn.textContent=target.enabled?\"Disable Boot Autostart\":\"Enable Boot Autostart\"),actionButtons.forEach(x=>x.disabled=!1)):scopeIsGlobal()?(summary.innerHTML=\"Global scope selected. Create or choose a dual pair tab to manage arbitrary two-GPU dual presets. The profile and optimization controls below still apply against the active global context.\",btn&&(btn.disabled=!0,btn.textContent=\"Select a GPU or Pair Scope\"),actionButtons.forEach(x=>x.disabled=!0)):target?(summary.innerHTML=`${scopeLabel(target)} · ${target.assignment_text} · port ${target.port} · ${target.running?\"running\":\"stopped\"} · proxy <code>${target.proxy_prefix}/</code> · ${target.enabled?\"autostart enabled\":\"autostart disabled\"}`,btn&&(btn.disabled=!1,btn.textContent=target.enabled?\"Disable Boot Autostart\":\"Enable Boot Autostart\"),actionButtons.forEach(x=>x.disabled=!1)):(summary.textContent=\"No GPU instances configured\",btn&&(btn.disabled=!0,btn.textContent=\"Boot autostart unavailable\"),actionButtons.forEach(x=>x.disabled=!0)),$(\"logInstanceLabel\")&&($(\"logInstanceLabel\").textContent=currentLogLabel())},renderPresetScopeTabs=function(){ensureDynamicPresetLayout();const tabs=$(\"presetScopeTabs\"),summary=$(\"presetScopeSummary\");if(!tabs||!summary)return;tabs.innerHTML=\"\";if([{id:\"GLOBAL\",display_name:\"Global\"},...scopeItems()].forEach(item=>{const btn=document.createElement(\"button\");btn.className=\"subtab\"+(selectedScope===item.id?\" active\":\"\"),btn.textContent=\"GLOBAL\"===item.id?\"Global\":scopeLabel(item),btn.onclick=()=>setScope(item.id,!0),tabs.appendChild(btn)}),scopeIsGlobal())summary.textContent=\"Global scope fans single-GPU presets out across every GPU, dual presets across every two-GPU pair, and multi-GPU presets into the shared runtime.\";else{const current=currentScopeInstance(!0)||currentScopeInstance(!1);summary.textContent=current?`${scopeLabel(current)} selected. Matching ${\"dual\"===current.kind?\"dual\":\"single\"} presets below will apply to this scope.`:\"Select a scope to apply discovered presets.\"}},updateScopedCards=function(){const target=currentScopeInstance(!1);$(\"profileScopeNote\")&&($(\"profileScopeNote\").innerHTML=`${scopeIsGlobal()?\"Global\":scopeLabel(target)} scope: applying a power profile resets the recorded GPU peak values and starts a fresh measurement session.`),$(\"powerScopeNote\")&&($(\"powerScopeNote\").innerHTML=`${scopeIsGlobal()?\"Global\":scopeLabel(target)} scope: optimization and cooling actions use the selected runtime context while keeping host-level power state in sync.`),renderLogSourcePanel()},powerAction=async function(a){const cur=currentScopeInstance(!1);if(![\"stop_container\",\"start_instance\",\"restart_instance\",\"toggle_enabled\"].includes(a)||cur){if(\"stop_container\"!==a||confirm(`Stop ${scopeLabel(cur)} now?`))try{await post(\"/admin/power\",{action:a,instance_id:cur?cur.id:null,enabled:cur?!cur.enabled:void 0})}catch(e){alert(e)}}else alert(\"Select a GPU or Pair scope first.\")},instanceAction=async function(a){await powerAction(a)},toggleInstanceEnabled=async function(){const cur=currentScopeInstance(!1);if(cur)try{await post(\"/admin/power\",{action:\"toggle_enabled\",instance_id:cur.id,enabled:!cur.enabled})}catch(e){alert(e)}else alert(\"Select a GPU or Pair scope first.\")},switchMode=async function(m){const cur=currentScopeInstance(!0);if(!cur||\"dual\"===cur.kind)return void alert(\"Select a single GPU tab to apply a single-GPU preset.\");const blockingPair=pairScopeItems().find(x=>x.running&&(x.gpu_indices||[]).includes(Number(cur.gpu_index))),warning=blockingPair?`\\n\\nWarning: GPU ${cur.gpu_index} is currently occupied by ${blockingPair.id} running ${blockingPair.mode}. Continuing will stop that pair and replace it with ${m} on ${cur.id}.`:\"\";if(confirm(`Assign ${m} to ${cur.id} and start it?${warning}`))try{await post(\"/admin/switch\",{instance_id:cur.id,mode:m})}catch(e){alert(e)}},profile=async function(p){const cur=currentScopeInstance(!1),instanceId=scopeIsGlobal()?legacyGlobalDualScope()?\"GLOBAL\":cur?.id||\"GLOBAL\":cur?.id||null,scopeText=scopeIsGlobal()?\"Global\":scopeLabel(cur);if(confirm(profileDescription(p)+`\\n\\nApply this profile now to ${scopeText} scope and reset the recorded GPU peaks?`))try{await post(\"/admin/profile\",{profile:p,instance_id:instanceId},`/admin/profile ${p} ${instanceId||\"GLOBAL\"}`)}catch(e){alert(e)}},saveGroupForm=async function(){try{const r=await fetch(\"/admin/groups\",{method:\"POST\",headers:{\"Content-Type\":\"application/json\"},body:JSON.stringify({action:\"save\",group:collectGroupForm()})}),j=await r.json();if(!r.ok||!j.ok)throw new Error(j.error||\"group save failed\");applyDirectoryPayload(j),resetGroupForm(!0),setGroupsMsg(\"Saved group \"+j.group.name),refreshStatus().catch(()=>{})}catch(e){alert(\"Group save failed: \"+e)}},deleteGroupByName=async function(name){if(confirm(\"Delete group \"+name+\"?\"))try{const r=await fetch(\"/admin/groups\",{method:\"POST\",headers:{\"Content-Type\":\"application/json\"},body:JSON.stringify({action:\"delete\",name})}),j=await r.json();if(!r.ok||!j.ok)throw new Error(j.error||\"group delete failed\");applyDirectoryPayload(j),selectedGroupName===name&&resetGroupForm(!0),setGroupsMsg(\"Deleted group \"+name),refreshStatus().catch(()=>{})}catch(e){alert(\"Group delete failed: \"+e)}},pairingEnabled=function(){return!!(lastStatus&&lastStatus.server_config&&lastStatus.server_config.gpu_pairing_enabled)},legacyGlobalDualScope=function(){return 2===gpuCount()&&!pairingEnabled()};const UI_STATE_KEY=\"club3090-ui-state\";let uiStateHydrated=!1,uiStateSaveTimer=null,lastQueuedUiStateJson=\"\",instanceBusyState={active:!1,message:\"\"},currentLogSignature=\"\",statusPollTimer=null;function readCachedUiState(){try{return JSON.parse(localStorage.getItem(UI_STATE_KEY)||\"{}\")||{}}catch(e){return{}}}function writeCachedUiState(data){try{localStorage.setItem(UI_STATE_KEY,JSON.stringify(data||{}))}catch(e){}}function readJsonCache(key,fallback){try{const parsed=JSON.parse(localStorage.getItem(key)||\"null\");return parsed&&\"object\"==typeof parsed?parsed:fallback}catch(e){return fallback}}function savePresetSummaryCache(){try{localStorage.setItem(SUMMARY_CACHE_KEY,JSON.stringify(presetSummaryCache))}catch(e){}}function hydratePresetSummaryCache(){const cached=readJsonCache(SUMMARY_CACHE_KEY,null);cached&&(presetSummaryCache={persistent:cached.persistent&&\"object\"==typeof cached.persistent?cached.persistent:{},transient:cached.transient&&\"object\"==typeof cached.transient?cached.transient:{},restartTargets:Array.isArray(cached.restartTargets)?cached.restartTargets:[],lastSeenUptime:Number(cached.lastSeenUptime||0)})}function saveChatState(){try{const safe=currentChatStatePayload();localStorage.setItem(CHAT_STATE_KEY,JSON.stringify(safe)),queueServerChatStateSave(safe)}catch(e){}}async function hydrateChatState(){let cached=null,migratedFromLocalCache=!1;try{const response=await fetch(`/admin/chat-state?_=${Date.now()}`,{cache:\"no-store\"}),payload=await response.json();response.ok&&payload?.ok&&payload?.state&&(cached=payload.state)}catch(e){}if(cached||(cached=readJsonCache(CHAT_STATE_KEY,null)||readJsonCache(LEGACY_CHAT_STATE_KEY,null)||readJsonCache(\"club3090-chat-state-v516\",null),migratedFromLocalCache=!!cached),cached&&Array.isArray(cached.conversations)){const conversations=cached.conversations.map(conversation=>createChatConversation(conversation)).filter(Boolean);conversations.length&&(chatState={...chatState,activeConversationId:String(cached.activeConversationId||conversations[0].id),conversations,promptTemplates:Array.isArray(cached.promptTemplates)?cached.promptTemplates.map(template=>({id:String(template?.id||chatConversationId()),name:String(template?.name||\"\").trim(),text:String(template?.text||\"\")})).filter(template=>template.name||template.text):[]})}else if(cached){const imported=createChatConversation({title:CHAT_UNTITLED_TITLE,presetId:String(cached.presetId||\"\"),apiPresetName:String(cached.apiPresetName||\"\"),params:cached.params&&\"object\"==typeof cached.params?cached.params:{},systemPrompt:String(cached.systemPrompt||\"\"),messages:Array.isArray(cached.messages)?cached.messages:[],attachments:Array.isArray(cached.attachments)?cached.attachments:[],autoCompactEnabled:!1!==cached.autoCompactEnabled,autoCompactThresholdPct:cached.autoCompactThresholdPct});chatState={...chatState,activeConversationId:imported.id,conversations:[imported]}}if(!Array.isArray(chatState.conversations)||!chatState.conversations.length){const firstConversation=createChatConversation();chatState.conversations=[firstConversation],chatState.activeConversationId=firstConversation.id}chatState.conversations.some(conversation=>conversation.id===chatState.activeConversationId)||(chatState.activeConversationId=chatState.conversations[0].id),syncChatStateFromActiveConversation(),chatStateServerReady=!0,migratedFromLocalCache&&saveChatState()}function chatConversations(){return Array.isArray(chatState.conversations)?chatState.conversations:[]}function activeChatConversation(){const rows=chatConversations();return rows.find(conversation=>conversation.id===chatState.activeConversationId)||rows[0]||null}function syncChatStateFromConversation(conversation){const source=conversation||createChatConversation();chatState.presetId=String(source.presetId||\"\"),chatState.apiPresetName=String(source.apiPresetName||\"\"),chatState.messages=cloneChatMessages(source.messages),chatState.attachments=Array.isArray(source.attachments)?source.attachments.map(cloneChatAttachment):[],chatState.params=cloneChatParams(source.params),chatState.systemPrompt=String(source.systemPrompt||\"\"),chatState.autoCompactEnabled=!1!==source.autoCompactEnabled,chatState.autoCompactThresholdPct=clampChatCompactionThreshold(source.autoCompactThresholdPct),chatState.statsCollapsed=!!source.statsCollapsed}function syncChatStateFromActiveConversation(){syncChatStateFromConversation(activeChatConversation())}function syncActiveConversationFromChatState(){const conversation=activeChatConversation();return conversation?(conversation.presetId=String(chatState.presetId||\"\"),conversation.apiPresetName=String(chatState.apiPresetName||\"\"),conversation.messages=cloneChatMessages(chatState.messages),conversation.attachments=Array.isArray(chatState.attachments)?chatState.attachments.map(cloneChatAttachment):[],conversation.params=cloneChatParams(chatState.params),conversation.systemPrompt=String(chatState.systemPrompt||\"\"),conversation.autoCompactEnabled=!1!==chatState.autoCompactEnabled,conversation.autoCompactThresholdPct=clampChatCompactionThreshold(chatState.autoCompactThresholdPct),conversation.statsCollapsed=!!chatState.statsCollapsed,conversation.updatedAt=Date.now(),conversation.lastUsedAt=conversation.updatedAt,conversation):null}function persistChatConversationState(){syncActiveConversationFromChatState(),saveChatState()}function normalizeTabName(name){return\"audit\"===name?\"logs\":[\"overview\",\"system\",\"presets\",\"metrics\",\"users\",\"logs\",\"chat\"].includes(name)?name:\"overview\"}function currentUiState(){return{active_tab:normalizeTabName(activeTabName),selected_scope:selectedScope||\"GLOBAL\",current_log_source:\"audit\"===currentLogSource?\"audit\":\"docker\",show_global_logs:!!showGlobalLogs}}function queueUiStateSave(extra={}){const state={...currentUiState(),...extra},nextJson=JSON.stringify(state);nextJson!==lastQueuedUiStateJson&&(lastQueuedUiStateJson=nextJson,writeCachedUiState(state),uiStateSaveTimer&&clearTimeout(uiStateSaveTimer),uiStateSaveTimer=setTimeout(async()=>{try{await fetch(\"/admin/ui-config\",{method:\"POST\",headers:{\"Content-Type\":\"application/json\"},body:nextJson})}catch(e){}},120))}function activeTabButton(name){return\"chat\"===name?$(\"chatLaunchBtn\")||null:[...document.querySelectorAll(\".tab\")].find(btn=>(btn.getAttribute(\"onclick\")||\"\").includes(`'${name}'`)||btn.id===`${name}TabBtn`)||null}function syncHeaderChatButtonAlignment(){const button=$(\"chatLaunchBtn\"),row=button&&\"function\"==typeof button.closest?button.closest(\".header-row\"):null,logsButton=activeTabButton(\"logs\");if(!button||!row||!logsButton)return;const rowRect=row.getBoundingClientRect(),logsRect=logsButton.getBoundingClientRect(),marginRight=Math.max(0,Math.round(rowRect.right-logsRect.right));button.style.marginRight=`${marginRight}px`}function hydrateUiState(cfg){if(uiStateHydrated)return;const state={...readCachedUiState(),...cfg||{}};activeTabName=normalizeTabName(state.active_tab||activeTabName),currentLogSource=\"audit\"===state.current_log_source?\"audit\":\"docker\",showGlobalLogs=\"boolean\"==typeof state.show_global_logs?state.show_global_logs:showGlobalLogs;const ids=new Set(scopeItems().map(x=>x.id)),candidate=state.selected_scope||selectedScope||\"GLOBAL\";selectedScope=\"GLOBAL\"===candidate?\"GLOBAL\":ids.has(candidate)?candidate:singleScopeItems()[0]?.id||pairScopeItems()[0]?.id||\"GLOBAL\",\"GLOBAL\"!==selectedScope&&(selectedInstance=selectedScope),lastQueuedUiStateJson=JSON.stringify(currentUiState()),uiStateHydrated=!0}legacyGlobalPair=function(){return lastStatus&&lastStatus.legacy_global_instance||null};let powerCoolingBusyState={active:!1,message:\"\"};const STATUS_POLL_MS=1e3;function syncPowerCoolingBusyState(){const panel=findPanelByHeading(\"system\",\"Optimizations + Cooling\");panel&&(panel.classList.toggle(\"instance-panel-busy\",!!powerCoolingBusyState.active),[...panel.querySelectorAll(\"button,input,select,textarea\")].forEach(el=>{powerCoolingBusyState.active?el.setAttribute(\"disabled\",\"disabled\"):el.removeAttribute(\"disabled\")}))}function setPowerCoolingBusy(active,message=\"\"){powerCoolingBusyState={active:!!active,message:message||\"\"},syncPowerCoolingBusyState()}async function withPowerCoolingBusy(message,fn){setPowerCoolingBusy(!0,message);try{return await fn()}finally{setPowerCoolingBusy(!1)}}function redrawMetricsSoon(){lastStatus&&(renderMetrics(lastStatus),requestAnimationFrame(()=>{lastStatus&&renderMetrics(lastStatus)}))}function syncInstancesBusyState(){const panel=findPanelByHeading(\"system\",\"Instances\");if(!panel)return;panel.classList.toggle(\"instance-panel-busy\",!!instanceBusyState.active),[...panel.querySelectorAll(\"button,input,select,textarea\")].forEach(el=>{instanceBusyState.active?el.setAttribute(\"disabled\",\"disabled\"):(\"gpuPairingEnabled\"!==el.id||gpuCount()>=2)&&el.removeAttribute(\"disabled\")});const note=$(\"pairingBusyNote\");if(note){const msg=instanceBusyState.message||(2===gpuCount()?\"Keep disabled if you want Global to keep behaving like the shared two-GPU runtime.\":\"Enable this to manage arbitrary dual-GPU pair groups.\");note.innerHTML=instanceBusyState.active?`<span class=\"spinner\" aria-hidden=\"true\"></span>${msg}`:msg}}function setInstancesBusy(active,message=\"\"){instanceBusyState={active:!!active,message:message||\"\"},syncInstancesBusyState()}async function saveGpuPairingSetting(enabled){setInstancesBusy(!0,\"Applying GPU pairing setting...\");try{const r=await fetch(\"/admin/users\",{method:\"POST\",headers:{\"Content-Type\":\"application/json\"},body:JSON.stringify({action:\"save_server_config\",gpu_pairing_enabled:!!enabled})}),j=await r.json();if(!r.ok||!j.ok)throw new Error(j.error||\"GPU pairing update failed\");j.server_config&&(lastStatus||(lastStatus={}),lastStatus.server_config=j.server_config),await refreshStatus(),enabled||setScope(\"GLOBAL\",!1)}catch(e){alert(\"GPU pairing update failed: \"+e)}finally{setInstancesBusy(!1)}}function ensureAuditOverviewCard(){const system=$(\"system\"),overview=findPanelByHeading(\"logs\",\"Audit Overview\")||findPanelByHeading(\"audit\",\"Audit Overview\")||findPanelByHeading(\"system\",\"Audit Overview\");if(system&&overview){const services=findPanelByHeading(\"system\",\"Services\");system.insertBefore(overview,services&&services.nextSibling||system.children[1]||null)}}function ensurePairingToggle(){const panel=findPanelByHeading(\"system\",\"Instances\");if(!panel)return;let row=$(\"pairingToggleRow\");if(!row){row=document.createElement(\"div\"),row.id=\"pairingToggleRow\",row.className=\"actions\";const tabs=$(\"instanceTabs\");tabs&&tabs.parentNode===panel&&tabs.insertAdjacentElement(\"beforebegin\",row)}const count=gpuCount(),enabled=pairingEnabled(),busy=!!instanceBusyState.active,hint=busy?instanceBusyState.message||\"Applying GPU pairing setting...\":2===count?\"Keep disabled if you want Global to keep behaving like the shared two-GPU runtime.\":\"Enable this to manage arbitrary dual-GPU pair groups.\";row.innerHTML=`<label class=\"label\"><input type=\"checkbox\" id=\"gpuPairingEnabled\" ${enabled?\"checked\":\"\"} ${count<2||busy?\"disabled\":\"\"} onchange=\"saveGpuPairingSetting(this.checked)\"> Enable GPU Pairing</label><span class=\"label busy-note\" id=\"pairingBusyNote\">${busy?`<span class=\"spinner\" aria-hidden=\"true\"></span>${hint}`:hint}</span>`}ensureAccessPolicyCard=function(){const card=findPanelByHeading(\"system\",\"Access Policy\");card&&\"1\"!==card.dataset.v414Policy&&(card.dataset.v414Policy=\"1\",card.innerHTML='<h2>Access Policy</h2><div class=\"actions\" id=\"accessPolicyRow\"><label class=\"label\"><input type=\"checkbox\" id=\"auditAllowAnonymousProxy\" onchange=\"mirrorAuthToggles(this.checked)\"> allow requests without per-user API keys</label><button class=\"btn blue\" onclick=\"saveAuthSettings()\">Save Policy</button></div><div class=\"value smallgap\" style=\"margin-top:10px\" id=\"auditPolicyText\">-</div>')},ensureMachineButtons=function(){const systemCard=findPanelByHeading(\"system\",\"System\");if(!systemCard)return;let utilityRow=$(\"systemUtilityRow\");utilityRow||(utilityRow=document.createElement(\"div\"),utilityRow.id=\"systemUtilityRow\",utilityRow.className=\"actions\",systemCard.insertBefore(utilityRow,systemCard.querySelector(\".machine-row\")||null));const machineRow=systemCard.querySelector(\".machine-row\"),buttonDefs=[{label:\"Benchmark\",className:\"btn blue\",action:\"promptBenchmarkRun()\"},{label:\"Run Report\",className:\"btn blue\",action:\"promptReportRun()\"},{label:\"Update\",className:\"btn blue\",action:\"promptUpdateRun()\"}];if(buttonDefs.forEach(def=>{let button=[...systemCard.querySelectorAll(\"button\")].find(item=>(item.textContent||\"\").trim()===def.label);button||(button=document.createElement(\"button\"),button.textContent=def.label),button.className=def.className,button.setAttribute(\"onclick\",def.action),utilityRow.contains(button),utilityRow.appendChild(button)}),[...utilityRow.querySelectorAll(\"button\")].forEach(button=>{const label=(button.textContent||\"\").trim();buttonDefs.some(def=>def.label===label)||button.remove()}),machineRow){let wolButton=[...systemCard.querySelectorAll(\"button\")].find(item=>\"Wake-on-LAN\"===(item.textContent||\"\").trim());wolButton||(wolButton=document.createElement(\"button\"),wolButton.textContent=\"Wake-on-LAN\"),wolButton.className=\"btn amber\",wolButton.setAttribute(\"onclick\",\"wol()\");const firstMachineButton=machineRow.querySelector(\"button\");firstMachineButton&&firstMachineButton!==wolButton?machineRow.insertBefore(wolButton,firstMachineButton):machineRow.contains(wolButton)||machineRow.appendChild(wolButton)}[...systemCard.querySelectorAll(\".actions\")].forEach(actions=>{actions===utilityRow||actions===machineRow||actions.querySelector(\"button\")||actions.remove()})},allPairChoices=function(){const count=gpuCount(),pairs=[];for(let a=0;a<count;a+=1)for(let b=a+1;b<count;b+=1)pairs.push([a,b]);return pairs},ensurePairManager=function(){const panel=findPanelByHeading(\"system\",\"Instances\");if(!panel)return;let bar=$(\"pairManagerBar\");if(!bar){bar=document.createElement(\"div\"),bar.id=\"pairManagerBar\",bar.className=\"actions\";const summary=$(\"instanceSummary\");summary&&summary.parentNode===panel&&summary.insertAdjacentElement(\"afterend\",bar)}if(!pairingEnabled()||gpuCount()<2)return void(bar.innerHTML=\"\");const pair=currentScopeInstance(!0),showDelete=!!pair&&\"dual\"===pair.kind,existing=new Set(pairScopeItems().map(x=>x.id)),quickAdds=allPairChoices().filter(([a,b])=>!existing.has(canonicalPairId(a,b))).map(([a,b])=>`<button class=\"btn blue\" onclick=\"createPairGroup(${a},${b})\">Add Pair ${a}+${b}</button>`).join(\"\");bar.style.margin=\"8px 0 10px\",bar.innerHTML=`${quickAdds||\"\"}<button class=\"btn purple\" onclick=\"createPairGroup()\">Custom Pair Group</button>${showDelete?`<button class=\"btn red\" onclick=\"deleteCurrentPairGroup()\">Delete ${scopeLabel(pair)}</button>`:\"\"}`},ensureV414Layout=function(){ensureV413Layout(),ensureUsersUi(),ensureGroupUi(),ensureAccessPolicyCard(),ensureAuditOverviewCard(),ensureMachineButtons(),ensurePairingToggle(),ensurePairManager(),syncInstancesBusyState(),syncPowerCoolingBusyState(),ensureDynamicPresetLayout(),ensurePresetActionModal()};const logCache=Object.create(null);let statusRefreshPromise=null,pendingForcedStatusRefresh=!1,logConnectToken=0,logExportBusy=!1;function renderLogSourcePanel(){$(\"logSourceDocker\")&&$(\"logSourceDocker\").classList.toggle(\"active\",\"docker\"===currentLogSource),$(\"logSourceAudit\")&&$(\"logSourceAudit\").classList.toggle(\"active\",\"audit\"===currentLogSource),$(\"logsSourceSummary\")&&($(\"logsSourceSummary\").innerHTML=\"audit\"!==currentLogSource?scopeIsGlobal()&&legacyGlobalDualScope()?\"Docker logs selected. The shared live log viewer follows the active global dual runtime.\":\"Docker logs selected. The shared live log viewer follows the currently selected tracked instance.\":\"Audit logs selected. The shared live log viewer follows <code>/opt/club3090-control/audit.log</code>.\")}function trimLogText(text){const value=String(text||\"\");return value.length>9e5?value.slice(-75e4):value}function logIsNearBottom(box=$(\"log\")){return!box||box.scrollHeight-(box.scrollTop+box.clientHeight)<=28}function scrollLogToBottom(box=$(\"log\")){box&&(box.scrollTop=box.scrollHeight)}function logCacheEntry(signature){return logCache[signature]||(logCache[signature]={text:\"\",loaded:!1}),logCache[signature]}function renderCurrentLog(signature,options={}){const box=$(\"log\");if(!box)return;const entry=logCacheEntry(signature),nextValue=entry.loaded?collapseRepeatedLogText(entry.text):\"Connecting...\\n\",changed=box.value!==nextValue;changed&&(box.value=nextValue),searchState.active?changed&&recalculateMatches(!0):changed&&options.follow&&$(\"autoscroll\")&&$(\"autoscroll\").checked&&scrollLogToBottom(box),flushPendingLogJump()}function collapseRepeatedLogText(text){const source=String(text||\"\");if(!source)return\"\";const hasTrailingNewline=source.endsWith(\"\\n\"),lines=source.split(\"\\n\");hasTrailingNewline&&lines.pop();const collapsed=[];for(const line of lines){const previous=collapsed[collapsed.length-1];previous&&previous.raw===line?previous.count+=1:collapsed.push({raw:line,count:1})}return collapsed.map(entry=>entry.count>1?`${entry.raw} (${entry.count})`:entry.raw).join(\"\\n\")+(hasTrailingNewline?\"\\n\":\"\")}function replaceLogBuffer(signature,text){const entry=logCacheEntry(signature),box=signature===currentLogSignature?$(\"log\"):null,shouldFollow=!!box&&!!$(\"autoscroll\")?.checked&&(!entry.loaded||\"Connecting...\\n\"===box.value||logIsNearBottom(box));entry.text=trimLogText(text||\"\"),entry.loaded=!0,signature===currentLogSignature&&renderCurrentLog(signature,{follow:shouldFollow})}function appendLogChunk(signature,text){if(!text)return;const entry=logCacheEntry(signature),box=signature===currentLogSignature?$(\"log\"):null,shouldFollow=!!box&&!!$(\"autoscroll\")?.checked&&logIsNearBottom(box);entry.text=trimLogText((entry.text||\"\")+text),entry.loaded=!0,signature===currentLogSignature&&renderCurrentLog(signature,{follow:shouldFollow})}function syntheticLog(message){appendLog(`[admin-ui ${(new Date).toLocaleTimeString()}] ${message}`)}function adminResultText(payload,rawText){let text=\"\";if(payload&&\"object\"==typeof payload)try{text=JSON.stringify(payload,null,2)}catch(e){text=\"\"}return text||(text=String(rawText||\"\").trim()),text.length>5e3&&(text=text.slice(0,5e3)+\"\\n...<truncated>...\"),text}function logStreamConfig(){if(\"audit\"===currentLogSource)return{signature:\"audit\",url:\"/admin/audit-stream?tail=4000\"};const tracked=trackedLogRuntime(),target=tracked||dockerLogTarget(),explicit=String(selectedLogInstanceId||\"\").trim().toUpperCase(),instanceId=explicit||(tracked&&(tracked.id||tracked.instance_id)?tracked.id||tracked.instance_id:scopeIsGlobal()&&legacyGlobalDualScope()?\"GLOBAL\":target&&target.id);return{signature:`docker:${instanceId||\"primary\"}`,url:\"/admin/logs\"+(instanceId?`?instance=${encodeURIComponent(instanceId)}`:\"\")}}function currentLogExportRequest(){if(\"audit\"===currentLogSource)return{source:\"audit\",instance_id:null};if(currentLogSignature&&currentLogSignature.startsWith(\"docker:\")){const fromSignature=currentLogSignature.slice(7);if(fromSignature&&\"primary\"!==fromSignature)return{source:\"docker\",instance_id:fromSignature}}const explicit=String(selectedLogInstanceId||\"\").trim().toUpperCase();if(explicit)return{source:\"docker\",instance_id:explicit};const tracked=trackedLogRuntime(),target=tracked||dockerLogTarget();return{source:\"docker\",instance_id:(tracked&&(tracked.id||tracked.instance_id)?tracked.id||tracked.instance_id:scopeIsGlobal()&&legacyGlobalDualScope()?\"GLOBAL\":target&&target.id)||null}}async function exportCurrentLog(){if(!logExportBusy){logExportBusy=!0;try{const req=currentLogExportRequest();openApiKeyModal(\"Log Export Link\",(await post(\"/admin/log-export\",req,`/admin/log-export ${req.source} ${req.instance_id||\"host\"}`)).url||\"\",\"Share this link directly for debugging. It points to the currently selected log export.\",{copySuccessText:\"Copied exported log URL to the clipboard.\",showTopClose:!1})}catch(e){alert(e)}finally{logExportBusy=!1}}}function focusAuditLogs(){\"audit\"!==currentLogSource&&setCurrentLogSource(\"audit\"),activateTab(\"logs\",!0)}function clearActiveLogJump(){pendingLogJump=null}function flushPendingLogJump(){if(!pendingLogJump||!$(\"log\"))return;const cfg=logStreamConfig();if(!(pendingLogJump.signature&&pendingLogJump.signature!==cfg.signature||\"audit\"===pendingLogJump.source&&\"audit\"!==currentLogSource)){if(pendingLogJump.query){const box=$(\"log\");if(!box.value||!box.value.toLowerCase().includes(pendingLogJump.query.toLowerCase()))return;searchState.active&&$(\"searchQuery\").value===pendingLogJump.query?searchState.matches.length&&gotoMatch(searchState.index>=0?searchState.index:0):($(\"searchQuery\").value=pendingLogJump.query,runSearchOrNext())}else $(\"autoscroll\").checked&&($(\"log\").scrollTop=$(\"log\").scrollHeight);pendingLogJump=null}}function chooseVariantLogInstanceId(target,selector=\"\"){const targetId=String(target?.id||\"\").trim().toUpperCase();if(targetId&&\"GLOBAL\"!==targetId)return targetId;if(\"GLOBAL\"===targetId&&legacyGlobalDualScope())return\"GLOBAL\";const scopeKind=String(target?.kind||\"\");if(\"dual\"===scopeKind){const pairs=pairScopeItems().filter(row=>!selector||String(row?.mode||\"\")===String(selector));return String(pairs[0]&&pairs[0].id||\"\")}if(\"global\"===scopeKind){const runtime=runtimeStatsRows(lastStatus).find(row=>!selector||String(row?.mode||\"\")===String(selector));return String(runtime&&(runtime.id||runtime.instance_id)||\"\")}const singles=singleScopeItems().filter(row=>!selector||String(row?.mode||\"\")===String(selector));return String(singles[0]&&singles[0].id||\"\")}function openRuntimeLogsAtPoint(instanceId=\"\",query=\"\"){clearActiveLogJump(),searchState.active&&cancelSearch(),\"docker\"!==currentLogSource&&setCurrentLogSource(\"docker\"),instanceId&&(selectedLogInstanceId=String(instanceId).trim().toUpperCase()),activateTab(\"logs\",!0),$(\"autoscroll\").checked=!query,pendingLogJump={source:\"docker\",signature:`docker:${instanceId||\"primary\"}`,query:String(query||\"\").trim()},connectLogs(!0),setTimeout(()=>flushPendingLogJump(),60)}function bestFailureLogQuery(failure){const lines=String(failure?.error||\"\").replace(/\\r/g,\"\").split(\"\\n\").map(line=>line.trim()).filter(Boolean);for(let i=lines.length-1;i>=0;i-=1){const line=lines[i];if(!/^timed out waiting/i.test(line)&&!/^container .* stopped during boot/i.test(line)&&!/^no docker logs/i.test(line))return line}return lines[0]||\"\"}function renderEnhancedGpuMetricCharts(j){const holder=$(\"gpuMetricCharts\");if(!holder||!j.gpus)return;const series=j.series||[],charts=[{key:\"util\",suffix:\"Util\",label:\"util %\",color:\"#72c7ff\"},{key:\"mem_pct\",suffix:\"Mem\",label:\"VRAM %\",color:\"#2fc46b\"},{key:\"temp\",suffix:\"Temp\",label:\"core temp °C\",color:\"#ffde59\"},{key:\"fan\",suffix:\"Fan\",label:\"fan %\",color:\"#a855f7\"},{key:\"power\",suffix:\"Power\",label:\"power W\",color:\"#ff5b6c\"}];holder.innerHTML=charts.map(cat=>j.gpus.map(g=>`<div class=\"chart\"><canvas id=\"cGpu${g.index}${cat.suffix}\"></canvas></div>`).join(\"\")).join(\"\"),charts.forEach(cat=>j.gpus.forEach(g=>drawGpuSeries(`cGpu${g.index}${cat.suffix}`,series,g.index,cat.key,`GPU${g.index} ${cat.label}`,cat.color)))}async function wol(){const mac=prompt(\"MAC address to wake (blank = configured default):\",\"\");if(null!==mac)try{await post(\"/admin/wol\",{mac})}catch(e){alert(e)}}async function machineAction(action){const label=\"reboot\"===action?\"RESTART\":\"SHUT DOWN\";if(confirm(label+\" machine now?\")&&confirm(\"Final confirmation: \"+label+\" now.\"))try{await post(\"/admin/machine\",{action})}catch(e){alert(e)}}function syncActiveTabDisplay(){document.querySelectorAll(\".tabpane\").forEach(x=>x.classList.remove(\"active\")),document.querySelectorAll(\".tab\").forEach(x=>x.classList.remove(\"active\")),$(\"chatLaunchBtn\")&&$(\"chatLaunchBtn\").classList.remove(\"active\");const pane=$(activeTabName);pane&&pane.classList.add(\"active\");const btn=activeTabButton(activeTabName);btn&&btn.classList.add(\"active\"),applyLogVisibility()}function activateTab(name,firstRender=!1){activeTabName=normalizeTabName(name),syncActiveTabDisplay(),(\"logs\"===activeTabName||showGlobalLogs||firstRender)&&connectLogs(!1),\"metrics\"===activeTabName&&redrawMetricsSoon(),\"chat\"===activeTabName&&renderChatUi(),refreshStatus({force:!0}).catch(()=>{}),queueUiStateSave(),setTimeout(()=>{!searchState.active&&$(\"autoscroll\").checked&&$(\"log\")&&($(\"log\").scrollTop=$(\"log\").scrollHeight)},0)}function clearLegacyPollers(){const marker=window.setInterval(()=>{},6e4);window.clearInterval(marker);for(let id=1;id<marker;id+=1)window.clearInterval(id)}async function bootAdminUi(){clearLegacyPollers(),ensureV414Layout(),hydratePresetSummaryCache(),await hydrateChatState(),resetUserForm(!0),resetGroupForm(!0),selectedScope||(selectedScope=singleScopeItems()[0]?.id||pairScopeItems()[0]?.id||\"GLOBAL\"),setScope(selectedScope,!1),refreshStatus().catch(()=>{}),statusPollTimer&&clearInterval(statusPollTimer),statusPollTimer=setInterval(()=>{refreshStatus()},1e3),syncHeaderChatButtonAlignment(),window.addEventListener(\"resize\",syncHeaderChatButtonAlignment),window.addEventListener(\"beforeunload\",()=>{if(logEs)try{logEs.close()}catch(e){}})}function runtimeInventory(){return lastStatus&&lastStatus.runtime_inventory||{models:[],variants:[]}}function inventoryModels(){return lastStatus&&lastStatus.models||runtimeInventory().models||[]}function inventoryVariants(){return lastStatus&&lastStatus.variants||runtimeInventory().variants||[]}function saveSelectedPresetModel(modelId=\"\"){const next=String(modelId||\"\").trim();selectedPresetModelId=next,lastStatus||(lastStatus={}),lastStatus.server_config={...lastStatus.server_config||{},selected_preset_model:next},fetch(\"/admin/users\",{method:\"POST\",headers:{\"Content-Type\":\"application/json\"},body:JSON.stringify({action:\"save_server_config\",selected_preset_model:next})}).then(r=>r.json()).then(j=>{j&&j.ok&&j.server_config&&(lastStatus||(lastStatus={}),lastStatus.server_config=j.server_config)}).catch(()=>{})}function hydrateSelectedPresetModel(){const models=inventoryModels(),valid=new Set(models.map(model=>String(model.model_id||\"\"))),configured=String(lastStatus?.server_config?.selected_preset_model||\"\").trim();if(!selectedPresetModelHydrated)return selectedPresetModelId=valid.has(configured)?configured:\"\",void(selectedPresetModelHydrated=!0);selectedPresetModelId&&valid.has(selectedPresetModelId)||(selectedPresetModelId=valid.has(configured)?configured:\"\")}function selectPresetModel(modelId=\"\"){selectedPresetModelId=String(modelId||\"\").trim(),selectedPresetModelHydrated=!0,renderPresetModelSelector(),renderDynamicPresetModels(),saveSelectedPresetModel(selectedPresetModelId)}function renderPresetModelSelector(){const host=$(\"presetModelSelector\");if(!host)return;const models=inventoryModels();if(!models.length)return host.innerHTML=\"\",void host.classList.add(\"hidden\");host.classList.remove(\"hidden\"),host.innerHTML=`<button class=\"subtab ${selectedPresetModelId?\"\":\"active\"}\" onclick=\"selectPresetModel('')\">Summary</button>${models.map(model=>{const modelId=String(model.model_id||\"\");return`<button class=\"subtab ${modelId===selectedPresetModelId?\"active\":\"\"}\" onclick=\"selectPresetModel('${escapeJs(modelId)}')\">${escapeHtml(model.display_name||modelId)}</button>`}).join(\"\")}`}function variantSelector(variant){return variant&&(variant.upstream_tag||variant.variant_id)||\"\"}function variantMapBySelector(){const map=new Map;return inventoryVariants().forEach(variant=>{const selector=variantSelector(variant);selector&&map.set(selector,variant)}),map}function escapeJs(value){return String(value??\"\").replaceAll(\"\\\\\",\"\\\\\\\\\").replaceAll(\"'\",\"\\\\'\")}function prettyEngineName(engine){return\"llamacpp\"===engine?\"llama.cpp\":String(engine||\"\")}function variantDisplayLabel(variant){if(variant&&variant.upstream_tag)return variant.upstream_tag;const bits=String(variant?.compose_rel_path||\"\").split(\"/\"),raw=(bits[bits.length-1]||\"\").replace(/\\.yml$/i,\"\"),stem=\"docker-compose\"===raw?\"default\":raw||\"preset\";return`${variant?.topology||\"global\"}/${stem}`}function variantMaxCtx(variant){const value=Number(variant?.max_model_len||0);return!Number.isFinite(value)||value<=0?\"n/a\":value>=1e3?`${Math.round(value/1e3)}K`:String(value)}function badgeClass(prefix,value){return`${prefix}-${String(value||\"unknown\").replaceAll(\" \",\"_\").replaceAll(\"/\",\"_\")}`}function installStateLabel(variant){const state=String(variant?.install_state||\"unknown\");return\"ready\"===state?\"ready\":\"requires_download\"===state?\"needs download\":\"unavailable\"===state?\"unavailable\":state}function statusLabel(variant){const kind=String(variant?.status_kind||\"unknown\");return\"production\"===kind?\"production\":\"production_caveat\"===kind?\"production + caveats\":\"preview\"===kind?\"preview\":\"upstream_gated\"===kind?\"upstream gated\":\"deprecated\"===kind?\"deprecated\":\"experimental\"===kind?\"experimental\":\"unknown\"}function currentSwitchFailure(){return lastStatus?.switch_failure||{}}function currentSwitchJob(){return lastStatus?.switch_job||{}}function switchJobElapsedSeconds(job){const started=Number(job?.started_at||0);if(!Number.isFinite(started)||started<=0)return 0;const finished=Number(job?.finished_at||0),end=Number.isFinite(finished)&&finished>0?finished:Date.now()/1e3;return Math.max(0,Math.floor(end-started))}function launchSecondsForVariant(selector,target){const job=currentSwitchJob();if(\"success\"!==job.status||!job.mode)return 0;const jobMode=String(job.mode||\"\"),jobTarget=String(job.target||\"\"),targetId=String(target?.id||\"\");return jobMode!==String(selector||\"\")||jobTarget&&targetId&&jobTarget!==targetId?0:switchJobElapsedSeconds(job)}function trimSummaryEntries(entries=[]){const seen=new Set,out=[];return entries.forEach(entry=>{const selector=String(entry?.selector||\"\").trim();selector&&!seen.has(selector)&&(seen.add(selector),out.push({selector,ts:Number(entry?.ts||Date.now()/1e3)}))}),out.slice(0,5)}function upsertSummaryEntry(storeKey,modelId,selector){const key=String(modelId||\"\").trim(),mode=String(selector||\"\").trim();if(!key||!mode)return;const current=Array.isArray(presetSummaryCache[storeKey]?.[key])?presetSummaryCache[storeKey][key]:[];presetSummaryCache[storeKey][key]=trimSummaryEntries([{selector:mode,ts:Date.now()/1e3},...current.filter(entry=>String(entry?.selector||\"\")!==mode)])}function removeSummaryEntry(modelId,selector){const key=String(modelId||\"\").trim(),mode=String(selector||\"\").trim();[\"persistent\",\"transient\"].forEach(storeKey=>{const current=Array.isArray(presetSummaryCache[storeKey]?.[key])?presetSummaryCache[storeKey][key]:[];presetSummaryCache[storeKey][key]=current.filter(entry=>String(entry?.selector||\"\")!==mode),presetSummaryCache[storeKey][key].length||delete presetSummaryCache[storeKey][key]}),savePresetSummaryCache()}function syncPresetSummaryCacheFromStatus(j){const uptime=Number(j?.uptime_seconds||0);Number.isFinite(presetSummaryCache.lastSeenUptime)&&presetSummaryCache.lastSeenUptime>0&&uptime>0&&uptime+5<presetSummaryCache.lastSeenUptime&&(presetSummaryCache.transient={},presetSummaryCache.restartTargets=[]),presetSummaryCache.lastSeenUptime=uptime;const variants=variantMapBySelector();runtimeStatsRows(j).forEach(runtime=>{const selector=String(runtime?.selector||runtime?.mode||\"\").trim(),variant=variants.get(selector);variant&&(upsertSummaryEntry(\"persistent\",variant.model_id,selector),removeSummaryEntry(variant.model_id,selector),upsertSummaryEntry(\"persistent\",variant.model_id,selector))});const switchJob=j?.switch_job||{},switchMode=String(switchJob.mode||\"\").trim(),switchVariant=variants.get(switchMode);if(switchVariant&&switchMode&&((switchJob.active||\"failed\"===switchJob.status)&&upsertSummaryEntry(\"transient\",switchVariant.model_id,switchMode),\"success\"===switchJob.status)){upsertSummaryEntry(\"persistent\",switchVariant.model_id,switchMode);const currentTransient=Array.isArray(presetSummaryCache.transient[switchVariant.model_id])?presetSummaryCache.transient[switchVariant.model_id]:[];presetSummaryCache.transient[switchVariant.model_id]=currentTransient.filter(entry=>String(entry?.selector||\"\")!==switchMode)}savePresetSummaryCache()}function summaryEntriesForModel(modelId){const key=String(modelId||\"\").trim(),persistent=Array.isArray(presetSummaryCache.persistent[key])?presetSummaryCache.persistent[key]:[];return trimSummaryEntries([...Array.isArray(presetSummaryCache.transient[key])?presetSummaryCache.transient[key]:[],...persistent])}function summaryRunningTargets(){return runtimeStatsRows(lastStatus).map(runtime=>({instance_id:String(runtime?.id||runtime?.instance_id||\"\"),mode:String(runtime?.selector||runtime?.mode||\"\")}))}function runtimeActiveForVariant(selector,target){const normalizedSelector=String(selector||\"\");if(!normalizedSelector||!target)return!1;if(\"GLOBAL\"===target.id){if(\"global\"===target.kind)return runtimeStatsRows(lastStatus).some(row=>String(row?.mode||\"\")===normalizedSelector&&\"GLOBAL\"===String(row?.id||\"\"));if(\"dual\"===target.kind){if(legacyGlobalDualScope()){const legacy=legacyGlobalPair();return!!legacy?.running&&String(legacy?.mode||\"\")===normalizedSelector}const pairs=pairScopeItems();return!!pairs.length&&pairs.every(row=>!!row?.running&&String(row?.mode||\"\")===normalizedSelector)}const singles=singleScopeItems();return!!singles.length&&singles.every(row=>!!row?.running&&String(row?.mode||\"\")===normalizedSelector)}const scoped=scopeItems().find(row=>String(row?.id||\"\")===String(target.id||\"\"));return!!scoped?.running&&String(scoped?.mode||\"\")===normalizedSelector}function handleSwitchJobTransition(previousStatus,currentStatus){const prevJob=previousStatus?.switch_job||{},nextJob=currentStatus?.switch_job||{},prevFailure=previousStatus?.switch_failure||{},nextFailure=currentStatus?.switch_failure||{},successTransition=\"success\"!==prevJob.status&&\"success\"===nextJob.status&&!nextJob.active&&nextJob.mode,failureTransition=\"failed\"!==prevJob.status&&\"failed\"===nextJob.status&&nextJob.mode||Number(prevFailure.ts||0)!==Number(nextFailure.ts||0)&&nextFailure.mode;if(successTransition){const key=`success:${nextJob.mode}:${nextJob.target}:${nextJob.finished_at}`;if(key!==lastSwitchNotificationKey&&(lastSwitchNotificationKey=key,!windowIsFocused())){const seconds=switchJobElapsedSeconds(nextJob);showBrowserNotification(\"Preset Active\",`${nextJob.mode} reached Active in ${seconds}s.`).catch(()=>{})}}else if(failureTransition){const mode=String(nextFailure.mode||nextJob.mode||\"unknown preset\"),key=`failed:${mode}:${Number(nextFailure.ts||nextJob.finished_at||Date.now())}`;if(key!==lastSwitchNotificationKey){lastSwitchNotificationKey=key;showBrowserNotification(\"Preset Error\",`${mode}: ${String(nextFailure.error||nextJob.error||\"Preset launch failed.\").split(\"\\n\")[0].trim()||\"Preset launch failed.\"}`).catch(()=>{})}}}function scopeTargetForVariant(variant){const scope=String(variant?.scope_kind||\"\");if(\"single\"===scope){if(scopeIsGlobal())return{id:\"GLOBAL\",kind:\"global\",display_name:\"Global\"};const current=currentScopeInstance(!0);return current&&\"dual\"!==current.kind?current:null}if(\"dual\"===scope){if(scopeIsGlobal())return gpuCount()<2?null:{id:\"GLOBAL\",kind:\"dual\",display_name:\"Global Dual\"};const current=currentScopeInstance(!1);return current&&\"dual\"===current.kind?current:null}return(\"multi\"===scope||\"global_only\"===scope)&&scopeIsGlobal()?{id:\"GLOBAL\",kind:\"global\",display_name:\"Global\"}:null}function scopeBlockReason(variant){const scope=String(variant?.scope_kind||\"\");return\"single\"===scope?\"Select a GPU scope, or Global to apply this single-GPU preset across every available GPU.\":\"dual\"===scope?\"Select a dual pair scope, or Global to apply this dual preset across every available GPU pair.\":\"multi\"===scope||\"global_only\"===scope?\"Select Global scope before applying this multi-GPU preset.\":\"This preset cannot be applied from the current scope.\"}function sortInventoryVariants(rows){return[...rows||[]].sort((a,b)=>{const activeA=runtimeStatsRows(lastStatus).some(row=>String(row?.mode||\"\")===variantSelector(a))?-1:0,activeB=runtimeStatsRows(lastStatus).some(row=>String(row?.mode||\"\")===variantSelector(b))?-1:0;if(activeA!==activeB)return activeA-activeB;const readyRank=item=>\"ready\"===item?.install_state?0:\"requires_download\"===item?.install_state?1:2,statusRank=item=>\"production\"===item?.status_kind?0:\"production_caveat\"===item?.status_kind?1:\"experimental\"===item?.status_kind?2:3;return readyRank(a)-readyRank(b)||statusRank(a)-statusRank(b)||variantDisplayLabel(a).localeCompare(variantDisplayLabel(b))})}function ensureDynamicPresetLayout(){const presets=$(\"presets\");if(!presets)return;const firstPanel=presets.querySelector(\".panel\");firstPanel&&(firstPanel.id=\"dynamicPresetPanel\",$(\"modelPresetGrid\")||(firstPanel.innerHTML='<div class=\"panel-head\"><h2>Dynamic Model Presets</h2><button class=\"btn green\" onclick=\"promptRuntimeInventoryRebuild()\">Rebuild Dynamic Model DB</button></div><div class=\"preset-help\">Discovered presets are rendered directly from the local <code>/opt/ai/club-3090</code> clone. Global applies single-GPU presets across every GPU, dual presets across every two-GPU pair, and multi-GPU presets to the shared runtime.</div><div class=\"preset-section-label\">Scope</div><div class=\"subtabs\" id=\"presetScopeTabs\"></div><div class=\"value smallgap\" id=\"presetScopeSummary\">-</div><div class=\"preset-section-label\">Models</div><div class=\"subtabs\" id=\"presetModelSelector\"></div><div class=\"value smallgap\" id=\"presetJobSummary\">-</div><div id=\"modelPresetGrid\" class=\"model-grid\"></div>'),$(\"singlePresetCard\")&&$(\"singlePresetCard\").removeAttribute(\"id\"),$(\"dualPresetCard\")&&$(\"dualPresetCard\").remove(),$(\"presetScopePanel\")&&$(\"presetScopePanel\").remove())}currentLogHeading=function(){return\"audit\"===currentLogSource?\"Audit Logs\":\"Docker Logs\"},currentLogLabel=function(){if(\"audit\"===currentLogSource)return\"source: audit\";const explicit=String(selectedLogInstanceId||\"\").trim().toUpperCase();if(explicit)return\"instance: \"+explicit;const tracked=trackedLogRuntime();if(tracked)return\"instance: \"+(tracked.id||tracked.instance_id||\"primary\");if(scopeIsGlobal()&&legacyGlobalDualScope())return\"instance: Global dual\";const cur=dockerLogTarget();return\"instance: \"+(cur&&cur.id||\"primary\")},applyLogVisibility=function(){const isLogs=\"logs\"===activeTabName;document.body.classList.toggle(\"logs-tab\",isLogs),document.body.classList.remove(\"audit-tab\");const card=document.querySelector(\".logs.panel\");card&&card.classList.toggle(\"log-card-hidden\",!isLogs&&!showGlobalLogs),$(\"logTitle\")&&($(\"logTitle\").textContent=currentLogHeading()),$(\"logInstanceLabel\")&&($(\"logInstanceLabel\").textContent=currentLogLabel()),renderLogSourcePanel(),renderLogTracker(),currentLogSignature&&renderCurrentLog(currentLogSignature)},connectLogs=function(force=!1){if(!(\"logs\"===activeTabName||showGlobalLogs)&&!force)return;const cfg=logStreamConfig();if(!force&&logEs&&cfg.signature===currentLogSignature)return void renderCurrentLog(cfg.signature);currentLogSignature=cfg.signature,renderCurrentLog(cfg.signature,{follow:!!$(\"autoscroll\")?.checked});const token=++logConnectToken;if(logEs){try{logEs.close()}catch(e){}logEs=null}const es=new EventSource(cfg.url);logEs=es;const handle=(mode,data)=>{let payload=null;try{payload=JSON.parse(data||\"{}\")}catch(e){}const text=payload&&\"string\"==typeof payload.text?payload.text:String(data||\"\").replaceAll(\"\\\\u0000\",\"\\n\");\"reset\"===mode?replaceLogBuffer(cfg.signature,text):appendLogChunk(cfg.signature,text),flushPendingLogJump()};es.addEventListener(\"reset\",e=>{token===logConnectToken&&handle(\"reset\",e.data)}),es.addEventListener(\"append\",e=>{token===logConnectToken&&handle(\"append\",e.data)}),es.onmessage=e=>{token===logConnectToken&&handle(\"append\",e.data)},es.onerror=()=>{}},setCurrentLogSource=function(source){currentLogSource=\"audit\"===source?\"audit\":\"docker\",applyLogVisibility(),queueUiStateSave({current_log_source:currentLogSource}),connectLogs(!0)},setShowGlobalLogs=function(v){showGlobalLogs=!!v,applyLogVisibility(),queueUiStateSave({show_global_logs:showGlobalLogs}),connectLogs(!1)},setScope=function(scope,reconnect=!0){const ids=new Set(scopeItems().map(x=>x.id));selectedScope=\"GLOBAL\"===scope?\"GLOBAL\":ids.has(scope)?scope:singleScopeItems()[0]?.id||pairScopeItems()[0]?.id||\"GLOBAL\",\"GLOBAL\"!==selectedScope&&(selectedInstance=selectedScope),renderInstances(getInstanceList()),renderPresetScopeTabs(),renderDynamicPresetModels(),updateScopedCards(),applyLogVisibility(),queueUiStateSave(),reconnect&&connectLogs(!0)},post=async function(path,obj,label=\"\"){const requestLabel=label||`${path} ${JSON.stringify(obj||{})}`;syntheticLog(`request sent: ${requestLabel}`);try{const r=await fetch(path,{method:\"POST\",headers:{\"Content-Type\":\"application/json\"},body:JSON.stringify(obj||{})}),text=await r.text();let payload=null;try{payload=JSON.parse(text)}catch(e){}if(!r.ok||payload&&!1===payload.ok)throw new Error(payload&&payload.error||text||`${path} failed`);return syntheticLog(`request finished: ${requestLabel}`),appendLog(`----- admin result -----\\n${adminResultText(payload,text)}\\n------------------------`),payload&&\"audit\"===payload.focus_log_source&&focusAuditLogs(),refreshStatus().catch(()=>{}),payload||text}catch(e){throw syntheticLog(`request failed: ${requestLabel} | ${e.message||e}`),appendLog(`----- admin error -----\\n${e.message||e}\\n-----------------------`),refreshStatus().catch(()=>{}),e}},metricTab=function(e,n){document.querySelectorAll(\".metricpane\").forEach(x=>x.classList.remove(\"active\")),document.querySelectorAll(\".subtab\").forEach(x=>x.classList.remove(\"active\"));const pane=$(n);pane&&pane.classList.add(\"active\"),e&&e.target&&e.target.classList.add(\"active\"),redrawMetricsSoon(),refreshStatus().catch(()=>{})},togglePowerOptimizations=async function(){const enable=$(\"optToggle\")&&$(\"optToggle\").textContent.includes(\"Enable\"),instanceId=scopeIsGlobal()?\"GLOBAL\":currentScopeInstance(!1)&&currentScopeInstance(!1).id||null;try{await withPowerCoolingBusy(enable?\"Applying power optimizations...\":\"Disabling power optimizations...\",()=>post(\"/admin/power\",{action:enable?\"enable_optimizations\":\"disable_optimizations\",instance_id:instanceId},\"/admin/power \"+(enable?\"enable_optimizations\":\"disable_optimizations\")))}catch(e){alert(e)}},toggleFansMax=async function(){const reset=$(\"fanToggle\")&&$(\"fanToggle\").textContent.includes(\"Reset\"),cur=currentScopeInstance(!1),instanceId=scopeIsGlobal()?\"GLOBAL\":cur&&cur.id||null;try{await withPowerCoolingBusy(reset?\"Resetting fans to default...\":\"Setting fans to max...\",()=>post(\"/admin/power\",{action:reset?\"fans_auto\":\"fans_max\",instance_id:instanceId},`/admin/power ${reset?\"fans_auto\":\"fans_max\"} ${instanceId||\"host\"}`))}catch(e){alert(e)}},tab=function(e,n){activateTab(n,!1)},refreshStatus=async function(opts={}){const force=!(!opts||!opts.force);return statusRefreshPromise?(force&&(pendingForcedStatusRefresh=!0),statusRefreshPromise):(statusRefreshPromise=(async()=>{try{ensureV414Layout();const suffix=force?`?force=1&_=${Date.now()}`:\"\",r=await fetch(`/admin/status${suffix}`,{cache:\"no-store\"});if(!r.ok)throw new Error(`status fetch failed (${r.status})`);const j=await r.json(),power=(j.metrics,j.power||{}),previousStatus=lastStatus;lastStatus=j,syncPresetSummaryCacheFromStatus(j),hydrateUiState(j.ui_config||{}),hydrateSelectedPresetModel(),$(\"showGlobalLogs\")&&($(\"showGlobalLogs\").checked=!!showGlobalLogs),$(\"services\").textContent=`vLLM=${j.vllm_service}, control=${j.control_service}, console=${j.console_service}`,renderOverviewStatus(j),renderGpuCards(j.gpus),$(\"optToggle\").textContent=power.optimizations_enabled?\"Disable Power Optimizations\":\"Enable Power Optimizations\",$(\"fanToggle\").textContent=power.fan_manual_override?\"Reset Fans to Default\":\"Set Fans to Max\",renderMetrics(j),renderPresetCatalog(j.presets),renderUsers(j.users||[]),renderGroups(j.groups||[]),renderAudit(j.server_config||{}),renderInstances(j.instances||[]),renderPresetScopeTabs(),updateScopedCards(),renderModelInstallStatus(),renderDynamicPresetModels(),renderChatUi(),syncActiveTabDisplay(),(\"logs\"===activeTabName||showGlobalLogs)&&connectLogs(!1),handleSwitchJobTransition(previousStatus,j),setMsg(\"\")}catch(e){setMsg(\"Status error: \"+e)}finally{statusRefreshPromise=null,pendingForcedStatusRefresh&&(pendingForcedStatusRefresh=!1,refreshStatus({force:!0}).catch(()=>{}))}})(),statusRefreshPromise)},bootAdminUi().catch(e=>{setMsg(\"Boot error: \"+e)});let presetActionHandler=null;function ensurePresetActionModal(){if($(\"presetActionModal\"))return;const modal=document.createElement(\"div\");modal.id=\"presetActionModal\",modal.className=\"club-modal hidden\",modal.innerHTML=`<div class=\"club-modal-card\" role=\"dialog\" aria-modal=\"true\" aria-labelledby=\"presetActionModalTitle\"><div class=\"panel-head\"><h2 id=\"presetActionModalTitle\">Confirm Action</h2><button class=\"iconbtn\" title=\"Close\" aria-label=\"Close\" onclick=\"closePresetActionModal()\">${svgIcon(\"delete\")}</button></div><div class=\"preset-help\" id=\"presetActionModalBody\">-</div><textarea id=\"presetActionModalDetail\" class=\"modal-keybox hidden\" readonly wrap=\"soft\" spellcheck=\"false\"></textarea><div class=\"preset-form-actions\"><button class=\"btn blue\" onclick=\"closePresetActionModal()\">Cancel</button><button class=\"btn green\" id=\"presetActionModalConfirm\">Continue</button></div><div class=\"msg\" id=\"presetActionModalMsg\"></div></div>`,modal.addEventListener(\"click\",event=>{event.target===modal&&closePresetActionModal()}),document.body.appendChild(modal)}function openPresetActionModal(opts={}){ensurePresetActionModal(),presetActionHandler=\"function\"==typeof opts.onConfirm?opts.onConfirm:null,$(\"presetActionModalTitle\").textContent=opts.title||\"Confirm Action\",$(\"presetActionModalBody\").innerHTML=opts.body||\"\",$(\"presetActionModalMsg\").textContent=\"\";const detail=$(\"presetActionModalDetail\");opts.detail?(detail.value=String(opts.detail),detail.scrollTop=0,detail.classList.remove(\"hidden\")):(detail.value=\"\",detail.classList.add(\"hidden\"));const confirmBtn=$(\"presetActionModalConfirm\");confirmBtn.textContent=opts.confirmLabel||\"Continue\",confirmBtn.className=`btn ${opts.confirmClass||\"green\"}`,confirmBtn.onclick=async()=>{if(!presetActionHandler)return closePresetActionModal();confirmBtn.disabled=!0;try{await presetActionHandler(),closePresetActionModal()}catch(e){$(\"presetActionModalMsg\").textContent=String(e||\"\")}finally{confirmBtn.disabled=!1}},$(\"presetActionModal\").classList.remove(\"hidden\")}function closePresetActionModal(){ensurePresetActionModal(),$(\"presetActionModal\").classList.add(\"hidden\"),presetActionHandler=null}function ensureActionChoiceModal(){if($(\"actionChoiceModal\"))return;const modal=document.createElement(\"div\");modal.id=\"actionChoiceModal\",modal.className=\"club-modal hidden\",modal.innerHTML=`<div class=\"club-modal-card\" role=\"dialog\" aria-modal=\"true\" aria-labelledby=\"actionChoiceModalTitle\"><div class=\"panel-head\"><h2 id=\"actionChoiceModalTitle\">Choose Action</h2><button class=\"iconbtn\" title=\"Close\" aria-label=\"Close\" onclick=\"closeActionChoiceModal()\">${svgIcon(\"delete\")}</button></div><div class=\"preset-help\" id=\"actionChoiceModalBody\">-</div><div class=\"preset-form-actions\" id=\"actionChoiceModalChoices\"></div><div class=\"preset-form-actions\"><button class=\"btn blue\" onclick=\"closeActionChoiceModal()\">Cancel</button></div><div class=\"msg\" id=\"actionChoiceModalMsg\"></div></div>`,modal.addEventListener(\"click\",event=>{event.target===modal&&closeActionChoiceModal()}),document.body.appendChild(modal)}function closeActionChoiceModal(){ensureActionChoiceModal(),$(\"actionChoiceModal\").classList.add(\"hidden\")}function openActionChoiceModal(opts={}){ensureActionChoiceModal(),$(\"actionChoiceModalTitle\").textContent=opts.title||\"Choose Action\",$(\"actionChoiceModalBody\").innerHTML=opts.body||\"\",$(\"actionChoiceModalMsg\").textContent=\"\";const host=$(\"actionChoiceModalChoices\");host.innerHTML=\"\",(opts.choices||[]).forEach(choice=>{const button=document.createElement(\"button\");button.className=`btn ${choice.className||\"green\"}`,button.textContent=choice.label||\"Continue\",button.onclick=async()=>{button.disabled=!0;try{await choice.onClick(),closeActionChoiceModal()}catch(e){$(\"actionChoiceModalMsg\").textContent=String(e||\"\")}finally{button.disabled=!1}},host.appendChild(button)}),$(\"actionChoiceModal\").classList.remove(\"hidden\")}function promptRuntimeInventoryRebuild(){openPresetActionModal({title:\"Rebuild Dynamic Model DB\",body:\"This rescans the upstream <code>club-3090</code> checkout, rebuilds the runtime inventory, and refreshes model/preset metadata without touching your downloaded model assets.\",confirmLabel:\"Rebuild\",confirmClass:\"green\",onConfirm:async()=>{await post(\"/admin/rebuild-inventory\",{},\"/admin/rebuild-inventory\"),await refreshStatus({force:!0})}})}function promptBenchmarkRun(){openPresetActionModal({title:\"Run Benchmark\",body:\"This runs the upstream <code>bash scripts/bench.sh</code> helper against the currently active backend and streams the full output into Audit Logs.\",confirmLabel:\"Run Benchmark\",confirmClass:\"blue\",onConfirm:async()=>{await post(\"/admin/benchmark\",{},\"/admin/benchmark\"),setAuditMsg(\"Benchmark started. Output is streaming to Audit Logs.\")}})}function promptReportRun(){openPresetActionModal({title:\"Run Report\",body:\"This runs the upstream <code>bash scripts/report.sh</code> helper for the current runtime and streams the generated report into Audit Logs.\",confirmLabel:\"Run Report\",confirmClass:\"blue\",onConfirm:async()=>{await post(\"/admin/run-report\",{},\"/admin/run-report\"),setAuditMsg(\"Run Report started. Output is streaming to Audit Logs.\")}})}async function startUpdateFlow(scope){const normalized=\"club3090\"===scope?\"club3090\":\"controller\";await post(\"/admin/update\",{scope:normalized},`/admin/update ${normalized}`),setAuditMsg(\"club3090\"===normalized?\"Club-3090 migration launched. Output is streaming to Audit Logs.\":\"Admin script update launched. Output is streaming to Audit Logs.\")}function promptUpdateRun(){openActionChoiceModal({title:\"Run Update\",body:\"Choose which update flow to launch. The admin-script option refreshes only the control layer. The Club-3090 option runs the full <code>--migrate</code> pass. Both stream their output into Audit Logs right away.\",choices:[{label:\"Update Admin Script\",className:\"blue\",onClick:async()=>{await startUpdateFlow(\"controller\")}},{label:\"Migrate Club-3090\",className:\"orange\",onClick:async()=>{await startUpdateFlow(\"club3090\")}}]})}function promptModelInstall(variant){openPresetActionModal({title:`Download ${escapeHtml(variant?.model_id||\"model\")} assets`,body:`${escapeHtml(variantDisplayLabel(variant))} is not ready on disk yet. Download the required assets now?<br><br>${escapeHtml(variant?.install_reason||\"This preset needs additional model files before it can run.\")}`,detail:variant?.install_command||\"\",confirmLabel:\"Download\",confirmClass:\"green\",onConfirm:async()=>{await post(\"/admin/model-install\",{model_id:variant.model_id,variant_id:variant.variant_id,install_command:variant.install_command},`/admin/model-install ${variant.model_id} ${variant.variant_id}`),await refreshStatus({force:!0})}})}async function switchInventoryVariant(selector){const variant=inventoryVariants().find(item=>variantSelector(item)===selector||item.variant_id===selector);if(!variant)return void alert(\"Preset not found in runtime inventory.\");if(\"ready\"!==variant.install_state)return void promptModelInstall(variant);const target=scopeTargetForVariant(variant);if(!target)return void alert(scopeBlockReason(variant));const label=variantDisplayLabel(variant),targetLabel=\"GLOBAL\"===target.id?\"single\"===variant.scope_kind?\"Global scope across every available GPU\":\"dual\"===variant.scope_kind?\"Global scope across every available GPU pair\":\"Global scope\":`${target.id}${target.gpu_indices?` on GPUs ${(target.gpu_indices||[]).join(\", \")}`:\"\"}`;confirm(`Apply ${label} to ${targetLabel}? This will stop any overlapping runtime currently using those GPUs.`)&&(openRuntimeLogsAtPoint(chooseVariantLogInstanceId(target,selector),\"\"),await post(\"/admin/switch\",{instance_id:target.id,mode:selector},`/admin/switch ${target.id} ${label}`),await refreshStatus({force:!0}))}function focusVariantFailure(selector){openRuntimeLogsAtPoint(chooseVariantLogInstanceId(scopeTargetForVariant(inventoryVariants().find(item=>variantSelector(item)===selector)||{}),selector),bestFailureLogQuery(currentSwitchFailure()))}function promptVariantStop(selector,booting=!1){const variant=inventoryVariants().find(item=>variantSelector(item)===selector),label=variantDisplayLabel(variant||{upstream_tag:selector}),target=scopeTargetForVariant(variant||{});openPresetActionModal({title:booting?\"Interrupt Preset Boot\":\"Stop Active Preset\",body:booting?`Interrupt <code>${escapeHtml(label)}</code> before it reaches Active and kill the container${\"GLOBAL\"===target?.id?\"s\":\"\"}?`:`Stop <code>${escapeHtml(label)}</code> and kill the running container${\"GLOBAL\"===target?.id?\"s\":\"\"}?`,confirmLabel:booting?\"Interrupt\":\"Stop\",confirmClass:\"rose\",onConfirm:async()=>{openRuntimeLogsAtPoint(chooseVariantLogInstanceId(target,selector),\"\"),await post(\"/admin/power\",{action:\"stop_container\",instance_id:target?.id||null,mode:selector},`/admin/power stop_container ${target&&target.id||\"GLOBAL\"} ${label}`),await refreshStatus({force:!0})}})}function promptRemoveSummaryPreset(modelId,selector){confirm(`Remove ${selector} from the cached summary list?`)&&(removeSummaryEntry(modelId,selector),renderDynamicPresetModels())}async function stopAllSummaryPresets(){const targets=summaryRunningTargets().filter(item=>item.instance_id&&item.mode);if(targets.length&&confirm(`Stop all ${targets.length} running preset${1===targets.length?\"\":\"s\"}?`)){presetSummaryCache.restartTargets=targets,savePresetSummaryCache();for(const target of targets)await post(\"/admin/power\",{action:\"stop_container\",instance_id:target.instance_id,mode:target.mode},`/admin/power stop_container ${target.instance_id} ${target.mode}`);await refreshStatus({force:!0})}}async function restartAllSummaryPresets(){const targets=Array.isArray(presetSummaryCache.restartTargets)?presetSummaryCache.restartTargets:[];if(targets.length){for(const target of targets)await post(\"/admin/switch\",{instance_id:target.instance_id,mode:target.mode},`/admin/switch ${target.instance_id} ${target.mode}`);presetSummaryCache.restartTargets=[],savePresetSummaryCache(),await refreshStatus({force:!0})}}function renderSummaryActionBar(){return summaryRunningTargets().filter(item=>item.instance_id&&item.mode).length?'<div class=\"summary-action-bar\"><button class=\"btn red\" onclick=\"stopAllSummaryPresets()\">Stop All</button></div>':Array.isArray(presetSummaryCache.restartTargets)&&presetSummaryCache.restartTargets.length?'<div class=\"summary-action-bar\"><button class=\"btn green\" onclick=\"restartAllSummaryPresets()\">Restart All</button></div>':\"\"}function modelFamilyHasActivePreset(modelVariants){const activeSelectors=new Set(runtimeStatsRows(lastStatus).filter(row=>row&&row.running).map(row=>String(row?.selector||row?.mode||\"\")));return(modelVariants||[]).some(variant=>activeSelectors.has(String(variantSelector(variant)||\"\")))}function renderSummaryVariantCard(variant,modelId){const selector=variantSelector(variant),target=scopeTargetForVariant(variant),switchJob=currentSwitchJob(),switchTarget=String(switchJob.target||\"\"),targetId=String(target?.id||\"\"),failed=!(String(currentSwitchFailure().mode||\"\")!==selector||runtimeStatsRows(lastStatus).some(row=>String(row?.mode||\"\")===selector)||targetId&&switchTarget&&switchTarget!==targetId),switching=!(!switchJob.active||String(switchJob.mode||\"\")!==selector||targetId&&switchTarget&&switchTarget!==targetId),active=runtimeActiveForVariant(selector,target)&&!switching&&!failed,buttonLabel=switching?\"Booting...\":active?\"Stop\":failed?\"Restart\":\"Apply\",buttonClass=switching?\"amber\":active||failed?\"rose\":\"blue\",action=active?`promptVariantStop('${escapeJs(selector)}', false)`:switching?`promptVariantStop('${escapeJs(selector)}', true)`:`switchInventoryVariant('${escapeJs(selector)}')`,stateClass=switching?\"state-booting\":active?\"state-active\":failed?\"state-error\":\"state-summary-inactive\",stateLabel=switching?\"booting\":active?\"active\":failed?\"error\":\"inactive\";return`<div class=\"summary-preset-card${active||switching?\"\":\" summary-preset-card-inactive\"}\"><div class=\"summary-preset-head\"><div class=\"summary-preset-title\">${escapeHtml(variantDisplayLabel(variant))}</div><div class=\"preset-actions\">${renderIconButton({title:\"Remove from summary\",action:`promptRemoveSummaryPreset('${escapeJs(modelId)}','${escapeJs(selector)}')`,icon:\"delete\"})}</div></div><div class=\"badge-row\"><span class=\"state-badge ${stateClass}\">${escapeHtml(stateLabel)}</span>${failed?\"\":`<span class=\"status-badge ${badgeClass(\"status\",variant.status_kind)}\">${escapeHtml(statusLabel(variant))}</span>`}</div><div class=\"summary-preset-meta\">${escapeHtml(variant.best_for||variant.quality_summary||\"Cached preset\")}</div><div class=\"variant-actions\"><button class=\"btn ${buttonClass}\" onclick=\"${action}\">${escapeHtml(buttonLabel)}</button></div></div>`}function renderSummaryModelBody(model,modelVariants){const entries=summaryEntriesForModel(model.model_id),bySelector=new Map(modelVariants.map(variant=>[variantSelector(variant),variant])),cards=entries.map(entry=>bySelector.get(String(entry.selector||\"\"))).filter(Boolean).slice(0,5).map(variant=>renderSummaryVariantCard(variant,model.model_id));return cards.length?cards.join(\"\"):'<div class=\"empty-variant-note\">No cached presets for this model yet. Active and booting presets will appear here automatically.</div>'}function renderVariantCard(variant){const selector=variantSelector(variant),target=scopeTargetForVariant(variant),installJob=lastStatus?.model_install_job||{},switchJob=currentSwitchJob(),failure=currentSwitchFailure(),switchTarget=String(switchJob.target||\"\"),targetId=String(target?.id||\"\"),failed=!(String(failure.mode||\"\")!==selector||runtimeStatsRows(lastStatus).some(row=>String(row?.mode||\"\")===selector)||targetId&&switchTarget&&switchTarget!==targetId),switching=!(!switchJob.active||String(switchJob.mode||\"\")!==selector||targetId&&switchTarget&&switchTarget!==targetId),active=runtimeActiveForVariant(selector,target)&&!switching&&!failed,ready=\"ready\"===variant.install_state,installing=!!installJob.active&&installJob.model_id===variant.model_id&&installJob.variant_id===variant.variant_id,disabled=ready&&!target||installing,bootSeconds=switchJobElapsedSeconds(switchJob),buttonLabel=installing?\"Installing...\":switching?`Booting for ${bootSeconds}s...`:ready?active?\"Stop\":failed?\"Restart\":\"Apply\":\"Download\",buttonClass=installing?\"green\":switching?\"amber\":ready?active||failed?\"rose\":\"blue\":\"green\",launchSeconds=active?launchSecondsForVariant(selector,target):0,stateClass=switching?\"state-booting\":active?\"state-active\":failed?\"state-error\":badgeClass(\"state\",variant.install_state),stateLabel=switching?\"booting\":active?\"active\":failed?\"error\":installStateLabel(variant),stateAttrs=failed?` role=\"button\" tabindex=\"0\" title=\"Open the relevant runtime log lines\" onclick=\"focusVariantFailure('${escapeJs(selector)}')\"`:\"\",caveat=variant.caveats?`<div class=\"variant-caveat\"><strong>Caveats:</strong> ${escapeHtml(variant.caveats)}</div>`:\"\",installNote=!ready&&variant.install_reason?`<div class=\"variant-install-note\"><strong>Install:</strong> ${escapeHtml(variant.install_reason)}</div>`:\"\",failureNote=failed?`<div class=\"variant-install-note error-note\"><strong>Last error:</strong> ${escapeHtml(String(failure.error||\"\").split(\"\\n\")[0]||\"Preset launch failed.\")}</div>`:\"\",statusBadge=failed?\"\":`<span class=\"status-badge ${badgeClass(\"status\",variant.status_kind)}\">${escapeHtml(statusLabel(variant))}</span>`,footer=launchSeconds?`<div class=\"variant-footer\"><span class=\"variant-launch-time\">${escapeHtml(formatElapsedLaunch(launchSeconds))}</span></div>`:'<div class=\"variant-footer\"></div>',action=ready?active?`promptVariantStop('${escapeJs(selector)}', false)`:switching?`promptVariantStop('${escapeJs(selector)}', true)`:`switchInventoryVariant('${escapeJs(selector)}')`:`switchInventoryVariant('${escapeJs(selector)}')`;return`<div class=\"variant-card${active?\" active-variant\":\"\"}\"><div class=\"variant-card-head\"><div class=\"variant-card-title\">${escapeHtml(variantDisplayLabel(variant))}</div><div class=\"badge-row\"><span class=\"state-badge ${stateClass}\"${stateAttrs}>${escapeHtml(stateLabel)}</span>${statusBadge}</div></div><div class=\"variant-meta\"><strong>Best for:</strong> ${escapeHtml(variant.best_for||\"No summary yet.\")}</div><div class=\"variant-meta\"><strong>Max ctx:</strong> ${escapeHtml(variantMaxCtx(variant))} <strong>Engine:</strong> ${escapeHtml(prettyEngineName(variant.engine))} <strong>Drafter:</strong> ${escapeHtml(variant.drafter||\"none\")} <strong>KV:</strong> ${escapeHtml(variant.kv_format||\"n/a\")}</div>${caveat}${installNote}${failureNote}<div class=\"variant-actions\"><button class=\"btn ${buttonClass}\" ${disabled?\"disabled\":\"\"} onclick=\"${action}\">${escapeHtml(buttonLabel)}</button></div>${footer}</div>`}function renderVariantGroup(title,rows){const items=sortInventoryVariants(rows),body=items.length?`<div class=\"variant-grid\">${items.map(renderVariantCard).join(\"\")}</div>`:'<div class=\"empty-variant-note\">No presets discovered for this category.</div>';return`<div class=\"variant-group\"><h4>${escapeHtml(`${title} (${items.length} Presets)`)}</h4>${body}</div>`}function renderDynamicPresetModels(){ensureDynamicPresetLayout(),hydrateSelectedPresetModel(),renderPresetModelSelector();const host=$(\"modelPresetGrid\");if(!host)return;const variants=inventoryVariants(),models=inventoryModels();if(!models.length)return void(host.innerHTML='<div class=\"model-card\"><div class=\"empty-variant-note\">No runtime inventory data was found. Rebuild the Dynamic Model DB to rescan the upstream checkout.</div></div>');const visibleModels=selectedPresetModelId?models.filter(model=>String(model.model_id||\"\")===selectedPresetModelId):models;host.innerHTML=`${visibleModels.map(model=>{const modelVariants=variants.filter(row=>row.model_id===model.model_id),selected=String(model.model_id||\"\")===selectedPresetModelId,familyActive=modelFamilyHasActivePreset(modelVariants),presetCount=modelVariants.length,summaryBody=renderSummaryModelBody(model,modelVariants),body=selected?`<div class=\"variant-groups\">${renderVariantGroup(\"Single GPU Docker Presets\",modelVariants.filter(row=>\"single\"===row.category))}${renderVariantGroup(\"Dual GPU Docker Presets\",modelVariants.filter(row=>\"dual\"===row.category))}${renderVariantGroup(\"Multi GPU Docker Presets\",modelVariants.filter(row=>\"multi\"===row.category))}${renderVariantGroup(\"Experimental Docker Presets\",modelVariants.filter(row=>\"experimental\"===row.category))}</div>`:summaryBody;return`<div class=\"model-card${selected?\" selected-model-card\":\" collapsed-model-card\"}${familyActive?\" model-card-active-family\":\"\"}\"><div class=\"model-card-head\"><div><h3>${escapeHtml(model.display_name||model.model_id)} (${presetCount} Presets)</h3><div class=\"model-summary\">${escapeHtml(model.summary||\"No summary available yet.\")}</div></div><div class=\"badge-row\"><span class=\"state-badge ${badgeClass(\"state\",model.installed_state)}\">${escapeHtml(String(model.installed_state||\"unknown\"))}</span></div></div>${body}</div>`}).join(\"\")}${selectedPresetModelId?\"\":renderSummaryActionBar()}`}function renderModelInstallStatus(){const target=$(\"presetJobSummary\");if(!target)return;const job=lastStatus?.model_install_job||{};job.active?target.textContent=`Model install running for ${job.model_id||\"unknown model\"} (${job.variant_id||\"preset\"}). Output is streaming to Audit Logs.`:\"success\"!==job.status?\"failed\"!==job.status?target.textContent=\"Downloads started from this tab stream into Audit Logs and automatically rebuild the Dynamic Model DB on success.\":target.textContent=`${job.summary||\"Model install failed.\"}`:target.textContent=`${job.summary||\"Model install completed successfully.\"}`}function chatConversationTitle(conversation){return String(conversation?.title||\"\").trim()||CHAT_UNTITLED_TITLE}function setSelectOptions(select,html){if(!select)return!1;const nextHtml=String(html||\"\");if(select.dataset.renderedOptions===nextHtml)return!1;const currentValue=String(select.value||\"\");return select.innerHTML=nextHtml,select.dataset.renderedOptions=nextHtml,currentValue&&[...select.options].some(option=>option.value===currentValue)&&(select.value=currentValue),!0}function chatConversationFolders(){return[...new Set(chatConversations().map(conversation=>normalizeConversationFolder(conversation.folder)).filter(Boolean))].sort((left,right)=>left.localeCompare(right))}function renderConversationSelector(){const select=$(\"chatConversationSelect\");if(!select)return;const rows=chatConversations(),rootRows=rows.filter(conversation=>!conversation.folder),grouped=chatConversationFolders().map(folder=>({folder,rows:rows.filter(conversation=>normalizeConversationFolder(conversation.folder)===folder)})).filter(group=>group.rows.length),html=[];rootRows.forEach(conversation=>{html.push(`<option value=\"${escapeHtml(conversation.id)}\" ${conversation.id===chatState.activeConversationId?\"selected\":\"\"}>${escapeHtml(chatConversationTitle(conversation))}</option>`)}),grouped.forEach(group=>{html.push(`<optgroup label=\"${escapeHtml(group.folder)}\">${group.rows.map(conversation=>`<option value=\"${escapeHtml(conversation.id)}\" ${conversation.id===chatState.activeConversationId?\"selected\":\"\"}>${escapeHtml(chatConversationTitle(conversation))}</option>`).join(\"\")}</optgroup>`)}),setSelectOptions(select,html.join(\"\")),chatState.activeConversationId&&[...select.options].some(option=>option.value===chatState.activeConversationId)&&(select.value=chatState.activeConversationId),select.disabled=!!chatState.busy}function selectChatConversation(value){const nextId=String(value||\"\");nextId&&nextId!==chatState.activeConversationId&&!chatState.busy&&(persistChatConversationState(),chatState.activeConversationId=nextId,syncChatStateFromActiveConversation(),saveChatState(),renderChatUi())}function createNewConversation(){if(chatState.busy)return;persistChatConversationState();const conversation=createChatConversation({},activeChatConversation());conversation.title=CHAT_UNTITLED_TITLE,conversation.autoNamed=!1,conversation.compactionSequence=1,conversation.compactedFromId=\"\",chatState.conversations=[...chatConversations(),conversation],chatState.activeConversationId=conversation.id,syncChatStateFromActiveConversation(),saveChatState(),renderChatUi(),setTimeout(()=>$(\"chatInput\")?.focus(),0)}function ensureConversationEditorModal(){if($(\"chatConversationModal\"))return;const modal=document.createElement(\"div\");modal.id=\"chatConversationModal\",modal.className=\"club-modal hidden\",modal.innerHTML=`<div class=\"club-modal-card conversation-modal-card\" role=\"dialog\" aria-modal=\"true\" aria-labelledby=\"chatConversationTitle\"><div class=\"panel-head\"><h2 id=\"chatConversationTitle\">Edit Conversation</h2><button class=\"iconbtn danger-iconbtn\" title=\"Close\" aria-label=\"Close\" onclick=\"closeConversationEditorModal()\">${svgIcon(\"close\")}</button></div><div class=\"formgrid\"><label>Conversation Name<input id=\"chatConversationName\" placeholder=\"${escapeHtml(CHAT_UNTITLED_TITLE)}\" /></label><label>Folder<input id=\"chatConversationFolder\" list=\"chatConversationFolderList\" placeholder=\"optional subfolder\" pattern=\"[A-Za-z0-9 _-]*\" /></label></div><datalist id=\"chatConversationFolderList\"></datalist><div class=\"preset-help\">Use only letters, numbers, spaces, <code>-</code>, and <code>_</code>.</div><div class=\"preset-form-actions\"><button class=\"btn blue\" onclick=\"closeConversationEditorModal()\">Cancel</button><button class=\"btn green\" onclick=\"saveConversationEditorModal()\">OK</button></div><div class=\"msg\" id=\"chatConversationModalMsg\"></div></div>`,modal.addEventListener(\"click\",event=>{event.target===modal&&closeConversationEditorModal()}),document.body.appendChild(modal)}function openConversationEditorModal(){if(chatState.busy)return;ensureConversationEditorModal();const conversation=activeChatConversation();conversation&&($(\"chatConversationName\").value=chatConversationTitle(conversation),$(\"chatConversationFolder\").value=normalizeConversationFolder(conversation.folder),$(\"chatConversationFolderList\").innerHTML=chatConversationFolders().map(folder=>`<option value=\"${escapeHtml(folder)}\"></option>`).join(\"\"),setElementMsg(\"chatConversationModalMsg\",\"\"),$(\"chatConversationModal\").classList.remove(\"hidden\"))}function closeConversationEditorModal(){ensureConversationEditorModal(),$(\"chatConversationModal\").classList.add(\"hidden\")}function saveConversationEditorModal(){const conversation=activeChatConversation();if(!conversation)return;const folderValue=String($(\"chatConversationFolder\")?.value||\"\").trim();if(!isValidConversationFolder(folderValue))return setElementMsg(\"chatConversationModalMsg\",\"Folder names may only use letters, numbers, spaces, - and _.\",\"error\");conversation.title=String($(\"chatConversationName\")?.value||\"\").trim()||CHAT_UNTITLED_TITLE,conversation.folder=normalizeConversationFolder(folderValue),conversation.autoNamed=!isUntitledConversationTitle(conversation.title),conversation.updatedAt=Date.now(),conversation.lastUsedAt=conversation.updatedAt,saveChatState(),renderChatUi(),closeConversationEditorModal()}function deleteActiveConversation(){if(chatState.busy)return;persistChatConversationState();const conversation=activeChatConversation();if(!conversation)return;if(!confirm(`Delete conversation \"${chatConversationTitle(conversation)}\"?`))return;let nextRows=chatConversations().filter(candidate=>candidate.id!==conversation.id);if(!nextRows.length){const replacement=createChatConversation({},conversation);replacement.title=CHAT_UNTITLED_TITLE,replacement.autoNamed=!1,replacement.compactionSequence=1,replacement.compactedFromId=\"\",nextRows=[replacement]}chatState.conversations=nextRows,chatState.activeConversationId=nextRows[0].id,syncChatStateFromActiveConversation(),saveChatState(),renderChatUi()}function fallbackConversationTitle(text,attachments=[]){const clean=String(text||\"\").replace(/\\s+/g,\" \").trim();return clean?clean.slice(0,48):attachments.length?`Files: ${attachments[0]?.name||\"attachment\"}`.slice(0,48):CHAT_UNTITLED_TITLE}function extractAdminChatText(payload){const response=payload?.response||{},choice=Array.isArray(response.choices)?response.choices[0]:null;return choice?.message?.content?String(choice.message.content):choice?.text?String(choice.text):\"\"}function parseConversationMetadataResult(text,fallbackTitleText,attachments=[]){const raw=String(text||\"\").trim();if(!raw)return{title:fallbackConversationTitle(fallbackTitleText,attachments),summary:\"\"};const fenced=raw.match(/```(?:json)?\\s*([\\s\\S]*?)```/i),candidate=fenced?fenced[1]:raw;try{const parsed=JSON.parse(candidate);return{title:String(parsed.title||\"\").trim()||fallbackConversationTitle(fallbackTitleText,attachments),summary:String(parsed.summary||\"\").trim()}}catch(e){return{title:raw.replace(/\\s+/g,\" \").split(/[.\\n]/)[0].trim().slice(0,48)||fallbackConversationTitle(fallbackTitleText,attachments),summary:raw.replace(/\\s+/g,\" \").trim().slice(0,220)}}}async function maybeAutoNameConversation(conversationId){const conversation=chatConversations().find(item=>item.id===conversationId),runtime=activeChatRuntime();if(!conversation||!runtime||conversation.autoNamed||chatConversationTitle(conversation)!==CHAT_UNTITLED_TITLE)return;const firstUser=(conversation.messages||[]).find(item=>\"user\"===item.role),firstAssistant=(conversation.messages||[]).find(item=>\"assistant\"===item.role);if(firstUser&&firstAssistant){try{const response=await fetch(\"/admin/chat\",{method:\"POST\",headers:{\"Content-Type\":\"application/json\"},body:JSON.stringify({instance_id:runtime.id||runtime.instance_id,mode:runtime.selector||runtime.mode,model:runtime.served_model_name||runtime.model_id,api_preset:\"\",params:{temperature:.2,top_p:.8,max_tokens:220},messages:[{role:\"system\",content:'Return only JSON with keys \"title\" and \"summary\". The title must stay under 8 words. The summary must be one short sentence describing the conversation purpose.'},{role:\"user\",content:`User message:\\n${firstUser.text||\"\"}\\n\\nAssistant reply:\\n${firstAssistant.text||\"\"}`}]})}),payload=await response.json(),parsed=parseConversationMetadataResult(response.ok&&payload.ok?extractAdminChatText(payload):\"\",firstUser.text||\"\",chatMessageAttachments(firstUser));conversation.title=parsed.title,conversation.summary=parsed.summary||conversation.summary||\"\"}catch(e){conversation.title=fallbackConversationTitle(firstUser.text||\"\",chatMessageAttachments(firstUser))}conversation.autoNamed=chatConversationTitle(conversation)!==CHAT_UNTITLED_TITLE,conversation.updatedAt=Date.now(),conversation.lastUsedAt=conversation.updatedAt,conversation.id===chatState.activeConversationId&&syncChatStateFromConversation(conversation),saveChatState(),renderChatUi()}}function parseContinuedConversationInfo(title){const text=chatConversationTitle({title}),match=text.match(/^(.*?)(?:\\s+\\(continued(?:\\s+(\\d+))?\\))$/i);return match?{baseTitle:String(match[1]||\"\").trim()||CHAT_UNTITLED_TITLE,sequence:Math.max(1,Number(match[2]||2)||2)}:{baseTitle:text,sequence:1}}function continuedConversationTitle(conversation){const info=parseContinuedConversationInfo(chatConversationTitle(conversation)),nextSequence=Math.max(2,Number(conversation?.compactionSequence||info.sequence||1)+1);return`${info.baseTitle} (continued ${nextSequence})`}function currentChatContextLimit(runtime){const preset=chatApiPresetOptions().find(item=>String(item?.name||\"\")===String(chatState.apiPresetName||\"\")),limits=[Number(runtime?.ctx_size_tokens||0),Number(preset?.params?.truncate_prompt_tokens||0)].filter(value=>Number.isFinite(value)&&value>0);return limits.length?Math.min(...limits):0}function estimateTextTokenCount(text){const clean=String(text||\"\").trim();return clean?Math.max(1,Math.ceil(clean.length/4)):0}function estimateAttachmentTokenCost(attachment){return attachment?\"image\"===attachment.kind?256:estimateTextTokenCount(chatAttachmentTextBlock(attachment))+8:0}function estimateMessageTokenCost(message){let total=estimateTextTokenCount(message?.text||\"\")+12;return chatMessageAttachments(message).forEach(attachment=>{total+=estimateAttachmentTokenCost(attachment)}),\"assistant\"===message?.role&&(total+=estimateTextTokenCount(chatMessageThinkingView(message).reasoningText)),total}function estimatedConversationTokenBaseline(messages=[]){return(messages||[]).reduce((sum,message)=>sum+estimateMessageTokenCost(message),0)}function measuredConversationTokenBaseline(runtime,conversation){const limit=currentChatContextLimit(runtime),measuredInput=Number(conversation?.lastInputTokens??runtime?.last_input_tokens??runtime?.last_total_tokens??0),measuredOutput=Number(conversation?.lastOutputTokens??runtime?.last_output_tokens??0),measuredTotal=Number(conversation?.lastTotalTokens??runtime?.last_total_tokens??0),estimatedBaseline=estimatedConversationTokenBaseline(conversation?.messages||chatState.messages||[]),baselineTokens=Math.max(measuredTotal||0,measuredInput+measuredOutput,estimatedBaseline),kvUsage=Number(conversation?.lastKvCacheUsagePct??runtime?.gpu_kv_cache_usage_pct??0),tokenPct=limit>0&&baselineTokens>0?baselineTokens/limit*100:0;return{baselineTokens,measuredPct:Math.max(Number.isFinite(kvUsage)&&kvUsage>0?kvUsage:0,tokenPct)}}function buildCompactedSystemPrompt(summary,originalPrompt){const parts=[\"Context from an earlier conversation was automatically compacted. Continue seamlessly without asking the user to repeat prior details unless something is genuinely ambiguous.\",`Compacted conversation summary:\\n${String(summary||\"\").trim()}`];return String(originalPrompt||\"\").trim()&&parts.push(`Original system prompt:\\n${String(originalPrompt).trim()}`),parts.join(\"\\n\\n\")}async function maybeCompactChatConversation(runtime,userMessage){if(!chatState.autoCompactEnabled||!(chatState.messages||[]).length)return;const limit=currentChatContextLimit(runtime);if(!limit)return;const baseConversation=activeChatConversation(),thresholdPct=clampChatCompactionThreshold(chatState.autoCompactThresholdPct),measured=measuredConversationTokenBaseline(runtime,baseConversation),projectedTokens=measured.baselineTokens+estimateMessageTokenCost(userMessage);if(Math.max(measured.measuredPct,projectedTokens/limit*100)<thresholdPct)return;setChatMsg(\"Compacting conversation context before sending...\");const summaryResponse=await fetch(\"/admin/chat\",{method:\"POST\",headers:{\"Content-Type\":\"application/json\"},body:JSON.stringify({instance_id:runtime.id||runtime.instance_id,mode:runtime.selector||runtime.mode,model:runtime.served_model_name||runtime.model_id,api_preset:\"\",params:{temperature:.2,top_p:.8,max_tokens:1200},messages:[{role:\"system\",content:\"Summarize the conversation so another assistant can continue it after a context compaction. Preserve the goal, key facts, decisions, code, unresolved work, and any exact strings that must be kept.\"},{role:\"user\",content:(chatState.messages||[]).map(message=>{const attachmentSummary=chatMessageAttachments(message).map(attachment=>\"image\"===attachment?.kind?`[image: ${attachment?.name||\"image\"}]`:`[file: ${attachment?.name||\"attachment\"}]`).join(\" \");return`${String(message.role||\"message\").toUpperCase()}: ${message.text||\"\"}${attachmentSummary?` ${attachmentSummary}`:\"\"}`}).join(\"\\n\\n\")}]})}),summary=extractAdminChatText(await summaryResponse.json())||\"Conversation summary unavailable.\";persistChatConversationState();const preset=chatApiPresetOptions().find(item=>String(item?.name||\"\")===String(chatState.apiPresetName||\"\")),nextConversation=createChatConversation({},baseConversation);nextConversation.compactedFromId=String(baseConversation?.id||\"\"),nextConversation.compactionSequence=Math.max(2,Number(baseConversation?.compactionSequence||1)+1),nextConversation.title=continuedConversationTitle(baseConversation),nextConversation.autoNamed=!0,nextConversation.summary=String(summary||\"\").trim(),nextConversation.apiPresetName=\"\",nextConversation.params=preset?normalizePresetParamsForChat(preset.params||{}):cloneChatParams(chatState.params),nextConversation.systemPrompt=buildCompactedSystemPrompt(summary,String(preset?preset.system_prompt||\"\":chatState.systemPrompt||\"\")),nextConversation.messages=[],nextConversation.attachments=[],chatState.conversations=[...chatConversations(),nextConversation],chatState.activeConversationId=nextConversation.id,syncChatStateFromActiveConversation(),saveChatState(),renderChatUi()}function chatPresetKey(runtime){return`${String(runtime?.id||runtime?.instance_id||\"\")}::${String(runtime?.selector||runtime?.mode||\"\")}`}function activeChatPresets(){return runtimeStatsRows(lastStatus).filter(runtime=>runtime&&runtime.running)}function activeChatRuntime(){const rows=activeChatPresets();if(!rows.length)return null;return rows.find(runtime=>chatPresetKey(runtime)===chatState.presetId)||rows[0]}function updateConversationRuntimeMetrics(conversation,runtime,payload={}){if(!conversation)return;const usage=payload?.usage||{};void 0!==usage.input_tokens&&(conversation.lastInputTokens=Number(usage.input_tokens||0)),void 0!==usage.output_tokens&&(conversation.lastOutputTokens=Number(usage.output_tokens||0)),void 0!==usage.tokens&&(conversation.lastTotalTokens=Number(usage.tokens||0)),void 0!==runtime?.ctx_size_tokens&&(conversation.lastCtxSizeTokens=Number(runtime.ctx_size_tokens||0)),void 0!==runtime?.gpu_kv_cache_usage_pct&&(conversation.lastKvCacheUsagePct=Number(runtime.gpu_kv_cache_usage_pct||0)),conversation.lastRuntimeRequestAt=Date.now()}function setChatMsg(text,tone=\"warning\"){setElementMsg(\"chatMsg\",text||\"\",tone)}function toggleChatOptionsMenu(force=null){chatOptionsMenuOpen=null===force?!chatOptionsMenuOpen:!!force,$(\"chatOptionsMenu\")&&$(\"chatOptionsMenu\").classList.toggle(\"hidden\",!chatOptionsMenuOpen)}function openChatSettingsPanel(){toggleChatOptionsMenu(!1),openChatSettingsModal()}function chatTemplateId(){return`chat-template-${Date.now()}-${Math.random().toString(36).slice(2,8)}`}function normalizePresetParamsForChat(params={}){const normalized={...defaultChatParams(),temperature:void 0!==params.temperature?String(params.temperature):\"\",top_p:void 0!==params.top_p?String(params.top_p):\"\",top_k:void 0!==params.top_k?String(params.top_k):\"\",min_p:void 0!==params.min_p?String(params.min_p):\"\",repetition_penalty:void 0!==params.repetition_penalty?String(params.repetition_penalty):\"\",presence_penalty:void 0!==params.presence_penalty?String(params.presence_penalty):\"\",frequency_penalty:void 0!==params.frequency_penalty?String(params.frequency_penalty):\"\",max_tokens:void 0!==params.max_tokens?String(params.max_tokens):void 0!==params.max_completion_tokens?String(params.max_completion_tokens):\"\",seed:void 0!==params.seed?String(params.seed):\"\"},template=params.chat_template_kwargs||{};return normalized.enable_thinking=!!template.enable_thinking,normalized.preserve_thinking=!!template.preserve_thinking,normalized}function ensureChatSettingsModal(){if($(\"chatSettingsModal\"))return;const modal=document.createElement(\"div\");modal.id=\"chatSettingsModal\",modal.className=\"club-modal hidden\",modal.innerHTML=`<div class=\"club-modal-card chat-settings-modal-card\" role=\"dialog\" aria-modal=\"true\" aria-labelledby=\"chatSettingsTitle\"><div class=\"panel-head\"><h2 id=\"chatSettingsTitle\">Chat Settings</h2><button class=\"iconbtn danger-iconbtn\" title=\"Close\" aria-label=\"Close\" onclick=\"closeChatSettingsModal()\">${svgIcon(\"close\")}</button></div><div class=\"preset-help\" id=\"chatSettingsPresetHint\"></div><div class=\"chat-settings-grid\"><label class=\"chat-settings-span-2\">System Prompt<textarea id=\"chatSystemPrompt\" placeholder=\"Optional system prompt for this conversation\"></textarea></label><div class=\"chat-settings-span-2\"><div class=\"chat-settings-template-row\"><input id=\"chatPromptTemplateName\" class=\"chat-settings-template-name\" placeholder=\"Template name\" /><select id=\"chatPromptTemplateSelect\" class=\"chat-settings-template-select\" aria-label=\"Choose template\"></select><div class=\"chat-settings-template-actions\"><button class=\"btn blue\" onclick=\"loadChatPromptTemplate()\">Load</button><button class=\"btn green\" onclick=\"saveChatPromptTemplate()\">Save Template</button><button class=\"btn red\" onclick=\"deleteChatPromptTemplate()\">Delete</button></div></div><div class=\"chat-settings-note chat-settings-template-note\">Templates are stored locally in this browser so you can save and reuse system prompts.</div><hr class=\"chat-settings-rule\" /></div><label>Temperature<input id=\"chatTemperature\" type=\"number\" step=\"0.01\" min=\"0\" max=\"2\" /></label><label>Top P<input id=\"chatTopP\" type=\"number\" step=\"0.01\" min=\"0\" max=\"1\" /></label><label>Top K<input id=\"chatTopK\" type=\"number\" step=\"1\" min=\"0\" /></label><label>Min P<input id=\"chatMinP\" type=\"number\" step=\"0.01\" min=\"0\" max=\"1\" /></label><label>Repeat Penalty<input id=\"chatRepetitionPenalty\" type=\"number\" step=\"0.01\" min=\"0\" max=\"4\" /></label><label>Presence Penalty<input id=\"chatPresencePenalty\" type=\"number\" step=\"0.01\" min=\"-2\" max=\"2\" /></label><label>Frequency Penalty<input id=\"chatFrequencyPenalty\" type=\"number\" step=\"0.01\" min=\"-2\" max=\"2\" /></label><label>Max Tokens<input id=\"chatMaxTokens\" type=\"number\" step=\"1\" min=\"1\" /></label><label>Enable Thinking<select id=\"chatEnableThinking\"><option value=\"false\">Off</option><option value=\"true\">On</option></select></label><label>Preserve Thinking<select id=\"chatPreserveThinking\"><option value=\"false\">Off</option><option value=\"true\">On</option></select></label><div class=\"chat-settings-span-2\"><hr class=\"chat-settings-rule\" /><div class=\"chat-settings-compact-block\"><div class=\"chat-settings-toggle-row\"><label class=\"toggle-switch\"><input id=\"chatAutoCompactEnabled\" type=\"checkbox\" onchange=\"updateChatCompactionThresholdLabel()\" /><span class=\"toggle-switch-track\"></span></label><span class=\"chat-settings-compact-title\">Automatically compact context when nearing max</span></div><div class=\"chat-threshold-row\"><span class=\"chat-settings-compact-threshold-label\">Threshold:</span><input id=\"chatAutoCompactThreshold\" type=\"range\" min=\"50\" max=\"95\" step=\"1\" value=\"95\" oninput=\"updateChatCompactionThresholdLabel()\" /><output id=\"chatAutoCompactThresholdValue\">95%</output></div><div class=\"chat-settings-note chat-settings-compact-description\">If about to run out of context, summarize the current chat and automatically recall the summary in a new conversation.</div></div></div></div><div class=\"preset-form-actions\"><button class=\"btn blue\" onclick=\"closeChatSettingsModal()\">Cancel</button><button class=\"btn green\" onclick=\"applyChatSettingsModal()\">Apply</button></div><div class=\"msg\" id=\"chatSettingsMsg\"></div></div>`,modal.addEventListener(\"click\",event=>{event.target===modal&&closeChatSettingsModal()}),document.body.appendChild(modal)}function setChatSettingsMsg(text,tone=\"warning\"){setElementMsg(\"chatSettingsMsg\",text||\"\",tone)}function renderChatPromptTemplateOptions(selectedId=\"\"){const select=$(\"chatPromptTemplateSelect\");if(!select)return;const rows=Array.isArray(chatState.promptTemplates)?[...chatState.promptTemplates].sort((left,right)=>String(left?.name||\"\").localeCompare(String(right?.name||\"\"))):[];select.innerHTML=`<option value=\"\">Choose Template</option>${rows.map(template=>`<option value=\"${escapeHtml(template.id)}\" ${template.id===selectedId?\"selected\":\"\"}>${escapeHtml(template.name||\"Template\")}</option>`).join(\"\")}`}function updateChatCompactionThresholdLabel(){const slider=$(\"chatAutoCompactThreshold\"),output=$(\"chatAutoCompactThresholdValue\"),enabled=!!$(\"chatAutoCompactEnabled\")?.checked;slider&&(slider.disabled=!enabled),output&&slider&&(output.value=`${clampChatCompactionThreshold(slider.value)}%`)}function loadChatPromptTemplate(){const template=(chatState.promptTemplates||[]).find(item=>item.id===$(\"chatPromptTemplateSelect\")?.value);if(!template)return setChatSettingsMsg(\"Select a prompt template first.\");$(\"chatPromptTemplateName\").value=template.name||\"\",$(\"chatSystemPrompt\").value=template.text||\"\",setChatSettingsMsg(`Loaded template \"${template.name}\".`)}function saveChatPromptTemplate(){const name=String($(\"chatPromptTemplateName\")?.value||\"\").trim(),text=String($(\"chatSystemPrompt\")?.value||\"\");if(!name)return setChatSettingsMsg(\"Template name is required.\",\"error\");if(!text.trim())return setChatSettingsMsg(\"Template text cannot be empty.\",\"error\");const existing=(chatState.promptTemplates||[]).find(item=>String(item.name||\"\").toLowerCase()===name.toLowerCase());if(existing)existing.name=name,existing.text=text,renderChatPromptTemplateOptions(existing.id);else{const template={id:chatTemplateId(),name,text};chatState.promptTemplates=[...chatState.promptTemplates||[],template],renderChatPromptTemplateOptions(template.id)}saveChatState(),setChatSettingsMsg(`Saved template \"${name}\".`)}function deleteChatPromptTemplate(){const template=(chatState.promptTemplates||[]).find(item=>item.id===$(\"chatPromptTemplateSelect\")?.value);if(!template)return setChatSettingsMsg(\"Select a template to delete.\");confirm(`Delete prompt template \"${template.name}\"?`)&&(chatState.promptTemplates=(chatState.promptTemplates||[]).filter(item=>item.id!==template.id),saveChatState(),renderChatPromptTemplateOptions(),$(\"chatPromptTemplateName\").value=\"\",setChatSettingsMsg(`Deleted template \"${template.name}\".`))}function populateChatSettingsInputs(values=chatState.params){ensureChatSettingsModal();const preset=chatApiPresetOptions().find(item=>String(item?.name||\"\")===String(chatState.apiPresetName||\"\")),sourceParams=preset?{...defaultChatParams(),...normalizePresetParamsForChat(preset.params||{})}:{...defaultChatParams(),...values||{}};chatSettingsDraft={usingPreset:!!preset},$(\"chatSettingsPresetHint\").innerHTML=preset?`Showing settings from API Preset <code>${escapeHtml(preset.name||\"Preset\")}</code>. Applying saves a Direct copy for this conversation and switches the selector to <code>Direct</code>.`:\"These Direct settings are stored locally with this conversation.\",$(\"chatSystemPrompt\").value=String(preset?preset.system_prompt||\"\":chatState.systemPrompt||\"\"),$(\"chatTemperature\").value=sourceParams.temperature||\"\",$(\"chatTopP\").value=sourceParams.top_p||\"\",$(\"chatTopK\").value=sourceParams.top_k||\"\",$(\"chatMinP\").value=sourceParams.min_p||\"\",$(\"chatRepetitionPenalty\").value=sourceParams.repetition_penalty||\"\",$(\"chatPresencePenalty\").value=sourceParams.presence_penalty||\"\",$(\"chatFrequencyPenalty\").value=sourceParams.frequency_penalty||\"\",$(\"chatMaxTokens\").value=sourceParams.max_tokens||\"\",$(\"chatEnableThinking\").value=sourceParams.enable_thinking?\"true\":\"false\",$(\"chatPreserveThinking\").value=sourceParams.preserve_thinking?\"true\":\"false\",$(\"chatAutoCompactEnabled\").checked=!1!==chatState.autoCompactEnabled,$(\"chatAutoCompactThreshold\").value=clampChatCompactionThreshold(chatState.autoCompactThresholdPct),$(\"chatPromptTemplateName\").value=\"\",renderChatPromptTemplateOptions(),updateChatCompactionThresholdLabel()}function openChatSettingsModal(){populateChatSettingsInputs(chatState.params),setChatSettingsMsg(\"\"),$(\"chatSettingsModal\").classList.remove(\"hidden\")}function closeChatSettingsModal(){ensureChatSettingsModal(),$(\"chatSettingsModal\").classList.add(\"hidden\"),chatSettingsDraft=null}function validateChatSettingNumber(label,raw,{min=null,max=null,integer=!1}={}){const text=String(raw??\"\").trim();if(!text)return\"\";const value=integer?Number.parseInt(text,10):Number(text);if(!Number.isFinite(value))throw new Error(`${label} must be a valid number.`);if(integer&&!Number.isInteger(value))throw new Error(`${label} must be a whole number.`);if(null!==min&&value<min)throw new Error(`${label} must be at least ${min}.`);if(null!==max&&value>max)throw new Error(`${label} must be at most ${max}.`);return String(value)}function applyChatSettingsModal(){try{chatState.params={...chatState.params,temperature:validateChatSettingNumber(\"Temperature\",$(\"chatTemperature\").value,{min:0,max:2}),top_p:validateChatSettingNumber(\"Top P\",$(\"chatTopP\").value,{min:0,max:1}),top_k:validateChatSettingNumber(\"Top K\",$(\"chatTopK\").value,{min:0,integer:!0}),min_p:validateChatSettingNumber(\"Min P\",$(\"chatMinP\").value,{min:0,max:1}),repetition_penalty:validateChatSettingNumber(\"Repeat Penalty\",$(\"chatRepetitionPenalty\").value,{min:0,max:4}),presence_penalty:validateChatSettingNumber(\"Presence Penalty\",$(\"chatPresencePenalty\").value,{min:-2,max:2}),frequency_penalty:validateChatSettingNumber(\"Frequency Penalty\",$(\"chatFrequencyPenalty\").value,{min:-2,max:2}),max_tokens:validateChatSettingNumber(\"Max Tokens\",$(\"chatMaxTokens\").value,{min:1,integer:!0}),enable_thinking:\"true\"===$(\"chatEnableThinking\").value,preserve_thinking:\"true\"===$(\"chatPreserveThinking\").value},chatState.systemPrompt=String($(\"chatSystemPrompt\").value||\"\"),chatState.autoCompactEnabled=!!$(\"chatAutoCompactEnabled\").checked,chatState.autoCompactThresholdPct=clampChatCompactionThreshold($(\"chatAutoCompactThreshold\").value),chatSettingsDraft?.usingPreset&&(chatState.apiPresetName=\"\"),persistChatConversationState(),setChatSettingsMsg(\"\"),closeChatSettingsModal(),renderChatUi()}catch(e){setChatSettingsMsg(String(e||\"\"),\"error\")}}function ensureMcpManagerModal(){if($(\"mcpManagerModal\"))return;const modal=document.createElement(\"div\");modal.id=\"mcpManagerModal\",modal.className=\"club-modal hidden\",modal.innerHTML=`<div class=\"club-modal-card\" role=\"dialog\" aria-modal=\"true\" aria-labelledby=\"mcpManagerTitle\"><div class=\"panel-head\"><h2 id=\"mcpManagerTitle\">MCP Servers</h2><button class=\"iconbtn danger-iconbtn\" title=\"Close\" aria-label=\"Close\" onclick=\"closeMcpManagerModal()\">${svgIcon(\"close\")}</button></div><div class=\"preset-help\">Add stdio MCP servers here to expose tools to the local chat interface. New servers are only saved after the control layer can successfully initialize and list their tools.</div><div class=\"formgrid\"><label>Server Name<input id=\"mcpServerName\" placeholder=\"filesystem\" /></label><label>Command<input id=\"mcpServerCommand\" placeholder=\"npx -y @modelcontextprotocol/server-filesystem /path\" /></label></div><div class=\"preset-form-actions\"><button class=\"btn green\" onclick=\"saveMcpServerFromForm()\">Save Server</button></div><div class=\"msg\" id=\"mcpManagerMsg\"></div><div class=\"panel\" style=\"margin-top:12px\"><h2>Configured MCP Servers</h2><div id=\"mcpServerList\" class=\"api-grid\"></div></div></div>`,modal.addEventListener(\"click\",event=>{event.target===modal&&closeMcpManagerModal()}),document.body.appendChild(modal)}function setMcpManagerMsg(text,tone=\"warning\"){setElementMsg(\"mcpManagerMsg\",text||\"\",tone)}function resetMcpServerForm(){mcpManagerState.editingId=\"\",$(\"mcpServerName\")&&($(\"mcpServerName\").value=\"\"),$(\"mcpServerCommand\")&&($(\"mcpServerCommand\").value=\"\"),setMcpManagerMsg(\"\")}function renderMcpServerList(){const host=$(\"mcpServerList\");if(!host)return;const rows=Array.isArray(mcpManagerState.servers)?mcpManagerState.servers:[];host.innerHTML=rows.map(server=>{const tools=Array.isArray(server.tools)?server.tools:[],toolText=tools.length?tools.map(tool=>tool.name).join(\", \"):\"connected\"===server.status?\"no tools reported\":server.error||\"not connected\";return`<div class=\"api-card\"><div class=\"api-card-head\"><h3>${escapeHtml(server.name||server.id)}<br><span class=\"label\">${escapeHtml(server.status||\"unknown\")} · ${server.enabled?\"enabled\":\"disabled\"}</span></h3><span class=\"preset-actions\"><button class=\"iconbtn\" title=\"Edit\" onclick=\"editMcpServer('${escapeJs(server.id)}')\">${svgIcon(\"edit\")}</button><button class=\"iconbtn\" title=\"Delete\" onclick=\"deleteMcpServer('${escapeJs(server.id)}')\">${svgIcon(\"delete\")}</button></span></div><p>${escapeHtml(server.command||\"\")}</p><p class=\"label\">tools: ${escapeHtml(toolText)}</p><div class=\"variant-actions\"><button class=\"btn ${server.enabled?\"amber\":\"green\"}\" onclick=\"toggleMcpServer('${escapeJs(server.id)}', ${server.enabled?\"false\":\"true\"})\">${server.enabled?\"Disable\":\"Enable\"}</button></div></div>`}).join(\"\")||'<div class=\"value\">No MCP servers configured yet.</div>'}async function loadMcpServers(){ensureMcpManagerModal();const response=await fetch(\"/admin/mcp\"),payload=await response.json();if(!response.ok||!payload.ok)throw new Error(payload.error||\"Failed to load MCP servers\");mcpManagerState.servers=Array.isArray(payload.servers)?payload.servers:[],renderMcpServerList()}function editMcpServer(serverId){const row=(mcpManagerState.servers||[]).find(server=>server.id===serverId);row&&(mcpManagerState.editingId=serverId,$(\"mcpServerName\").value=row.name||\"\",$(\"mcpServerCommand\").value=row.command||\"\",setMcpManagerMsg(`Editing MCP server \"${row.name||row.id}\".`))}async function saveMcpServerFromForm(){try{const response=await fetch(\"/admin/mcp\",{method:\"POST\",headers:{\"Content-Type\":\"application/json\"},body:JSON.stringify({action:\"save\",id:mcpManagerState.editingId||\"\",name:$(\"mcpServerName\")?.value||\"\",command:$(\"mcpServerCommand\")?.value||\"\",enabled:!0})}),payload=await response.json();if(!response.ok||!payload.ok)throw new Error(payload.error||\"Failed to save MCP server\");mcpManagerState.servers=Array.isArray(payload.servers)?payload.servers:[],resetMcpServerForm(),renderMcpServerList(),setMcpManagerMsg(\"Saved MCP server.\")}catch(e){setMcpManagerMsg(String(e||\"\"),\"error\")}}async function deleteMcpServer(serverId){if(!confirm(`Delete MCP server ${serverId}?`))return;const response=await fetch(\"/admin/mcp\",{method:\"POST\",headers:{\"Content-Type\":\"application/json\"},body:JSON.stringify({action:\"delete\",id:serverId})}),payload=await response.json();if(!response.ok||!payload.ok)return setMcpManagerMsg(payload.error||\"Failed to delete MCP server\");mcpManagerState.servers=Array.isArray(payload.servers)?payload.servers:[],renderMcpServerList()}async function toggleMcpServer(serverId,enabled){const response=await fetch(\"/admin/mcp\",{method:\"POST\",headers:{\"Content-Type\":\"application/json\"},body:JSON.stringify({action:\"toggle\",id:serverId,enabled:!!enabled})}),payload=await response.json();if(!response.ok||!payload.ok)return setMcpManagerMsg(payload.error||\"Failed to toggle MCP server\",\"error\");mcpManagerState.servers=Array.isArray(payload.servers)?payload.servers:[],renderMcpServerList(),setMcpManagerMsg(enabled?\"Enabled MCP server.\":\"Disabled MCP server.\")}async function openMcpManagerModal(){toggleChatOptionsMenu(!1),ensureMcpManagerModal(),$(\"mcpManagerModal\").classList.remove(\"hidden\"),resetMcpServerForm(),setMcpManagerMsg(\"Loading MCP servers...\");try{await loadMcpServers(),setMcpManagerMsg(\"\")}catch(e){setMcpManagerMsg(String(e||\"\"),\"error\")}}function closeMcpManagerModal(){ensureMcpManagerModal(),$(\"mcpManagerModal\").classList.add(\"hidden\")}function openChatTab(){activateTab(\"chat\",!1),renderChatUi()}function selectChatPreset(value){chatState.presetId=String(value||\"\"),persistChatConversationState(),renderChatUi()}function selectChatApiPreset(value){chatState.apiPresetName=String(value||\"\"),persistChatConversationState(),renderChatUi()}function handleChatInputResize(){const box=$(\"chatInput\");if(!box)return;box.style.height=\"auto\";box.style.height=`${Math.max(88,Math.min(176,box.scrollHeight))}px`}function handleChatInputChange(){handleChatInputResize();const runtime=activeChatRuntime(),hasDraft=!!String($(\"chatInput\")?.value||\"\").trim()||!!(chatState.attachments||[]).length;$(\"chatSendBtn\")&&($(\"chatSendBtn\").disabled=!runtime||!chatState.busy&&!hasDraft)}function handleChatInputKeydown(event){event&&\"Enter\"===event.key&&(event.ctrlKey||event.metaKey)&&(event.preventDefault(),sendChatMessage())}function renderChatPresetSelector(){const select=$(\"chatPresetSelect\");if(!select)return;const rows=activeChatPresets();if(!rows.length)return select.innerHTML='<option value=\"\">No active presets</option>',select.disabled=!0,void(chatState.presetId=\"\");rows.some(runtime=>chatPresetKey(runtime)===chatState.presetId)||(chatState.presetId=chatPresetKey(rows[0])),select.disabled=!1;setSelectOptions(select,rows.map(runtime=>{const key=chatPresetKey(runtime),label=`${variantDisplayLabel({upstream_tag:runtime.selector||runtime.mode})} | ${runtime.id||runtime.instance_id}`;return`<option value=\"${escapeHtml(key)}\" ${key===chatState.presetId?\"selected\":\"\"}>${escapeHtml(label)}</option>`}).join(\"\")),chatState.presetId&&[...select.options].some(option=>option.value===chatState.presetId)&&(select.value=chatState.presetId)}function chatApiPresetOptions(){const presetCatalog=lastStatus?.presets||{};return[...presetCatalog.defaults||[],...presetCatalog.custom||[]]}function renderChatApiPresetSelector(){const select=$(\"chatApiPresetSelect\");if(!select)return;const presets=chatApiPresetOptions(),valid=new Set(presets.map(preset=>String(preset?.name||\"\")));chatState.apiPresetName&&!valid.has(chatState.apiPresetName)&&(chatState.apiPresetName=\"\");setSelectOptions(select,`<option value=\"\" ${chatState.apiPresetName?\"\":\"selected\"}>Direct</option>${presets.map(preset=>{const name=String(preset?.name||\"\"),label=`${name}${preset?.locked?\" - default\":\"\"}`;return`<option value=\"${escapeHtml(name)}\" ${name===chatState.apiPresetName?\"selected\":\"\"}>${escapeHtml(label)}</option>`}).join(\"\")}`),select.value=chatState.apiPresetName||\"\"}function chatRuntimeSupportsVision(runtime){return!!runtime&&!!String(runtime.vision||\"\").trim()}function chatAttachmentId(){return`chat-att-${Date.now()}-${Math.random().toString(36).slice(2,8)}`}function chatAttachmentKindClass(attachment){return\"image\"===attachment?.kind?\"chat-attachment-image\":\"chat-attachment-text\"}function renderChatAttachments(){const host=$(\"chatAttachmentRow\");host&&(host.innerHTML=(chatState.attachments||[]).map((attachment,index)=>`<div class=\"chat-attachment-pill ${chatAttachmentKindClass(attachment)}\"><button class=\"chat-attachment-remove\" title=\"Remove attachment\" aria-label=\"Remove attachment\" onclick=\"removeChatAttachment(${index})\">x</button><span class=\"chat-attachment-name\">${escapeHtml(attachment?.name||`attachment-${index+1}`)}</span></div>`).join(\"\"))}function removeChatAttachment(index){chatState.attachments=(chatState.attachments||[]).filter((_,itemIndex)=>itemIndex!==index),persistChatConversationState(),renderChatAttachments()}function chatTranscriptIsNearBottom(host=$(\"chatTranscript\")){return!host||host.scrollHeight-(host.scrollTop+host.clientHeight)<=36}function ensureChatTranscriptBehavior(){const host=$(\"chatTranscript\");host&&\"1\"!==host.dataset.followBound&&(host.dataset.followBound=\"1\",host.addEventListener(\"scroll\",()=>{chatTranscriptAutoFollow=chatTranscriptIsNearBottom(host)}))}function chatMessageAttachments(message){return Array.isArray(message?.attachments)?message.attachments:Array.isArray(message?.images)?message.images.map(image=>({kind:\"image\",name:image?.name||\"image\",url:image?.url||\"\"})):[]}function normalizeMarkdownUrl(url,{allowDataImage=!0}={}){const raw=String(url||\"\").trim();if(!raw)return\"\";if(allowDataImage&&/^data:image\\//i.test(raw))return raw;if(/^mailto:/i.test(raw))return raw;try{const parsed=new URL(raw,window.location.origin);return/^https?:$/i.test(parsed.protocol)||/^blob:$/i.test(parsed.protocol)?parsed.href:\"\"}catch(e){return\"\"}}function markdownUrlParts(candidate){let url=String(candidate||\"\"),trailing=\"\";for(;url&&/[),.;!?]$/.test(url)&&!/\\([^)]+\\)$/.test(url);)trailing=url.slice(-1)+trailing,url=url.slice(0,-1);return{url,trailing}}function urlLooksLikeImage(url){return/^data:image\\//i.test(url)||/\\.(avif|gif|jpe?g|png|svg|webp)$/i.test(url.split(\"?\")[0])}function urlLooksLikeVideo(url){return/\\.(mp4|m4v|mov|webm|ogv)$/i.test(url.split(\"?\")[0])}function urlLooksLikeAudio(url){return/\\.(mp3|wav|ogg|m4a|flac)$/i.test(url.split(\"?\")[0])}function youtubeEmbedUrl(url){try{const parsed=new URL(url);if(/youtube\\.com$/i.test(parsed.hostname)||/www\\.youtube\\.com$/i.test(parsed.hostname)){const videoId=parsed.searchParams.get(\"v\");if(videoId)return`https://www.youtube.com/embed/${encodeURIComponent(videoId)}`}if(/youtu\\.be$/i.test(parsed.hostname)){const videoId=parsed.pathname.replace(/\\//g,\"\").trim();if(videoId)return`https://www.youtube.com/embed/${encodeURIComponent(videoId)}`}}catch(e){}return\"\"}function richEmbedForUrl(url,altText=\"\"){const safeUrl=normalizeMarkdownUrl(url);if(!safeUrl)return\"\";if(urlLooksLikeImage(safeUrl))return`<div class=\"chat-rich-embed\"><img class=\"chat-markdown-image\" src=\"${escapeHtml(safeUrl)}\" alt=\"${escapeHtml(altText||\"image\")}\" /></div>`;if(urlLooksLikeVideo(safeUrl))return`<div class=\"chat-rich-embed\"><video class=\"chat-markdown-media\" controls preload=\"metadata\" src=\"${escapeHtml(safeUrl)}\"></video></div>`;if(urlLooksLikeAudio(safeUrl))return`<div class=\"chat-rich-embed\"><audio class=\"chat-markdown-media\" controls preload=\"metadata\" src=\"${escapeHtml(safeUrl)}\"></audio></div>`;const youtubeUrl=youtubeEmbedUrl(safeUrl);return youtubeUrl?`<div class=\"chat-rich-embed\"><iframe class=\"chat-markdown-media\" src=\"${escapeHtml(youtubeUrl)}\" title=\"${escapeHtml(altText||\"embedded media\")}\" loading=\"lazy\" allowfullscreen></iframe></div>`:\"\"}function applyBalancedUnderscoreFormatting(text){return String(text||\"\").replace(/(^|[^A-Za-z0-9])___([^\\s_](?:.*?[^\\s_])?)___(?=[^A-Za-z0-9]|$)/g,(_,prefix,body)=>`${prefix}<strong><em>${body}</em></strong>`).replace(/(^|[^A-Za-z0-9])__([^\\s_](?:.*?[^\\s_])?)__(?=[^A-Za-z0-9]|$)/g,(_,prefix,body)=>`${prefix}<strong>${body}</strong>`).replace(/(^|[^A-Za-z0-9])_([^\\s_]+)_(?=[^A-Za-z0-9]|$)/g,(_,prefix,body)=>`${prefix}<em>${body}</em>`)}function renderMarkdownInline(text){const tokens=[],stash=html=>{const token=`@@CHATMDTOKEN${tokens.length}@@`;return tokens.push(html),token};let value=String(text||\"\");value=value.replace(/`([^`]+)`/g,(_,code)=>stash(`<code>${escapeHtml(code)}</code>`)),value=value.replace(/!\\[([^\\]]*)\\]\\(([^)\\s]+)(?:\\s+\"([^\"]*)\")?\\)/g,(_,altText,url)=>stash(`<img class=\"chat-markdown-image\" src=\"${escapeHtml(normalizeMarkdownUrl(url)||\"\")}\" alt=\"${escapeHtml(altText||\"image\")}\" />`)),value=value.replace(/\\[([^\\]]+)\\]\\(([^)\\s]+)(?:\\s+\"([^\"]*)\")?\\)/g,(_,label,url)=>{const safeUrl=normalizeMarkdownUrl(url,{allowDataImage:!1});return safeUrl?stash(`<a href=\"${escapeHtml(safeUrl)}\" target=\"_blank\" rel=\"noreferrer\">${escapeHtml(label)}</a>${richEmbedForUrl(safeUrl,label)}`):escapeHtml(label)}),value=value.replace(/((?:https?:\\/\\/|mailto:)[^\\s<]+)/g,candidate=>{const{url,trailing}=markdownUrlParts(candidate),safeUrl=normalizeMarkdownUrl(url,{allowDataImage:!1});return safeUrl?`${stash(`<a href=\"${escapeHtml(safeUrl)}\" target=\"_blank\" rel=\"noreferrer\">${escapeHtml(url)}</a>${richEmbedForUrl(safeUrl,url)}`)}${escapeHtml(trailing)}`:escapeHtml(candidate)});let html=applyBalancedUnderscoreFormatting(escapeHtml(value).replace(/~~([^~]+)~~/g,\"<del>$1</del>\").replace(/\\*\\*([^*]+)\\*\\*/g,\"<strong>$1</strong>\").replace(/\\*([^*\\n]+)\\*/g,\"<em>$1</em>\"));return html=html.replace(/\\n/g,\"<br />\"),tokens.forEach((token,index)=>{html=html.replaceAll(`@@CHATMDTOKEN${index}@@`,token)}),html}function splitMarkdownTableRow(line){let text=String(line||\"\").trim();return text.startsWith(\"|\")&&(text=text.slice(1)),text.endsWith(\"|\")&&(text=text.slice(0,-1)),text.split(\"|\").map(cell=>cell.trim())}function markdownToHtml(text){const source=String(text||\"\").replace(/\\r\\n/g,\"\\n\").replace(/\\r/g,\"\\n\");if(!source)return\"\";const lines=source.split(\"\\n\"),blocks=[];let index=0;for(;index<lines.length;){const line=String(lines[index]||\"\"),trimmed=line.trim();if(!trimmed){index+=1;continue}const fenceMatch=trimmed.match(/^```(?:\\s*(.*?))?\\s*$/);if(fenceMatch){const inlineTitle=String(fenceMatch[1]||\"\").trim(),rawCodeLines=[];for(index+=1;index<lines.length&&!/^```/.test(String(lines[index]||\"\").trim());)rawCodeLines.push(lines[index]),index+=1;index<lines.length&&(index+=1);let title=inlineTitle,codeLines=rawCodeLines;if(!title&&rawCodeLines.length>1){const firstLine=String(rawCodeLines[0]||\"\").trim();firstLine&&(title=firstLine,codeLines=rawCodeLines.slice(1))}title||(title=\"text\"),blocks.push(`<pre class=\"chat-code\"><div class=\"chat-code-lang\">${escapeHtml(title)}</div><code>${escapeHtml(codeLines.join(\"\\n\"))}</code></pre>`);continue}if(index+1<lines.length&&line.includes(\"|\")&&lines[index+1].includes(\"|\")&&splitMarkdownTableRow(lines[index+1]).every(cell=>/^:?-{3,}:?$/.test(cell))){const headerCells=splitMarkdownTableRow(line),rows=[];for(index+=2;index<lines.length&&String(lines[index]||\"\").includes(\"|\");)rows.push(splitMarkdownTableRow(lines[index])),index+=1;blocks.push(`<table><thead><tr>${headerCells.map(cell=>`<th>${renderMarkdownInline(cell)}</th>`).join(\"\")}</tr></thead><tbody>${rows.map(cells=>`<tr>${cells.map(cell=>`<td>${renderMarkdownInline(cell)}</td>`).join(\"\")}</tr>`).join(\"\")}</tbody></table>`);continue}const headingMatch=trimmed.match(/^(#{1,6})\\s+(.+)$/);if(headingMatch){const level=headingMatch[1].length;blocks.push(`<h${level}>${renderMarkdownInline(headingMatch[2])}</h${level}>`),index+=1;continue}if(/^([-*_]\\s*){3,}$/.test(trimmed)){blocks.push(\"<hr />\"),index+=1;continue}if(/^>\\s?/.test(trimmed)){const quoteLines=[];for(;index<lines.length&&/^>\\s?/.test(String(lines[index]||\"\").trim());)quoteLines.push(String(lines[index]||\"\").replace(/^\\s*>\\s?/,\"\")),index+=1;blocks.push(`<blockquote>${quoteLines.map(quote=>renderMarkdownInline(quote)).join(\"<br />\")}</blockquote>`);continue}if(/^(\\s*)([-+*]|\\d+\\.)\\s+/.test(line)){const ordered=/\\d+\\./.test(trimmed),listItems=[];for(;index<lines.length&&/^(\\s*)([-+*]|\\d+\\.)\\s+/.test(String(lines[index]||\"\"));)listItems.push(String(lines[index]||\"\").replace(/^(\\s*)([-+*]|\\d+\\.)\\s+/,\"\")),index+=1;blocks.push(`<${ordered?\"ol\":\"ul\"}>${listItems.map(item=>`<li>${renderMarkdownInline(item)}</li>`).join(\"\")}</${ordered?\"ol\":\"ul\"}>`);continue}const paragraphLines=[];for(;index<lines.length&&String(lines[index]||\"\").trim();)paragraphLines.push(lines[index]),index+=1;blocks.push(`<p>${renderMarkdownInline(paragraphLines.join(\"\\n\"))}</p>`)}return blocks.join(\"\")}function renderChatTranscript(forceFollow=!1){const host=$(\"chatTranscript\");if(!host)return;ensureChatTranscriptBehavior();const shouldFollow=forceFollow||chatTranscriptAutoFollow||chatTranscriptIsNearBottom(host),turns=[];let currentTurn=null;(chatState.messages||[]).forEach((message,messageIndex)=>{const entry={message,messageIndex};if(\"user\"===message.role||!currentTurn)return currentTurn={number:turns.length+1,messages:[entry]},void turns.push(currentTurn);currentTurn.messages.push(entry)});const nextHtml=turns.map(turn=>{const turnMessages=turn.messages.map(({message,messageIndex})=>{const title=\"assistant\"===message.role?`${message.modelLabel||\"Model\"}:`:\"user\"===message.role?\"User:\":\"System:\",thinkingView=\"assistant\"===message.role?chatMessageThinkingView(message):{reasoningText:\"\",contentText:String(message?.text||\"\")},body=markdownToHtml(thinkingView.contentText||\"\"),thinkingActive=chatMessageThinkingActive(message),thinkingExpanded=void 0!==message.thinkingExpanded?!!message.thinkingExpanded:thinkingActive,thinkingDuration=formatChatThinkingDuration(thinkingActive?Date.now()-Number(message.thinkingStartedAt||Date.now()):message.thinkingDurationMs),thinkingTitle=thinkingDuration?`${thinkingActive?\"Thinking\":\"Thought\"} for ${thinkingDuration}`:thinkingActive?\"Thinking\":\"Thought\",thinkingSubtitle=thinkingActive?\"Reasoning is streaming live.\":thinkingExpanded?\"Tap to collapse.\":\"Tap to expand.\",thinkingCard=thinkingView.reasoningText?`<div class=\"chat-thinking-card ${thinkingActive?\"thinking-live\":\"thinking-done\"} ${thinkingExpanded?\"expanded\":\"collapsed\"}\"><button type=\"button\" class=\"chat-thinking-toggle\" onclick=\"toggleChatReasoning(${messageIndex})\" aria-expanded=\"${thinkingExpanded?\"true\":\"false\"}\"><span class=\"chat-thinking-copy\"><span class=\"chat-thinking-title\">${escapeHtml(thinkingTitle)}</span><span class=\"chat-thinking-subtitle\">${escapeHtml(thinkingSubtitle)}</span></span><span class=\"chat-thinking-chevron\">${svgIcon(thinkingExpanded?\"chevron-up\":\"chevron-right\")}</span></button>${thinkingExpanded?`<div class=\"chat-thinking-body\">${markdownToHtml(thinkingView.reasoningText)}</div>`:\"\"}</div>`:\"\",attachments=chatMessageAttachments(message),imageAttachments=attachments.filter(attachment=>\"image\"===attachment?.kind),fileAttachments=attachments.filter(attachment=>\"image\"!==attachment?.kind),files=fileAttachments.length?`<div class=\"chat-message-attachments\">${fileAttachments.map(attachment=>`<div class=\"chat-message-attachment ${chatAttachmentKindClass(attachment)}\"><span class=\"chat-attachment-name\">${escapeHtml(attachment?.name||\"file\")}</span></div>`).join(\"\")}</div>`:\"\",images=imageAttachments.length?`<div class=\"chat-inline-images\">${imageAttachments.map(image=>`<img src=\"${image.url}\" alt=\"${escapeHtml(image.name||\"image\")}\" />`).join(\"\")}</div>`:\"\";return`<div class=\"chat-message chat-${message.role}\"><div class=\"chat-message-title\">${escapeHtml(title)}</div><div class=\"chat-message-body\">${thinkingCard}${body}${files}${images}</div></div>`}).join(\"\");return`<div class=\"chat-turn\"><div class=\"chat-turn-divider\"><span class=\"chat-turn-label\">Turn #${turn.number}</span></div>${turnMessages}</div>`}).join(\"\");host.innerHTML!==nextHtml&&(host.innerHTML=nextHtml),shouldFollow&&(host.scrollTop=host.scrollHeight),syncChatThinkingTicker()}function renderChatRuntimeStatsLegacy(){const host=$(\"chatRuntimeStats\");if(!host)return;const runtime=activeChatRuntime();host.innerHTML=runtime?`<div class=\"value\">${escapeHtml(runtime.display_name||runtime.id||\"Runtime\")}</div><div class=\"value-subline\">${escapeHtml([runtime.mode||\"-\",runtime.container||\"no container\",Array.isArray(runtime.gpu_indices)&&runtime.gpu_indices.length?`GPUs ${runtime.gpu_indices.join(\", \")}`:\"GPU mapping unavailable\"].join(\" · \"))}</div><div class=\"value-subline\">${formatLastStatusCard(runtime,{}).replace(/<[^>]+>/g,\" \")}</div>${null!==runtime.prompt_tps&&void 0!==runtime.prompt_tps?`<div class=\"value-subline\">${escapeHtml(`prompt ${formatNumber(runtime.prompt_tps,2)} tk/s`)}</div>`:\"\"}${null!==runtime.generation_tps&&void 0!==runtime.generation_tps?`<div class=\"value-subline\">${escapeHtml(`generation ${formatNumber(runtime.generation_tps,2)} tk/s`)}</div>`:\"\"}${null!==runtime.last_total_tokens&&void 0!==runtime.last_total_tokens?`<div class=\"value-subline\">${escapeHtml(`last total ${formatCompactInt(runtime.last_total_tokens)} tokens`)}</div>`:\"\"}`:'<div class=\"empty-variant-note\">Start a preset to test it from the local chat interface.</div>'}function renderChatRuntimeStats(){const host=$(\"chatRuntimeStats\");if(!host)return;const runtime=activeChatRuntime();host.innerHTML=runtime?formatGenerationRuntimeCard(runtime):'<div class=\"empty-variant-note\">Start a preset to test it from the local chat interface.</div>'}function toggleChatStatsCollapsed(){chatState.statsCollapsed=!chatState.statsCollapsed,persistChatConversationState(),renderChatUi()}function renderChatUi(){const toggle=$(\"chatSettingsToggle\");toggle&&(toggle.innerHTML=svgIcon(\"gear\")),$(\"chatOptionsMenu\")&&$(\"chatOptionsMenu\").classList.toggle(\"hidden\",!chatOptionsMenuOpen),renderConversationSelector(),renderChatPresetSelector(),renderChatApiPresetSelector(),renderChatAttachments(),renderChatTranscript(),renderChatRuntimeStats(),handleChatInputResize();const runtime=activeChatRuntime();if($(\"chatStatsCard\")&&$(\"chatStatsCard\").classList.toggle(\"collapsed\",!!chatState.statsCollapsed),$(\"chatStatsToggleBtn\")&&($(\"chatStatsToggleBtn\").innerHTML=svgIcon(chatState.statsCollapsed?\"chevron-down\":\"chevron-up\")),$(\"chatSendBtn\")){const hasDraft=!!String($(\"chatInput\")?.value||\"\").trim()||!!(chatState.attachments||[]).length;$(\"chatSendBtn\").disabled=!runtime||!chatState.busy&&!hasDraft,$(\"chatSendBtn\").classList.toggle(\"is-stop\",!!chatState.busy),$(\"chatSendBtn\").innerHTML=svgIcon(chatState.busy?\"stop\":\"send\")}$(\"chatAttachBtn\")&&($(\"chatAttachBtn\").disabled=chatState.busy),$(\"chatMicBtn\")&&($(\"chatMicBtn\").disabled=chatState.busy,$(\"chatMicBtn\").classList.toggle(\"recording\",!!chatRecognition?.__active)),$(\"chatConversationNewBtn\")&&($(\"chatConversationNewBtn\").disabled=chatState.busy),$(\"chatConversationEditBtn\")&&($(\"chatConversationEditBtn\").disabled=chatState.busy),$(\"chatConversationDeleteBtn\")&&($(\"chatConversationDeleteBtn\").disabled=chatState.busy),syncHeaderChatButtonAlignment()}function chatTextAttachmentName(prefix=\"pasted\"){return`${prefix}-${(new Date).toISOString().replace(/[:.]/g,\"-\")}.md`}function isTextAttachmentFile(file){const type=String(file?.type||\"\").toLowerCase(),name=String(file?.name||\"\").toLowerCase();return type.startsWith(\"text/\")||/(json|javascript|typescript|yaml|xml|csv|x-sh)/.test(type)||/\\.(txt|md|markdown|json|jsonl|csv|tsv|ya?ml|xml|html?|css|jsx?|tsx?|mjs|cjs|py|sh|bash|zsh|log|ini|cfg|conf)$/i.test(name)}function readFileAsDataUrl(file){return new Promise((resolve,reject)=>{const reader=new FileReader;reader.onload=()=>resolve(String(reader.result||\"\")),reader.onerror=()=>reject(reader.error||new Error(`Failed to read ${file?.name||\"file\"}.`)),reader.readAsDataURL(file)})}async function uploadChatImageAttachment(file,source=\"file\"){const response=await fetch(\"/admin/chat-attachments\",{method:\"POST\",headers:{\"Content-Type\":\"application/json\"},body:JSON.stringify({kind:\"image\",name:file?.name||\"image\",mime:file?.type||\"image/*\",source,data_url:await readFileAsDataUrl(file)})}),payload=await response.json();if(!response.ok||!payload?.ok||!payload?.attachment)throw new Error(payload?.error||`Failed to upload ${file?.name||\"image\"}.`);return cloneChatAttachment(payload.attachment)}async function buildChatAttachmentsFromFiles(files,source=\"file\"){const additions=[];for(const file of files||[])if(file)if(String(file.type||\"\").toLowerCase().startsWith(\"image/\"))additions.push(await uploadChatImageAttachment(file,source));else{if(!isTextAttachmentFile(file))throw new Error(`Unsupported attachment type: ${file.name||\"file\"}. Attach text files or images only.`);additions.push({id:chatAttachmentId(),kind:\"text\",name:file.name||`attachment-${additions.length+1}.txt`,mime:file.type||\"text/plain\",text:await file.text(),source})}return additions}function addChatAttachments(additions){Array.isArray(additions)&&additions.length&&(chatState.attachments=[...chatState.attachments||[],...additions],persistChatConversationState(),renderChatAttachments())}function openChatAttachmentPicker(){chatState.busy||$(\"chatAttachmentInput\")?.click()}async function handleChatAttachmentSelect(event){const files=Array.from(event?.target?.files||[]);if(files.length)try{addChatAttachments(await buildChatAttachmentsFromFiles(files)),setChatMsg(\"\")}catch(e){setChatMsg(String(e||\"\"))}finally{event?.target&&(event.target.value=\"\")}}async function handleChatPaste(event){const clipboard=event?.clipboardData;if(!clipboard)return;const files=Array.from(clipboard.files||[]).filter(Boolean);if(files.length){event.preventDefault();try{addChatAttachments(await buildChatAttachmentsFromFiles(files,\"paste\")),setChatMsg(\"\")}catch(e){setChatMsg(String(e||\"\"))}return}const text=String(clipboard.getData(\"text/plain\")||\"\");text.length<1024||(event.preventDefault(),addChatAttachments([{id:chatAttachmentId(),kind:\"text\",name:chatTextAttachmentName(),mime:\"text/markdown\",text,source:\"paste\"}]),setChatMsg(\"Attached the pasted text as a Markdown file.\"))}function speechRecognitionCtor(){return window.SpeechRecognition||window.webkitSpeechRecognition||null}function appendChatInputText(text){const input=$(\"chatInput\");if(!input)return;const current=String(input.value||\"\");input.value=current?`${current}${/\\s$/.test(current)?\"\":\" \"}${text}`:text,input.dispatchEvent(new Event(\"input\",{bubbles:!0}))}function ensureChatRecognition(){if(chatRecognition)return chatRecognition;const Ctor=speechRecognitionCtor();if(!Ctor)return null;const recognition=new Ctor;return recognition.continuous=!0,recognition.interimResults=!1,recognition.lang=navigator.language||\"en-US\",recognition.onstart=()=>{recognition.__active=!0,setChatMsg(\"Listening for dictation...\"),renderChatUi()},recognition.onend=()=>{recognition.__active=!1,chatState.busy||setChatMsg(\"\"),renderChatUi()},recognition.onerror=event=>{recognition.__active=!1,setChatMsg(`Voice dictation error: ${event?.error||\"unknown error\"}`),renderChatUi()},recognition.onresult=event=>{const chunks=[];for(let index=event.resultIndex;index<event.results.length;index+=1){const result=event.results[index];result?.isFinal&&chunks.push(String(result[0]?.transcript||\"\").trim())}const text=chunks.filter(Boolean).join(\" \");text&&appendChatInputText(text)},chatRecognition=recognition,recognition}function toggleChatDictation(){const recognition=ensureChatRecognition();if(recognition)try{recognition.__active?recognition.stop():recognition.start()}catch(e){setChatMsg(String(e||\"Unable to toggle voice dictation.\"))}else setChatMsg(\"Voice dictation is not available in this browser.\")}function chatAttachmentTextBlock(attachment){return`Attached file: ${attachment?.name||\"attachment\"}\\n\\n${attachment?.text||\"\"}`}function activeChatRequestParams(){const preset=chatApiPresetOptions().find(item=>String(item?.name||\"\")===String(chatState.apiPresetName||\"\"));return preset?{...defaultChatParams(),...normalizePresetParamsForChat(preset.params||{})}:cloneChatParams(chatState.params)}function chatMessageReasoningText(message){return String(message?.reasoningText||message?.reasoning_content||message?.reasoning||\"\")}function splitThinkingBlocks(text){const blocks=[],content=String(text||\"\").replace(/<(think|thinking)>([\\s\\S]*?)<\\/\\1>/gi,(_,_tag,body)=>{const clean=String(body||\"\").trim();return clean&&blocks.push(clean),\"\\n\\n\"});return{reasoningText:blocks.join(\"\\n\\n\").trim(),contentText:content.replace(/\\n{3,}/g,\"\\n\\n\").trim()}}function chatMessageThinkingView(message){const inline=splitThinkingBlocks(message?.text||\"\"),direct=chatMessageReasoningText(message).trim(),parts=[];return direct&&parts.push(direct),inline.reasoningText&&!parts.includes(inline.reasoningText)&&parts.push(inline.reasoningText),{reasoningText:parts.join(\"\\n\\n\").trim(),contentText:inline.reasoningText?inline.contentText:String(message?.text||\"\")}}function clampChatThinkingDurationMs(value){const numeric=Number(value);return!Number.isFinite(numeric)||numeric<0?0:Math.round(numeric)}function formatChatThinkingDuration(value){const ms=clampChatThinkingDurationMs(value);if(!ms)return\"\";const seconds=ms/1e3,digits=seconds>=10?0:1,formatted=trimFormattedNumber(seconds.toFixed(digits));return`${formatted} second${\"1\"===formatted?\"\":\"s\"}`}function chatMessageThinkingActive(message){return!!message?.thinkingLive}function finalizeChatThinkingState(message,collapse=!0){message&&(message.thinkingStartedAt?message.thinkingDurationMs=clampChatThinkingDurationMs(Date.now()-Number(message.thinkingStartedAt||0)):message.thinkingDurationMs=clampChatThinkingDurationMs(message.thinkingDurationMs),message.thinkingLive=!1,message.thinkingDone=!!chatMessageThinkingView(message).reasoningText,collapse&&message.thinkingDone&&(message.thinkingExpanded=!1))}function syncChatThinkingTicker(){const needsTicker=!!chatState.busy&&(chatState.messages||[]).some(message=>chatMessageThinkingActive(message));needsTicker&&!chatThinkingTicker?chatThinkingTicker=setInterval(()=>{renderChatTranscript()},250):!needsTicker&&chatThinkingTicker&&(clearInterval(chatThinkingTicker),chatThinkingTicker=null)}function toggleChatReasoning(messageIndex){const idx=Number(messageIndex);if(!Number.isInteger(idx)||idx<0)return;const message=(chatState.messages||[])[idx];if(!message||!chatMessageThinkingView(message).reasoningText)return;const expanded=void 0!==message.thinkingExpanded?!!message.thinkingExpanded:chatMessageThinkingActive(message);message.thinkingExpanded=!expanded,persistChatConversationState(),renderChatTranscript()}function buildChatRequestMessages(messages=chatState.messages||[]){const preserveThinking=!!activeChatRequestParams().preserve_thinking;return(messages||[]).map(message=>{if(\"user\"!==message.role){const view=\"assistant\"===message.role?chatMessageThinkingView(message):{reasoningText:\"\",contentText:String(message?.text||\"\")},payload={role:message.role,content:view.contentText||\"\"};return\"assistant\"===message.role&&preserveThinking&&view.reasoningText&&(payload.reasoning_content=view.reasoningText),payload}const attachments=chatMessageAttachments(message),content=[];return message.text&&content.push({type:\"text\",text:message.text}),attachments.forEach(attachment=>{\"image\"===attachment?.kind&&attachment?.url?content.push({type:\"image_url\",image_url:{url:attachment.url}}):\"text\"===attachment?.kind&&attachment?.text&&content.push({type:\"text\",text:chatAttachmentTextBlock(attachment)})}),content.length?1===content.length&&\"text\"===content[0].type?{role:message.role,content:content[0].text}:{role:message.role,content}:null}).filter(Boolean)}function parseChatStreamFrame(frame){const lines=String(frame||\"\").split(/\\r?\\n/);let eventName=\"message\";const payloadLines=[];for(const line of lines)line&&(line.startsWith(\"event:\")?eventName=line.slice(6).trim():line.startsWith(\"data:\")&&payloadLines.push(line.slice(5).trimStart()));if(!payloadLines.length)return null;const raw=payloadLines.join(\"\\n\");if(\"[DONE]\"===raw)return null;try{return{eventName,payload:JSON.parse(raw)}}catch(e){return{eventName,payload:{text:raw}}}}function stopChatGeneration(){if(chatRequestController){setChatMsg(\"Stopping generation...\");try{chatRequestController.abort()}catch(e){}}}async function sendChatMessage(){if(chatState.busy)return void stopChatGeneration();const runtime=activeChatRuntime(),input=$(\"chatInput\"),text=String(input?.value||\"\").trim(),pendingAttachments=[...chatState.attachments||[]];if(!runtime)return setChatMsg(\"Start a preset before using local chat.\");if(!text&&!pendingAttachments.length)return;if(!chatRuntimeSupportsVision(runtime)&&pendingAttachments.some(attachment=>\"image\"===attachment?.kind))return setChatMsg(\"The selected container does not advertise vision support, so image attachments are disabled for this request.\");const userMessage={role:\"user\",text,attachments:pendingAttachments};try{await maybeCompactChatConversation(runtime,userMessage)}catch(e){return setChatMsg(String(e||\"\"),\"error\")}const assistantMessage={role:\"assistant\",text:\"\",reasoningText:\"\",thinkingStartedAt:0,thinkingDurationMs:0,thinkingLive:!1,thinkingDone:!1,thinkingExpanded:!0,modelLabel:runtime.served_model_name||runtime.model_id||runtime.mode||\"Model\"},shouldAutoNameConversation=0===(chatState.messages||[]).length,requestHistory=[...chatState.messages||[],userMessage];chatState.messages=[...requestHistory,assistantMessage],chatState.attachments=[],chatState.busy=!0,chatTranscriptAutoFollow=!0,input&&(input.value=\"\"),persistChatConversationState(),renderChatUi(),renderChatTranscript(!0),setChatMsg(\"Generating message...\");const assistantIndex=chatState.messages.length-1;try{const requestBody={instance_id:runtime.id||runtime.instance_id,mode:runtime.selector||runtime.mode,model:runtime.served_model_name||runtime.model_id,messages:buildChatRequestMessages(requestHistory),params:{...chatState.params},api_preset:chatState.apiPresetName||\"\"};chatRequestController=new AbortController;const raw=await fetch(\"/admin/chat-stream\",{method:\"POST\",headers:{\"Content-Type\":\"application/json\"},body:JSON.stringify(requestBody),signal:chatRequestController.signal});if(!raw.ok||!raw.body){let errorText=\"Chat request failed\";try{errorText=(await raw.json()).error||errorText}catch(e){}throw new Error(errorText)}const reader=raw.body.getReader(),decoder=new TextDecoder(\"utf-8\");let buffer=\"\",streamFinished=!1;for(;;){const{value,done}=await reader.read();buffer+=decoder.decode(value||new Uint8Array,{stream:!done});const frames=buffer.split(\"\\n\\n\");buffer=frames.pop()||\"\";for(const frame of frames){const event=parseChatStreamFrame(frame);if(event)if(\"delta\"===event.eventName)chatMessageThinkingActive(chatState.messages[assistantIndex])&&finalizeChatThinkingState(chatState.messages[assistantIndex]),chatState.messages[assistantIndex].text+=String(event.payload?.text||\"\"),renderChatTranscript(!0);else if(\"reasoning\"===event.eventName){const assistant=chatState.messages[assistantIndex];assistant.thinkingStartedAt||(assistant.thinkingStartedAt=Date.now()),assistant.thinkingLive=!0,assistant.thinkingDone=!1,assistant.thinkingExpanded=!0,assistant.reasoningText+=String(event.payload?.text||\"\"),assistant.thinkingDurationMs=clampChatThinkingDurationMs(Date.now()-Number(assistant.thinkingStartedAt||Date.now())),renderChatTranscript(!0)}else if(\"tool\"===event.eventName)chatMessageThinkingActive(chatState.messages[assistantIndex])&&finalizeChatThinkingState(chatState.messages[assistantIndex]),setChatMsg(event.payload?.message||`Running tool ${event.payload?.name||\"\"}...`);else if(\"status\"===event.eventName)setChatMsg(String(event.payload?.message||\"\"));else{if(\"error\"===event.eventName)throw new Error(event.payload?.error||event.payload?.message||\"Chat stream failed.\");if(\"done\"===event.eventName){chatMessageThinkingActive(chatState.messages[assistantIndex])&&finalizeChatThinkingState(chatState.messages[assistantIndex]),updateConversationRuntimeMetrics(activeChatConversation(),runtime,event.payload||{}),streamFinished=!0,setChatMsg(\"\");break}}}if(done||streamFinished)break}if(!streamFinished&&buffer.trim()){const event=parseChatStreamFrame(buffer);if(\"delta\"===event?.eventName)chatMessageThinkingActive(chatState.messages[assistantIndex])&&finalizeChatThinkingState(chatState.messages[assistantIndex]),chatState.messages[assistantIndex].text+=String(event.payload?.text||\"\"),renderChatTranscript(!0);else if(\"reasoning\"===event?.eventName){const assistant=chatState.messages[assistantIndex];assistant.thinkingStartedAt||(assistant.thinkingStartedAt=Date.now()),assistant.thinkingLive=!0,assistant.thinkingDone=!1,assistant.thinkingExpanded=!0,assistant.reasoningText+=String(event.payload?.text||\"\"),assistant.thinkingDurationMs=clampChatThinkingDurationMs(Date.now()-Number(assistant.thinkingStartedAt||Date.now())),renderChatTranscript(!0)}else if(\"tool\"===event?.eventName)chatMessageThinkingActive(chatState.messages[assistantIndex])&&finalizeChatThinkingState(chatState.messages[assistantIndex]),setChatMsg(event.payload?.message||`Running tool ${event.payload?.name||\"\"}...`);else if(\"status\"===event?.eventName)setChatMsg(String(event.payload?.message||\"\"));else{if(\"error\"===event?.eventName)throw new Error(event.payload?.error||event.payload?.message||\"Chat stream failed.\");\"done\"===event?.eventName&&(chatMessageThinkingActive(chatState.messages[assistantIndex])&&finalizeChatThinkingState(chatState.messages[assistantIndex]),updateConversationRuntimeMetrics(activeChatConversation(),runtime,event.payload||{}),setChatMsg(\"\"))}}if((chatMessageThinkingActive(chatState.messages[assistantIndex])||chatState.messages[assistantIndex].reasoningText)&&finalizeChatThinkingState(chatState.messages[assistantIndex]),chatState.messages[assistantIndex].text.trim()||chatMessageThinkingView(chatState.messages[assistantIndex]).reasoningText||(chatState.messages[assistantIndex].text=\"[No text returned]\"),setChatMsg(\"\"),refreshStatus({force:!0}).catch(()=>{}),shouldAutoNameConversation){maybeAutoNameConversation(chatState.activeConversationId).catch(()=>{})}}catch(e){const aborted=\"AbortError\"===e?.name||/aborted|abort/i.test(String(e?.message||e||\"\"));chatMessageThinkingActive(chatState.messages[assistantIndex])&&finalizeChatThinkingState(chatState.messages[assistantIndex],!aborted),String(chatState.messages[assistantIndex]?.text||\"\").trim()||chatMessageThinkingView(chatState.messages[assistantIndex]||{}).reasoningText||(chatState.messages=chatState.messages.filter((_,index)=>index!==assistantIndex)),setChatMsg(aborted?\"Generation stopped.\":String(e||\"\"),aborted?\"warning\":\"error\")}finally{chatState.busy=!1,chatRequestController=null,persistChatConversationState(),renderChatUi()}}switchMode=function(mode){return switchInventoryVariant(mode)},switchDualMode=function(mode){return switchInventoryVariant(mode)},ensureDynamicPresetLayout(),ensurePresetActionModal(),renderPresetScopeTabs(),renderModelInstallStatus(),renderDynamicPresetModels(),refreshStatus({force:!0}).catch(()=>{});</script></body></html>"
class CommonMixin:
    def log_message(self, fmt, *args):
        return
    def queue_header(self, name, value):
        pending = list(getattr(self, "_pending_headers", []) or [])
        pending.append((str(name), str(value)))
        self._pending_headers = pending
    def emit_pending_headers(self):
        for name, value in list(getattr(self, "_pending_headers", []) or []):
            self.send_header(name, value)
        self._pending_headers = []
    def read_json_body(self):
        n = int(self.headers.get("content-length","0") or "0")
        body = self.rfile.read(n) if n else b"{}"
        if not body:
            return {}
        return json.loads(body)
    def redirect(self, location, code=302):
        self.close_connection = True
        self.send_response(code)
        self.send_header("Location", location)
        self.emit_pending_headers()
        self.send_header("Content-Length", "0")
        self.send_header("Connection", "close")
        self.end_headers()
    def send_bytes(self, payload, content_type="application/octet-stream", code=200):
        self.close_connection = True
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.emit_pending_headers()
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)
    def send_json(self, obj, code=200):
        self.send_bytes(json.dumps(obj, indent=2).encode("utf-8"), "application/json", code)

class AdminHandler(CommonMixin, BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def require_auth(self):
        client_ip = self.client_address[0] if self.client_address else ""
        if admin_session_ok(self.headers, client_ip):
            return True
        auth_header = self.headers.get("Authorization","")
        if check_basic_auth(auth_header):
            self.queue_header("Set-Cookie", build_admin_session_cookie(create_admin_session(client_ip)))
            return True
        if parse_cookie_header(self.headers.get("Cookie", "")).get(ADMIN_SESSION_COOKIE_NAME):
            self.queue_header("Set-Cookie", expired_admin_session_cookie())
        if should_log_admin_auth_denial(client_ip, self.path):
            log_audit("admin_auth_denied", client=client_ip, path=self.path)
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="club-3090"')
        self.emit_pending_headers()
        self.send_header("Content-Length", "0")
        self.send_header("Connection", "close")
        self.end_headers()
        return False
    def send_sse_event(self, event_name, payload):
        body = json.dumps(payload, ensure_ascii=False)
        self.wfile.write(f"event: {event_name}\ndata: {body}\n\n".encode("utf-8", errors="replace"))
        try:
            self.wfile.flush()
        except Exception:
            pass
        self.wfile.flush()
    def send_sse_comment(self, text="ping"):
        self.wfile.write(f": {text}\n\n".encode("utf-8", errors="replace"))
        self.wfile.flush()
    def do_GET(self):
        if not self.require_auth():
            return
        parsed = urlsplit(self.path)
        path = parsed.path
        if path == "/":
            self.redirect("/admin")
            return
        if path == "/admin":
            html = HTML.replace("__SCRIPT_VERSION__", SCRIPT_VERSION).replace(":8008/admin", f":{ADMIN_PORT}/admin").replace(":8009", f":{PROXY_PORT}")
            self.send_bytes(html.encode("utf-8"), "text/html; charset=utf-8")
            return
        if path == "/admin/status":
            params = parse_admin_query_params(parsed)
            force = str(params.get("force") or "").strip().lower() in {"1", "true", "yes", "on"}
            self.send_json(get_status_snapshot(force=force))
            return
        if path == "/admin/logs":
            self.close_connection = False
            self.send_response(200)
            self.send_header("Content-Type","text/event-stream")
            self.send_header("Cache-Control","no-cache")
            self.send_header("Connection","keep-alive")
            self.emit_pending_headers()
            self.end_headers()
            self.stream_logs(parsed)
            return
        if path == "/admin/audit-stream":
            params = parse_admin_query_params(parsed)
            self.close_connection = False
            self.send_response(200)
            self.send_header("Content-Type","text/event-stream")
            self.send_header("Cache-Control","no-cache")
            self.send_header("Connection","keep-alive")
            self.emit_pending_headers()
            self.end_headers()
            self.stream_text_file(AUDIT_LOG_FILE, "no audit entries yet; waiting...", initial_tail_lines=parse_tail_lines_param(params, 250))
            return
        if path == "/admin/presets":
            self.send_json({"ok": True, "presets": preset_catalog()})
            return
        if path == "/admin/instances":
            self.send_json({"ok": True, "instances": instances_snapshot(), "single_gpu_modes": list(SINGLE_GPU_MODES), "dual_gpu_modes": list(DUAL_GPU_MODES), "running_dual_instances": running_dual_instance_snapshots()})
            return
        if path == "/admin/users":
            self.send_json({"ok": True, "users": list_users_public(), "groups": list_groups_public(), "server_config": read_server_config()})
            return
        if path == "/admin/groups":
            self.send_json({"ok": True, "groups": list_groups_public(), "users": list_users_public(), "server_config": read_server_config()})
            return
        if path == "/admin/mcp":
            self.send_json({"ok": True, "servers": list_mcp_server_statuses()})
            return
        if path == "/admin/chat-state":
            self.send_json({"ok": True, "state": read_chat_state()})
            return
        if path.startswith("/admin/chat-attachments/"):
            attachment_id = re.sub(r"[^A-Za-z0-9._-]+", "", path.rsplit("/", 1)[-1])
            payload, content_type = read_chat_attachment_response(attachment_id)
            if payload is None:
                self.send_error(404)
                return
            self.send_bytes(payload, f"{content_type}; charset=utf-8" if content_type.startswith("text/") else content_type)
            return
        if path == "/admin/control-log":
            try:
                payload = subprocess.check_output(["tail","-n","300",CONTROL_LOG_FILE], text=True, stderr=subprocess.DEVNULL, timeout=3).encode("utf-8", errors="replace")
            except Exception:
                payload = b""
            self.send_bytes(payload, "text/plain; charset=utf-8")
            return
        if path == "/admin/audit-log":
            try:
                payload = subprocess.check_output(["tail","-n","300",AUDIT_LOG_FILE], text=True, stderr=subprocess.DEVNULL, timeout=3).encode("utf-8", errors="replace")
            except Exception:
                payload = b""
            self.send_bytes(payload, "text/plain; charset=utf-8")
            return
        self.send_error(404)
    def do_POST(self):
        if not self.require_auth():
            return
        path = urlsplit(self.path).path
        if path == "/admin/switch":
            try:
                data = self.read_json_body()
                instance_id = str(data.get("instance_id") or "").strip().upper()
                mode = canonical_mode_selector(data.get("mode"))
                spec = resolve_variant_spec(mode)
                if not spec:
                    raise ValueError("Invalid mode")
                scope_kind = str(spec.get("scope_kind") or "")
                if is_legacy_global_instance_id(instance_id):
                    if mode not in DUAL_GPU_MODES:
                        raise ValueError("Preset type does not match the selected instance scope")
                    rc, stop_msg = stop_legacy_global_instance()
                    result = run_switch(mode)
                    log_audit("admin_switch_mode_legacy_global", instance="GLOBAL", mode=mode, stop_rc=rc)
                    self.send_json({"ok": True, "instance": legacy_global_instance_snapshot(), "mode": mode, "output": (stop_msg + "\n" + result)[-12000:], "stopped_instances": ([{"id": "GLOBAL", "rc": rc, "output": stop_msg[-1200:]}] if stop_msg else []), "instances": instances_snapshot(), "running_dual_instances": running_dual_instance_snapshots()})
                    return
                if instance_id == "GLOBAL" and scope_kind == "single":
                    targets = [inst for inst in read_instances_config() if inst.get("kind") == "single"]
                    if not targets:
                        raise ValueError("No single-GPU targets are available")
                    wanted_indices = []
                    for target in targets:
                        wanted_indices.extend(target.get("gpu_indices") or [target.get("gpu_index")])
                    stopped = stop_overlapping_instances(wanted_indices)
                    updated_targets = [update_instance(target["id"], mode=mode, enabled=True) for target in targets]
                    outputs = []
                    _set_switch_job(
                        active=True,
                        status="booting",
                        mode=mode,
                        target="GLOBAL",
                        started_at=int(time.time()),
                        finished_at=0,
                        error="",
                    )
                    try:
                        for target in updated_targets:
                            result = start_instance(target["id"], track_switch_job=False)
                            outputs.append(f"{target['id']}: {(result.get('output') or '')[-2400:]}")
                        clear_switch_failure(mode)
                        _set_switch_job(
                            active=False,
                            status="success",
                            mode=mode,
                            target="GLOBAL",
                            finished_at=int(time.time()),
                            error="",
                        )
                    except Exception as e:
                        write_switch_failure(mode, e)
                        _set_switch_job(
                            active=False,
                            status="failed",
                            mode=mode,
                            target="GLOBAL",
                            finished_at=int(time.time()),
                            error=str(e)[-12000:],
                        )
                        raise
                    log_audit("admin_switch_mode_global_single", instance="GLOBAL", mode=mode, targets=[row["id"] for row in updated_targets], stopped_instances=[row["id"] for row in stopped])
                    self.send_json({"ok": True, "instance": None, "mode": mode, "output": "\n\n".join(outputs)[-12000:], "stopped_instances": stopped, "instances": instances_snapshot(), "running_dual_instances": running_dual_instance_snapshots()})
                    return
                if instance_id == "GLOBAL" and scope_kind == "dual":
                    gpu_count = detect_gpu_count_runtime()
                    if gpu_count == 2 and not gpu_pairing_enabled(gpu_count=gpu_count):
                        rc, stop_msg = stop_legacy_global_instance()
                        result = run_switch(mode)
                        log_audit("admin_switch_mode_legacy_global", instance="GLOBAL", mode=mode, stop_rc=rc)
                        self.send_json({"ok": True, "instance": legacy_global_instance_snapshot(), "mode": mode, "output": (stop_msg + "\n" + result)[-12000:], "stopped_instances": ([{"id": "GLOBAL", "rc": rc, "output": stop_msg[-1200:]}] if stop_msg else []), "instances": instances_snapshot(), "running_dual_instances": running_dual_instance_snapshots()})
                        return
                    pair_targets = sequential_global_gpu_pairs(gpu_count)
                    if not pair_targets:
                        raise ValueError("At least two GPUs are required before applying a dual preset globally")
                    stopped = stop_overlapping_instances([idx for pair in pair_targets for idx in pair])
                    updated_targets = []
                    outputs = []
                    _set_switch_job(
                        active=True,
                        status="booting",
                        mode=mode,
                        target="GLOBAL",
                        started_at=int(time.time()),
                        finished_at=0,
                        error="",
                    )
                    try:
                        for pair in pair_targets:
                            target = save_pair_instance(pair, mode=mode, enabled=True)
                            target = update_instance(target["id"], mode=mode, enabled=True)
                            updated_targets.append(target)
                            result = start_instance(target["id"], track_switch_job=False)
                            outputs.append(f"{target['id']}: {(result.get('output') or '')[-2400:]}")
                        clear_switch_failure(mode)
                        _set_switch_job(
                            active=False,
                            status="success",
                            mode=mode,
                            target="GLOBAL",
                            finished_at=int(time.time()),
                            error="",
                        )
                    except Exception as e:
                        write_switch_failure(mode, e)
                        _set_switch_job(
                            active=False,
                            status="failed",
                            mode=mode,
                            target="GLOBAL",
                            finished_at=int(time.time()),
                            error=str(e)[-12000:],
                        )
                        raise
                    log_audit("admin_switch_mode_global_dual", instance="GLOBAL", mode=mode, targets=[row["id"] for row in updated_targets], stopped_instances=[row["id"] for row in stopped])
                    self.send_json({"ok": True, "instance": None, "mode": mode, "output": "\n\n".join(outputs)[-12000:], "stopped_instances": stopped, "instances": instances_snapshot(), "running_dual_instances": running_dual_instance_snapshots()})
                    return
                if instance_id == "GLOBAL" and scope_kind in {"multi", "global_only"}:
                    stop_msg = cleanup_vllm_containers()
                    result = run_switch(mode)
                    log_audit("admin_switch_mode_global", instance="GLOBAL", mode=mode)
                    self.send_json({"ok": True, "instance": None, "mode": mode, "output": (str(stop_msg) + "\n" + result)[-12000:], "stopped_instances": [], "instances": instances_snapshot(), "running_dual_instances": running_dual_instance_snapshots()})
                    return
                if instance_id:
                    target = get_instance(instance_id)
                    if not target:
                        raise ValueError(f"Unknown instance: {instance_id}")
                    valid_modes = DUAL_GPU_MODES if target.get("kind") == "dual" else SINGLE_GPU_MODES
                    if mode not in valid_modes:
                        raise ValueError("Preset type does not match the selected instance scope")
                    stopped = stop_overlapping_instances(target.get("gpu_indices") or [target.get("gpu_index")])
                    updated = update_instance(instance_id, mode=mode, enabled=True)
                    result = start_instance(updated["id"])
                    log_audit("admin_switch_mode", instance=updated["id"], mode=mode, stopped_instances=[row["id"] for row in stopped])
                    self.send_json({"ok": True, "instance": instance_snapshot(updated), "mode": mode, "output": result.get("output", ""), "stopped_instances": stopped, "instances": instances_snapshot(), "running_dual_instances": running_dual_instance_snapshots()})
                else:
                    if scope_kind in {"multi", "global_only"}:
                        stop_msg = cleanup_vllm_containers()
                        result = run_switch(mode)
                        log_audit("admin_switch_mode_global", instance="GLOBAL", mode=mode)
                        self.send_json({"ok": True, "instance": None, "mode": mode, "output": (str(stop_msg) + "\n" + result)[-12000:], "stopped_instances": [], "instances": instances_snapshot(), "running_dual_instances": running_dual_instance_snapshots()})
                        return
                    if detect_gpu_count_runtime() == 2 and not gpu_pairing_enabled():
                        rc, stop_msg = stop_vllm_container("legacy_dual_switch")
                        result = run_switch(mode)
                        log_audit("admin_switch_mode_legacy_global", instance="legacy", mode=mode, stop_rc=rc)
                        self.send_json({"ok": True, "instance": None, "mode": mode, "output": (stop_msg + "\n" + result)[-12000:], "stopped_instances": ([{"id": "legacy", "rc": rc, "output": stop_msg[-1200:]}] if stop_msg else []), "instances": instances_snapshot(), "running_dual_instances": running_dual_instance_snapshots()})
                        return
                    pairs = [inst for inst in read_instances_config() if inst.get("kind") == "dual"]
                    if len(pairs) != 1:
                        raise ValueError("Select a specific dual pair scope before applying a dual preset")
                    target = pairs[0]
                    stopped = stop_overlapping_instances(target.get("gpu_indices") or [target.get("gpu_index")])
                    updated = update_instance(target["id"], mode=mode, enabled=True)
                    result = start_instance(updated["id"])
                    log_audit("admin_switch_mode_pair_default", instance=updated["id"], mode=mode, stopped_instances=[row["id"] for row in stopped])
                    self.send_json({"ok": True, "instance": instance_snapshot(updated), "mode": mode, "output": result.get("output", ""), "stopped_instances": stopped, "instances": instances_snapshot(), "running_dual_instances": running_dual_instance_snapshots()})
            except Exception as e:
                self.send_json({"ok": False, "error": str(e)}, 500)
            return
        if path == "/admin/rebuild-inventory":
            try:
                inventory = rebuild_runtime_inventory()
                log_audit("admin_runtime_inventory_rebuilt", models=len(inventory.get("models") or []), variants=len(inventory.get("variants") or []))
                self.send_json({"ok": True, "runtime_inventory": inventory, "models": inventory.get("models") or [], "variants": inventory.get("variants") or []})
            except Exception as e:
                self.send_json({"ok": False, "error": str(e)}, 500)
            return
        if path == "/admin/model-install":
            try:
                data = self.read_json_body()
                job = start_model_install_job(
                    data.get("model_id"),
                    data.get("variant_id"),
                    data.get("install_command"),
                )
                self.send_json({"ok": True, "model_install_job": job, "focus_log_source": "audit"})
            except Exception as e:
                self.send_json({"ok": False, "error": str(e)}, 500)
            return
        if path == "/admin/benchmark":
            try:
                job = start_admin_task_job("benchmark")
                self.send_json({"ok": True, "admin_task_job": job, "focus_log_source": "audit"})
            except Exception as e:
                self.send_json({"ok": False, "error": str(e)}, 500)
            return
        if path == "/admin/run-report":
            try:
                job = start_admin_task_job("report")
                self.send_json({"ok": True, "admin_task_job": job, "focus_log_source": "audit"})
            except Exception as e:
                self.send_json({"ok": False, "error": str(e)}, 500)
            return
        if path == "/admin/update":
            try:
                data = self.read_json_body()
                result = start_self_update_job(data.get("scope"))
                self.send_json(result)
            except Exception as e:
                self.send_json({"ok": False, "error": str(e)}, 500)
            return
        if path == "/admin/chat-stream":
            try:
                data = self.read_json_body()
            except Exception as e:
                self.send_json({"ok": False, "error": str(e)}, 500)
                return
            stream_admin_chat_request(self, data)
            return
        if path == "/admin/chat":
            try:
                data = self.read_json_body()
                self.send_json(run_admin_chat_request(data))
            except Exception as e:
                self.send_json({"ok": False, "error": str(e)}, 500)
            return
        if path == "/admin/chat-state":
            try:
                data = self.read_json_body()
                self.send_json({"ok": True, "state": write_chat_state(data)})
            except Exception as e:
                self.send_json({"ok": False, "error": str(e)}, 500)
            return
        if path == "/admin/chat-attachments":
            try:
                data = self.read_json_body()
                self.send_json({"ok": True, "attachment": save_chat_attachment(data)})
            except Exception as e:
                self.send_json({"ok": False, "error": str(e)}, 500)
            return
        if path == "/admin/power":
            try:
                data = self.read_json_body()
                action = data.get("action")
                instance_id = data.get("instance_id")
                log_control(f"POWER action requested action={action} instance={instance_id}")
                if action == "active":
                    out = {"cpu": apply_cpu_active_power(), "gpu": apply_gpu_active_power()}
                elif action == "idle_clocks":
                    out = {"cpu": apply_cpu_idle_power(), "gpu": apply_gpu_idle_power()}
                elif action == "stop_container":
                    if is_legacy_global_instance_id(instance_id):
                        rc, msg = stop_legacy_global_instance()
                    else:
                        rc, msg = stop_runtime_scope(instance_id=instance_id, mode=data.get("mode"))
                    out = {"container_stop_rc": rc, "container_stop_output": msg, "cpu": apply_cpu_idle_power(), "gpu": apply_gpu_idle_power()}
                elif action == "start_instance":
                    out = start_legacy_global_instance() if is_legacy_global_instance_id(instance_id) else start_instance(instance_id)
                elif action == "restart_instance":
                    if is_legacy_global_instance_id(instance_id):
                        stop_legacy_global_instance()
                        out = start_legacy_global_instance()
                    else:
                        stop_vllm_container("manual_restart", instance_id=instance_id)
                        out = start_instance(instance_id)
                elif action == "toggle_enabled":
                    enabled = bool(data.get("enabled"))
                    if is_legacy_global_instance_id(instance_id) or (not instance_id and detect_gpu_count_runtime() == 2 and not gpu_pairing_enabled(gpu_count=2)):
                        instance_id = "GLOBAL"
                        out = {"instance": set_legacy_global_enabled(enabled)}
                    else:
                        inst = update_instance(instance_id, enabled=enabled)
                        out = {"instance": instance_snapshot(inst)}
                elif action == "disable_optimizations":
                    out = set_power_optimizations(False, instance_id=instance_id)
                elif action == "enable_optimizations":
                    out = set_power_optimizations(True, instance_id=instance_id)
                elif action == "fans_max":
                    out = {"fans": set_fan_max_toggle(True, instance_id=instance_id)}
                elif action == "fans_auto":
                    out = {"fans": set_fan_max_toggle(False, instance_id=instance_id)}
                else:
                    raise ValueError("Invalid power action")
                log_audit("admin_power_action", action=action, instance=instance_id)
                self.send_json({"ok": True, "action": action, "result": out, "power": power_status()})
            except Exception as e:
                self.send_json({"ok": False, "error": str(e)}, 500)
            return
        if path == "/admin/profile":
            try:
                data = self.read_json_body()
                profile_name = data.get("profile")
                instance_id = str(data.get("instance_id") or "").strip().upper()
                log_control(f"PROFILE request received name={profile_name} instance={instance_id or 'GLOBAL'}")
                out = apply_performance_profile(profile_name)
                log_audit("admin_profile", profile=profile_name, instance=instance_id or "GLOBAL")
                self.send_json({"ok": True, "profile": profile_name, "result": out, "power": power_status()})
            except Exception as e:
                self.send_json({"ok": False, "error": str(e)}, 500)
            return
        if path == "/admin/wol":
            try:
                data = self.read_json_body()
                out = wake_on_lan(data.get("mac") or None, data.get("broadcast") or None)
                log_audit("admin_wol", mac=data.get("mac") or "", broadcast=data.get("broadcast") or "")
                self.send_json({"ok": True, "result": out})
            except Exception as e:
                self.send_json({"ok": False, "error": str(e)}, 500)
            return
        if path == "/admin/presets":
            try:
                data = self.read_json_body()
                action = data.get("action")
                if action == "save":
                    catalog = save_custom_preset(data.get("name"), data.get("preset") or {})
                    log_audit("admin_preset_save", name=data.get("name"))
                elif action == "delete":
                    catalog = delete_custom_preset(data.get("name"))
                    log_audit("admin_preset_delete", name=data.get("name"))
                else:
                    raise ValueError("Invalid preset action")
                self.send_json({"ok": True, "presets": catalog})
            except Exception as e:
                self.send_json({"ok": False, "error": str(e)}, 500)
            return
        if path == "/admin/mcp":
            try:
                data = self.read_json_body()
                action = str(data.get("action") or "").strip().lower()
                rows = sanitize_mcp_servers(read_server_config().get("mcp_servers") or [])
                if action == "save":
                    row = {
                        "id": str(data.get("id") or "").strip() or secrets.token_hex(6),
                        "name": str(data.get("name") or "").strip() or "mcp-server",
                        "command": str(data.get("command") or "").strip(),
                        "enabled": bool(data.get("enabled", True)),
                    }
                    validate_mcp_server_row(row)
                    rows = [item for item in rows if str(item.get("id") or "") != row["id"]] + [row]
                    write_server_config({"mcp_servers": rows})
                    log_audit("admin_mcp_saved", server=row["id"], enabled=row["enabled"])
                elif action == "delete":
                    server_id = str(data.get("id") or "").strip()
                    rows = [item for item in rows if str(item.get("id") or "") != server_id]
                    write_server_config({"mcp_servers": rows})
                    close_removed_mcp_clients(rows)
                    log_audit("admin_mcp_deleted", server=server_id)
                elif action == "toggle":
                    server_id = str(data.get("id") or "").strip()
                    enabled = bool(data.get("enabled"))
                    for row in rows:
                        if str(row.get("id") or "") == server_id:
                            row["enabled"] = enabled
                            if enabled:
                                validate_mcp_server_row(row)
                            break
                    write_server_config({"mcp_servers": rows})
                    if not enabled:
                        close_removed_mcp_clients([row for row in rows if row.get("enabled")])
                    log_audit("admin_mcp_toggled", server=server_id, enabled=enabled)
                else:
                    raise ValueError("Invalid MCP action")
                self.send_json({"ok": True, "servers": list_mcp_server_statuses()})
            except Exception as e:
                self.send_json({"ok": False, "error": str(e)}, 500)
            return
        if path == "/admin/ui-config":
            try:
                data = self.read_json_body()
                cfg, changed = write_ui_config(data)
                self.send_json({"ok": True, "ui_config": cfg, "changed": changed})
            except Exception as e:
                self.send_json({"ok": False, "error": str(e)}, 500)
            return
        if path == "/admin/log-export":
            try:
                data = self.read_json_body()
                export_payload = export_selected_log(
                    source=data.get("source") or "docker",
                    instance_id=data.get("instance_id") or "",
                )
                upload = upload_text_to_share_host(
                    export_payload.get("text") or "",
                    filename=export_payload.get("file_name") or "club3090-log.txt",
                )
                log_audit(
                    "admin_log_export",
                    source=export_payload.get("source"),
                    instance=export_payload.get("instance_id"),
                    container=export_payload.get("container"),
                    provider=upload.get("provider"),
                    url=upload.get("url"),
                )
                self.send_json(
                    {
                        "ok": True,
                        "source": export_payload.get("source"),
                        "instance_id": export_payload.get("instance_id"),
                        "container": export_payload.get("container"),
                        "file_name": export_payload.get("file_name"),
                        "provider": upload.get("provider"),
                        "url": upload.get("url"),
                    }
                )
            except Exception as e:
                self.send_json({"ok": False, "error": str(e)}, 500)
            return
        if path == "/admin/instances":
            try:
                data = self.read_json_body()
                action = str(data.get("action") or "").strip()
                if action == "save_pair":
                    instance = save_pair_instance(data.get("gpu_indices") or [], mode=data.get("mode"), enabled=data.get("enabled"))
                    log_audit("admin_pair_saved", instance=instance["id"], gpu_indices=instance.get("gpu_indices") or [], mode=instance.get("mode"))
                    self.send_json({"ok": True, "instance": instance_snapshot(instance), "instances": instances_snapshot(), "running_dual_instances": running_dual_instance_snapshots()})
                    return
                if action == "delete_pair":
                    instances = delete_pair_instance(data.get("instance_id"))
                    log_audit("admin_pair_deleted", instance=str(data.get("instance_id") or "").strip().upper())
                    self.send_json({"ok": True, "instances": instances, "running_dual_instances": running_dual_instance_snapshots()})
                    return
                raise ValueError("Invalid instances action")
            except Exception as e:
                self.send_json({"ok": False, "error": str(e)}, 500)
            return
        if path == "/admin/users":
            try:
                data = self.read_json_body()
                action = str(data.get("action") or "").strip()
                if action == "save":
                    user, api_key = save_user_record(data.get("user") or {})
                    self.send_json({"ok": True, "user": user, "api_key": api_key, "users": list_users_public(), "groups": list_groups_public(), "server_config": read_server_config()})
                    return
                if action == "delete":
                    users = delete_user_record(data.get("name"))
                    self.send_json({"ok": True, "users": users, "groups": list_groups_public(), "server_config": read_server_config()})
                    return
                if action == "reset_key":
                    api_key, user = issue_api_key_for_user(safe_user_name(data.get("name")))
                    self.send_json({"ok": True, "user": user, "api_key": api_key, "users": list_users_public(), "groups": list_groups_public(), "server_config": read_server_config()})
                    return
                if action == "show_key":
                    api_key, user = show_api_key_for_user(safe_user_name(data.get("name")))
                    self.send_json({"ok": True, "user": user, "api_key": api_key})
                    return
                if action == "save_server_config":
                    before_cfg = read_server_config()
                    cfg_data = {}
                    if "allow_proxy_without_api_key" in data:
                        cfg_data["allow_proxy_without_api_key"] = bool(data.get("allow_proxy_without_api_key", True))
                    if "gpu_pairing_enabled" in data:
                        cfg_data["gpu_pairing_enabled"] = bool(data.get("gpu_pairing_enabled"))
                    cfg = write_server_config(cfg_data)
                    read_instances_config()
                    if cfg != before_cfg:
                        log_audit("admin_server_config", allow_proxy_without_api_key=cfg.get("allow_proxy_without_api_key", True), gpu_pairing_enabled=cfg.get("gpu_pairing_enabled"))
                    self.send_json({"ok": True, "server_config": cfg, "users": list_users_public(), "groups": list_groups_public()})
                    return
                raise ValueError("Invalid users action")
            except Exception as e:
                self.send_json({"ok": False, "error": str(e)}, 500)
            return
        if path == "/admin/groups":
            try:
                data = self.read_json_body()
                action = str(data.get("action") or "").strip()
                if action == "save":
                    group = save_group_record(data.get("group") or {})
                    self.send_json({"ok": True, "group": group, "groups": list_groups_public(), "users": list_users_public(), "server_config": read_server_config()})
                    return
                if action == "delete":
                    groups = delete_group_record(data.get("name"))
                    self.send_json({"ok": True, "groups": groups, "users": list_users_public(), "server_config": read_server_config()})
                    return
                raise ValueError("Invalid groups action")
            except Exception as e:
                self.send_json({"ok": False, "error": str(e)}, 500)
            return
        if path == "/admin/machine":
            try:
                data = self.read_json_body()
                action = data.get("action")
                if action == "reboot":
                    log_audit("admin_machine", action="reboot")
                    self.send_json({"ok": True, "action": "reboot", "message": "Reboot command accepted"})
                    threading.Thread(target=lambda: (time.sleep(1), subprocess.run(["systemctl", "reboot"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)), daemon=True).start()
                    return
                if action == "shutdown":
                    log_audit("admin_machine", action="shutdown")
                    self.send_json({"ok": True, "action": "shutdown", "message": "Shutdown command accepted"})
                    threading.Thread(target=lambda: (time.sleep(1), subprocess.run(["systemctl", "poweroff"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)), daemon=True).start()
                    return
                raise ValueError("Invalid machine action")
            except Exception as e:
                self.send_json({"ok": False, "error": str(e)}, 500)
            return
        self.send_error(404)
    def stream_logs(self, parsed):
        params = parse_admin_query_params(parsed)
        requested = str(params.get("instance") or "").strip().upper()
        last_container = ""
        client_generation = -1
        client_seq = 0
        waiting_sent = False
        while True:
            instance, container = resolve_runtime_log_container(requested)
            if not container:
                try:
                    if not waiting_sent:
                        text = f"\n[log stream] {last_container} is no longer running; waiting for the next runtime container...\n" if last_container else "no running club-3090 runtime container found; waiting...\n"
                        self.send_sse_event("append", {"text": text})
                        waiting_sent = True
                        last_container = ""
                    else:
                        self.send_sse_comment()
                except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, OSError):
                    return
                time.sleep(2)
                continue
            waiting_sent = False
            watcher = get_runtime_log_watcher(container)
            if watcher is None:
                time.sleep(1)
                continue
            if container != last_container:
                last_container = container
                client_generation = -1
                client_seq = 0
            try:
                watcher.wait_for_change(client_generation, client_seq, timeout=15)
                snapshot = watcher.snapshot()
                if snapshot["generation"] != client_generation:
                    self.send_sse_event("reset", {"text": snapshot["text"]})
                    client_generation = snapshot["generation"]
                    client_seq = snapshot["seq"]
                    continue
                update = watcher.collect_updates_since(client_generation, client_seq)
                if update["reset"]:
                    self.send_sse_event("reset", {"text": update["text"]})
                    client_generation = update["generation"]
                    client_seq = update["seq"]
                elif update["text"]:
                    self.send_sse_event("append", {"text": update["text"]})
                    client_seq = update["seq"]
                else:
                    self.send_sse_comment()
            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, OSError):
                return
    def stream_text_file(self, path, empty_message="waiting...", initial_tail_lines=250):
        sent_reset = False
        offset = 0
        idle_since = time.time()
        while True:
            try:
                if not os.path.exists(path):
                    if not sent_reset:
                        self.send_sse_event("reset", {"text": str(empty_message or "waiting...").rstrip("\n") + "\n"})
                        sent_reset = True
                    else:
                        self.send_sse_comment()
                    time.sleep(2)
                    continue
                with open(path, "r", encoding="utf-8", errors="replace") as f:
                    if offset <= 0:
                        if int(initial_tail_lines) > 0:
                            lines = collections.deque(f, maxlen=int(initial_tail_lines))
                            text = "".join(lines)
                        else:
                            text = ""
                            f.seek(0, os.SEEK_END)
                        self.send_sse_event("reset", {"text": text or (str(empty_message or "waiting...").rstrip("\n") + "\n")})
                        offset = f.tell()
                        sent_reset = True
                        initial_tail_lines = 0
                        idle_since = time.time()
                    else:
                        try:
                            size_now = os.path.getsize(path)
                        except Exception:
                            size_now = offset
                        if size_now < offset:
                            offset = 0
                            sent_reset = False
                            continue
                        f.seek(offset)
                        chunk = f.read()
                        if chunk:
                            self.send_sse_event("append", {"text": chunk})
                            offset = f.tell()
                            idle_since = time.time()
                        elif time.time() - idle_since >= 15:
                            self.send_sse_comment()
                            idle_since = time.time()
            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, OSError):
                return
            time.sleep(1)


class LocalApiHandler(CommonMixin, BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def require_local_access(self):
        client_ip = self.client_address[0] if self.client_address else ""
        if client_ip not in ("127.0.0.1", "::1"):
            log_audit("local_api_denied", reason="non_loopback", client=client_ip, path=self.path)
            self.send_json({"ok": False, "error": "Local API is loopback-only"}, 403)
            return False
        if not local_api_token_ok(self.headers.get("X-Club3090-Local-Token", "")):
            log_audit("local_api_denied", reason="invalid_token", client=client_ip, path=self.path)
            self.send_json({"ok": False, "error": "Missing or invalid local API token"}, 401)
            return False
        return True
    def do_GET(self):
        if not self.require_local_access():
            return
        path = urlsplit(self.path).path
        if path == "/users":
            self.send_json({"ok": True, "users": list_users_public(), "groups": list_groups_public(), "server_config": read_server_config()})
            return
        if path == "/groups":
            self.send_json({"ok": True, "groups": list_groups_public(), "users": list_users_public(), "server_config": read_server_config()})
            return
        if path == "/server-config":
            self.send_json({"ok": True, "server_config": read_server_config()})
            return
        self.send_error(404)
    def do_POST(self):
        if not self.require_local_access():
            return
        path = urlsplit(self.path).path
        try:
            data = self.read_json_body()
            if path == "/users":
                action = str(data.get("action") or "").strip()
                if action == "save":
                    user, api_key = save_user_record(data.get("user") or {})
                    self.send_json({"ok": True, "user": user, "api_key": api_key, "users": list_users_public(), "groups": list_groups_public()})
                    return
                if action == "delete":
                    users = delete_user_record(data.get("name"))
                    self.send_json({"ok": True, "users": users, "groups": list_groups_public()})
                    return
                if action == "reset_key":
                    api_key, user = issue_api_key_for_user(safe_user_name(data.get("name")))
                    self.send_json({"ok": True, "user": user, "api_key": api_key, "users": list_users_public(), "groups": list_groups_public()})
                    return
                raise ValueError("Invalid users action")
            if path == "/groups":
                action = str(data.get("action") or "").strip()
                if action == "save":
                    group = save_group_record(data.get("group") or {})
                    self.send_json({"ok": True, "group": group, "groups": list_groups_public(), "users": list_users_public()})
                    return
                if action == "delete":
                    groups = delete_group_record(data.get("name"))
                    self.send_json({"ok": True, "groups": groups, "users": list_users_public()})
                    return
                raise ValueError("Invalid groups action")
            if path == "/server-config":
                cfg = write_server_config(data or {})
                self.send_json({"ok": True, "server_config": cfg})
                return
            raise ValueError("Unknown local API path")
        except Exception as e:
            self.send_json({"ok": False, "error": str(e)}, 500)

class ProxyHandler(CommonMixin, BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def do_GET(self):
        parsed = urlsplit(self.path)
        if parsed.path in {"/health", "/v1/health"}:
            self.send_json({
                "ok": True,
                "active_mode": active_mode(),
                "active_port": active_port(),
                "container": current_container(),
            })
            return
        instance_id, stripped = parse_instance_path(self.path)
        upstream_path, preset_name, cap = parse_preset_path(stripped)
        self.forward(None, upstream_path, preset_name, cap, instance_id=instance_id)
    def do_POST(self):
        n = int(self.headers.get("content-length","0") or "0")
        body = self.rfile.read(n) if n else b""
        instance_id, stripped = parse_instance_path(self.path)
        upstream_path, preset_name, cap = parse_preset_path(stripped)
        if preset_name and (upstream_path.startswith("/v1/chat/completions") or upstream_path.startswith("/v1/completions")):
            body = apply_preset(body, preset_name, cap)
        self.forward(body, upstream_path, preset_name, cap, instance_id=instance_id)
    def forward(self, body, upstream_path, preset_name, cap, instance_id=None):
        global last_request_finished_at
        start = time.time()
        status = None
        response_usage = {"tokens": 0, "input_tokens": 0, "output_tokens": 0, "tool_calls": 0}
        target = get_instance(instance_id) if instance_id else primary_instance()
        target_id = target["id"] if target else "legacy"
        target_metrics_key = str(target_id or "").strip().upper()
        request_usage = extract_request_usage(body) if body is not None and is_quota_counted_path(upstream_path) else {}
        auth_result = authorize_proxy_request(self.headers, instance_id, upstream_path, request_usage=request_usage)
        if auth_result[0] is False:
            _, code, payload = auth_result
            self.send_json(payload, code)
            return
        auth_context = auth_result[1]
        with metrics_lock:
            metrics["total_requests"] += 1
            metrics["active_requests"] += 1
            metrics["last_preset"] = preset_name or "raw"
            metrics["last_path"] = self.path
            target_request_metrics.setdefault(target_metrics_key, default_target_request_metrics())
        needs_model = upstream_path.startswith("/v1/models") or (body is not None and (upstream_path.startswith("/v1/chat/completions") or upstream_path.startswith("/v1/completions")))
        if needs_model:
            with metrics_lock:
                metrics["queued_requests"] += 1
                request_queue.append({"time": time.strftime("%H:%M:%S"), "path": self.path, "preset": preset_name or "raw", "instance": target_id})
            ensure_vllm_running_for_request(target["id"] if target else None)
            with metrics_lock:
                metrics["queued_requests"] = max(0, metrics["queued_requests"] - 1)
        url = f"http://127.0.0.1:{instance_runtime_port(target) if target else active_port()}" + upstream_path
        headers = {k:v for k,v in self.headers.items() if k.lower() not in HOP_HEADERS}
        for secret_header in ("Authorization", "authorization", "X-API-Key", "x-api-key", "api-key"):
            headers.pop(secret_header, None)
        if body is not None:
            headers["Content-Type"] = headers.get("Content-Type", "application/json")
        req = urllib.request.Request(url, data=body, headers=headers, method=self.command)
        try:
            with urllib.request.urlopen(req, timeout=None) as r:
                status = r.status
                self.send_response(r.status)
                for k,v in r.headers.items():
                    if k.lower() not in HOP_HEADERS:
                        self.send_header(k,v)
                self.send_header("X-Club3090-Instance", target_id)
                self.send_header("Connection","close")
                self.end_headers()
                if "text/event-stream" in r.headers.get("Content-Type","").lower():
                    with metrics_lock:
                        metrics["streaming_requests"] += 1
                first_chunk_at = None
                total_bytes = bytearray()
                while True:
                    chunk = r.read1(8192) if hasattr(r, "read1") else r.read(8192)
                    if not chunk:
                        break
                    if first_chunk_at is None:
                        first_chunk_at = time.time()
                    if len(total_bytes) < 2000000:
                        total_bytes.extend(chunk)
                    self.wfile.write(chunk)
                    self.wfile.flush()
                if first_chunk_at is not None:
                    toks = estimate_tokens_from_stream_bytes(bytes(total_bytes))
                    response_usage["output_tokens"] = max(int(response_usage.get("output_tokens") or 0), int(toks or 0))
                    response_usage["tokens"] = max(int(response_usage.get("tokens") or 0), int(toks or 0))
                    ttft = round(first_chunk_at - start, 3)
                    gen_time = max(0.001, time.time() - first_chunk_at)
                    with metrics_lock:
                        metrics["last_ttft_s"] = ttft
                        metrics["last_estimated_tokens"] = toks
                        metrics["last_tokens_per_second"] = round(toks / gen_time, 2) if toks else None
                        target_row = dict(target_request_metrics.get(target_metrics_key) or default_target_request_metrics())
                        target_row["last_ttft_s"] = ttft
                        target_row["last_estimated_tokens"] = toks
                        target_row["last_tokens_per_second"] = round(toks / gen_time, 2) if toks else None
                        target_request_metrics[target_metrics_key] = target_row
                parsed_usage = extract_response_usage(bytes(total_bytes))
                for key in ("tokens", "input_tokens", "output_tokens", "tool_calls"):
                    response_usage[key] = max(int(response_usage.get(key) or 0), int(parsed_usage.get(key) or 0))
        except urllib.error.HTTPError as e:
            status = e.code
            payload = e.read()
            parsed_usage = extract_response_usage(payload)
            for key in ("tokens", "input_tokens", "output_tokens", "tool_calls"):
                response_usage[key] = max(int(response_usage.get(key) or 0), int(parsed_usage.get(key) or 0))
            self.send_response(e.code)
            self.send_header("Content-Type", e.headers.get("Content-Type","text/plain"))
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Connection","close")
            self.end_headers()
            self.wfile.write(payload)
        except Exception as e:
            status = 502
            # Best-effort self-healing failover for stopped/crashed containers.
            # Only attempt for model discovery/completion paths, and only once.
            if upstream_path.startswith("/v1/models") or upstream_path.startswith("/v1/chat/completions") or upstream_path.startswith("/v1/completions"):
                try:
                    with metrics_lock:
                        metrics["failovers"] += 1
                    log_control(f"PROXY failover attempt instance={target_id} mode={(target['mode'] if target else active_mode())} error={e}")
                    if target:
                        start_instance(target["id"])
                    else:
                        run_switch(active_mode())
                    retry_url = f"http://127.0.0.1:{instance_runtime_port(target) if target else active_port()}" + upstream_path
                    retry_req = urllib.request.Request(retry_url, data=body, headers=headers, method=self.command)
                    with urllib.request.urlopen(retry_req, timeout=None) as r2:
                        status = r2.status
                        self.send_response(r2.status)
                        for k,v in r2.headers.items():
                            if k.lower() not in HOP_HEADERS:
                                self.send_header(k,v)
                        self.send_header("X-Club3090-Instance", target_id)
                        self.send_header("Connection","close")
                        self.end_headers()
                        retry_bytes = bytearray()
                        while True:
                            chunk = r2.read1(8192) if hasattr(r2, "read1") else r2.read(8192)
                            if not chunk:
                                break
                            if len(retry_bytes) < 2000000:
                                retry_bytes.extend(chunk)
                            self.wfile.write(chunk)
                            self.wfile.flush()
                        parsed_retry_usage = extract_response_usage(bytes(retry_bytes))
                        for key in ("tokens", "input_tokens", "output_tokens", "tool_calls"):
                            response_usage[key] = max(int(response_usage.get(key) or 0), int(parsed_retry_usage.get(key) or 0))
                        if int(response_usage.get("output_tokens") or 0) == 0:
                            retry_toks = estimate_tokens_from_stream_bytes(bytes(retry_bytes))
                            response_usage["output_tokens"] = max(int(response_usage.get("output_tokens") or 0), int(retry_toks or 0))
                            response_usage["tokens"] = max(int(response_usage.get("tokens") or 0), int(retry_toks or 0))
                        return
                except Exception as failover_error:
                    log_control(f"PROXY failover failed: {failover_error}")
            self.send_json({"error": str(e), "active_mode": active_mode(), "active_port": active_port()}, 502)
        finally:
            latency = round(time.time() - start, 3)
            prompt_tokens = max(int(request_usage.get("input_tokens") or 0), int(response_usage.get("input_tokens") or 0))
            output_tokens = max(int(response_usage.get("output_tokens") or 0), max(0, int(response_usage.get("tokens") or 0) - int(prompt_tokens)))
            total_tokens = max(int(response_usage.get("tokens") or 0), int(prompt_tokens) + int(output_tokens))
            tool_calls = int(response_usage.get("tool_calls") or 0)
            log_metrics = runtime_log_metrics_for_container(target.get("container"), force=True) if target and target.get("container") else {}
            display_tps = first_defined(log_metrics.get("generation_tps"), None)
            if display_tps not in (None, "", 0, 0.0):
                try:
                    display_tps = round(float(display_tps), 2)
                except Exception:
                    display_tps = None
            else:
                display_tps = None
            with metrics_lock:
                metrics["active_requests"] = max(0, metrics["active_requests"] - 1)
                if metrics["active_requests"] <= 0:
                    last_request_finished_at = time.time()
                metrics["completed_requests"] += 1
                if status is None or int(status) >= 400:
                    metrics["failed_requests"] += 1
                metrics["last_latency_s"] = latency
                metrics["last_status"] = status
                if display_tps not in (None, "", 0, 0.0):
                    metrics["last_tokens_per_second"] = display_tps
                recent_requests.appendleft({"time":time.strftime("%H:%M:%S"),"status":status,"latency_s":latency,"preset":preset_name or "raw","path":self.path,"upstream":upstream_path,"instance":target_id,"user":auth_context.get("user_name") or "anonymous"})
                target_row = dict(target_request_metrics.get(target_metrics_key) or default_target_request_metrics())
                target_row["last_status"] = status
                target_row["last_latency_s"] = latency
                if display_tps not in (None, "", 0, 0.0):
                    target_row["last_tokens_per_second"] = display_tps
                target_row["last_input_tokens"] = prompt_tokens
                target_row["last_output_tokens"] = output_tokens
                target_row["last_total_tokens"] = total_tokens
                target_row["last_tool_calls"] = tool_calls
                target_row["last_preset"] = preset_name or "raw"
                target_row["last_path"] = self.path
                target_row["last_request_at"] = int(time.time())
                target_request_metrics[target_metrics_key] = target_row
            record_user_usage(auth_context.get("user_name"), auth_context.get("count_request", False), status, request_usage, response_usage, latency)
            log_control(f"REQ user={(auth_context.get('user_name') or 'anonymous')} instance={target_id} status={status} latency={latency}s preset={preset_name or 'raw'} path={self.path} upstream={upstream_path} input_tokens={prompt_tokens} output_tokens={output_tokens} total_tokens={total_tokens} tool_calls={tool_calls}")

def build_server(port, handler, bind="0.0.0.0"):
    server = ThreadingHTTPServer((bind, port), handler)
    server.daemon_threads = True
    return server

def serve(server, label="server"):
    sock = None
    try:
        sock = server.socket.getsockname()
    except Exception:
        sock = ("?", "?")
    log_control(f"{label} listening on {sock[0]}:{sock[1]}")
    server.serve_forever()

def startup_power_primer():
    try:
        apply_cpu_active_power()
    except Exception as e:
        log_control(f"STARTUP cpu power primer error: {e}")
    try:
        apply_gpu_active_power(skip_fans=True)
    except Exception as e:
        log_control(f"STARTUP gpu power primer error: {e}")

def main():
    os.makedirs(CONTROL_DIR, exist_ok=True)
    os.makedirs(INSTANCES_DIR, exist_ok=True)
    write_server_config(read_server_config())
    ensure_local_api_token()
    # Hard fail early if an update somehow produced an incomplete control script.
    # This specifically guards the proxy/autostart path that depends on port_open().
    if not callable(globals().get("port_open")):
        raise RuntimeError("internal install error: port_open() is not defined")
    load_runtime_inventory(force=not os.path.exists(RUNTIME_INVENTORY_FILE), rebuild_if_missing=True)
    if len(sys.argv) > 1 and sys.argv[1] == "--rebuild-inventory":
        rebuilt = rebuild_runtime_inventory()
        print(json.dumps({"ok": True, "models": len(rebuilt.get("models") or []), "variants": len(rebuilt.get("variants") or [])}))
        return
    if len(sys.argv) > 1 and sys.argv[1] == "--boot-enabled-instances":
        boot_enabled_instances()
        return
    if resolve_variant_spec(DEFAULT_MODE) and read_active_mode_file() is None:
        write_active_mode(DEFAULT_MODE)
    read_instances_config()
    log_control("control service starting")
    try:
        build_series_point()
    except Exception as e:
        log_control(f"initial metrics snapshot error: {e}")
    try:
        refresh_status_snapshot()
    except Exception as e:
        log_control(f"initial status snapshot error: {e}")
    threading.Thread(target=idle_watchdog, daemon=True).start()
    threading.Thread(target=metrics_collector, daemon=True).start()
    threading.Thread(target=status_snapshot_collector, daemon=True).start()
    cfg = read_server_config()
    admin_server = build_server(ADMIN_BIND_PORT, AdminHandler, ADMIN_BIND_HOST)
    if cfg.get("local_api_enabled", False):
        local_api_port = int(cfg.get("local_api_port", LOCAL_API_PORT))
        local_api_server = build_server(local_api_port, LocalApiHandler, "127.0.0.1")
        threading.Thread(target=serve, args=(local_api_server, "local-api"), daemon=True).start()
    proxy_server = build_server(PROXY_BIND_PORT, ProxyHandler, PROXY_BIND_HOST)
    threading.Thread(target=serve, args=(proxy_server, "proxy"), daemon=True).start()
    threading.Thread(target=startup_power_primer, daemon=True).start()
    serve(admin_server, "admin")

if __name__ == "__main__":
    main()
PYCTRL

"${SUDO[@]}" chmod +x "${CONTROL_PY}"
log_done "Control backend written"

log_step "Writing headless X and runtime helper scripts"
"${SUDO[@]}" tee "${HEADLESS_X_SH}" >/dev/null <<'HEADLESSX'
#!/usr/bin/env bash
set -euo pipefail

CONFIG=/etc/X11/club3090-headless-xorg.conf
DISPLAY_NUM="${CLUB3090_FAN_DISPLAY_NUM:-99}"
LOGFILE=/var/log/club3090-headless-xorg.log

mkdir -p /etc/X11 /var/log

# Canonical private headless Xorg used for manual NVIDIA fan control.
# It keeps the working "do not steal outputs" hardening without carrying a
# second duplicate headless-X path.
if command -v nvidia-xconfig >/dev/null 2>&1; then
  nvidia-xconfig     --enable-all-gpus     --cool-bits=28     --allow-empty-initial-configuration     --use-display-device=None     --virtual=1280x720     --xconfig="${CONFIG}" >/tmp/club3090-nvidia-xconfig.log 2>&1 || true
fi

if [[ -s "${CONFIG}" ]]; then
  PY_PATCH_BIN="$(command -v python || command -v python3 || true)"
  if [[ -n "${PY_PATCH_BIN}" ]]; then
    "${PY_PATCH_BIN}" - "${CONFIG}" <<'PYXCONF' || true
import re, sys
path = sys.argv[1]
text = open(path, encoding='utf-8', errors='ignore').read()
text = re.sub(r'(?im)^\s*Option\s+"ConnectedMonitor".*
?', '', text)
text = re.sub(r'(?im)^\s*Option\s+"UseDisplayDevice".*
?', '', text)
def patch(sec):
    if re.search(r'(?im)^\s*Driver\s+"nvidia"', sec):
        if 'AllowEmptyInitialConfiguration' not in sec:
            sec = sec.rstrip() + '
    Option "AllowEmptyInitialConfiguration" "true"
'
        if 'Coolbits' not in sec and 'CoolBits' not in sec:
            sec = sec.rstrip() + '
    Option "Coolbits" "28"
'
        sec = sec.rstrip() + '
    Option "UseDisplayDevice" "None"
'
    return sec
text = re.sub(r'(?is)Section\s+"Device".*?EndSection', lambda m: patch(m.group(0)), text)
def patch_screen(sec):
    if 'AllowEmptyInitialConfiguration' not in sec:
        sec = sec.rstrip() + '
    Option "AllowEmptyInitialConfiguration" "true"
'
    sec = sec.rstrip() + '
    Option "UseDisplayDevice" "None"
'
    if not re.search(r'(?is)SubSection\s+"Display".*?Virtual\s+\d+\s+\d+.*?EndSubSection', sec):
        sec = sec.rstrip() + '
    SubSection "Display"
        Virtual 1280 720
    EndSubSection
'
    return sec
text = re.sub(r'(?is)Section\s+"Screen".*?EndSection', lambda m: patch_screen(m.group(0)), text)
open(path, 'w', encoding='utf-8').write(text)
PYXCONF
  fi
fi

if [[ ! -s "${CONFIG}" ]]; then
  cat > "${CONFIG}" <<'XCONF'
Section "ServerLayout"
    Identifier "club3090-headless"
    Screen 0 "Screen0"
EndSection

Section "Device"
    Identifier "Device0"
    Driver "nvidia"
    Option "AllowEmptyInitialConfiguration" "true"
    Option "Coolbits" "28"
    Option "UseDisplayDevice" "None"
EndSection

Section "Screen"
    Identifier "Screen0"
    Device "Device0"
    Option "AllowEmptyInitialConfiguration" "true"
    Option "UseDisplayDevice" "None"
    SubSection "Display"
        Virtual 1280 720
    EndSubSection
EndSection
XCONF
fi

exec /usr/bin/Xorg :${DISPLAY_NUM}   -config "${CONFIG}"   -noreset   -nolisten tcp   -ac   -novtswitch   -sharevts   +extension GLX +extension RANDR +extension RENDER   -logfile "${LOGFILE}"
HEADLESSX
"${SUDO[@]}" chmod +x "${HEADLESS_X_SH}"

"${SUDO[@]}" tee "${START_SH}" >/dev/null <<'STARTVLLM'
#!/usr/bin/env bash
set -euo pipefail

CONTROL_DIR="/opt/club3090-control"
CONTROL_PY="${CONTROL_DIR}/control.py"

echo "[club3090-vllm] applying active power profile before model startup"
if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi -pm 1 || true
  nvidia-smi -rgc || true
  nvidia-smi -pl "${CLUB3090_GPU_ACTIVE_POWER_LIMIT_W:-280}" || true
fi
if command -v cpupower >/dev/null 2>&1; then
  cpupower frequency-set -g "${CLUB3090_CPU_ACTIVE_GOVERNOR:-performance}" || true
fi

echo "[club3090-vllm] starting enabled club-3090 instances"
exec python3 "${CONTROL_PY}" --boot-enabled-instances
STARTVLLM
"${SUDO[@]}" chmod +x "${START_SH}"

"${SUDO[@]}" tee "${FOLLOW_SH}" >/dev/null <<'LOGFOLLOW' 
#!/usr/bin/env bash
set -euo pipefail

# This service is attached by systemd to one specific TTY, normally /dev/tty1.
# Keep output human-readable: no health-check spam, no identical consecutive lines,
# and at most one printed line per second.
INTERVAL_SECONDS="${CLUB3090_CONSOLE_INTERVAL:-1}"
TAIL_LINES="${CLUB3090_CONSOLE_TAIL:-80}"
last_line=""
last_emit=0

emit() {
  local line="$1"
  [[ -z "${line}" ]] && return 0

  # vLLM logs every internal health poll. These are useless on the physical TTY
  # and can completely flood the screen.
  if [[ "${line}" == *"GET /health HTTP/1.1"* ]]; then
    return 0
  fi

  if [[ "${line}" == "${last_line}" ]]; then
    return 0
  fi

  local now
  now="$(date +%s)"
  if (( now - last_emit < INTERVAL_SECONDS )); then
    return 0
  fi

  printf '[club3090-console] %s\n' "${line}"
  last_line="${line}"
  last_emit="${now}"
}

emit "Docker log follower starting. Waiting for club-3090 runtime container..."
while true; do
  mapfile -t containers < <(docker ps --format '{{.Names}}' | grep -Ei 'club3090-|vllm|qwen|llama-cpp' || true)
  if [[ "${#containers[@]}" -eq 0 ]]; then
    emit "No club-3090 runtime container yet; waiting..."
    sleep 3
    continue
  fi

  emit "Following docker logs for: ${containers[*]}"
  pids=()
  for container in "${containers[@]}"; do
    {
      while IFS= read -r line; do
        emit "[${container}] ${line}"
      done < <(docker logs --tail "${TAIL_LINES}" -f "${container}" 2>&1 || true)
    } &
    pids+=("$!")
  done

  wait -n "${pids[@]}" 2>/dev/null || true
  for pid in "${pids[@]}"; do
    kill "${pid}" 2>/dev/null || true
  done
  emit "A log stream ended; rescanning..."
  sleep 2
done
LOGFOLLOW
"${SUDO[@]}" chmod +x "${FOLLOW_SH}"
log_done "Helper scripts written"

if [[ ! -f "${ACTIVE_MODE_FILE}" ]]; then
  echo "${DEFAULT_MODE}" | "${SUDO[@]}" tee "${ACTIVE_MODE_FILE}" >/dev/null
fi
if [[ ! -f "${CONTROL_DIR}/last_good_mode" ]]; then
  "${SUDO[@]}" cp "${ACTIVE_MODE_FILE}" "${CONTROL_DIR}/last_good_mode" 2>/dev/null || true
fi

log_step "Refreshing persisted server configuration"
"${SUDO[@]}" "${PYTHON_BIN}" - "${CONTROL_DIR}" "${ONLINE_EFFECTIVE_ENABLED}" "${LOCAL_AUTOMATION_EFFECTIVE_ENABLED}" "${ONLINE_TLS_EFFECTIVE_ENABLED}" "${LOCAL_API_PORT}" "${TLS_CERT_FILE}" "${TLS_KEY_FILE}" <<'PYSERVERCFG'
import json, os, sys
control_dir = sys.argv[1]
online_mode = sys.argv[2]
local_automation_mode = sys.argv[3]
https_mode = sys.argv[4]
local_api_port = int(sys.argv[5])
https_cert_file = sys.argv[6]
https_key_file = sys.argv[7]
path = os.path.join(control_dir, "server_config.json")
current = {
    "allow_proxy_without_api_key": True,
    "online_enabled": False,
    "upnp_enabled": False,
    "https_enabled": False,
    "https_cert_file": https_cert_file,
    "https_key_file": https_key_file,
    "admin_path": "/admin",
    "local_api_enabled": False,
    "local_api_port": local_api_port,
}
had_existing = False
try:
    with open(path, "r", encoding="utf-8") as f:
        loaded = json.load(f)
    if isinstance(loaded, dict):
        had_existing = True
        current.update({k: loaded[k] for k in current.keys() if k in loaded})
except Exception:
    pass
current["online_enabled"] = online_mode == "true"
current["upnp_enabled"] = online_mode == "true"
current["https_enabled"] = https_mode == "true"
current["https_cert_file"] = https_cert_file
current["https_key_file"] = https_key_file
if online_mode == "true":
    current["allow_proxy_without_api_key"] = bool(current.get("allow_proxy_without_api_key", False)) if had_existing else False
if local_automation_mode == "true":
    current["local_api_enabled"] = True
    current["local_api_port"] = local_api_port
else:
    current["local_api_enabled"] = False
current["admin_path"] = "/admin"
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(current, f, indent=2, sort_keys=True)
os.replace(tmp, path)
PYSERVERCFG
log_done "Server configuration refreshed"

log_step "Validating generated control files"
"${SUDO[@]}" "${BASH_BIN}" -n "${HEADLESS_X_SH}"
"${SUDO[@]}" "${PYTHON_BIN}" -m py_compile "${CONTROL_PY}"
# Structural validation: catch missing helper functions before replacing a working service.
"${SUDO[@]}" "${PYTHON_BIN}" - "${CONTROL_PY}" <<'PYVERIFY'
import ast, sys
path = sys.argv[1]
tree = ast.parse(open(path, encoding="utf-8").read(), filename=path)
funcs = {node.name for node in ast.walk(tree) if isinstance(node, ast.FunctionDef)}
required = {"port_open","wait_for_runtime_ready","cleanup_vllm_containers","run_switch","detected_mode","active_port","ensure_vllm_running_for_request","apply_preset","parse_preset_path","set_gpu_fans","set_power_optimizations","set_fan_max_toggle","apply_fan_curve_once","ensure_headless_x_running","run_nvidia_settings","metrics_collector","wake_on_lan","apply_performance_profile","system_stats","read_ui_config","write_ui_config","read_custom_presets","write_custom_presets","get_all_presets","preset_catalog","save_custom_preset","delete_custom_preset","serve","main"}
missing = sorted(required - funcs)
if missing:
    raise SystemExit("control.py missing required functions: " + ", ".join(missing))
PYVERIFY
# Guardrail: the control service must not make vLLM /health requests.
if grep -q 'urlopen.*health\|/health.*urlopen' "${CONTROL_PY}"; then
  echo "ERROR: control.py still contains HTTP /health polling" >&2
  exit 1
fi
log_done "Generated files validated"

if [[ "${ACTION}" == "migrate" ]]; then
  quarantine_non_git_genesis_dirs
  if [[ "${MIGRATION_BOOTSTRAP_INVENTORY_DONE}" != "1" ]]; then
    rebuild_runtime_inventory_cli "MIGRATION_BOOTSTRAP_INVENTORY_DONE" "inventory_bootstrap"
  else
    append_control_log_line "migrate bootstrap inventory already complete; skipping"
  fi
  if [[ "${MIGRATION_SETUP_DONE}" != "1" ]]; then
    append_control_log_line "migrate setup phase delegated to final update.sh run; skipping standalone setup.sh replay"
    migration_mark_flag_done "MIGRATION_SETUP_DONE" "setup_delegated_to_update"
  else
    append_control_log_line "migrate setup step already complete; skipping"
  fi
  if [[ "${MIGRATION_POST_SETUP_INVENTORY_DONE}" != "1" ]]; then
    append_control_log_line "migrate post-setup inventory phase skipped because update.sh owns the final setup sync"
    migration_mark_flag_done "MIGRATION_POST_SETUP_INVENTORY_DONE" "inventory_post_setup_skipped"
  else
    append_control_log_line "migrate post-setup inventory already complete; skipping"
  fi
  if [[ "${MIGRATION_UPDATE_DONE}" != "1" ]]; then
    log_step "Running upstream update.sh at the end of migration"
    run_required_update_scripts
  else
    append_control_log_line "migrate update.sh step already complete; skipping"
  fi
  if [[ "${MIGRATION_FINAL_INVENTORY_DONE}" != "1" ]]; then
    rebuild_runtime_inventory_cli "MIGRATION_FINAL_INVENTORY_DONE" "inventory_final"
  else
    append_control_log_line "migrate final inventory already complete; skipping"
  fi
  log_done "Migration setup commands completed"
else
  rebuild_runtime_inventory_cli
  if [[ "${ACTION}" == "install" ]]; then
    log_step "Running upstream update.sh at the end of install"
    append_control_log_line "install update.sh command: bash scripts/update.sh"
    run_live_command "upstream update.sh" "${CLUB3090_DIR}" "bash scripts/update.sh"
    rebuild_runtime_inventory_cli "" "inventory_post_install_update"
    log_done "Install repo update completed"
  fi
fi

write_control_units() {
  "${SUDO[@]}" tee /etc/systemd/system/club3090-control.service >/dev/null <<UNIT
[Unit]
Description=club-3090 proxy and admin control panel
ConditionKernelCommandLine=club3090.server=1
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=CLUB3090_DIR=${CLUB3090_DIR}
Environment=DEFAULT_MODE=${DEFAULT_MODE}
Environment=CLUB3090_SCRIPT_VERSION=${SCRIPT_VERSION}
Environment=CLUB3090_ADMIN_PORT=${ADMIN_PORT}
Environment=CLUB3090_PROXY_PORT=${PROXY_PORT}
Environment=CLUB3090_LOCAL_API_PORT=${LOCAL_API_PORT}
Environment=CLUB3090_ADMIN_BIND_HOST=${CONTROL_ADMIN_BIND_HOST}
Environment=CLUB3090_PROXY_BIND_HOST=${CONTROL_PROXY_BIND_HOST}
Environment=CLUB3090_ADMIN_BIND_PORT=${CONTROL_ADMIN_BIND_PORT}
Environment=CLUB3090_PROXY_BIND_PORT=${CONTROL_PROXY_BIND_PORT}
Environment=CLUB3090_POWER_IDLE_AFTER_SECONDS=600
Environment=CLUB3090_CONTAINER_STOP_AFTER_SECONDS=3600
Environment=CLUB3090_GPU_ACTIVE_POWER_LIMIT_W=280
Environment=CLUB3090_GPU_IDLE_POWER_LIMIT_W=120
Environment=CLUB3090_GPU_IDLE_LOCK_CLOCKS=210,900
Environment=CLUB3090_CPU_ACTIVE_GOVERNOR=performance
Environment=CLUB3090_CPU_IDLE_GOVERNOR=powersave
Environment=CLUB3090_FAN_MAX_SPEED=100
Environment=CLUB3090_FAN_MIN_SAFE_SPEED=35
Environment=CLUB3090_WOL_MAC=
Environment=CLUB3090_WOL_BROADCAST=255.255.255.255
ExecStart=${CONTROL_PY}
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

  "${SUDO[@]}" tee /etc/systemd/system/club3090-headless-x.service >/dev/null <<UNIT
[Unit]
Description=club-3090 private headless Xorg for NVIDIA fan control
ConditionKernelCommandLine=club3090.server=1
After=multi-user.target

[Service]
Type=simple
ExecStart=${HEADLESS_X_SH}
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

  "${SUDO[@]}" tee /etc/systemd/system/club3090-console-log.service >/dev/null <<UNIT
[Unit]
Description=club-3090 console docker log follower
ConditionKernelCommandLine=club3090.server=1
After=docker.service
Wants=docker.service

[Service]
Type=simple
ExecStart=${FOLLOW_SH}
Restart=always
RestartSec=5
# Send visual feedback to exactly one local TTY instead of the kernel console.
# This avoids spamming every VT while still giving boot-time progress on tty1.
StandardOutput=tty
StandardError=tty
TTYPath=/dev/tty1
TTYReset=no
TTYVHangup=no
TTYVTDisallocate=no

[Install]
WantedBy=multi-user.target
UNIT
}

write_caddy_config() {
  "${SUDO[@]}" tee "${CADDYFILE_PATH}" >/dev/null <<CADDY
{
    auto_https disable_redirects
    admin off
}

https://:${ADMIN_PORT} {
    tls ${TLS_CERT_FILE} ${TLS_KEY_FILE}
    reverse_proxy 127.0.0.1:${CONTROL_ADMIN_BIND_PORT}
}

https://:${PROXY_PORT} {
    tls ${TLS_CERT_FILE} ${TLS_KEY_FILE}
    reverse_proxy 127.0.0.1:${CONTROL_PROXY_BIND_PORT}
}
CADDY
}

write_caddy_unit() {
  "${SUDO[@]}" tee /etc/systemd/system/club3090-caddy.service >/dev/null <<UNIT
[Unit]
Description=club-3090 HTTPS frontend (Caddy)
ConditionKernelCommandLine=club3090.server=1
After=club3090-control.service network-online.target
Wants=club3090-control.service network-online.target

[Service]
Type=simple
ExecStart=$(command -v caddy) run --config ${CADDYFILE_PATH} --adapter caddyfile
ExecReload=$(command -v caddy) reload --config ${CADDYFILE_PATH} --adapter caddyfile
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT
}

configure_https_frontend() {
  if [[ "${ONLINE_TLS_EFFECTIVE_ENABLED}" != "true" ]]; then
    "${SUDO[@]}" systemctl disable --now club3090-caddy.service 2>/dev/null || true
    "${SUDO[@]}" rm -f /etc/systemd/system/club3090-caddy.service "${CADDYFILE_PATH}" >/dev/null 2>&1 || true
    return 0
  fi
  ensure_https_certificate
  write_caddy_config
  if ! "${SUDO[@]}" caddy fmt --overwrite "${CADDYFILE_PATH}" >/dev/null 2>&1; then
    echo "ERROR: Failed to format generated Caddy configuration." >&2
    exit 1
  fi
  if ! "${SUDO[@]}" caddy validate --config "${CADDYFILE_PATH}" --adapter caddyfile >/dev/null 2>&1; then
    echo "ERROR: Generated Caddy configuration is invalid." >&2
    exit 1
  fi
  write_caddy_unit
}

write_vllm_unit() {
  "${SUDO[@]}" tee /etc/systemd/system/club3090-vllm.service >/dev/null <<UNIT
[Unit]
Description=club-3090 vLLM server
ConditionKernelCommandLine=club3090.server=1
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${CLUB3090_DIR}
Environment=CLUB3090_DIR=${CLUB3090_DIR}
Environment=DEFAULT_MODE=${DEFAULT_MODE}
ExecStart=${START_SH}
TimeoutStartSec=1800
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT
}

cleanup_legacy_fan_test_artifacts() {
  "${SUDO[@]}" systemctl disable --now club3090-headless-x-v213.service 2>/dev/null || true
  "${SUDO[@]}" rm -f \
    /etc/systemd/system/club3090-headless-x-v213.service \
    "${CONTROL_DIR}/prepare-headless-x-v213.sh" \
    /etc/X11/club3090-headless-xorg-v213.conf \
    /var/log/club3090-headless-xorg-v213.log >/dev/null 2>&1 || true
}

enable_managed_units() {
  "${SUDO[@]}" systemctl enable club3090-vllm.service
  "${SUDO[@]}" systemctl disable club3090-headless-x.service 2>/dev/null || true
  "${SUDO[@]}" systemctl enable club3090-control.service
  "${SUDO[@]}" systemctl enable club3090-console-log.service
  if [[ "${ONLINE_TLS_EFFECTIVE_ENABLED}" == "true" ]]; then
    "${SUDO[@]}" systemctl enable club3090-caddy.service
  else
    "${SUDO[@]}" systemctl disable club3090-caddy.service 2>/dev/null || true
  fi
}

configure_networking_and_frontend() {
  if [[ "${ONLINE_EFFECTIVE_ENABLED}" == "true" ]]; then
    configure_online_exposure
  else
    ensure_local_control_access
    close_runtime_exposure
  fi
}

start_control_plane_services_if_booted() {
  if ! grep -q 'club3090.server=1' /proc/cmdline; then
    return 0
  fi
  start_unit_nonblocking club3090-control.service
  if [[ "${ONLINE_TLS_EFFECTIVE_ENABLED}" == "true" ]]; then
    start_unit_nonblocking club3090-caddy.service
  fi
  start_unit_nonblocking club3090-console-log.service
}

start_unit_nonblocking() {
  local unit="$1"
  if "${SUDO[@]}" systemctl --help 2>/dev/null | grep -q -- '--no-block'; then
    "${SUDO[@]}" systemctl start --no-block "${unit}" >/dev/null 2>&1 || true
    return 0
  fi
  "${SUDO[@]}" systemctl start "${unit}" >/dev/null 2>&1 || true
}

if [[ "${ACTION}" == "install" ]]; then
  log_step "Writing and enabling systemd units for a fresh install"
  write_vllm_unit
  write_control_units
  configure_https_frontend
  cleanup_legacy_fan_test_artifacts
  log_step "Reloading systemd manager configuration"
  "${SUDO[@]}" systemctl daemon-reload
  log_step "Enabling managed club-3090 services"
  enable_managed_units
  log_step "Configuring networking and frontend exposure"
  configure_networking_and_frontend
  log_step "Starting control-plane services when server boot mode is active"
  start_control_plane_services_if_booted
  log_done "Install actions completed"

  echo
  echo "Installed club-3090 server control services."
  echo "They start unattended before login, but only when booted with kernel arg: club3090.server=1"
elif [[ "${ACTION}" == "update" ]]; then
  log_step "Refreshing systemd units and managed services for update"
  # Update the vLLM unit too so the next reboot uses the last selected mode.
  # Do not restart it here; that would interrupt a running model session.
  write_vllm_unit
  write_control_units
  configure_https_frontend
  cleanup_legacy_fan_test_artifacts
  log_step "Reloading systemd manager configuration"
  "${SUDO[@]}" systemctl daemon-reload
  log_step "Re-enabling managed club-3090 services"
  enable_managed_units
  log_step "Refreshing networking and frontend exposure"
  configure_networking_and_frontend
  log_step "Starting control-plane services if the server boot flag is active"
  start_control_plane_services_if_booted
  log_done "Update actions completed"
  echo
  echo "Updated club-3090 multi-instance control plane, proxy, metrics UI, console log follower, and boot unit."
  echo "Running Docker instances were left unchanged; next server boot will restore enabled entries from ${CONTROL_DIR}/instances.json."
else
  log_step "Refreshing systemd units and managed services after migrate"
  write_vllm_unit
  write_control_units
  configure_https_frontend
  cleanup_legacy_fan_test_artifacts
  log_step "Reloading systemd manager configuration"
  "${SUDO[@]}" systemctl daemon-reload
  log_step "Re-enabling managed club-3090 services"
  enable_managed_units
  log_step "Refreshing networking and frontend exposure"
  configure_networking_and_frontend
  log_step "Starting control-plane services if the server boot flag is active"
  start_control_plane_services_if_booted
  migration_mark_flag_done "MIGRATION_SERVICES_REFRESHED" "services_refreshed_after_migrate"
  finalize_migration_state_success
  log_done "Migrate actions completed"
  echo
  echo "Migrated the upstream club-3090 checkout to a fresh clone, preserved runtime/model assets, rebuilt the dynamic inventory, and refreshed the control plane."
fi

URL_SCHEME="http"
if [[ "${ONLINE_TLS_EFFECTIVE_ENABLED}" == "true" ]]; then
  URL_SCHEME="https"
fi
echo "Admin UI:  ${URL_SCHEME}://SERVER:${ADMIN_PORT}/admin"
echo "Proxy API: ${URL_SCHEME}://SERVER:${PROXY_PORT}/v1/chat/completions"
echo "OpenAI base URL: ${URL_SCHEME}://SERVER:${PROXY_PORT}/v1"
echo "Per-GPU proxy: ${URL_SCHEME}://SERVER:${PROXY_PORT}/GPU0/v1/chat/completions"
if [[ "${ONLINE_TLS_EFFECTIVE_ENABLED}" == "true" ]]; then
  echo "HTTPS edge: Caddy ${ADMIN_PORT}->127.0.0.1:${CONTROL_ADMIN_BIND_PORT}, ${PROXY_PORT}->127.0.0.1:${CONTROL_PROXY_BIND_PORT}"
fi
if [[ "${LOCAL_AUTOMATION_EFFECTIVE_ENABLED}" == "true" ]]; then
  echo "Local user API: http://127.0.0.1:${LOCAL_API_PORT}/users (token in ${CONTROL_DIR}/local_api_token)"
else
  echo "Local user API: disabled by default, enable with --local-automation"
fi
echo "Fan Control: private on-demand Xorg :99 via club3090-headless-x.service"
echo "Club dir:  ${CLUB3090_DIR}"
echo "Detected OS: ${PRETTY_NAME:-${ID:-unknown}} (${OS_FAMILY})"
echo "GPUs:      ${GPU_COUNT} detected"
echo "Auto mode: ${AUTO_DEFAULT_MODE}"
echo "Default:   ${DEFAULT_MODE}"
echo "Admin port:${ADMIN_PORT}"
echo "Proxy port:${PROXY_PORT}"
echo "Local API: ${LOCAL_API_PORT} ($([[ "${LOCAL_AUTOMATION_EFFECTIVE_ENABLED}" == "true" ]] && echo enabled || echo disabled))"
echo "Instances: ${CONTROL_DIR}/instances.json"
echo "Server cfg: ${CONTROL_DIR}/server_config.json"
echo "Users:     ${CONTROL_DIR}/users.json"
echo "Action:    ${ACTION}"
echo "Version:   ${SCRIPT_VERSION}"
echo "Online:    $([[ "${ONLINE_EFFECTIVE_ENABLED}" == "true" ]] && echo enabled || echo disabled)"
echo "HTTPS:     $([[ "${ONLINE_TLS_EFFECTIVE_ENABLED}" == "true" ]] && echo enabled || echo disabled)"
echo "Preset path styles supported: ${URL_SCHEME}://SERVER:${PROXY_PORT}/v1/<preset>/chat/completions, ${URL_SCHEME}://SERVER:${PROXY_PORT}/<preset>/v1/chat/completions, and per-GPU prefixes like ${URL_SCHEME}://SERVER:${PROXY_PORT}/GPU0/v1/<preset>/chat/completions"
