#!/bin/bash
# Devolve o servidor ao motor de entrega original do XUI One.
#
#   ./uninstall.sh
#
# Os PHPs originais nunca foram apagados: basta o nginx voltar a apontar para
# eles. O painel, os canais e os usuarios nao sao tocados.
set -euo pipefail

NGINX_CONF=/home/xui/bin/nginx/conf/nginx.conf

falha() { echo; echo "ERRO: $*" >&2; exit 1; }

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    sed -n '2,7p' "$0" | sed 's/^# \?//'
    exit 0
fi

[ "$(id -u)" -eq 0 ] || falha "rode como root."

# Este script fica instalado dentro de /home/xui/loadbalance, que ele mesmo
# apaga no passo 3. Apagar o proprio arquivo no meio da execucao deixa o bash
# lendo um arquivo que nao existe mais, entao seguimos a partir de uma copia.
AQUI="$(cd "$(dirname "$0")" && pwd)"
if [ "$AQUI" = "/home/xui/loadbalance" ] && [ -z "${LB2_UNINSTALL_RELOCADO:-}" ]; then
    COPIA="$(mktemp /tmp/lb2-uninstall-XXXXXX.sh)"
    cp "$0" "$COPIA"
    chmod +x "$COPIA"
    LB2_UNINSTALL_RELOCADO=1 exec "$COPIA" "$@"
fi

echo "Voltando ao motor original do XUI..."

# ── 1. Para o servico ───────────────────────────────────────────────────────
systemctl stop lb2 2>/dev/null || true
systemctl disable lb2 2>/dev/null || true
rm -f /etc/systemd/system/lb2.service
systemctl daemon-reload
echo "  ok  servico removido"

# ── 2. Restaura o nginx ─────────────────────────────────────────────────────
# Sem o nginx voltar aos rewrites originais o servidor fica sem entregar nada,
# entao esta e a parte que realmente importa.
BACKUP="$(ls -1d /root/backup-motor-oficial-*/ 2>/dev/null | sort | head -1 || true)"
if [ -n "$BACKUP" ] && [ -f "${BACKUP}nginx.conf" ]; then
    chmod u+w "$NGINX_CONF" 2>/dev/null || true
    cp "${BACKUP}nginx.conf" "$NGINX_CONF"
    if /home/xui/bin/nginx/sbin/nginx -t -c "$NGINX_CONF" -p /home/xui/bin/nginx/ >/dev/null 2>&1; then
        /home/xui/bin/nginx/sbin/nginx -s reload -c "$NGINX_CONF" -p /home/xui/bin/nginx/ 2>/dev/null || true
        echo "  ok  nginx restaurado de ${BACKUP}"
    else
        falha "o nginx.conf restaurado ficou invalido. Confira ${BACKUP}nginx.conf manualmente."
    fi
else
    echo "  !!  nenhum backup encontrado em /root/backup-motor-oficial-*/"
    echo "      remova as linhas do bloco 'LB2' e o 'upstream lb2' de $NGINX_CONF a mao,"
    echo "      e recoloque os rewrites de streaming do XUI."
fi

# ── 3. Arquivos e usuario do banco ──────────────────────────────────────────
rm -rf /home/xui/loadbalance
echo "  ok  /home/xui/loadbalance removido"

if mysql -N -e "SELECT 1" >/dev/null 2>&1; then
    mysql -N -e "SELECT CONCAT(\"DROP USER IF EXISTS 'lb2'@'\", host, \"';\") FROM mysql.user WHERE user='lb2';" \
        | mysql 2>/dev/null || true
    mysql -e "FLUSH PRIVILEGES;" 2>/dev/null || true
    echo "  ok  usuario lb2 do banco removido"
fi

# encrypt_playlist fica como esta. Religar seria mexer numa configuracao do
# painel que o administrador pode ter escolhido, e o motor original funciona
# com ela desligada.

echo
echo "Pronto. O XUI voltou a entregar o conteudo pelo motor original."
echo "O log /var/log/lb2.log foi mantido, caso precise consultar."
