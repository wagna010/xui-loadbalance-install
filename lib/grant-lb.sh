#!/bin/bash
# Libera o acesso do LB2 ao banco e gera o token de instalacao.
# Rodar no servidor PRINCIPAL.
#
#   ./grant-lb.sh                      # configura o proprio principal
#   ./grant-lb.sh 10.0.0.5             # libera um LB e imprime o token
#   ./grant-lb.sh 10.0.0.5 1.2.3.4     # idem, informando o IP do principal
#
# O token carrega host, porta, base, usuario e senha. E so isso que o LB
# precisa receber — ele nao depende de saber nada mais sobre o principal.
set -euo pipefail

DB=xui

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    sed -n '2,11p' "$0" | sed 's/^# \?//'
    exit 0
fi

[ "$(id -u)" -eq 0 ] || { echo "Rode como root." >&2; exit 1; }

if ! mysql -N -e "SELECT 1" >/dev/null 2>&1; then
    echo "Nao consegui falar com o MySQL local. Rode este script no servidor principal." >&2
    exit 1
fi

LB_IP="${1:-}"

# O LB precisa alcancar o principal pela rede. O IP vem do cadastro no painel,
# mas na nuvem o endereco util pode ser outro — dai o segundo argumento.
if [ -n "${2:-}" ]; then
    MAIN_IP="$2"
elif [ -n "$LB_IP" ]; then
    MAIN_IP="$(mysql ${DB} -N -e "SELECT server_ip FROM servers WHERE is_main=1 LIMIT 1;")"
    [ -n "$MAIN_IP" ] || { echo "Nao achei o IP do principal na tabela servers. Informe: ./grant-lb.sh $LB_IP <ip-do-principal>" >&2; exit 1; }
else
    MAIN_IP="127.0.0.1"
fi

# Cada host e uma identidade separada no MariaDB, entao a senha de um LB nao
# interfere na dos outros nem na do principal.
if [ -z "$LB_IP" ]; then
    HOSTS=("localhost" "127.0.0.1")
else
    HOSTS=("$LB_IP")
fi

PASS="$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)"

for HOST in "${HOSTS[@]}"; do
    mysql <<SQL
CREATE USER IF NOT EXISTS 'lb2'@'${HOST}' IDENTIFIED BY '${PASS}';
ALTER USER 'lb2'@'${HOST}' IDENTIFIED BY '${PASS}';

GRANT SELECT ON ${DB}.\`lines\`        TO 'lb2'@'${HOST}';
GRANT SELECT ON ${DB}.bouquets         TO 'lb2'@'${HOST}';
GRANT SELECT ON ${DB}.streams          TO 'lb2'@'${HOST}';
GRANT SELECT ON ${DB}.streams_episodes TO 'lb2'@'${HOST}';
GRANT SELECT ON ${DB}.streams_series   TO 'lb2'@'${HOST}';
GRANT SELECT ON ${DB}.streams_servers  TO 'lb2'@'${HOST}';
GRANT SELECT ON ${DB}.servers          TO 'lb2'@'${HOST}';
GRANT SELECT ON ${DB}.settings         TO 'lb2'@'${HOST}';

-- lines_live e a unica tabela que o LB2 escreve: as sessoes ativas.
GRANT SELECT, INSERT, UPDATE, DELETE ON ${DB}.lines_live TO 'lb2'@'${HOST}';

FLUSH PRIVILEGES;
SQL
    echo "  ok  lb2@${HOST}"
done

# A playlist com token aponta para /play/<token>, formato que o LB2 nao decodifica.
#
# Isto e uma configuracao GLOBAL do painel, entao so mexemos nela ao converter o
# principal (sem argumento). Ao liberar um LB o script e chamado pelo
# deploy-lb.sh, que por decisao de projeto nao altera o painel: mudar uma opcao
# global de dentro de um comando que o admin acha que so mexe num LB e o tipo de
# efeito colateral silencioso que ja derrubou servidor aqui. Nesse caso, avisa.
if [ -z "$LB_IP" ]; then
    mysql ${DB} -e "UPDATE settings SET encrypt_playlist=0, encrypt_playlist_restreamer=0;"
    echo "  ok  playlist sem criptografia"
elif [ "$(mysql ${DB} -N -e "SELECT COALESCE(MAX(encrypt_playlist),0) FROM settings;" 2>/dev/null || echo 0)" != "0" ]; then
    echo "  !!  encrypt_playlist esta LIGADO no painel."
    echo "      O LB2 nao decodifica /play/<token>, entao este LB nao vai entregar."
    echo "      Desligue em Settings, ou rode neste principal: ./grant-lb.sh"
fi

PORT="$(mysql -N -e "SELECT @@port;")"
TOKEN="$(printf '{"h":"%s","P":%s,"d":"%s","u":"lb2","p":"%s"}' \
    "$MAIN_IP" "$PORT" "$DB" "$PASS" | base64 -w0)"

echo
if [ -z "$LB_IP" ]; then
    echo "Token para o proprio principal:"
else
    echo "Token para o LB ${LB_IP} (aponta para o principal em ${MAIN_IP}:${PORT}):"
fi
echo
echo "  ${TOKEN}"
echo
echo "No servidor novo:  ./install-lb.sh <server-id> ${TOKEN}"
