#!/usr/bin/env python3
"""Aponta as rotas de streaming do nginx do XUI para o LB2.

As rotas do painel (player_api, playlist, epg, admin, portal Stalker) continuam
sendo servidas pelo PHP original — só a entrega de vídeo muda de motor.
"""
import re
import sys

CONF = "/home/xui/bin/nginx/conf/nginx.conf"

# Rewrites que mandavam vídeo para o motor PHP antigo. As demais linhas de
# rewrite (playlist, player_api, epg, probe) precisam continuar intactas.
STREAMING_REWRITES = [
    r"rewrite \^/play/",
    r"rewrite \^/key/",
    r"rewrite \^/movie/",
    r"rewrite \^/series/",
    r"rewrite \^/subtitle/",
    r"rewrite \^/hls/",
    r"rewrite \^/tsauth/",
    r"rewrite \^/thauth/",
    r"rewrite \^/auth/",
    r"rewrite \^/vauth/",
    r"rewrite \^/subauth/",
    r"rewrite \^/timeshift/",
    r"rewrite \^/thumb/",
    r"rewrite \^/live/",
    r"rewrite \^/\(\.\*\)/\(\.\*\)/\(\\d\+\)",
]

UPSTREAM = """
upstream lb2 {
    server 127.0.0.1:9000;
    keepalive 128;
}
"""

# proxy_buffering off é essencial: com buffer o nginx segura os chunks e
# reintroduz a latência que o LB2 existe para eliminar.
PROXY_BLOCK = """
        # ---- LB2: motor de entrega de streaming ----
        location ~ ^/(live|movie|series)/[^/]+/[^/]+/\\d+(\\.\\w+)?$ {
            proxy_pass http://lb2;
            proxy_http_version 1.1;
            proxy_set_header Host $host;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_buffering off;
            proxy_request_buffering off;
            proxy_read_timeout 24h;
            proxy_send_timeout 24h;
            proxy_ignore_client_abort off;
        }

        # O nome do segmento vem do ffmpeg do XUI (ex: 1_75.ts), não é só dígito.
        location ~ ^/hls/[^/]+/[^/]+/\\d+/[\\w.-]+\\.ts$ {
            proxy_pass http://lb2;
            proxy_http_version 1.1;
            proxy_set_header Host $host;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_buffering off;
            proxy_read_timeout 60s;
        }

        # Formato legado /usuario/senha/123 — exatamente três segmentos, então
        # não conflita com /live/... nem com as rotas .php do painel.
        location ~ ^/[^/]+/[^/]+/\\d+(\\.\\w+)?$ {
            proxy_pass http://lb2;
            proxy_http_version 1.1;
            proxy_set_header Host $host;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_buffering off;
            proxy_request_buffering off;
            proxy_read_timeout 24h;
            proxy_send_timeout 24h;
        }
        # ---- fim LB2 ----
"""


def anchor_after(conf, pattern, insert):
    """Insere `insert` logo após a primeira linha que casa com `pattern`.
    Devolve None quando a âncora não existe, para o chamador tentar a próxima."""
    m = re.search(pattern, conf, re.MULTILINE)
    if not m:
        return None
    return conf[:m.end()] + insert + conf[m.end():]


def main():
    with open(CONF, "r", encoding="utf-8") as fh:
        conf = fh.read()

    if "upstream lb2" in conf:
        print("nginx.conf já aponta para o LB2, nada a fazer.")
        return 0

    lines = conf.splitlines(keepends=True)
    kept, removed = [], 0
    for line in lines:
        if any(re.search(pattern, line) for pattern in STREAMING_REWRITES):
            removed += 1
            continue
        kept.append(line)
    conf = "".join(kept)

    # O upstream só precisa estar dentro do bloco http. No principal ancoramos no
    # 'include balance.conf;'; um LB não tem esse include (balance.conf é a config
    # de balanceamento que só o principal usa), então caímos para logo após a
    # abertura do 'http {', que existe em qualquer nginx.conf do XUI.
    novo = anchor_after(conf, r"^[ \t]*include[ \t]+balance\.conf;[ \t]*\n", UPSTREAM)
    if novo is None:
        novo = anchor_after(conf, r"^[ \t]*http[ \t]*\{[ \t]*\n", UPSTREAM)
    if novo is None:
        print("ERRO: não achei onde ancorar o upstream (nem 'include balance.conf;' nem 'http {').", file=sys.stderr)
        return 1
    conf = novo

    # As locations entram logo após o root do server que serve o streaming.
    # Tolerante a indentação (principal e LB podem diferir).
    novo = anchor_after(conf, r"^[ \t]*root[ \t]+/home/xui/www/;[ \t]*\n", PROXY_BLOCK)
    if novo is None:
        print("ERRO: não encontrei a diretiva 'root /home/xui/www/;' do server.", file=sys.stderr)
        return 1
    conf = novo

    with open(CONF, "w", encoding="utf-8") as fh:
        fh.write(conf)

    print(f"Rewrites de streaming removidos: {removed}")
    print("nginx.conf atualizado para usar o LB2.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
