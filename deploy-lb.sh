#!/bin/bash
# Instala o LB2 em um servidor. Rodar no PRINCIPAL.
#
#   ./deploy-lb.sh root@10.0.0.5 'senha-ssh'          # cadastra e instala
#   ./deploy-lb.sh root@10.0.0.5 'senha-ssh' 3        # usa o id 3 do painel
#   ./deploy-lb.sh root@10.0.0.5:2222 'senha-ssh'     # porta SSH diferente
#   ./deploy-lb.sh root@10.0.0.5 ''                   # autenticacao por chave
#
# Sem o id, o script procura um servidor com esse IP no painel: se achar, usa;
# se nao achar, cadastra um novo. Rodar de novo nao duplica.
#
# Com o id, usa exatamente aquele servidor — util quando o cadastro tem outro
# endereco (IP privado, dominio) ou quando a maquina mudou de lugar.
#
# O mesmo comando serve para instalar, reinstalar e atualizar.
#
# Antes: instale o XUI na maquina de destino. E o XUI que roda o ffmpeg dos
# canais e cria /home/xui/content/streams, de onde o LB2 le.
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

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ $# -lt 2 ]; then
    sed -n '2,18p' "$0" | sed 's/^# \?//'
    exit 0
fi

DESTINO="$1"
SSH_PASS="$2"
SERVER_ID="${3:-}"

[ "$(id -u)" -eq 0 ] || falha "rode como root, no servidor principal."
[ -z "$SERVER_ID" ] || [[ "$SERVER_ID" =~ ^[0-9]+$ ]] \
    || falha "o id do servidor deve ser um numero. Veja em Servers, no painel."

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

# ── 2. Pre-requisitos e cadastro ────────────────────────────────────────────
passo "2/5  Verificando o destino e o cadastro"
remoto "test -d /home/xui/content/streams && test -f /home/xui/bin/nginx/conf/nginx.conf" \
    || falha "o XUI nao esta instalado em ${HOST}. Instale o XUI nessa maquina antes."
echo "XUI presente em ${HOST}."

MAIN_IP="$(mysql xui -N -e "SELECT server_ip FROM servers WHERE is_main=1 LIMIT 1;")"
[ -n "$MAIN_IP" ] || falha "nao achei o IP do principal na tabela servers."

# O IP de origem do destino pode nao ser o do SSH (NAT, multiplas placas).
# Perguntar ao proprio destino qual rota ele usa evita um grant no IP errado.
IP_ORIGEM="$(remoto "ip route get ${MAIN_IP} 2>/dev/null | grep -oP 'src \K[0-9.]+' | head -1" || true)"
[ -n "$IP_ORIGEM" ] || IP_ORIGEM="$HOST"

CRIADO=0
if [ -n "$SERVER_ID" ]; then
    # Instalar apontando para um id inexistente deixaria o LB no ar sem nunca
    # receber espectador — falha silenciosa, entao vale checar aqui.
    NOME="$(mysql xui -N -e "SELECT server_name FROM servers WHERE id=${SERVER_ID};" 2>/dev/null || true)"
    [ -n "$NOME" ] || falha "o servidor id=${SERVER_ID} nao existe no painel. Rode sem o id para cadastra-lo."
    echo "Servidor: id=${SERVER_ID} (${NOME})"
else
    # Sem id: reaproveita o cadastro que ja tenha este IP. E o que torna a forma
    # curta repetivel — rodar de novo atualiza o mesmo LB em vez de duplicar.
    SERVER_ID="$(mysql xui -N -e "SELECT id FROM servers WHERE server_ip='${HOST}' LIMIT 1;" 2>/dev/null || true)"

    if [ -n "$SERVER_ID" ]; then
        NOME="$(mysql xui -N -e "SELECT server_name FROM servers WHERE id=${SERVER_ID};")"
        echo "Servidor ja cadastrado: id=${SERVER_ID} (${NOME})"
    else
        # Se o destino alcanca o principal usando o proprio IP do principal, o
        # destino E o principal. Cadastrar aqui criaria um servidor duplicado
        # competindo com o main pelos mesmos canais.
        [ "$IP_ORIGEM" != "$MAIN_IP" ] \
            || falha "este destino e o proprio servidor principal. Para converte-lo use ./install.sh, nao o deploy-lb.sh."

        # Id sequencial em vez do AUTO_INCREMENT: apagar e recadastrar servidores
        # deixa o contador adiantado, e o admin acaba com ids esparsos no painel.
        SERVER_ID="$(mysql xui -N -e "SELECT COALESCE(MAX(id),0)+1 FROM servers;")"
        [[ "$SERVER_ID" =~ ^[0-9]+$ ]] || falha "nao consegui calcular o proximo id de servidor."

        # Reaproveitar um id ja usado antes traz junto o que sobrou dele. Sao
        # linhas orfas — apontam para um servidor que nao existe mais — e sem
        # limpar, o LB novo herdaria canais e sessoes que nunca foram dele.
        mysql xui -e "DELETE FROM streams_servers WHERE server_id=${SERVER_ID};
                      DELETE FROM lines_live      WHERE server_id=${SERVER_ID};"

        NOME="LB ${HOST}"
        # Quase toda coluna de 'servers' tem DEFAULT util; so preenchemos o que
        # define a identidade e o que o roteamento le (enabled/last_status).
        mysql xui -e "INSERT INTO servers
            (id, server_type, xui_version, server_name, server_ip, is_main, parent_id,
             enabled, last_status, status, http_broadcast_port, total_clients,
             network_interface)
            VALUES (${SERVER_ID}, 0,
                    (SELECT v FROM (SELECT xui_version AS v FROM servers WHERE is_main=1 LIMIT 1) t),
                    '${NOME}', '${HOST}', 0, 0, 1, 1, 1, 80, 1000, 'auto');" \
            || falha "nao consegui cadastrar o servidor no painel."
        CRIADO=1
        echo "Servidor cadastrado no painel: id=${SERVER_ID} (${NOME})"
    fi
fi

# ── 3. Acesso ao banco ──────────────────────────────────────────────────────
passo "3/5  Liberando o acesso ao banco"
TOKEN="$(bash "$LIB/grant-lb.sh" "$IP_ORIGEM" "$MAIN_IP" | grep -oE '^  [A-Za-z0-9+/=]{40,}$' | tr -d ' ')"
[ -n "$TOKEN" ] || falha "o grant-lb.sh nao devolveu um token."
echo "liberado para lb2@${IP_ORIGEM} (destino chega no principal por ${MAIN_IP})"

# ── 4. Envia e instala ──────────────────────────────────────────────────────
passo "4/5  Enviando e instalando"
[ -f "$BIN" ] || falha "binario nao encontrado em $BIN"
for f in install-lb.sh lb2.service patch_nginx.py; do
    [ -f "$LIB/$f" ] || falha "$f nao encontrado em $LIB"
done
[ -f "$HERE/uninstall.sh" ] || falha "uninstall.sh nao encontrado em $HERE"

remoto "mkdir -p ${REMOTE_DIR}"
# O uninstall.sh vai junto para ficar instalado no LB: quem precisa reverter
# esta la, no servidor, e nao aqui.
enviar "$BIN" "$LIB/install-lb.sh" "$LIB/lb2.service" "$LIB/patch_nginx.py" "$HERE/uninstall.sh"
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

if [ "$CRIADO" -eq 1 ]; then
    echo "  Cadastro criado agora, com limite de 1000 clientes. Ajuste o nome e"
    echo "  o limite em Servers, no painel, se precisar."
    echo
fi

# O principal redireciona os espectadores para o endereco cadastrado no painel.
# Se ele nao apontar para esta maquina, o LB fica no ar sem receber ninguem.
if [ "$IP_PAINEL" != "$HOST" ]; then
    echo "  Atencao: no painel este servidor esta como ${IP_PAINEL}, e voce"
    echo "  instalou em ${HOST}. Se os clientes devem chegar por ${HOST},"
    echo "  ajuste o campo em Servers — e por ele que o principal redireciona."
    echo
fi

echo "  Falta atribuir os canais a este servidor no painel."
