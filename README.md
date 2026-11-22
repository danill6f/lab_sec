# Lab de Segurança — Docker Compose

Rede `lab_net` → **10.200.50.0/24** por padrão (gateway .1). O `./up.sh` troca a faixa sozinho se ela já estiver em uso.

| Serviço          | Container        | IP           | Acesso pelo host                  | Login                                   |
|------------------|------------------|--------------|-----------------------------------|-----------------------------------------|
| Wazuh Manager    | wazuh-manager    | 10.200.50.10  | 1514, 1515, 514/udp, 55000 (API)  | API: `wazuh-wui` / `MyS3cr37P450r.*-`   |
| Wazuh Indexer    | wazuh-indexer    | 10.200.50.11  | — (só interno)                    | `admin` / `SecretPassword`              |
| Wazuh Dashboard  | wazuh-dashboard  | 10.200.50.12  | https://localhost                 | `admin` / `SecretPassword`              |
| OpenVAS          | openvas          | 10.200.50.20  | http://localhost:9392             | `admin` / `OpenVAS@2026!`               |
| Metasploitable 2 | metasploitable2  | 10.200.50.30  | — (só interno, de propósito)      | `analista` / `Lab@2026!` · `msfadmin` / `msfadmin` |
| Metasploitable 3 (Linux) | metasploitable3 | 10.200.50.31 | — (só interno, de propósito) | `analista` / `Lab@2026!` · `msfadmin` / `msfadmin` |
| Nginx            | nginx            | 10.200.50.40  | http://localhost:8080             | `analista` / `Lab@2026!`                |
| Rocky Linux 9    | rocky            | 10.200.50.50  | `ssh -p 2221 analista@localhost`  | `analista` / `Lab@2026!`                |
| Debian 12        | debian           | 10.200.50.51  | `ssh -p 2222 analista@localhost`  | `analista` / `Lab@2026!`                |
| Ubuntu 24.04     | ubuntu           | 10.200.50.52  | `ssh -p 2223 analista@localhost`  | `analista` / `Lab@2026!`                |

**root** em Rocky, Debian, Ubuntu, Nginx, Metasploitable 2 e 3: `Root@2026!`
O usuário `analista` tem `sudo` (grupo `wheel` no Rocky, `sudo` no Debian/Ubuntu).
Todas as credenciais ficam no arquivo `.env` (criado a partir de `.env.example`, fora do git) — **troque antes de subir**.

## Requisitos
- Docker + Docker Compose v2
- ~8 GB de RAM livres (Wazuh Indexer e OpenVAS são os mais pesados)
- No host Linux (obrigatório para o Wazuh Indexer):
  ```bash
  sudo sysctl -w vm.max_map_count=262144
  echo "vm.max_map_count=262144" | sudo tee -a /etc/sysctl.conf
  ```

## Subindo (recomendado)
```bash
./up.sh            # checa a rede, cria .env, gera certificados e sobe tudo
./up.sh --check    # só verifica se a sub-rede está livre e mostra os IPs
```
O Docker **não** procura uma faixa livre quando a sub-rede é fixa — ele só
falha com `Pool overlaps with other one on this address space`. O `up.sh`
compara `LAB_NET` com todas as redes Docker e com as rotas do host (LAN, VPN)
e, se houver conflito, escolhe uma faixa livre e grava no `.env`.

## Subindo manualmente
```bash
cp .env.example .env      # troque as senhas
sudo sysctl -w vm.max_map_count=262144
docker compose -f generate-indexer-certs.yml run --rm generator
docker compose up -d --build
```

## Metasploitable 3 (Linux)
O projeto oficial ([rapid7/metasploitable3](https://github.com/rapid7/metasploitable3))
é distribuído como VM (Vagrant/Packer). Aqui usamos a imagem Docker da
comunidade `kirscht/metasploitable3-ub1404`, com todos os serviços ligados:
CUPS, ProFTPD, Apache, UnrealIRCd, Samba, SSH e MySQL. A versão Windows
(Server 2008) não roda em container — só como VM.

## Testes rápidos
```bash
# Entrar num host e varrer o alvo vulnerável
docker exec -it debian bash
ping 10.200.50.30

# Shell como root
docker exec -it rocky bash
su -            # senha: Root@2026!
```
No OpenVAS, crie um *Target* com `10.200.50.30` (ou `10.200.50.0/24`) e rode um *Task*.

## Trocar as senhas do Wazuh Indexer
O indexer lê `config/wazuh_indexer/internal_users.yml` na **primeira** inicialização.
```bash
docker run --rm -it wazuh/wazuh-indexer:4.12.0 \
  bash /usr/share/wazuh-indexer/plugins/opensearch-security/tools/hash.sh
```
Cole o hash no `internal_users.yml`, atualize o `.env` e recrie do zero
(`docker compose down -v && docker compose up -d`). Se trocar `API_PASSWORD`,
atualize também `config/wazuh_dashboard/wazuh.yml`.

## Próximo passo sugerido
Instalar o agente Wazuh em Rocky/Debian/Ubuntu apontando para `10.200.50.10`
para que os eventos desses hosts apareçam no dashboard.

## ⚠️ Segurança
O Metasploitable 2 é **intencionalmente vulnerável**: ele não publica portas no host.
Não exponha este lab na internet nem em redes de produção.
