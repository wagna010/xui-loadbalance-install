#!/bin/bash
# Instala o LB2 neste servidor. Rodar no servidor NOVO, depois do XUI instalado.
#
#   ./install-lb.sh <server-id> <token>
#
# O server-id e o id que o servidor recebeu ao ser cadastrado no painel do XUI.
# O token vem do grant-lb.sh, rodado no principal, e ja carrega endereco, porta,
# base, usuario e senha — este servidor nao precisa saber mais nada sobre o
# principal.
#
# Precisa do binario lb2, do lb2.service e do patch_nginx.py por perto.
set -euo pipefail

DEST=/home/xui/loadbalance
UNIT=/etc/systemd/system/lb2.service
NGINX_CONF=/home/xui/bin/nginx/conf/nginx.conf
HERE="$(cd "$(dirname "$0")" && pwd)"

# No pacote de distribuicao o binario fica em bin/ e os auxiliares em lib/;
# rodando direto da pasta deploy/ do projeto, fica tudo junto. Aceita os dois.
if [ -f "$HERE/lb2" ]; then
    BIN="$HERE/lb2"
else
    BIN="$HERE/../bin/lb2"
fi

falha() { echo "ERRO: $*" >&2; exit 1; }

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ $# -lt 2 ]; then
    sed -n '2,11p' "$0" | sed 's/^# \?//'
    exit 0
fi

SERVER_ID="$1"
TOKEN="$2"

[ "$(id -u)" -eq 0 ] || falha "rode como root."
[[ "$SERVER_ID" =~ ^[0-9]+$ ]] || falha "server-id deve ser um numero (o id do servidor no painel)."

# ── 1. O XUI precisa estar instalado ────────────────────────────────────────
echo "[1/7] Verificando o XUI..."
[ -f "$NGINX_CONF" ] || falha "$NGINX_CONF nao existe. Instale o XUI antes."
[ -d /home/xui/content/streams ] || falha "/home/xui/content/streams nao existe. Instale o XUI antes."
[ -f "$BIN" ] || falha "binario 'lb2' nao encontrado ao lado deste script."
[ -f "$HERE/patch_nginx.py" ] || falha "patch_nginx.py nao encontrado em $HERE"

# ── 2. O token carrega tudo que precisamos do principal ─────────────────────
echo "[2/7] Lendo o token..."
DECODED="$(echo "$TOKEN" | base64 -d 2>/dev/null || true)"
[ -n "$DECODED" ] || falha "token invalido. Gere um novo com ./grant-lb.sh <ip-deste-servidor> no principal."

campo() { echo "$DECODED" | python3 -c "import json,sys; print(json.load(sys.stdin)['$1'])" 2>/dev/null || true; }
DB_HOST="$(campo h)"
DB_PORT="$(campo P)"
DB_NAME="$(campo d)"
DB_USER="$(campo u)"
DB_PASS="$(campo p)"
[ -n "$DB_HOST" ] && [ -n "$DB_PASS" ] || falha "token incompleto. Gere um novo com ./grant-lb.sh no principal."
echo "      banco: ${DB_HOST}:${DB_PORT}/${DB_NAME}  server_id=${SERVER_ID}"

# ── 3. Binario e configuracao ───────────────────────────────────────────────
echo "[3/7] Instalando em $DEST..."
mkdir -p "$DEST"
install -m 755 "$BIN" "$DEST/lb2"

cat > "$DEST/config.json" <<JSON
{
  "mysql_host": "${DB_HOST}",
  "mysql_port": ${DB_PORT:-3306},
  "mysql_user": "${DB_USER:-lb2}",
  "mysql_password": "${DB_PASS}",
  "mysql_database": "${DB_NAME:-xui}",
  "listen_addr": "127.0.0.1:9000",
  "server_id": ${SERVER_ID},
  "streams_dir": "/home/xui/content/streams",
  "vod_dir": "/home/xui/content/vod",
  "auth_cache_ttl_seconds": 45,
  "hub_idle_timeout_seconds": 20,
  "hls_idle_timeout_seconds": 90,
  "hls_session_ttl_seconds": 30,
  "subscriber_buffer": 64,
  "prebuffer_chunks": 48
}
JSON
chmod 600 "$DEST/config.json"

# As ferramentas de operacao ficam junto do binario. Sem isso elas so existiriam
# na pasta onde o pacote foi baixado — que o admin apaga, e depois nao sabe de
# onde rodar o proximo comando.
mkdir -p "$DEST/lib"
install -m 755 "$HERE/install-lb.sh"  "$DEST/lib/install-lb.sh"
install -m 755 "$HERE/patch_nginx.py" "$DEST/lib/patch_nginx.py"
install -m 644 "$HERE/lb2.service"    "$DEST/lib/lb2.service"

# No pacote completo o uninstall.sh esta na raiz; instalando um LB ele chega
# junto dos demais. LB2_FILES aponta para a raiz quando o install.sh e quem chama.
PKG="${LB2_FILES:-$HERE}"
for ORIGEM in "$PKG/uninstall.sh" "$HERE/uninstall.sh"; do
    if [ -f "$ORIGEM" ]; then
        install -m 755 "$ORIGEM" "$DEST/uninstall.sh"
        break
    fi
done

# ── 4. Servico ──────────────────────────────────────────────────────────────
echo "[4/7] Instalando o servico..."
install -m 644 "$HERE/lb2.service" "$UNIT"
touch /var/log/lb2.log
systemctl daemon-reload
systemctl enable lb2 >/dev/null 2>&1
systemctl restart lb2

# ── 5. So mexe no nginx depois que o LB2 provar que conecta no banco ────────
# Credencial errada e o erro mais provavel; melhor falhar aqui, com o nginx
# ainda intacto, do que deixar o servidor sem entregar nada.
echo "[5/7] Testando a conexao com o banco..."
OK=0
for _ in $(seq 1 10); do
    sleep 1
    if curl -sf --max-time 2 http://127.0.0.1:9000/lb2/health >/dev/null 2>&1; then
        OK=1
        break
    fi
done
if [ "$OK" -ne 1 ]; then
    echo "--- ultimas linhas do log ---" >&2
    tail -5 /var/log/lb2.log >&2
    systemctl stop lb2 || true
    falha "o LB2 nao subiu. Confira se o grant-lb.sh foi rodado no principal com o IP deste servidor, e se a porta ${DB_PORT} do principal esta acessivel daqui. O nginx nao foi alterado."
fi

# ── 6. nginx: backup, patch, valida a sintaxe, so entao recarrega ───────────
echo "[6/7] Apontando o nginx para o LB2..."
BACKUP="$DEST/backup/backup-motor-oficial-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP"
cp "$NGINX_CONF" "$BACKUP/nginx.conf"
[ -d /home/xui/www/stream ] && cp -r /home/xui/www/stream "$BACKUP/" 2>/dev/null || true

chmod u+w "$NGINX_CONF"
python3 "$HERE/patch_nginx.py"

if ! /home/xui/bin/nginx/sbin/nginx -t -c "$NGINX_CONF" -p /home/xui/bin/nginx/ >/dev/null 2>&1; then
    cp "$BACKUP/nginx.conf" "$NGINX_CONF"
    falha "a configuracao do nginx ficou invalida; restaurei o backup de $BACKUP"
fi
/home/xui/bin/nginx/sbin/nginx -s reload -c "$NGINX_CONF" -p /home/xui/bin/nginx/ 2>/dev/null || systemctl reload nginx 2>/dev/null || true
echo "      backup do estado anterior em $BACKUP"

# ── 7. Pronto ───────────────────────────────────────────────────────────────
echo "[7/7] Conferindo..."
sleep 2
PAPEL="$(grep -o 'papel: .*' /var/log/lb2.log | tail -1 || echo 'desconhecido')"
echo
echo "LB2 instalado. Servico: $(systemctl is-active lb2)"
echo "  server_id: ${SERVER_ID}"
echo "  ${PAPEL}"
echo
echo "Falta so atribuir os canais a este servidor no painel do XUI."
