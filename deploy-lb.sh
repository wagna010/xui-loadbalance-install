#!/bin/bash
# Instala o LB2 em um servidor novo, do começo ao fim. Rodar no PRINCIPAL.
#
#   ./deploy-lb.sh root@10.0.0.5 'senha-ssh'
#   ./deploy-lb.sh root@10.0.0.5:2222 'senha-ssh'
#   ./deploy-lb.sh root@10.0.0.5            # usa chave SSH, sem senha
#   ./deploy-lb.sh root@10.0.0.5 'senha' 3  # forca o server-id 3
#
# O XUI ja precisa estar instalado no servidor de destino: e ele quem roda o
# ffmpeg dos canais e cria /home/xui/content/streams, que o LB2 le.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REMOTE_DIR=/root/lb2-install

# No pacote de distribuicao os auxiliares ficam em lib/ e o binario em bin/;
# rodando da pasta deploy/ do projeto, fica tudo junto. Aceita os dois layouts.
if [ -d "$HERE/lib" ]; then
    LIB="$HERE/lib"
else
    LIB="$HERE"
fi
# Prefere o binario ja instalado neste servidor: e a versao que esta rodando e
# comprovadamente funciona, entao os LBs recebem exatamente a mesma.
if [ -f /home/xui/loadbalance/lb2 ]; then
    BIN=/home/xui/loadbalance/lb2
else
    BIN="$HERE/bin/lb2"
fi

falha() { echo "ERRO: $*" >&2; exit 1; }
passo() { echo; echo "── $* ──"; }

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ $# -lt 1 ]; then
    sed -n '2,12p' "$0" | sed 's/^# \?//'
    exit 0
fi

DESTINO="$1"
SSH_PASS="${2:-}"
SERVER_ID_FORCADO="${3:-}"

[ "$(id -u)" -eq 0 ] || falha "rode como root, no servidor principal."

# ── Separa usuario, host e porta ────────────────────────────────────────────
USUARIO="${DESTINO%@*}"
RESTO="${DESTINO#*@}"
HOST="${RESTO%%:*}"
PORTA="22"
[ "$RESTO" != "${RESTO#*:}" ] && PORTA="${RESTO##*:}"
[ -n "$USUARIO" ] && [ -n "$HOST" ] || falha "destino invalido. Use: root@10.0.0.5 ou root@10.0.0.5:2222"

# ── Ferramentas ─────────────────────────────────────────────────────────────
if [ -n "$SSH_PASS" ] && ! command -v sshpass >/dev/null; then
    echo "Instalando sshpass..."
    apt-get install -y sshpass >/dev/null 2>&1 || falha "nao consegui instalar o sshpass. Instale manualmente ou use chave SSH."
fi

SSH_OPTS=(-p "$PORTA" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR)
if [ -n "$SSH_PASS" ]; then
    remoto() { sshpass -p "$SSH_PASS" ssh "${SSH_OPTS[@]}" "${USUARIO}@${HOST}" "$@"; }
    enviar() { sshpass -p "$SSH_PASS" scp -P "$PORTA" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$@" "${USUARIO}@${HOST}:${REMOTE_DIR}/"; }
else
    remoto() { ssh "${SSH_OPTS[@]}" "${USUARIO}@${HOST}" "$@"; }
    enviar() { scp -P "$PORTA" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$@" "${USUARIO}@${HOST}:${REMOTE_DIR}/"; }
fi

# ── 1. Conexao ──────────────────────────────────────────────────────────────
passo "1/6  Conectando em ${USUARIO}@${HOST}:${PORTA}"
remoto "echo ok" >/dev/null 2>&1 || falha "nao consegui conectar. Confira o endereco, a porta e a senha."
echo "conectado."

# ── 2. Pre-requisitos no destino ────────────────────────────────────────────
passo "2/6  Verificando o XUI no destino"
remoto "test -d /home/xui/content/streams && test -f /home/xui/bin/nginx/conf/nginx.conf" \
    || falha "o XUI nao esta instalado em ${HOST}. Instale o XUI como LB nesse servidor antes de rodar este script."

if [ -n "$SERVER_ID_FORCADO" ]; then
    SERVER_ID="$SERVER_ID_FORCADO"
else
    SERVER_ID="$(remoto "sed -n 's/^[[:space:]]*server_id[[:space:]]*=[[:space:]]*\"\?\([0-9]*\)\"\?[[:space:]]*$/\1/p' /home/xui/config/config.ini | head -1" || true)"
fi
[[ "${SERVER_ID:-}" =~ ^[0-9]+$ ]] || falha "nao consegui descobrir o server_id do destino. Informe como terceiro argumento: ./deploy-lb.sh $DESTINO 'senha' <server-id>"

# Confere que esse id existe no painel — instalar apontando para um id que nao
# foi cadastrado deixaria o LB no ar sem nunca receber espectador.
NOME="$(mysql xui -N -e "SELECT server_name FROM servers WHERE id=${SERVER_ID};" 2>/dev/null || true)"
[ -n "$NOME" ] || falha "o servidor id=${SERVER_ID} nao existe no painel. Cadastre-o primeiro em Servers."
echo "XUI presente. Servidor: id=${SERVER_ID} (${NOME})"

# ── 3. Descobre por qual IP o destino enxerga o principal ───────────────────
passo "3/6  Liberando o acesso ao banco"
MAIN_IP="$(mysql xui -N -e "SELECT server_ip FROM servers WHERE is_main=1 LIMIT 1;")"
[ -n "$MAIN_IP" ] || falha "nao achei o IP do principal na tabela servers."

# O IP de origem do destino pode nao ser o mesmo do SSH (NAT, multiplas placas).
# Perguntar ao proprio destino qual rota ele usa evita um grant no IP errado.
IP_ORIGEM="$(remoto "ip route get ${MAIN_IP} 2>/dev/null | grep -oP 'src \K[0-9.]+' | head -1" || true)"
[ -n "$IP_ORIGEM" ] || IP_ORIGEM="$HOST"
echo "destino chega no principal (${MAIN_IP}) usando o IP ${IP_ORIGEM}"

TOKEN="$(bash "$LIB/grant-lb.sh" "$IP_ORIGEM" "$MAIN_IP" | grep -oE '^  [A-Za-z0-9+/=]{40,}$' | tr -d ' ')"
[ -n "$TOKEN" ] || falha "o grant-lb.sh nao devolveu um token."
echo "acesso liberado para lb2@${IP_ORIGEM}"

# ── 4. Envia os arquivos ────────────────────────────────────────────────────
passo "4/6  Enviando arquivos"
[ -f "$BIN" ] || falha "binario nao encontrado em $BIN. Compile antes: cd lb2 && go build -o $BIN ./cmd/lb2"
for f in install-lb.sh lb2.service patch_nginx.py; do
    [ -f "$LIB/$f" ] || falha "$f nao encontrado em $LIB"
done

remoto "mkdir -p ${REMOTE_DIR}"
enviar "$BIN" "$LIB/install-lb.sh" "$LIB/lb2.service" "$LIB/patch_nginx.py"
remoto "chmod +x ${REMOTE_DIR}/install-lb.sh"
echo "enviados."

# ── 5. Instala no destino ───────────────────────────────────────────────────
passo "5/6  Instalando no destino"
remoto "cd ${REMOTE_DIR} && ./install-lb.sh ${SERVER_ID} ${TOKEN}" || falha "a instalacao falhou no destino (a saida acima mostra em qual passo)."

# ── 6. Confere que ficou operacional ────────────────────────────────────────
passo "6/6  Conferindo"
ATIVO="$(remoto "systemctl is-active lb2" || true)"
[ "$ATIVO" = "active" ] || falha "o servico nao esta ativo no destino."

PAPEL="$(remoto "grep -o 'papel: .*' /var/log/lb2.log | tail -1" || true)"
remoto "rm -rf ${REMOTE_DIR}"

echo
echo "════════════════════════════════════════════════════════"
echo " LB operacional em ${HOST}"
echo "   servidor : id=${SERVER_ID} (${NOME})"
echo "   ${PAPEL}"
echo "════════════════════════════════════════════════════════"
echo
echo "Falta so atribuir os canais a este servidor no painel."
