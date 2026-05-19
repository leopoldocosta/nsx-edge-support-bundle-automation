#!/usr/bin/env bash
# =============================================================================
# deploy_nsx_sb_check.sh  —  v3.14
# Deploy local do kit NSX Edge Automation - Support Bundle
# Estrutura: lib/ + automations/support_bundle/
#
# USO:
#   bash deploy_nsx_sb_check.sh [--dir /caminho/destino]
#
# Padrão: ~/nsx-edge-automation
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Diretório de destino
# ---------------------------------------------------------------------------
BASE_DIR="${HOME}/nsx-edge-automation"
if [[ "${1:-}" == "--dir" && -n "${2:-}" ]]; then
  BASE_DIR="$2"
fi

AUTO_DIR="${BASE_DIR}/automations/support_bundle"
LIB_DIR="${BASE_DIR}/lib"
DOCS_DIR="${BASE_DIR}/docs"
EXAMPLES_DIR="${BASE_DIR}/examples"

mkdir -p \
  "${AUTO_DIR}/logs" \
  "${AUTO_DIR}/run" \
  "${AUTO_DIR}/.ssh_keys" \
  "${LIB_DIR}" \
  "${DOCS_DIR}" \
  "${EXAMPLES_DIR}"

chmod 700 "${AUTO_DIR}/.ssh_keys"

echo ""
echo "==> Instalando em: ${BASE_DIR}"
echo ""

# ===========================================================================
# .gitignore
# ===========================================================================
cat > "${BASE_DIR}/.gitignore" <<'GITIGNORE'
# Runtime e logs
logs/
run/
*.log
*.csv
.env
session.env

# Chaves SSH (nunca versionar)
.ssh_keys/
*.pem
*.key
id_*

# IPs reais (usar edge_nodes.example como template)
edge_nodes.txt

# Temp
*.swp
*.tmp
__pycache__/
GITIGNORE

# ===========================================================================
# README.md raiz
# ===========================================================================
cat > "${BASE_DIR}/README.md" <<'README'
# NSX Edge Automations

Bash automation toolkit for managing NSX Edge Nodes (NSX-T / VMware NSX).

Each use case lives in its own folder under `automations/`, all sharing a common SSH/auth library.

> **Notice:** No proprietary data, credentials, environment-specific references, or real IP addresses are included in this repository.

## Structure

```
.
├── lib/
│   └── common.sh                      # Shared: SSH, auth, IP loading, root control
├── automations/
│   └── support_bundle/                # Use case: NSX support bundle collection
│       ├── edge_nodes.example         # IP list template (copy to edge_nodes.txt)
│       ├── deploy_nsx_sb_check.sh     # Deploy local completo
│       ├── install_dependencies.sh
│       ├── setup_keys.sh
│       ├── test_connections.sh
│       ├── nsx_sb_main.sh
│       ├── admin_exec.sh
│       ├── root_exec.sh
│       └── README.md
├── docs/
│   ├── MANUAL.md
│   └── CONTRIBUTING.md
├── examples/
│   └── ip_list_example.txt
├── .gitignore
└── README.md
```

## IP Address Management

```
edge_nodes.example   ← versioned template, safe to commit
edge_nodes.txt       ← your real IPs, local only, git-ignored
```

## Password Handling

- Collected **once** at script start, reused for all nodes
- Accepts **any special characters** (slashes, quotes, etc.) safely
- Passed to sshpass via private temp file (never exposed in process args)
- Cleared from memory at the end

## Quick Start

```bash
bash automations/support_bundle/deploy_nsx_sb_check.sh
cd ~/nsx-edge-automation/automations/support_bundle
cp edge_nodes.example edge_nodes.txt
# Edit edge_nodes.txt with real IPs
./install_dependencies.sh
./setup_keys.sh
./test_connections.sh
screen -S nsx_sb && ./nsx_sb_main.sh
```

## License

MIT — free to use for infrastructure automation.
README

# ===========================================================================
# lib/common.sh
# ===========================================================================
cat > "${LIB_DIR}/common.sh" <<'COMMON'
#!/usr/bin/env bash
# lib/common.sh — v3.14
# Shared library for all NSX Edge automations.
# Provides: SSH access (admin + root), IP loading, credential handling.
#
# Usage in any automation script:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   export AUTO_DIR="${SCRIPT_DIR}"
#   source "${SCRIPT_DIR}/../../lib/common.sh"
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${LIB_DIR}/.." && pwd)"

AUTO_DIR="${AUTO_DIR:-$(pwd)}"

LOG_DIR="${AUTO_DIR}/logs"
RUN_DIR="${AUTO_DIR}/run"
KEY_DIR="${AUTO_DIR}/.ssh_keys"
EDGE_FILE="${AUTO_DIR}/edge_nodes.txt"
EDGE_EXAMPLE="${AUTO_DIR}/edge_nodes.example"
ADMIN_KEY="${KEY_DIR}/nsx_admin_key"
ROOT_KEY="${KEY_DIR}/nsx_root_key"

mkdir -p "${LOG_DIR}" "${RUN_DIR}" "${KEY_DIR}"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log(){      printf '[%s] %s\n'        "$(date '+%F %T')" "$*"; }
log_ok(){   printf '[%s] [OK]   %s\n' "$(date '+%F %T')" "$*"; }
log_warn(){ printf '[%s] [WARN] %s\n' "$(date '+%F %T')" "$*"; }
log_err(){  printf '[%s] [ERR]  %s\n' "$(date '+%F %T')" "$*"; }

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------
need_cmd(){
  command -v "$1" >/dev/null 2>&1 || {
    log_err "Missing required command: $1"
    exit 1
  }
}

# ---------------------------------------------------------------------------
# IP Management
# ---------------------------------------------------------------------------
collect_ips(){
  if [[ -f "${EDGE_EXAMPLE}" ]]; then
    echo "  Template available: ${EDGE_EXAMPLE}"
    echo "  Copy with: cp edge_nodes.example edge_nodes.txt, then edit."
    echo "  Or paste IPs directly below."
  fi
  echo ""
  echo "Paste Edge Node IPs, one per line. Empty line to finish:"
  : > "${EDGE_FILE}"
  while IFS= read -r line; do
    [[ -z "$line" ]] && break
    [[ "$line" =~ ^# ]] && continue
    if [[ "$line" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "$line" >> "${EDGE_FILE}"
    else
      log_warn "Skipping invalid entry: ${line}"
    fi
  done
  local count
  count=$(wc -l < "${EDGE_FILE}" | tr -d ' ')
  log "${count} IP(s) saved to ${EDGE_FILE}"
}

load_ips(){
  if [[ ! -s "${EDGE_FILE}" ]]; then
    log_warn "${EDGE_FILE} not found or empty."
    collect_ips
  fi
  mapfile -t EDGE_IPS < <(grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' "${EDGE_FILE}" 2>/dev/null || true)
  if [[ ${#EDGE_IPS[@]} -eq 0 ]]; then
    log_err "No valid IPs found in ${EDGE_FILE}."
    exit 1
  fi
  log "Loaded ${#EDGE_IPS[@]} Edge Node(s): ${EDGE_IPS[*]}"
}

# ---------------------------------------------------------------------------
# Credentials
# ---------------------------------------------------------------------------
ask_admin_creds(){
  if [[ -n "${NSX_PASS:-}" ]]; then
    log "Admin credentials already loaded, skipping prompt."
    return 0
  fi
  read -rp  "Admin username [admin]: " NSX_USER
  NSX_USER="${NSX_USER:-admin}"
  IFS= read -rsp "Admin password (all special characters accepted): " NSX_PASS; echo
  export NSX_USER NSX_PASS
  log "Credentials collected for user '${NSX_USER}'. Will be reused for all nodes."
}

ask_root_creds(){
  if [[ -n "${ROOT_PASS:-}" ]]; then
    log "Root credentials already loaded, skipping prompt."
    return 0
  fi
  IFS= read -rsp "Root password (all special characters accepted): " ROOT_PASS; echo
  export ROOT_PASS
  log "Root credentials collected. Will be reused for all nodes."
}

clear_creds(){
  unset NSX_PASS ROOT_PASS NSX_USER 2>/dev/null || true
  log "Credentials cleared from memory."
}

# ---------------------------------------------------------------------------
# SSH helper: escreve senha em arquivo temp privado (600), passa via SSHPASS.
# ---------------------------------------------------------------------------
_sshpass_safe(){
  local _passvar="$1"; shift
  local _pass="${!_passvar}"
  local _tmpfile
  _tmpfile="$(mktemp -t sshpass_XXXXXX)"
  chmod 600 "${_tmpfile}"
  printf '%s' "${_pass}" > "${_tmpfile}"
  SSHPASS="$(cat "${_tmpfile}")" sshpass -e "$@"
  local _rc=$?
  rm -f "${_tmpfile}"
  return $_rc
}

# ---------------------------------------------------------------------------
# SSH Functions
# FIX v3.13: stderr do cliente SSH suprimido com 2>/dev/null para evitar
# que warnings locais (ex: /etc/ssh/ssh_config gssapiauthentication)
# contaminem o stdout capturado pelos callers.
# ---------------------------------------------------------------------------
ssh_admin(){
  local ip="$1"; shift
  if [[ -f "${ADMIN_KEY}" ]]; then
    ssh -i "${ADMIN_KEY}" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=15 \
        -o BatchMode=yes \
        "admin@${ip}" "$@" 2>/dev/null
  else
    _sshpass_safe NSX_PASS ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=15 \
        "${NSX_USER}@${ip}" "$@" 2>/dev/null
  fi
}

ssh_root(){
  local ip="$1"; shift
  if [[ -f "${ROOT_KEY}" ]]; then
    ssh -i "${ROOT_KEY}" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=15 \
        -o BatchMode=yes \
        "root@${ip}" "$@" 2>/dev/null
  else
    _sshpass_safe ROOT_PASS ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=15 \
        "root@${ip}" "$@" 2>/dev/null
  fi
}

admin_cmd(){ local ip="$1" cmd="$2"; ssh_admin "$ip" "$cmd"; }
root_cmd(){  local ip="$1" cmd="$2"; ssh_root  "$ip" "$cmd"; }

# ---------------------------------------------------------------------------
# Root SSH Control
# ---------------------------------------------------------------------------
enable_root_ssh(){
  local ip="$1"
  log "${ip}: enabling root SSH..."
  admin_cmd "$ip" 'set service ssh enabled; start service ssh; set service ssh root-login enabled' || true
}

disable_root_ssh(){
  local ip="$1"
  log "${ip}: disabling root SSH..."
  admin_cmd "$ip" 'set service ssh root-login disabled' || true
}

# ---------------------------------------------------------------------------
# Support Bundle helpers
# ---------------------------------------------------------------------------
request_support_bundle(){
  local ip="$1"
  admin_cmd "$ip" 'get support-bundle status; start support-bundle' \
    || admin_cmd "$ip" 'start support-bundle' || true
}

check_support_bundle(){
  local ip="$1"
  local out_log out_files out_root
  out_log="$(root_cmd "$ip" \
    "test -f /var/log/support_bundle && tail -50 /var/log/support_bundle || echo FILE_NOT_FOUND")"
  out_files="$(root_cmd "$ip" \
    "find /var/log /storage /tmp -maxdepth 3 \( -name '*support*bundle*' -o -name '*.tgz' -o -name '*.tar.gz' \) -type f 2>/dev/null | head -20")"
  out_root="$(root_cmd "$ip" "getent passwd root >/dev/null 2>&1; echo ROOT_OK")"
  printf '%s\n----FILES----\n%s\n----ROOT----\n%s\n' "$out_log" "$out_files" "$out_root"
}

# ---------------------------------------------------------------------------
# Bundle list helper
# FIX v3.13: aceita APENAS nomes no padrão sb_*.tgz — descarta qualquer
# linha de stderr ou arquivo não relacionado que possa ter vazado para o
# stdout (ex: warnings do ssh_config, arquivos .pcap, .py, .sh).
# ---------------------------------------------------------------------------
list_remote_bundles(){
  local ip="$1"
  root_cmd "$ip" "ls /var/vmware/nsx/file-store/ 2>/dev/null" \
    | grep -E '^sb_.*\.tgz$' || true
}

# ---------------------------------------------------------------------------
# bundle_file_date  —  v3.14
# Extrai a data do nome do arquivo bundle (padrão sb_IP_YYYYMMDD_HHMMSS.tgz).
# Retorna string no formato "YYYY-MM-DD HH:MM".
# Fallback: string vazia quando o nome não segue o padrão.
# ---------------------------------------------------------------------------
bundle_file_date(){
  local fname="$1"
  # Padrão: qualquer coisa terminando em _YYYYMMDD_HHMMSS.tgz
  if [[ "$fname" =~ _([0-9]{4})([0-9]{2})([0-9]{2})_([0-9]{2})([0-9]{2})[0-9]{2}\.tgz$ ]]; then
    printf '%s-%s-%s %s:%s' \
      "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" \
      "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}"
  else
    printf ''
  fi
}
COMMON
chmod +x "${LIB_DIR}/common.sh"

# ===========================================================================
# automations/support_bundle/edge_nodes.example
# ===========================================================================
cat > "${AUTO_DIR}/edge_nodes.example" <<'EXAMPLE'
# edge_nodes.example
# Template para lista de IPs dos Edge Nodes NSX.
#
# USO:
#   cp edge_nodes.example edge_nodes.txt
#   Edite edge_nodes.txt com os IPs reais (um por linha).
#   edge_nodes.txt é ignorado pelo git e nunca será commitado.
#
# FORMATO: um endereço IPv4 por linha. Linhas com # são ignoradas.
#
# Exemplo (substitua pelos IPs reais):
# 192.168.10.10
# 192.168.10.11
# 192.168.10.12
EXAMPLE

# ===========================================================================
# automations/support_bundle/README.md
# ===========================================================================
cat > "${AUTO_DIR}/README.md" <<'SBREADME'
# Automation: Support Bundle Collection

Coleta e verifica support bundles NSX em todos os Edge Nodes.

## Workflow

```
Fase 1 (imediata)
  ├── Habilita root SSH em cada nó
  ├── Solicita geração do support bundle
  └── Registra status

Fase 2 (verifica a cada 5 min, até 30 min)
  ├── Lê /var/log/support_bundle
  ├── Busca arquivos .tgz / .tar.gz
  ├── Para antecipadamente em caso de erro
  └── Desabilita root SSH em todos os nós ao final
```

## Setup

```bash
cd automations/support_bundle

# 1. Crie sua lista de IPs
cp edge_nodes.example edge_nodes.txt
vim edge_nodes.txt

# 2. Instale dependências (primeira vez)
./install_dependencies.sh

# 3. Configure SSH keys (primeira vez)
./setup_keys.sh

# 4. Valide o ambiente
./test_connections.sh

# 5. Execute (recomendado dentro do screen)
screen -S nsx_sb
./nsx_sb_main.sh
```

## Ad-hoc

```bash
./admin_exec.sh   # qualquer comando NSX-T CLI como admin
./root_exec.sh    # qualquer comando Linux como root (pede confirmação)
```
SBREADME

# ===========================================================================
# automations/support_bundle/install_dependencies.sh
# ===========================================================================
cat > "${AUTO_DIR}/install_dependencies.sh" <<'INST'
#!/usr/bin/env bash
set -euo pipefail
OS_ID="$(. /etc/os-release 2>/dev/null; echo "${ID:-unknown}")"
if [[ "$OS_ID" =~ (ubuntu|debian) ]]; then
  echo "[INFO] Ubuntu/Debian detectado..."
  sudo apt-get update
  sudo apt-get install -y openssh-client sshpass expect screen
elif [[ "$OS_ID" =~ (ol|oracle|rhel|centos|rocky|almalinux|fedora) ]]; then
  echo "[INFO] RHEL-family detectado..."
  sudo dnf install -y openssh-clients sshpass expect screen 2>/dev/null \
    || sudo yum install -y openssh-clients sshpass expect screen
else
  echo "[WARN] OS '${OS_ID}' não reconhecido. Instale manualmente: openssh-client sshpass expect screen"
fi
echo "[OK] Dependências instaladas."
INST
chmod +x "${AUTO_DIR}/install_dependencies.sh"

# ===========================================================================
# automations/support_bundle/setup_keys.sh
# ===========================================================================
cat > "${AUTO_DIR}/setup_keys.sh" <<'SETUP'
#!/usr/bin/env bash
# setup_keys.sh - Gera chaves Ed25519 e distribui para cada Edge Node
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/../../lib/common.sh"

need_cmd ssh-keygen
need_cmd sshpass
load_ips
ask_admin_creds

[[ -f "${ADMIN_KEY}" ]] || ssh-keygen -t ed25519 -f "${ADMIN_KEY}" -N '' -C 'nsx-admin-key' -q
[[ -f "${ROOT_KEY}" ]]  || ssh-keygen -t ed25519 -f "${ROOT_KEY}"  -N '' -C 'nsx-root-key'  -q

ADMIN_PUB="$(cat "${ADMIN_KEY}.pub")"
ROOT_PUB="$(cat "${ROOT_KEY}.pub")"

for ip in "${EDGE_IPS[@]}"; do
  log "Distribuindo chaves para ${ip}..."
  admin_cmd "$ip" "set user admin ssh-key \"${ADMIN_PUB}\"" || true
  enable_root_ssh "$ip"
  admin_cmd "$ip" "set user root ssh-key \"${ROOT_PUB}\""  || true
  disable_root_ssh "$ip"
  log_ok "${ip}: chaves distribuídas."
done

clear_creds
log_ok "Setup de chaves SSH concluído."
SETUP
chmod +x "${AUTO_DIR}/setup_keys.sh"

# ===========================================================================
# automations/support_bundle/test_connections.sh
# ===========================================================================
cat > "${AUTO_DIR}/test_connections.sh" <<'TESTC'
#!/usr/bin/env bash
# test_connections.sh - Valida conectividade e acesso admin + root
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/../../lib/common.sh"

need_cmd ssh
load_ips

if [[ ! -f "${ADMIN_KEY}" ]]; then
  need_cmd sshpass
  ask_admin_creds
fi
if [[ ! -f "${ROOT_KEY}" ]]; then
  ask_root_creds
fi

REPORT="${LOG_DIR}/test_$(date +%Y%m%d_%H%M%S).log"
log "Relatório: ${REPORT}"

for ip in "${EDGE_IPS[@]}"; do
  {
    echo "======================================"
    echo " Node: ${ip}"
    echo "======================================"
    echo "--- [1] Ping ---"
    ping -c 1 -W 2 "$ip" 2>&1 || echo "WARN: ping falhou (pode estar filtrado)"
    echo "--- [2] admin: get version ---"
    admin_cmd "$ip" 'get version' || echo "FAIL"
    echo "--- [3] admin: get service ssh ---"
    admin_cmd "$ip" 'get service ssh' || echo "FAIL"
    echo "--- [4] admin: get managers ---"
    admin_cmd "$ip" 'get managers' || echo "FAIL"
    echo "--- [5] habilitar root SSH ---"
    enable_root_ssh "$ip"
    sleep 2
    echo "--- [6] root: uname -a ---"
    root_cmd "$ip" 'uname -a' || echo "FAIL"
    echo "--- [7] root: uptime ---"
    root_cmd "$ip" 'uptime' || echo "FAIL"
    echo "--- [8] root: df -h /var/log ---"
    root_cmd "$ip" 'df -h /var/log' || echo "FAIL"
    echo "--- [9] root: presença do log support_bundle ---"
    root_cmd "$ip" 'ls -lh /var/log/support_bundle 2>/dev/null || echo FILE_NOT_FOUND'
    echo "--- [10] desabilitar root SSH ---"
    disable_root_ssh "$ip"
    echo
  } | tee -a "$REPORT"
done

clear_creds
log_ok "Teste concluído. Relatório: ${REPORT}"
TESTC
chmod +x "${AUTO_DIR}/test_connections.sh"

# ===========================================================================
# automations/support_bundle/nsx_sb_main.sh
# ===========================================================================
cat > "${AUTO_DIR}/nsx_sb_main.sh" <<'MAIN'
#!/usr/bin/env bash
# nsx_sb_main.sh - Orquestrador: Fase 1 (solicita SB) + Fase 2 (verifica a cada 5 min)
# Recomendado: executar dentro de screen ou tmux (~35 min no total)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/../../lib/common.sh"

need_cmd ssh
load_ips

# Coleta credenciais UMA VEZ para todos os nós
if [[ ! -f "${ADMIN_KEY}" ]]; then
  need_cmd sshpass
  ask_admin_creds
fi
if [[ ! -f "${ROOT_KEY}" ]]; then
  ask_root_creds
fi

RUN_LOG="${LOG_DIR}/sb_run_$(date +%Y%m%d_%H%M%S).log"
STATUS_CSV="${LOG_DIR}/sb_status_$(date +%Y%m%d_%H%M%S).csv"
echo 'ip,phase,status,details,timestamp' > "$STATUS_CSV"

EXPIRY_EPOCH="$(( $(date +%s) + 1800 ))"

# Auto-limpa arquivo de sessão após 30 min
auto_clear_bg(){
  ( while [[ "$(date +%s)" -lt "$1" ]]; do sleep 5; done
    rm -f "${RUN_DIR}/session.env" 2>/dev/null || true
  ) >/dev/null 2>&1 &
}
if [[ -n "${NSX_PASS:-}" ]]; then
  umask 077
  printf 'export NSX_USER=%q\nexport NSX_PASS=%q\nexport ROOT_PASS=%q\n' \
    "${NSX_USER}" "${NSX_PASS}" "${ROOT_PASS:-}" > "${RUN_DIR}/session.env"
  auto_clear_bg "$EXPIRY_EPOCH"
fi

# ---------------------------------------------------------------------------
# Tabelas formatadas: larguras fixas para alinhamento
# COL_NODE=19  COL_STATUS=18  COL_ACAO=18  COL_FILE=20
# ---------------------------------------------------------------------------
_tbl_sep(){
  printf '╠═══════════════════╬══════════════════╬══════════════════╬════════════════════╣\n'
}
_tbl_header(){
  printf '╔════════════════════════════════════════════════════════════════════════════╗\n'
  printf '║    PRE-CHECK — Estado dos Support Bundles  —  %-28s  ║\n' "$(date '+%F %T')"
  printf '╠═══════════════════╦══════════════════╦══════════════════╦════════════════════╣\n'
  printf '║ %-17s ║ %-16s ║ %-16s ║ %-18s ║\n' 'NODE' 'STATUS' 'AÇÃO' 'ARQUIVO'
  printf '╠═══════════════════╬══════════════════╬══════════════════╬════════════════════╣\n'
}
_tbl_row(){
  # $1=ip $2=status $3=acao $4=arquivo
  printf '║ %-17s ║ %-16s ║ %-16s ║ %-18s ║\n' \
    "$1" "$2" "$3" "${4:0:18}"
}
_tbl_footer(){
  printf '╚═══════════════════╩══════════════════╩══════════════════╩════════════════════╝\n'
}

# ---------------------------------------------------------------------------
# PRE-CHECK — verifica bundles existentes antes de disparar geração
# v3.14: STATUS exibe a data do arquivo (YYYY-MM-DD HH:MM) extraída
#        do nome do bundle (sb_IP_YYYYMMDD_HHMMSS.tgz) em vez de
#        'RECENTE (≤7d)'.
# ---------------------------------------------------------------------------
declare -A PC_STATUS PC_ACAO PC_FILE PC_SKIP

run_precheck(){
  log "=== PRE-CHECK: Verificando bundles existentes ==="
  local now_epoch
  now_epoch=$(date +%s)

  for ip in "${EDGE_IPS[@]}"; do
    log "${ip}: iniciando PRE-CHECK..."
    enable_root_ssh "$ip"

    # Último log de geração
    local last_log
    last_log="$(root_cmd "$ip" \
      "tail -1 /var/log/support_bundle.log 2>/dev/null || echo FILE_NOT_FOUND")"
    printf '\n  ┌─ %s: /var/log/support_bundle.log (última linha)           ─┐\n' "$ip"
    printf '  │  %s\n' "$last_log"
    printf '  └────────────────────────────────────────────────────────────────────────┘\n\n'
    if echo "$last_log" | grep -qiE 'error|fail|unable|denied'; then
      log_warn "${ip}: última linha do log indica possível erro."
    else
      log_ok   "${ip}: última linha do log sem erros aparentes."
    fi

    # Lista bundles remotos
    log "${ip}: [PRE-CHECK] verificando status do support bundle..."
    local raw_list
    raw_list="$(list_remote_bundles "$ip")"

    # Exibe ls completo para contexto
    local ls_out
    ls_out="$(root_cmd "$ip" "ls -lh /var/vmware/nsx/file-store/ 2>/dev/null" || true)"
    printf '\n  ┌─ %s: ls -lh /var/vmware/nsx/file-store/                    ─┐\n' "$ip"
    while IFS= read -r line; do printf '  │  %s\n' "$line"; done <<< "$ls_out"
    printf '  └────────────────────────────────────────────────────────────────────────┘\n\n'

    log "${ip}: [bundles detectados] resultado bruto: '${raw_list}'"

    # Processa lista de bundles
    local -a bundles_recent bundles_old
    bundles_recent=(); bundles_old=()
    local total_count=0

    while IFS= read -r fname; do
      [[ -z "$fname" ]] && continue
      (( total_count++ ))

      # Idade via nome do arquivo (campo YYYYMMDD após último IP-segment)
      local age_days=0
      if [[ "$fname" =~ _([0-9]{4})([0-9]{2})([0-9]{2})_[0-9]{6}\.tgz$ ]]; then
        local fyear="${BASH_REMATCH[1]}" fmon="${BASH_REMATCH[2]}" fday="${BASH_REMATCH[3]}"
        local file_epoch
        file_epoch=$(date -d "${fyear}-${fmon}-${fday}" +%s 2>/dev/null || echo "$now_epoch")
        age_days=$(( (now_epoch - file_epoch) / 86400 ))
      else
        # fallback: considera velho quando não reconhece o padrão
        age_days=999
      fi
      log "${ip}: arquivo '${fname}' → ${age_days} dia(s)."

      if [[ $age_days -le 7 ]]; then
        bundles_recent+=("$fname")
      else
        bundles_old+=("$fname")
      fi
    done <<< "$raw_list"

    log "${ip}: ${total_count} bundle(s) encontrado(s)."

    printf '\n  ┌─ %s: %d bundle(s) recente(s) ≤7d | %d antigo(s) >7d        ─┐\n' \
      "$ip" "${#bundles_recent[@]}" "${#bundles_old[@]}"
    for f in "${bundles_recent[@]}"; do printf '  │  ✔  %s\n' "$f"; done
    for f in "${bundles_old[@]}";   do printf '  │  ⚠  %s  [ANTIGO]\n' "$f"; done
    printf '  └────────────────────────────────────────────────────────────────────────┘\n\n'

    if [[ ${#bundles_recent[@]} -gt 0 ]]; then
      # Pega o bundle mais recente (último da lista ordenada por nome)
      local newest_bundle
      newest_bundle="$(printf '%s\n' "${bundles_recent[@]}" | sort | tail -1)"

      # v3.14: status = data extraída do nome do arquivo
      local file_date
      file_date="$(bundle_file_date "${newest_bundle}")"
      local status_label
      if [[ -n "$file_date" ]]; then
        status_label="${file_date}"
      else
        status_label="RECENTE (≤7d)"
      fi

      PC_STATUS["$ip"]="$status_label"
      PC_ACAO["$ip"]="OK"
      PC_FILE["$ip"]="${newest_bundle}"
      PC_SKIP["$ip"]="true"
      log_ok "${ip}: bundle recente presente — geração será pulada."
      [[ ${#bundles_old[@]} -gt 0 ]] && \
        log_warn "${ip}: bundle(s) antigo(s) presentes — use --clean-all para remover."
    elif [[ $total_count -gt 0 ]]; then
      PC_STATUS["$ip"]="ANTIGO (>7d)"
      PC_ACAO["$ip"]="GERAR"
      PC_FILE["$ip"]="—"
      PC_SKIP["$ip"]="false"
      log_warn "${ip}: apenas bundle(s) antigo(s) — será gerado novo."
    else
      PC_STATUS["$ip"]="EM ANDAMENTO"
      PC_ACAO["$ip"]="AGUARDAR"
      PC_FILE["$ip"]="—"
      PC_SKIP["$ip"]="false"
      log "${ip}: nenhum bundle encontrado."
    fi
  done

  # Exibe tabela do pre-check
  local precheck_csv="${LOG_DIR}/precheck_$(date +%Y%m%d_%H%M%S).csv"
  echo 'ip,status,acao,arquivo' > "$precheck_csv"

  _tbl_header
  for ip in "${EDGE_IPS[@]}"; do
    _tbl_row "$ip" "${PC_STATUS[$ip]}" "${PC_ACAO[$ip]}" "${PC_FILE[$ip]}"
    printf '%s,%s,%s,%s\n' "$ip" "${PC_STATUS[$ip]}" "${PC_ACAO[$ip]}" "${PC_FILE[$ip]}" >> "$precheck_csv"
  done
  _tbl_footer

  log_ok "Pre-check concluído. CSV: ${precheck_csv}"
  printf '[%s] Para gerar bundles: ./nsx_sb_main.sh\n'    "$(date '+%F %T')"
  printf '[%s] Para limpar todos:  ./nsx_sb_main.sh --clean-all\n' "$(date '+%F %T')"
}

# ---- FASE 1: Habilita root SSH + Solicita Support Bundle ----
log "=== FASE 1: Solicitação do Support Bundle ==="
run_precheck

for ip in "${EDGE_IPS[@]}"; do
  if [[ "${PC_SKIP[$ip]:-false}" == "true" ]]; then
    log "${ip}: pulando solicitação de bundle."
    continue
  fi
  enable_root_ssh "$ip"
  printf '%s,phase1,root_ssh_enabled,ok,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
  request_support_bundle "$ip"
  printf '%s,phase1,sb_requested,ok,%s\n'     "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
done
log "Fase 1 concluída. Aguardando geração dos bundles..."

# ---- FASE 2: Verifica a cada 5 min, até 30 min (6 rounds) ----
log "=== FASE 2: Verificação ==="
declare -A NODE_DONE
for ip in "${EDGE_IPS[@]}"; do NODE_DONE["$ip"]="false"; done

for ((round=1; round<=6; round++)); do
  log "Verificação ${round}/6 — aguardando 5 min..."
  sleep 300
  for ip in "${EDGE_IPS[@]}"; do
    [[ "${NODE_DONE[$ip]}" == "true" ]] && continue
    OUT="$(check_support_bundle "$ip" || true)"
    if grep -qiE 'error|fail|unable|denied' <<< "$OUT"; then
      log_err  "${ip}: erro detectado — encerrando verificações neste nó."
      printf '%s,phase2,error,%q,%s\n'   "$ip" "$OUT" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
      NODE_DONE["$ip"]="true"
    elif grep -qiE 'complete|generated|success' <<< "$OUT" && ! grep -q 'FILE_NOT_FOUND' <<< "$OUT"; then
      log_ok   "${ip}: bundle confirmado."
      printf '%s,phase2,success,%q,%s\n' "$ip" "$OUT" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
      NODE_DONE["$ip"]="true"
    else
      log_warn "${ip}: ainda pendente..."
      printf '%s,phase2,pending,%q,%s\n' "$ip" "$OUT" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
    fi
  done
done

# ---- RELATÓRIO FINAL ----
printf '\n'
printf '╔══════════════════════════════════════════════════════════════════════════════╗\n'
printf '║  RELATÓRIO FINAL — Support Bundle Check  %-33s║\n' "$(date '+%F %T')"
printf '╠═══════════════════╦══════════════════╦══════════════════╦════════════════════╣\n'
printf '║ %-17s ║ %-16s ║ %-16s ║ %-18s ║\n' 'NODE' 'STATUS' 'AÇÃO' 'ARQUIVO'
printf '╠═══════════════════╬══════════════════╬══════════════════╬════════════════════╣\n'
for ip in "${EDGE_IPS[@]}"; do
  _tbl_row "$ip" "${PC_STATUS[$ip]:-—}" "${PC_ACAO[$ip]:-—}" "${PC_FILE[$ip]:-—}"
done
printf '╚═══════════════════╩══════════════════╩══════════════════╩════════════════════╝\n'

# ---- FINAL: Desabilita root SSH em todos os nós ----
log "=== FINAL: Desabilitando root SSH ==="
for ip in "${EDGE_IPS[@]}"; do
  disable_root_ssh "$ip" || true
  printf '%s,final,root_ssh_disabled,ok,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
done

clear_creds
rm -f "${RUN_DIR}/session.env" 2>/dev/null || true
log_ok "Concluído. CSV de status: ${STATUS_CSV}"
MAIN
chmod +x "${AUTO_DIR}/nsx_sb_main.sh"

# ===========================================================================
# automations/support_bundle/admin_exec.sh
# ===========================================================================
cat > "${AUTO_DIR}/admin_exec.sh" <<'ADMX'
#!/usr/bin/env bash
# admin_exec.sh - Executa qualquer comando NSX-T admin CLI nos Edge Nodes
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/../../lib/common.sh"

load_ips
[[ -f "${ADMIN_KEY}" ]] || { need_cmd sshpass; ask_admin_creds; }

echo ""
echo "Edge Nodes:"
for i in "${!EDGE_IPS[@]}"; do printf '  [%d] %s\n' "$((i+1))" "${EDGE_IPS[$i]}"; done
echo "  [A] Todos"
echo ""
read -rp 'Selecione o nó (número ou A): ' SEL
read -rp 'Comando NSX-T admin CLI: '       CMD
echo ""

run(){ echo "===== admin@${1} ====="; admin_cmd "$1" "$CMD" || true; echo; }

if   [[ "${SEL^^}" == "A" ]]; then for ip in "${EDGE_IPS[@]}"; do run "$ip"; done
elif [[ "$SEL" =~ ^[0-9]+$ ]] && (( SEL >= 1 && SEL <= ${#EDGE_IPS[@]} )); then
  run "${EDGE_IPS[$((SEL-1))]}"
else echo "[ERROR] Seleção inválida."; exit 1; fi

clear_creds
ADMX
chmod +x "${AUTO_DIR}/admin_exec.sh"

# ===========================================================================
# automations/support_bundle/root_exec.sh
# ===========================================================================
cat > "${AUTO_DIR}/root_exec.sh" <<'ROTX'
#!/usr/bin/env bash
# root_exec.sh - Executa qualquer comando Linux como root nos Edge Nodes
#                Habilita root SSH antes, desabilita após.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/../../lib/common.sh"

load_ips
[[ -f "${ADMIN_KEY}" ]] || { need_cmd sshpass; ask_admin_creds; }
[[ -f "${ROOT_KEY}" ]]  || ask_root_creds

echo ""
echo "Edge Nodes:"
for i in "${!EDGE_IPS[@]}"; do printf '  [%d] %s\n' "$((i+1))" "${EDGE_IPS[$i]}"; done
echo "  [A] Todos"
echo ""
read -rp 'Selecione o nó (número ou A): '               SEL
read -rp 'Comando Linux root: '                          CMD
read -rp '[AVISO] Confirma execução root em produção? [s/N]: ' CONFIRM
[[ "${CONFIRM,,}" =~ ^(s|y)$ ]] || { echo "Cancelado."; exit 0; }

run(){
  local ip="$1"
  echo "===== root@${ip} ====="
  enable_root_ssh "$ip"; sleep 2
  root_cmd "$ip" "$CMD" || true
  disable_root_ssh "$ip"
  echo
}

if   [[ "${SEL^^}" == "A" ]]; then for ip in "${EDGE_IPS[@]}"; do run "$ip"; done
elif [[ "$SEL" =~ ^[0-9]+$ ]] && (( SEL >= 1 && SEL <= ${#EDGE_IPS[@]} )); then
  run "${EDGE_IPS[$((SEL-1))]}"
else echo "[ERROR] Seleção inválida."; exit 1; fi

clear_creds
ROTX
chmod +x "${AUTO_DIR}/root_exec.sh"

# ===========================================================================
# docs/MANUAL.md
# ===========================================================================
cat > "${DOCS_DIR}/MANUAL.md" <<'MANUALDOC'
# Manual Geral

## Design do Repositório

```
lib/common.sh          ← fonte única: SSH, auth, carregamento de IPs
automations/<nome>/    ← pasta isolada por caso de uso
```

Cada automação:
- Define `export AUTO_DIR="${SCRIPT_DIR}"` antes de dar source na lib
- Contém seu próprio `edge_nodes.example`

## Convenção de IPs

| Arquivo              | Versionado | Propósito              |
|----------------------|------------|------------------------|
| `edge_nodes.example` | ✅ Sim     | Template sem IPs reais |
| `edge_nodes.txt`     | ❌ Não     | IPs reais, git-ignored |

## Senhas

- Coletadas **uma única vez** no início do script
- Aceita qualquer caractere especial (`/`, `\`, `'`, `"`, etc.)
- Armazenadas internamente como string raw (`IFS= read -r`)
- Repassadas ao `sshpass` via arquivo temporário privado (600)
- Nunca expostas em argumentos de processo
- Removidas da memória ao final (`clear_creds`)

## Política de Root SSH

- Habilitado apenas quando a automação precisa de acesso root
- Desabilitado imediatamente após cada nó
- Desabilitado em todos os nós no passo FINAL
MANUALDOC

# ===========================================================================
# docs/CONTRIBUTING.md
# ===========================================================================
cat > "${DOCS_DIR}/CONTRIBUTING.md" <<'CONTRIBDOC'
# Como Adicionar uma Nova Automação

## Passo a passo

### 1. Crie a pasta

```bash
mkdir automations/<nome>
cd automations/<nome>
```

### 2. Crie o template de IPs

```bash
cat > edge_nodes.example <<'EOF'
# edge_nodes.example
# Copie para edge_nodes.txt e adicione os IPs reais.
EOF
```

### 3. Inicie o script principal com

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/../../lib/common.sh"

load_ips
ask_admin_creds   # coleta UMA VEZ para todos os nós

# ... lógica da automação ...

clear_creds
```

### 4. Funções disponíveis de lib/common.sh

| Função                    | Descrição                                           |
|---------------------------|-----------------------------------------------------|
| `load_ips`                | Carrega edge_nodes.txt, solicita preenchimento      |
| `ask_admin_creds`         | Coleta usuário e senha admin (uma vez)              |
| `ask_root_creds`          | Coleta senha root (uma vez)                         |
| `clear_creds`             | Remove variáveis de credencial da memória           |
| `admin_cmd ip cmd`        | Executa comando NSX CLI como admin                  |
| `root_cmd ip cmd`         | Executa comando Linux como root                     |
| `enable_root_ssh ip`      | Habilita login root SSH via CLI admin               |
| `disable_root_ssh ip`     | Desabilita login root SSH via CLI admin             |
| `list_remote_bundles ip`  | Lista apenas arquivos sb_*.tgz no file-store        |
| `bundle_file_date fname`  | Extrai data do nome do bundle (YYYY-MM-DD HH:MM)    |
| `log / log_ok / log_warn / log_err` | Log com timestamp                       |
| `need_cmd binário`        | Encerra se binário não encontrado no PATH           |
CONTRIBDOC

# ===========================================================================
# examples/ip_list_example.txt
# ===========================================================================
cat > "${EXAMPLES_DIR}/ip_list_example.txt" <<'IPEX'
# ip_list_example.txt
# Formato para edge_nodes.txt — um IPv4 por linha. # são ignorados.
192.168.1.10
192.168.1.11
192.168.1.12
IPEX

# ===========================================================================
# Sumário final
# ===========================================================================
echo ""
echo "========================================================"
echo " Kit NSX Edge Automation instalado com sucesso! v3.14"
echo "========================================================"
echo ""
echo "  Localização : ${BASE_DIR}"
echo ""
echo "  Próximos passos:"
echo "    cd ${AUTO_DIR}"
echo "    cp edge_nodes.example edge_nodes.txt"
echo "    # Edite edge_nodes.txt com os IPs reais"
echo "    ./install_dependencies.sh"
echo "    ./setup_keys.sh"
echo "    ./test_connections.sh"
echo "    screen -S nsx_sb && ./nsx_sb_main.sh"
echo ""
echo "  Senhas: coletadas uma vez, qualquer caractere aceito."
echo ""
