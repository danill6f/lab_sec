#!/usr/bin/env bash
# ==================================================================
#  up.sh — sobe o lab checando antes se a sub-rede está livre
#
#  1. Cria o .env a partir do .env.example (se não existir)
#  2. Verifica se LAB_NET.0/24 conflita com redes Docker ou rotas do host
#     -> se conflitar, escolhe uma faixa livre e grava no .env
#  3. Gera os certificados do Wazuh (se ainda não existirem)
#  4. docker compose up -d --build
#
#  Uso:  ./up.sh            (argumentos extras vão para o docker compose up)
#        ./up.sh --check    (só verifica a rede, não sobe nada)
# ==================================================================
set -euo pipefail
cd "$(dirname "$0")"

NET_NAME="lab_net"
ENV_FILE=".env"

info()  { printf '\033[1;34m[i]\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m[✓]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
fail()  { printf '\033[1;31m[✗]\033[0m %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null || fail "docker não encontrado"

# ---------- helpers de IP ----------
ip2int() {
  local IFS=. a b c d
  read -r a b c d <<<"$1"
  echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

# imprime "inicio fim" (inteiros) de um CIDR; IP sem /mask = /32
cidr_range() {
  local ip="${1%/*}" mask=32
  [[ "$1" == */* ]] && mask="${1#*/}"
  local n; n=$(ip2int "$ip")
  local size=$(( 1 << (32 - mask) ))
  local start=$(( n & ~(size - 1) & 0xFFFFFFFF ))
  echo "$start $(( start + size - 1 ))"
}

overlaps() {   # overlaps CIDR_A CIDR_B
  local as ae bs be
  read -r as ae <<<"$(cidr_range "$1")"
  read -r bs be <<<"$(cidr_range "$2")"
  (( as <= be && bs <= ae ))
}

# ---------- faixas em uso ----------
used_subnets() {
  # redes Docker (exceto a própria lab_net, se já existir)
  local ids
  ids=$(docker network ls -q)
  if [[ -n "$ids" ]]; then
    # shellcheck disable=SC2086
    docker network inspect $ids \
      --format '{{.Name}} {{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null \
    | while read -r name subnets; do
        [[ "$name" == "$NET_NAME" ]] && continue
        for s in $subnets; do [[ "$s" == *.* ]] && echo "$s"; done
      done
  fi
  # rotas do host (LAN, VPN, etc.)
  if command -v ip >/dev/null; then
    ip -4 route show 2>/dev/null | awk '$1 ~ /^[0-9]/ {print $1}'
  fi
}

conflict_with() {   # imprime a primeira faixa em uso que conflita com $1
  local cand="$1" s
  while read -r s; do
    [[ -z "$s" ]] && continue
    if overlaps "$cand" "$s"; then echo "$s"; return 0; fi
  done <<<"$USED"
  return 1
}

# ---------- 1) .env ----------
if [[ ! -f "$ENV_FILE" ]]; then
  cp .env.example "$ENV_FILE"
  warn ".env criado a partir de .env.example — troque as senhas depois!"
fi

LAB_NET=$(grep -E '^LAB_NET=' "$ENV_FILE" | tail -1 | cut -d= -f2 | tr -d ' "' || true)
if [[ -z "$LAB_NET" ]]; then
  LAB_NET="10.200.50"
  printf '\nLAB_NET=%s\n' "$LAB_NET" >> "$ENV_FILE"
fi

# ---------- 2) checagem da rede ----------
if docker network inspect "$NET_NAME" >/dev/null 2>&1; then
  CUR=$(docker network inspect "$NET_NAME" --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}')
  if [[ "$CUR" == "${LAB_NET}.0/24" ]]; then
    ok "Rede $NET_NAME já existe com ${CUR} — reaproveitando"
  else
    fail "Rede $NET_NAME já existe com ${CUR}, mas o .env pede ${LAB_NET}.0/24. Rode 'docker compose down' e tente de novo."
  fi
else
  USED=$(used_subnets | sort -u)
  if hit=$(conflict_with "${LAB_NET}.0/24"); then
    warn "${LAB_NET}.0/24 conflita com ${hit} — procurando uma faixa livre..."
    found=""
    for a in 10 172 192; do
      case $a in
        10)  cands=$(for b in 200 201 202 210 220 230 240 250; do for c in 50 60 70 80 90; do echo "10.$b.$c"; done; done) ;;
        172) cands=$(for b in 28 29 30 31; do for c in 50 60 70; do echo "172.$b.$c"; done; done) ;;
        192) cands=$(for c in 250 240 230 220; do echo "192.168.$c"; done) ;;
      esac
      for cand in $cands; do
        if ! conflict_with "${cand}.0/24" >/dev/null; then found="$cand"; break 2; fi
      done
    done
    [[ -z "$found" ]] && fail "Nenhuma faixa livre encontrada. Ajuste LAB_NET no .env manualmente."
    sed -i "s/^LAB_NET=.*/LAB_NET=${found}/" "$ENV_FILE"
    LAB_NET="$found"
    ok "Usando ${LAB_NET}.0/24 (gravado no .env)"
  else
    ok "Sub-rede ${LAB_NET}.0/24 está livre"
  fi
fi

if [[ "${1:-}" == "--check" ]]; then
  info "IPs do lab:"
  printf '   %-18s %s\n' \
    wazuh-manager "${LAB_NET}.10"  wazuh-indexer  "${LAB_NET}.11" \
    wazuh-dashboard "${LAB_NET}.12" openvas       "${LAB_NET}.20" \
    metasploitable2 "${LAB_NET}.30" metasploitable3 "${LAB_NET}.31" \
    nginx "${LAB_NET}.40" rocky "${LAB_NET}.50" debian "${LAB_NET}.51" ubuntu "${LAB_NET}.52"
  exit 0
fi

# ---------- 3) pré-requisitos ----------
if [[ -r /proc/sys/vm/max_map_count ]] && (( $(cat /proc/sys/vm/max_map_count) < 262144 )); then
  warn "vm.max_map_count baixo — o Wazuh Indexer precisa de 262144"
  info "Rodando: sudo sysctl -w vm.max_map_count=262144"
  sudo sysctl -w vm.max_map_count=262144 >/dev/null
fi

if [[ ! -f config/wazuh_indexer_ssl_certs/root-ca.pem ]]; then
  info "Gerando certificados do Wazuh..."
  docker compose -f generate-indexer-certs.yml run --rm generator
fi

# ---------- 4) subir ----------
info "Subindo o lab em ${LAB_NET}.0/24 ..."
docker compose up -d --build "$@"
ok "Pronto! Veja o status com: docker compose ps"
