#!/bin/bash
# Devolve o servidor ao motor de entrega original do XUI One.
#
#   ./uninstall.sh
#
# Os PHPs originais nunca foram apagados: basta o nginx voltar a apontar para
# eles. O painel, os canais e os usuarios nao sao tocados.
set -euo pipefail

DEST=/home/xui/loadbalance
NGINX_CONF=/home/xui/bin/nginx/conf/nginx.conf

falha() { echo; echo "ERRO: $*" >&2; exit 1; }

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    sed -n '2,7p' "$0" | sed 's/^# \?//'
    exit 0
fi

[ "$(id -u)" -eq 0 ] || falha "rode como root."

# Este script fica instalado dentro de /home/xui/loadbalance, que ele mesmo
# apaga no fim. Apagar o proprio arquivo no meio da execucao deixa o bash lendo
# um arquivo que nao existe mais, entao seguimos a partir de uma copia.
AQUI="$(cd "$(dirname "$0")" && pwd)"
if [ "$AQUI" = "/home/xui/loadbalance" ] && [ -z "${LB2_UNINSTALL_RELOCADO:-}" ]; then
    COPIA="$(mktemp /tmp/lb2-uninstall-XXXXXX.sh)"
    cp "$0" "$COPIA"
    chmod +x "$COPIA"
    LB2_UNINSTALL_RELOCADO=1 exec "$COPIA" "$@"
fi

echo "Voltando ao motor original do XUI..."

# ── 1. Acha e valida o backup ANTES de mexer em qualquer coisa ───────────────
# Restaurar o nginx e a parte que importa: sem os rewrites originais o servidor
# para de entregar. Por isso localizamos e VALIDAMOS o backup primeiro e
# abortamos se algo estiver errado — em vez de remover o servico e so depois
# descobrir que nao da para restaurar, deixando a entrega no chao.
#
# Ate a versao anterior os backups iam para /root; hoje ficam em $DEST/backup.
# Procuramos nos dois lugares e usamos o MAIS ANTIGO (o nome e a data): e ele que
# guarda o nginx.conf de antes de qualquer instalacao do LB2.
#
# nullglob faz um padrao sem correspondencia sumir em vez de sobrar literal —
# sem isso, com /root vazio, o antigo `ls` do glob literal falhava e o
# `set -e`/`pipefail` matava o script bem aqui, apos remover o servico.
shopt -s nullglob
CANDIDATOS=( /root/backup-motor-oficial-*/ "$DEST"/backup/backup-motor-oficial-*/ )
shopt -u nullglob

BACKUP=""
if [ ${#CANDIDATOS[@]} -gt 0 ]; then
    # Ordena por nome de pasta (data). A escolha do primeiro e feita com
    # expansao de parametro, nao `head`, para nao arriscar SIGPIPE sob pipefail.
    ORDENADOS="$(for d in "${CANDIDATOS[@]}"; do d="${d%/}"; echo "$(basename "$d")|$d"; done | sort)"
    PRIMEIRA="${ORDENADOS%%$'\n'*}"
    BACKUP="${PRIMEIRA#*|}"
fi

[ -n "$BACKUP" ] && [ -f "$BACKUP/nginx.conf" ] \
    || falha "nenhum backup do nginx em $DEST/backup/ nem em /root/. Abortei sem mexer no servico para nao derrubar a entrega; restaure o nginx.conf a mao se precisar."

# O backup guarda so o nginx.conf, sem os arquivos vizinhos (mime.types etc.)
# que ele referencia com caminho relativo. O nginx resolve um "include" relativo
# a partir do diretorio do ARQUIVO passado em -c, nao do -p — entao validar o
# backup no lugar onde ele esta sempre falharia com "mime.types nao encontrado",
# mesmo com o conteudo correto. Por isso testamos uma copia colocada ao lado do
# nginx.conf real, onde os vizinhos existem de verdade.
STAGING="$(dirname "$NGINX_CONF")/.lb2-uninstall-staging.conf"
cp "$BACKUP/nginx.conf" "$STAGING"
if ! /home/xui/bin/nginx/sbin/nginx -t -c "$STAGING" -p /home/xui/bin/nginx/ >/dev/null 2>&1; then
    rm -f "$STAGING"
    falha "o nginx.conf do backup ($BACKUP) esta invalido. Abortei sem mexer no servico."
fi
echo "  ok  backup validado: $BACKUP"

# ── 2. Para o servico ───────────────────────────────────────────────────────
systemctl stop lb2 2>/dev/null || true
systemctl disable lb2 2>/dev/null || true
rm -f /etc/systemd/system/lb2.service
systemctl daemon-reload
echo "  ok  servico removido"

# ── 3. Restaura o nginx ─────────────────────────────────────────────────────
# O staging ja foi validado no lugar certo; so falta aplicar o conteudo.
# "cp" (nao "mv") de proposito: cp sobrescreve o CONTEUDO do arquivo existente,
# preservando dono/permissao do nginx.conf ja instalado; "mv" trocaria o inode
# inteiro pelo do staging (criado por este script, dono root), e o nginx roda
# como usuario nao-root (ex.: "user xui;") — um nginx.conf dono de root fica
# ilegivel pra ele, e todo reload futuro falha silenciosamente com os workers
# antigos presos no ar. Confirmado na pratica: cp preserva, mv nao.
chmod u+w "$NGINX_CONF" 2>/dev/null || true
cp "$STAGING" "$NGINX_CONF"
rm -f "$STAGING"
if /home/xui/bin/nginx/sbin/nginx -t -c "$NGINX_CONF" -p /home/xui/bin/nginx/ >/dev/null 2>&1; then
    /home/xui/bin/nginx/sbin/nginx -s reload -c "$NGINX_CONF" -p /home/xui/bin/nginx/ 2>/dev/null || true
    echo "  ok  nginx restaurado de ${BACKUP}"
else
    # Nao deveria acontecer: o mesmo conteudo ja foi validado no passo 1.
    falha "o nginx.conf restaurado ficou invalido. Confira $BACKUP/nginx.conf a mao."
fi

# ── 4. Arquivos e usuario do banco ──────────────────────────────────────────
# O backup fica: e a unica copia do nginx.conf original, e apagar a rede de
# seguranca junto com o que ela protege seria uma porta de mao unica.
find "$DEST" -mindepth 1 -maxdepth 1 ! -name backup -exec rm -rf {} + 2>/dev/null || true
if [ -d "$DEST/backup" ]; then
    echo "  ok  $DEST esvaziado (backup mantido em $DEST/backup)"
else
    rmdir "$DEST" 2>/dev/null || true
    echo "  ok  $DEST removido"
fi

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
if [ -d "$DEST/backup" ]; then
    echo "O backup em $DEST/backup pode ser apagado quando quiser."
fi
