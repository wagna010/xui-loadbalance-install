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

Terminada a instalação, tudo passa a viver em **`/home/xui/loadbalance`** e a
pasta do `git clone` pode ser apagada:

```
/home/xui/loadbalance/
├── lb2              o serviço
├── config.json      credenciais do banco (modo 600)
├── deploy-lb.sh     adicionar/atualizar um LB
├── uninstall.sh     voltar ao motor original
└── lib/             usados pelos scripts acima
```

É de lá que os comandos seguintes são rodados.

## Adicionar um LB

Instale o XUI na máquina que vai ser o LB — é ele que roda o ffmpeg dos canais e
cria `/home/xui/content/streams`, de onde este motor lê.

Depois, **um comando no servidor principal**:

```bash
cd /home/xui/loadbalance
./deploy-lb.sh root@10.0.0.5 'senha-ssh'
```

Ele cadastra o servidor no painel sozinho, com o próximo id livre, e instala.
Não é preciso criar nada em **Servers** antes — o painel do XUI não oferece essa
opção sem instalar a versão antiga junto.

Rodar de novo não duplica: o script procura um servidor com aquele IP e
reaproveita o cadastro se encontrar.

Variações:

```bash
./deploy-lb.sh root@10.0.0.5 'senha' 3        # usa o id 3, já cadastrado
./deploy-lb.sh root@10.0.0.5:2222 'senha'     # porta SSH diferente
./deploy-lb.sh root@10.0.0.5 ''               # autenticação por chave
```

Informe o id quando o cadastro tiver outro endereço (IP privado, domínio) ou
quando a máquina do LB tiver mudado de lugar — aí é o id que diz qual servidor
você está reinstalando.

O cadastro criado vem com limite de 1000 clientes; ajuste em **Servers** se
precisar.

Por último, **atribua os canais ao novo servidor no painel**. É isso que faz o
principal começar a mandar espectadores para ele.

### Atualizar, reinstalar ou trocar a máquina

Sempre o mesmo comando. Ele envia o binário atual, reinstala e reinicia; nada é
duplicado, então rodar de novo é seguro.

Ao trocar a máquina de um servidor, instale no endereço novo com o mesmo id e
**atualize o IP em Servers, no painel** — é por esse campo que o principal
monta o redirect. O script avisa quando o endereço cadastrado não bate com a
máquina onde ele acabou de instalar, mas não altera o cadastro: quem manda no
painel é você.

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

## Conviver com LBs do XUI original

Um LB instalado pelo método oficial do XUI e um LB instalado por aqui funcionam
lado a lado, sob o mesmo principal. Não é preciso migrar tudo de uma vez.

Funciona porque o principal redireciona preservando o caminho original
(`/live/usuario/senha/123.ts`) — que é o formato nativo do XUI — e escolhe o
servidor lendo apenas `servers`, `streams_servers` e `lines_live`. Não existe
marcador de versão: os dois tipos de LB são indistinguíveis para o roteamento, e
como ambos registram as sessões em `lines_live`, o balanceamento por menor carga
continua justo entre eles.

Duas coisas a saber:

- **No servidor principal não há convivência.** O `install.sh` substitui a
  entrega dele por completo. O principal continua entregando os canais que você
  atribuir a ele no painel, só que por este motor.
- **O painel não mostra qual servidor roda qual versão.** É o que faz a mistura
  funcionar, e o que atrapalha na hora de investigar um problema. Recursos fora
  de escopo (legendas, MAG/Stalker, Enigma2) falham se o espectador cair num LB
  deste motor e funcionariam num LB oficial.

## Operação

```bash
curl -s http://127.0.0.1:9000/lb2/stats   # conexões, canais, memória
tail -f /var/log/lb2.log                  # log
systemctl status lb2                      # serviço
```

O endpoint de métricas responde apenas de localhost.

## Voltar ao XUI original

```bash
/home/xui/loadbalance/uninstall.sh
```

Vale para o principal e para cada LB — o desinstalador fica instalado em todos.

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
- Playlist criptografada — o `install.sh` desliga `encrypt_playlist`, porque o
  formato com token não é reconhecido por este motor. O controle de acesso
  continua por usuário e senha. Se a opção for religada depois, o `deploy-lb.sh`
  **avisa mas não altera**: é uma configuração global do painel, e quem manda
  nela é você.
