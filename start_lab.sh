#!/usr/bin/env bash
# ==================================================================
#  start_lab.sh — configura e sobe o Lab de Segurança
#
#  ./start_lab.sh             modo interativo: sugere a rede (você pode
#                             trocar), pergunta usuário e senhas, preenche
#                             o .env e pede confirmação antes de subir
#  ./start_lab.sh --default   modo automático: escolhe rede livre, gera
#                             senhas fortes e só pede a confirmação final
#  ./start_lab.sh --check     só mostra a rede sugerida e os IPs
#
#  Em qualquer modo, se já existir um .env, os valores atuais são
#  reaproveitados como padrão (nada é sobrescrito sem você confirmar).
# ==================================================================
set -euo pipefail
cd "$(dirname "$0")"

NET_NAME="lab_net"
ENV_FILE=".env"
PROJECT="lab-seguranca"

# ------------------------------------------------------------------
#  Saída
# ------------------------------------------------------------------
B=$'\033[1m'; R=$'\033[0m'; CY=$'\033[36m'
info()  { printf '\033[1;34m[i]\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m[✓]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
fail()  { printf '\033[1;31m[✗]\033[0m %s\n' "$*" >&2; exit 1; }
title() { printf '\n%s== %s ==%s\n' "$B" "$*" "$R"; }

usage() { sed -n '3,14p' "$0" | sed 's/^#  \{0,1\}//'; exit 0; }

MODE="interactive"
case "${1:-}" in
  ""|-i|--interactive) ;;
  -d|--default|-y|--yes) MODE="default" ;;
  --check) MODE="check" ;;
  -h|--help) usage ;;
  *) fail "Opção desconhecida: $1 (use --help)" ;;
esac

command -v docker >/dev/null || fail "docker não encontrado"
docker info >/dev/null 2>&1 || fail "Não consegui falar com o Docker (o serviço está rodando? seu usuário está no grupo docker?)"

# ------------------------------------------------------------------
#  Helpers de IP / rede
# ------------------------------------------------------------------
ip2int() { local IFS=. a b c d; read -r a b c d <<<"$1"; echo $(( (a<<24) + (b<<16) + (c<<8) + d )); }

cidr_range() {   # "inicio fim" de um CIDR (IP sem máscara = /32)
  local ip="${1%/*}" mask=32
  [[ "$1" == */* ]] && mask="${1#*/}"
  local n size start
  n=$(ip2int "$ip"); size=$(( 1 << (32 - mask) ))
  start=$(( n & ~(size - 1) & 0xFFFFFFFF ))
  echo "$start $(( start + size - 1 ))"
}

overlaps() {
  local as ae bs be
  read -r as ae <<<"$(cidr_range "$1")"
  read -r bs be <<<"$(cidr_range "$2")"
  (( as <= be && bs <= ae ))
}

used_subnets() {   # redes Docker (exceto lab_net) + rotas do host
  local ids; ids=$(docker network ls -q)
  if [[ -n "$ids" ]]; then
    # shellcheck disable=SC2086
    docker network inspect $ids --format '{{.Name}} {{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null \
    | while read -r name subnets; do
        [[ "$name" == "$NET_NAME" ]] && continue
        for s in $subnets; do [[ "$s" == *.* ]] && echo "$s $name"; done
      done
  fi
  if command -v ip >/dev/null; then
    ip -4 route show 2>/dev/null | awk '$1 ~ /^[0-9]/ {print $1, "rota:" $3}'
  fi
}

conflict_with() {   # imprime "faixa (dono)" que conflita com $1
  local s owner
  while read -r s owner; do
    [[ -z "$s" ]] && continue
    if overlaps "$1" "$s"; then echo "$s ($owner)"; return 0; fi
  done <<<"$USED"
  return 1
}

valid_net() {   # 3 octetos, faixa privada
  [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  local a=${BASH_REMATCH[1]} b=${BASH_REMATCH[2]} c=${BASH_REMATCH[3]}
  (( a <= 255 && b <= 255 && c <= 255 )) || return 1
  (( a == 10 )) || (( a == 172 && b >= 16 && b <= 31 )) || (( a == 192 && b == 168 ))
}

find_free_net() {
  local cand
  for cand in "$@" \
      $(for b in 200 201 202 210 220 230 240 250; do for c in 50 60 70 80 90; do echo "10.$b.$c"; done; done) \
      $(for b in 28 29 30 31; do for c in 50 60 70; do echo "172.$b.$c"; done; done) \
      192.168.250 192.168.240 192.168.230; do
    [[ -z "$cand" ]] && continue
    valid_net "$cand" || continue
    conflict_with "${cand}.0/24" >/dev/null || { echo "$cand"; return 0; }
  done
  return 1
}

# ------------------------------------------------------------------
#  Helpers de .env / senhas
# ------------------------------------------------------------------
env_get() {   # env_get CHAVE  -> valor do .env (ou vazio)
  [[ -f "$ENV_FILE" ]] || return 0
  grep -E "^$1=" "$ENV_FILE" | tail -1 | cut -d= -f2- || true
}

gen_pass() {   # 16 chars com maiúscula, minúscula, número e símbolo
  local p
  while :; do
    p=$(LC_ALL=C tr -dc 'A-Za-z0-9@%+=_' </dev/urandom | head -c 16)
    [[ "$p" =~ [A-Z] && "$p" =~ [a-z] && "$p" =~ [0-9] && "$p" =~ [@%+=_] ]] && { echo "$p"; return; }
  done
}

valid_pass() {   # sem espaço, aspas, $, `, \, # (quebram .env/compose/shell)
  local p="$1"
  (( ${#p} >= 8 )) || { warn "Mínimo de 8 caracteres."; return 1; }
  [[ "$p" =~ [[:space:]\'\"\$\`\\#] ]] && { warn "Não use espaço, aspas, \$, \`, \\ ou #."; return 1; }
  return 0
}

valid_user() { [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || { warn "Use letras minúsculas, números, _ ou - (começando por letra)."; return 1; }; }

ask() {   # ask VAR "Pergunta" padrão [validador]
  local __var=$1 q=$2 def=$3 check=${4:-} ans
  while :; do
    read -rp "  $q [${CY}${def}${R}]: " ans || true
    ans=${ans:-$def}
    [[ -z "$check" ]] || "$check" "$ans" || continue
    printf -v "$__var" '%s' "$ans"; return
  done
}

ask_pass() {   # ask_pass VAR "Pergunta" valor_atual
  local __var=$1 q=$2 cur=$3 hint p1 p2
  if [[ -n "$cur" ]]; then hint="Enter = manter a atual"; else hint="Enter = gerar automaticamente"; fi
  while :; do
    read -rsp "  $q [${CY}${hint}${R}]: " p1 || true; echo
    if [[ -z "$p1" ]]; then
      printf -v "$__var" '%s' "${cur:-$(gen_pass)}"; return
    fi
    valid_pass "$p1" || continue
    read -rsp "  Confirme a senha: " p2 || true; echo
    [[ "$p1" == "$p2" ]] || { warn "As senhas não conferem."; continue; }
    printf -v "$__var" '%s' "$p1"; return
  done
}

bcrypt_hash() {   # gera hash bcrypt $2y$ (python3+bcrypt -> htpasswd -> container httpd)
  local p="$1" h=""
  if command -v python3 >/dev/null && python3 -c 'import bcrypt' 2>/dev/null; then
    h=$(P="$p" python3 -c 'import bcrypt,os;print(bcrypt.hashpw(os.environ["P"].encode(),bcrypt.gensalt(12)).decode())')
  elif command -v htpasswd >/dev/null; then
    h=$(htpasswd -nbBC 12 x "$p" | cut -d: -f2-)
  else
    info "Gerando hash bcrypt com um container httpd:alpine..."
    h=$(docker run --rm httpd:2.4-alpine htpasswd -nbBC 12 x "$p" | tr -d '\r' | cut -d: -f2-)
  fi
  [[ "$h" == \$2* ]] || fail "Não consegui gerar o hash bcrypt da senha do Wazuh."
  echo "\$2y\$${h#\$2?\$}"
}

INDEXER_USERS_BASE=config/wazuh_indexer/internal_users.yml
INDEXER_USERS_LOCAL=config/wazuh_indexer/internal_users.local.yml   # fora do git

set_indexer_hash() {   # set_indexer_hash usuario hash  (edita a cópia local)
  local f=$INDEXER_USERS_LOCAL
  [[ -f "$f" ]] || cp "$INDEXER_USERS_BASE" "$f"
  U="$1" H="$2" awk '
    $0 ~ "^"ENVIRON["U"]":" {inblk=1; print; next}
    /^[^ #]/ {inblk=0}
    inblk && /^  hash:/ {print "  hash: \"" ENVIRON["H"] "\""; inblk=0; next}
    {print}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  sed -i "s|^#   $1 .*|#   $1 -> (definida pelo start_lab.sh / .env)|" "$f"
}

# ------------------------------------------------------------------
#  1) Rede
# ------------------------------------------------------------------
title "Rede do laboratório"
CUR_NET=$(env_get LAB_NET)

if docker network inspect "$NET_NAME" >/dev/null 2>&1; then
  EXIST=$(docker network inspect "$NET_NAME" --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}')
  LAB_NET="${EXIST%.0/24}"
  ok "A rede $NET_NAME já existe com ${EXIST} — ela será reaproveitada."
  info "Para mudar de faixa: docker compose down  (e rode este script de novo)"
else
  USED=$(used_subnets | sort -u)
  if [[ -n "$CUR_NET" ]] && valid_net "$CUR_NET" && ! hit=$(conflict_with "${CUR_NET}.0/24"); then
    SUGGEST="$CUR_NET"
    ok "A faixa atual do .env (${CUR_NET}.0/24) está livre."
  else
    [[ -n "$CUR_NET" && -n "${hit:-}" ]] && warn "A faixa do .env (${CUR_NET}.0/24) conflita com ${hit}."
    SUGGEST=$(find_free_net "10.200.50") || fail "Não achei faixa livre automaticamente."
    ok "Faixa livre sugerida: ${SUGGEST}.0/24"
  fi

  if [[ "$MODE" == "interactive" ]]; then
    if [[ -n "$USED" ]]; then
      info "Faixas já em uso nesta máquina:"
      while read -r s owner; do printf '      %-18s %s\n' "$s" "$owner"; done <<<"$USED"
    fi
    while :; do
      ask LAB_NET "Sub-rede do lab (3 primeiros octetos, /24)" "$SUGGEST"
      valid_net "$LAB_NET" || { warn "Use uma faixa privada: 10.x.y, 172.16-31.y ou 192.168.y"; continue; }
      if hit=$(conflict_with "${LAB_NET}.0/24"); then warn "${LAB_NET}.0/24 conflita com ${hit}. Escolha outra."; continue; fi
      break
    done
  else
    LAB_NET="$SUGGEST"
  fi
fi

if [[ "$MODE" == "check" ]]; then
  printf '\n  IPs do lab em %s.0/24:\n' "$LAB_NET"
  printf '   %-18s %s\n' \
    wazuh-manager "${LAB_NET}.10"  wazuh-indexer  "${LAB_NET}.11" \
    wazuh-dashboard "${LAB_NET}.12" openvas "${LAB_NET}.20" \
    metasploitable2 "${LAB_NET}.30" metasploitable3 "${LAB_NET}.31" \
    nginx "${LAB_NET}.40" rocky "${LAB_NET}.50" debian "${LAB_NET}.51" ubuntu "${LAB_NET}.52"
  exit 0
fi

# ------------------------------------------------------------------
#  2) Credenciais
# ------------------------------------------------------------------
OLD_INDEXER_PASS=$(env_get INDEXER_PASSWORD); OLD_INDEXER_PASS=${OLD_INDEXER_PASS:-SecretPassword}

LAB_USER=$(env_get LAB_USER);         LAB_USER=${LAB_USER:-analista}
LAB_PASS=$(env_get LAB_PASS)
ROOT_PASS=$(env_get ROOT_PASS)
OPENVAS_USER=$(env_get OPENVAS_USER); OPENVAS_USER=${OPENVAS_USER:-admin}
OPENVAS_PASS=$(env_get OPENVAS_PASS)
INDEXER_PASSWORD=$(env_get INDEXER_PASSWORD)
WAZUH_VERSION=$(env_get WAZUH_VERSION); WAZUH_VERSION=${WAZUH_VERSION:-4.12.0}
DASHBOARD_PASSWORD=$(env_get DASHBOARD_PASSWORD); DASHBOARD_PASSWORD=${DASHBOARD_PASSWORD:-kibanaserver}
API_PASSWORD=$(env_get API_PASSWORD); API_PASSWORD=${API_PASSWORD:-MyS3cr37P450r.*-}

if [[ "$MODE" == "interactive" ]]; then
  title "Usuários e senhas"
  echo "  Usuário local e root valem para Rocky, Debian, Ubuntu, Nginx e Metasploitable 2/3."
  ask      LAB_USER     "Usuário local"                "$LAB_USER" valid_user
  ask_pass LAB_PASS     "Senha do usuário $LAB_USER"   "$LAB_PASS"
  ask_pass ROOT_PASS    "Senha do root"                "$ROOT_PASS"
  ask      OPENVAS_USER "Usuário web do OpenVAS"       "$OPENVAS_USER" valid_user
  ask_pass OPENVAS_PASS "Senha web do OpenVAS"         "$OPENVAS_PASS"
  ask_pass INDEXER_PASSWORD "Senha do admin do Wazuh (login no dashboard)" "$INDEXER_PASSWORD"
else
  [[ -n "$LAB_PASS" ]]         || LAB_PASS=$(gen_pass)
  [[ -n "$ROOT_PASS" ]]        || ROOT_PASS=$(gen_pass)
  [[ -n "$OPENVAS_PASS" ]]     || OPENVAS_PASS=$(gen_pass)
  [[ -n "$INDEXER_PASSWORD" ]] || INDEXER_PASSWORD=$(gen_pass)
fi

# ------------------------------------------------------------------
#  3) Resumo e confirmação
# ------------------------------------------------------------------
title "Resumo"
cat <<EOF
  Rede            ${LAB_NET}.0/24  (gateway ${LAB_NET}.1)

  Serviço            IP               Acesso pelo host
  wazuh-manager      ${LAB_NET}.10     1514, 1515, 514/udp, 55000
  wazuh-indexer      ${LAB_NET}.11     (interno)
  wazuh-dashboard    ${LAB_NET}.12     https://localhost
  openvas            ${LAB_NET}.20     http://localhost:9392
  metasploitable2    ${LAB_NET}.30     (interno)
  metasploitable3    ${LAB_NET}.31     (interno)
  nginx              ${LAB_NET}.40     http://localhost:8080
  rocky              ${LAB_NET}.50     ssh -p 2221 ${LAB_USER}@localhost
  debian             ${LAB_NET}.51     ssh -p 2222 ${LAB_USER}@localhost
  ubuntu             ${LAB_NET}.52     ssh -p 2223 ${LAB_USER}@localhost

  Credenciais
  Usuário local      ${LAB_USER} / ${LAB_PASS}
  root               ${ROOT_PASS}
  OpenVAS            ${OPENVAS_USER} / ${OPENVAS_PASS}
  Wazuh dashboard    admin / ${INDEXER_PASSWORD}
  Metasploitable     também msfadmin / msfadmin
EOF

INDEXER_CHANGED=""
[[ "$INDEXER_PASSWORD" != "$OLD_INDEXER_PASS" ]] && INDEXER_CHANGED=1
if [[ -n "$INDEXER_CHANGED" || -f "$INDEXER_USERS_LOCAL" ]]; then
  INDEXER_USERS_FILE="./$INDEXER_USERS_LOCAL"
else
  INDEXER_USERS_FILE="./$INDEXER_USERS_BASE"
fi
if [[ -n "$INDEXER_CHANGED" ]] && docker volume inspect "${PROJECT}_wazuh-indexer-data" >/dev/null 2>&1; then
  echo
  warn "O Wazuh Indexer já foi inicializado antes: a nova senha do admin só vale"
  warn "depois de recriar o volume (docker compose down -v apaga os dados do Wazuh)."
fi

echo
read -rp "  Gravar o .env e subir o lab agora? [S/n]: " go || true
[[ "${go:-S}" =~ ^[SsYy]$ ]] || { info "Cancelado. Nada foi alterado."; exit 0; }

# ------------------------------------------------------------------
#  4) Grava .env (+ hash do Wazuh)
# ------------------------------------------------------------------
[[ -f "$ENV_FILE" ]] && cp "$ENV_FILE" "$ENV_FILE.bak"
umask 077
cat > "$ENV_FILE" <<EOF
# ============================================================
#  Gerado por start_lab.sh em $(date '+%Y-%m-%d %H:%M')
#  Rode ./start_lab.sh de novo para alterar
# ============================================================

# Rede do lab (3 primeiros octetos da /24)
LAB_NET=${LAB_NET}

# Usuário local e root (Rocky, Debian, Ubuntu, Nginx, Metasploitable 2/3)
LAB_USER=${LAB_USER}
LAB_PASS=${LAB_PASS}
ROOT_PASS=${ROOT_PASS}

# OpenVAS (login web)
OPENVAS_USER=${OPENVAS_USER}
OPENVAS_PASS=${OPENVAS_PASS}

# Wazuh
WAZUH_VERSION=${WAZUH_VERSION}
INDEXER_USERNAME=admin
INDEXER_PASSWORD=${INDEXER_PASSWORD}
DASHBOARD_USERNAME=kibanaserver
DASHBOARD_PASSWORD=${DASHBOARD_PASSWORD}
API_USERNAME=wazuh-wui
API_PASSWORD=${API_PASSWORD}
INDEXER_USERS_FILE=${INDEXER_USERS_FILE}
EOF
umask 022
if [[ -f "$ENV_FILE.bak" ]]; then ok ".env gravado (o anterior ficou em .env.bak)"; else ok ".env gravado"; fi

if [[ -n "$INDEXER_CHANGED" ]]; then
  set_indexer_hash admin "$(bcrypt_hash "$INDEXER_PASSWORD")"
  ok "Hash da senha do admin do Wazuh gravado em $INDEXER_USERS_LOCAL"
fi

# ------------------------------------------------------------------
#  5) Pré-requisitos e subida
# ------------------------------------------------------------------
title "Subindo o lab"
if [[ -r /proc/sys/vm/max_map_count ]] && (( $(cat /proc/sys/vm/max_map_count) < 262144 )); then
  info "Ajustando vm.max_map_count=262144 (exigido pelo Wazuh Indexer)"
  sudo sysctl -w vm.max_map_count=262144 >/dev/null
fi

if [[ ! -f config/wazuh_indexer_ssl_certs/root-ca.pem ]]; then
  info "Gerando certificados do Wazuh..."
  docker compose -f generate-indexer-certs.yml run --rm generator
fi

docker compose up -d --build
echo
ok "Lab no ar em ${LAB_NET}.0/24 — status: docker compose ps"
info "O OpenVAS pode levar 30+ min na primeira subida (sincronizando feeds)."
