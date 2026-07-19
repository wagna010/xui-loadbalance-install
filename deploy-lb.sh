#!/bin/bash
# Instala o LB2 em um servidor. Rodar no PRINCIPAL.
#
#   ./deploy-lb.sh root@10.0.0.5 'senha-ssh' 3
#   ./deploy-lb.sh root@10.0.0.5:2222 'senha-ssh' 3   # porta SSH diferente
#   ./deploy-lb.sh root@10.0.0.5 '' 3                 # autenticacao por chave
#
# O ultimo argumento e o id do servidor no painel. O mesmo comando serve para
# instalar, reinstalar e atualizar — nada e duplicado.
#
# Antes: cadastre o servidor no painel (Servers) e instale o XUI na maquina de
# destino. E o XUI que roda o ffmpeg dos canais e cria
# /home/xui/content/streams, de onde o LB2 le.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REMOTE_DIR=/root/lb2-install

# No pacote de distribuicao os auxiliares ficam em lib/ e o binario em bin/;
# rodando da pasta deploy/ do projeto, fica tudo junto. Aceita os dois layouts.
[ -d "$HERE/lib" ] && LIB="$HERE/lib" || LIB="$HERE"
# Prefere o binario ja instalado aqui: e a versao rodando e comprovadamente boa.
[ -f /home/xui/loadbalance/lb2 ] && BIN=/home/xui/loadbalance/lb2 || BIN="$HERE/bin/lb2"

falha() { echo; echo "ERRO: $*" >&2; exit 1; }
passo() { echo; echo "── $* ──"; }

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ $# -lt 3 ]; then
    sed -n '2,13p' "$0" | sed 's/^# \?//'
    [ $# -gt 0 ] && [ $# -lt 3 ] && echo && echo "Faltou o id do servidor no painel."
    exit 0
fi

DESTINO="$1"
SSH_PASS="$2"
SERVER_ID="$3"

[ "$(id -u)" -eq 0 ] || falha "rode como root, no servidor principal."
[[ "$SERVER_ID" =~ ^[0-9]+$ ]] || falha "o id do servidor deve ser um numero. Veja em Servers, no painel."

# ── Separa usuario, host e porta ────────────────────────────────────────────
USUARIO="${DESTINO%@*}"
RESTO="${DESTINO#*@}"
HOST="${RESTO%%:*}"
PORTA="22"
[ "$RESTO" != "${RESTO#*:}" ] && PORTA="${RESTO##*:}"
[ -n "$USUARIO" ] && [ -n "$HOST" ] || falha "destino invalido. Use: root@10.0.0.5 ou root@10.0.0.5:2222"

# ── SSH com ou sem senha ────────────────────────────────────────────────────
if [ -n "$SSH_PASS" ] && ! command -v sshpass >/dev/null; then
    apt-get install -y sshpass >/dev/null 2>&1 || falha "instale o sshpass, ou use autenticacao por chave."
fi

SSH_OPTS=(-p "$PORTA" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR)
SCP_OPTS=(-P "$PORTA" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
if [ -n "$SSH_PASS" ]; then
    remoto() { sshpass -p "$SSH_PASS" ssh "${SSH_OPTS[@]}" "${USUARIO}@${HOST}" "$@"; }
    enviar() { sshpass -p "$SSH_PASS" scp "${SCP_OPTS[@]}" "$@" "${USUARIO}@${HOST}:${REMOTE_DIR}/"; }
else
    remoto() { ssh "${SSH_OPTS[@]}" "${USUARIO}@${HOST}" "$@"; }
    enviar() { scp "${SCP_OPTS[@]}" "$@" "${USUARIO}@${HOST}:${REMOTE_DIR}/"; }
fi

# ── 1. Conexao ──────────────────────────────────────────────────────────────
passo "1/5  Conectando em ${USUARIO}@${HOST}:${PORTA}"
remoto "echo ok" >/dev/null 2>&1 || falha "nao consegui conectar. Confira o endereco, a porta e a senha."
echo "conectado."

# ── 2. Pre-requisitos ───────────────────────────────────────────────────────
passo "2/5  Verificando o destino e o cadastro"
remoto "test -d /home/xui/content/streams && test -f /home/xui/bin/nginx/conf/nginx.conf" \
    || falha "o XUI nao esta instalado em ${HOST}. Instale o XUI nessa maquina antes."

# Instalar apontando para um id inexistente deixaria o LB no ar sem nunca
# receber espectador — falha silenciosa, entao vale checar aqui.
NOME="$(mysql xui -N -e "SELECT server_name FROM servers WHERE id=${SERVER_ID};" 2>/dev/null || true)"
[ -n "$NOME" ] || falha "o servidor id=${SERVER_ID} nao existe no painel. Cadastre-o primeiro em Servers."
echo "XUI presente. Servidor: id=${SERVER_ID} (${NOME})"

# ── 3. Acesso ao banco ──────────────────────────────────────────────────────
passo "3/5  Liberando o acesso ao banco"
MAIN_IP="$(mysql xui -N -e "SELECT server_ip FROM servers WHERE is_main=1 LIMIT 1;")"
[ -n "$MAIN_IP" ] || falha "nao achei o IP do principal na tabela servers."

# O IP de origem do destino pode nao ser o do SSH (NAT, multiplas placas).
# Perguntar ao proprio destino qual rota ele usa evita um grant no IP errado.
IP_ORIGEM="$(remoto "ip route get ${MAIN_IP} 2>/dev/null | grep -oP 'src \K[0-9.]+' | head -1" || true)"
[ -n "$IP_ORIGEM" ] || IP_ORIGEM="$HOST"

TOKEN="$(bash "$LIB/grant-lb.sh" "$IP_ORIGEM" "$MAIN_IP" | grep -oE '^  [A-Za-z0-9+/=]{40,}$' | tr -d ' ')"
[ -n "$TOKEN" ] || falha "o grant-lb.sh nao devolveu um token."
echo "liberado para lb2@${IP_ORIGEM} (destino chega no principal por ${MAIN_IP})"

# ── 4. Envia e instala ──────────────────────────────────────────────────────
passo "4/5  Enviando e instalando"
[ -f "$BIN" ] || falha "binario nao encontrado em $BIN"
for f in install-lb.sh lb2.service patch_nginx.py; do
    [ -f "$LIB/$f" ] || falha "$f nao encontrado em $LIB"
done

remoto "mkdir -p ${REMOTE_DIR}"
enviar "$BIN" "$LIB/install-lb.sh" "$LIB/lb2.service" "$LIB/patch_nginx.py"
remoto "chmod +x ${REMOTE_DIR}/install-lb.sh"
remoto "cd ${REMOTE_DIR} && ./install-lb.sh ${SERVER_ID} ${TOKEN}" \
    || falha "a instalacao falhou no destino (a saida acima mostra em qual passo)."

# ── 5. Confere ──────────────────────────────────────────────────────────────
passo "5/5  Conferindo"
ATIVO="$(remoto "systemctl is-active lb2" || true)"
[ "$ATIVO" = "active" ] || falha "o servico nao ficou ativo no destino."
PAPEL="$(remoto "grep -o 'papel: .*' /var/log/lb2.log | tail -1" || true)"
remoto "rm -rf ${REMOTE_DIR}"

IP_PAINEL="$(mysql xui -N -e "SELECT server_ip FROM servers WHERE id=${SERVER_ID};")"

cat <<FIM

════════════════════════════════════════════════════════
 LB operacional em ${HOST}
   servidor : id=${SERVER_ID} (${NOME})
   ${PAPEL}
════════════════════════════════════════════════════════

FIM

# O principal redireciona os espectadores para o endereco cadastrado no painel.
# Se ele nao apontar para esta maquina, o LB fica no ar sem receber ninguem.
if [ "$IP_PAINEL" != "$HOST" ]; then
    echo "  Atencao: no painel este servidor esta como ${IP_PAINEL}, e voce"
    echo "  instalou em ${HOST}. Se os clientes devem chegar por ${HOST},"
    echo "  ajuste o campo em Servers — e por ele que o principal redireciona."
    echo
fi

echo "  Falta atribuir os canais a este servidor no painel."
