#!/bin/bash
# Converte um XUI One original para usar o motor de entrega LoadBalance.
# Rodar no SERVIDOR PRINCIPAL, com o XUI ja instalado.
#
#   ./install.sh
#
# O painel, a API, o admin e o controle dos canais continuam sendo o XUI
# original. Muda apenas quem entrega o video aos espectadores.
#
# Para instalar em um LB depois, use:  ./deploy-lb.sh root@ip 'senha'
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

falha() { echo; echo "ERRO: $*" >&2; exit 1; }

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    sed -n '2,10p' "$0" | sed 's/^# \?//'
    exit 0
fi

echo "╔══════════════════════════════════════════════════════╗"
echo "║   XUI LoadBalance — instalacao no servidor principal ║"
echo "╚══════════════════════════════════════════════════════╝"

[ "$(id -u)" -eq 0 ] || falha "rode como root."

# ── Pre-requisitos ──────────────────────────────────────────────────────────
[ -f /home/xui/bin/nginx/conf/nginx.conf ] || falha "o XUI nao esta instalado neste servidor."
[ -d /home/xui/content/streams ] || falha "/home/xui/content/streams nao existe. O XUI parece incompleto."
[ -f "$HERE/bin/lb2" ] || falha "binario nao encontrado em $HERE/bin/lb2"

mysql -N -e "SELECT 1" >/dev/null 2>&1 \
    || falha "sem acesso ao MySQL local. Este script roda no servidor principal, onde fica o banco."

# O id deste servidor vem do proprio cadastro do XUI.
SERVER_ID="$(sed -n 's/^[[:space:]]*server_id[[:space:]]*=[[:space:]]*"\?\([0-9]*\)"\?[[:space:]]*$/\1/p' /home/xui/config/config.ini | head -1)"
[[ "${SERVER_ID:-}" =~ ^[0-9]+$ ]] || falha "nao consegui ler o server_id de /home/xui/config/config.ini"

NOME="$(mysql xui -N -e "SELECT server_name FROM servers WHERE id=${SERVER_ID};" 2>/dev/null || true)"
[ -n "$NOME" ] || falha "o servidor id=${SERVER_ID} nao existe na tabela servers do painel."
echo
echo "Servidor: id=${SERVER_ID} (${NOME})"

# ── 1. Acesso ao banco ──────────────────────────────────────────────────────
echo
echo "── Liberando o acesso ao banco ──"
TOKEN="$(bash "$HERE/lib/grant-lb.sh" | grep -oE '^  [A-Za-z0-9+/=]{40,}$' | tr -d ' ')"
[ -n "$TOKEN" ] || falha "nao consegui gerar o token de acesso ao banco."

# ── 2. Instalacao ───────────────────────────────────────────────────────────
echo
LB2_FILES="$HERE" bash "$HERE/lib/install-lb.sh" "$SERVER_ID" "$TOKEN"

# ── 3. Ferramentas que so o principal usa ───────────────────────────────────
# Ficam junto do binario para que a pasta do git clone possa ser apagada.
install -m 755 "$HERE/deploy-lb.sh"     /home/xui/loadbalance/deploy-lb.sh
install -m 755 "$HERE/lib/grant-lb.sh"  /home/xui/loadbalance/lib/grant-lb.sh

# ── 4. Pronto ───────────────────────────────────────────────────────────────
cat <<FIM

╔══════════════════════════════════════════════════════╗
║   Instalado                                          ║
╚══════════════════════════════════════════════════════╝

  Tudo fica em /home/xui/loadbalance — esta pasta do git clone
  pode ser apagada.

  Metricas:  curl -s http://127.0.0.1:9000/lb2/stats
  Log:       tail -f /var/log/lb2.log
  Servico:   systemctl status lb2

  Para adicionar um LB:
    cd /home/xui/loadbalance
    ./deploy-lb.sh root@IP-DO-LB 'senha-ssh'

  Para voltar ao XUI original:
    /home/xui/loadbalance/uninstall.sh

FIM
