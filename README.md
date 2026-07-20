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

Com o XUI One já instalado e funcionando, como root:

```bash
cd /tmp
git clone https://github.com/wagna010/xui-loadbalance-install.git
cd xui-loadbalance-install
chmod +x install.sh
./install.sh
```

Roda do `/tmp` porque essa pasta é descartável — a instalação copia tudo o que
precisa para `/home/xui/loadbalance`, e o clone pode ser apagado depois. O
`chmod` é só garantia: os scripts já vêm com permissão de execução.

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
├── backup/          nginx.conf de antes da instalação
└── lib/             usados pelos scripts acima
```

É de lá que os comandos seguintes são rodados.

## Adicionar um LB

**1. Instale o XUI na máquina do LB**, como load balancer.

Não é opcional: é o ffmpeg do XUI que captura o canal e escreve os segmentos em
`/home/xui/content/streams`, de onde este motor lê. Cada LB roda o próprio
ffmpeg dos canais atribuídos a ele. É essa instalação também que cadastra o
servidor no painel e gera o id.

**2. Um comando no servidor principal**, com o id que o painel mostra em
**Servers**:

```bash
cd /home/xui/loadbalance
./deploy-lb.sh root@10.0.0.5 'senha-ssh' 3
```

Variações:

```bash
./deploy-lb.sh root@10.0.0.5:2222 'senha' 3   # porta SSH diferente
./deploy-lb.sh root@10.0.0.5 '' 3             # autenticação por chave
```

**3. Atribua os canais ao novo servidor no painel.** É isso que faz o principal
começar a mandar espectadores para ele.

O XUI no LB não vira legado: o ffmpeg dele continua sendo peça essencial. O que
sai de cena é o caminho PHP que entregava vídeo ao espectador — o gargalo.

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

## Um esquema só: LB2 **ou** oficial, nunca misturado

**Não dá para misturar um LB oficial do XUI com um LB2 sob o mesmo principal.**
Ou o principal e todos os LBs são LB2, ou tudo fica no esquema oficial. Só um dos
dois funciona por vez.

O motivo é a URL de entrega:

- **LB oficial**: só entende URLs **por token** — `/auth/<token>`, `/hls/<token>`,
  `/vauth/<token>`. O nginx dele não tem rota para `/live/usuario/senha/123.ts`.
- **LB2**: o principal redireciona preservando o caminho **puro**
  `/live/usuario/senha/123.ts` (e o `install.sh` desliga `encrypt_playlist`,
  então é esse o formato que sai).

Quando o principal em LB2 manda um espectador para um LB oficial, o LB oficial
recebe `/live/...`, não reconhece e responde **404** — o canal não abre. Vale o
inverso: um principal oficial redireciona por token, e o LB2 não decodifica token.
Os dois motores não se entendem na hora do redirect.

**Consequência prática — ao adotar o LB2, converta a frota inteira.** Depois do
`install.sh` no principal, rode o `deploy-lb.sh` em **cada** LB para convertê-lo:

```bash
cd /home/xui/loadbalance
./deploy-lb.sh root@IP-DO-LB 'senha-ssh' <id-do-LB>
```

Um LB que ficar no esquema oficial vai dar 404 e ficar sem receber ninguém. Se
você precisa de recursos que o LB2 não faz (MAG/Stalker e timeshift por token,
legendas), a frota inteira tem de permanecer oficial — o LB2 não é opção para
esses casos. Para voltar um servidor ao motor original, use o `uninstall.sh`.

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

A pasta `backup/` fica — é a única cópia do `nginx.conf` anterior à instalação,
e apagá-la junto seria uma porta de mão única. Remova quando quiser.

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
