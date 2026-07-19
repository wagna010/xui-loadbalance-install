# XUI LoadBalance

Motor de entrega de streaming para o XUI One.

O painel, a API, o admin, o EPG e o controle dos canais continuam sendo o XUI
original. Muda apenas **como o vídeo chega ao espectador**.

## Por que

No XUI original cada espectador ocupa um worker do PHP-FPM durante toda a
sessão. Worker de PHP é pesado, e é daí que vem boa parte do travamento.

Aqui a entrega é feita por um serviço em Go: cada espectador custa uma
goroutine, não um processo. Em teste, 300 espectadores simultâneos ocuparam
39 MB de memória, com **uma única** leitura por canal independentemente de
quantos estão assistindo.

Cobre canais ao vivo (TS e HLS), filmes e séries, com contagem de conexões,
limite por linha e troca de canal funcionando.

## Instalar no servidor principal

Com o XUI One já instalado e funcionando:

```bash
git clone https://github.com/wagna010/xui-loadbalance-install.git
cd xui-loadbalance-install
./install.sh
```

O script descobre o `server_id` pelo cadastro do próprio XUI, cria o usuário do
banco, instala o serviço, aponta o nginx e confere que subiu.

Se algo der errado no meio, ele para **antes** de mexer no nginx — o servidor
não fica quebrado pela metade.

## Adicionar um LB

Dois passos no painel do XUI, uma vez por LB:

1. Cadastrar o servidor em **Servers** (isso gera o id).
2. Instalar o XUI nesse servidor, como LB. É o XUI que roda o ffmpeg dos canais
   e cria `/home/xui/content/streams`, de onde este motor lê.

Depois, **um comando no servidor principal**:

```bash
./deploy-lb.sh root@10.0.0.5 'senha-ssh'
```

Variações:

```bash
./deploy-lb.sh root@10.0.0.5:2222 'senha'   # porta SSH diferente
./deploy-lb.sh root@10.0.0.5                # autenticação por chave
./deploy-lb.sh root@10.0.0.5 'senha' 3      # força o server-id
```

Por último, **atribua os canais ao novo servidor no painel**. É isso que faz o
principal começar a mandar espectadores para ele.

## Como o tráfego é distribuído

```
   cliente  ──►  PRINCIPAL  ──302──►  LB com o conteúdo  ──►  entrega o vídeo
                (só roteia)
```

O principal escolhe o LB com menos conexões entre os que têm aquele canal no ar
e redireciona. A playlist do cliente continua apontando para o domínio
principal, então nada muda para quem assiste.

**O principal só entrega vídeo se o admin atribuir o canal a ele no painel.** Se
os LBs responsáveis por um canal caírem, o canal fica fora do ar — o tráfego
nunca é desviado para o principal por conta própria.

## Operação

```bash
curl -s http://127.0.0.1:9000/lb2/stats   # conexões, canais, memória
tail -f /var/log/lb2.log                  # log
systemctl status lb2                      # serviço
```

O endpoint de métricas responde apenas de localhost.

## Voltar ao XUI original

```bash
./uninstall.sh
```

Restaura o nginx do backup e remove o serviço. Os PHPs originais do XUI nunca
são apagados, então a volta é imediata. Canais, usuários e as configurações do
painel não são tocados.

## Requisitos

- XUI One instalado e funcionando
- Linux x86-64
- No servidor principal: acesso ao MySQL local
- Nos LBs: alcançar a porta 3306 do principal

## O que não faz

Fora de escopo, para não haver surpresa:

- Legendas (rotas `/subtitle/...`)
- Transcodificação — a entrega é repasse puro
- Bloqueio por país ou operadora
- Autenticação de dispositivos MAG/Stalker e Enigma2
- Detecção de restream
- Playlist criptografada — a instalação desliga `encrypt_playlist`, porque o
  formato com token não é reconhecido por este motor. O controle de acesso
  continua por usuário e senha.
