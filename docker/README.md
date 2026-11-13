# reCSQTT в Docker Compose

Образ из GHCR разворачивает сервер **с нуля**: при первом `up` контейнер сам
создаёт identity панели, `install.json`, self-signed сертификат и каталог
`/etc/csqtt`, а сервер при первом запуске создаёт SQLite-базу. Установщик
`scripts/install.sh` для этого не нужен. Каталог `./csqtt-data` переживает
`down`/`up` и пересоздание контейнера.

## Требования к хосту

- Linux **amd64** (сервер собирается только под amd64) и Docker с Compose v2.
- `/dev/net/tun` на хосте: `sudo modprobe tun` (обычно модуль уже загружен).
  Docker не создаёт TUN-узел сам, а без него контейнер не стартует.
- Файл блокировки iptables: `sudo touch /run/xtables.lock`. Если Docker успел
  создать на этом месте каталог, после `docker compose down` выполните
  `sudo rmdir /run/xtables.lock` и создайте файл заново.
- Свободные порты: `46000/udp` (туннель), `443/tcp` в доменном режиме или
  `46002/tcp` в IP-режиме, `80/tcp` (зарезервирован под ACME/HTTP).
- Запуск от root или пользователя в группе `docker`: контейнер работает в
  `network_mode: host` и управляет netfilter хоста.

## Быстрый старт

```bash
sudo touch /run/xtables.lock   # один раз, см. «Требования к хосту»
cd docker
cp .env.example .env        # при необходимости: CSQTT_IMAGE, CSQTT_HOST
docker compose up -d
docker logs csqtt
```

Дальше все команды в этом README выполняются из каталога `docker/`.

В логах при первом старте печатается блок с URL, логином и паролем панели —
например:

```
Панель reCSQTT готова (пароль показан один раз):
  URL:     https://203.0.113.7:46002/k3f9a1c7d2e4b8f0
  Логин:   a1b2c3d4e5
  Пароль:  ...
```

Пароль и логин повторно не печатаются. Достать их позже:

```bash
docker exec csqtt cat /etc/csqtt/csqtt.env
# или с хоста:
sudo cat csqtt-data/csqtt.env
```

Учётные данные печатаются заново только если пароль пришлось сгенерировать
(например, `csqtt.env` потеряли, а `install.json` остался).

## Первый старт: что создаётся

`entrypoint.sh` при отсутствии `install.json` или `csqtt.env`:

1. Создаёт `/etc/csqtt` с правами `0700`, ничего не удаляя; уже существующие
   значения identity сохраняются, дописывается только недостающее.
2. Генерирует логин (10 символов), пароль (24) и secret path (16) — только
   `[A-Za-z0-9]`; публичный адрес берётся из `CSQTT_HOST`, иначе
   автоопределяется публичный IPv4, а если он приватный/loopback — hostname
   (с предупреждением в лог).
3. Пишет `csqtt.env` в systemd-формате (`KEY="value"`, `0600`) и
   `install.json` (`version` из `csqtt --version`, `mode=docker`, `panel_mode`
   по виду адреса, `peer_port=46000`, `web_port=443` для домена и `46002` для
   IP, `tls=selfsigned`).
4. Выпускает self-signed пару `web_cert.pem`/`web_key.pem` через `openssl` с
   явным SAN: `DNS:<host>` для домена, `IP:<host>` для адреса. Пара
   генерируется одинаково в обоих режимах, чтобы сертификат не зависел от
   того, что сервер сможет определить в рантайме. Существующая пара (включая
   ваши собственные сертификаты) не перезаписывается.

Дальше при каждом старте: source `csqtt.env`, ожидание WAN до 90 с, sysctl
(best-effort), правила `iptables` с меткой `CSQTT_MANAGED` и
`exec csqtt --listen 0.0.0.0:46000 --web-port <из install.json> --config-dir /etc/csqtt`.

`install.json` — источник правды по портам и режиму. Если нужен нестандартный
порт, правьте его в `csqtt-data/install.json` между перезапусками, а не в
compose.

## Домен вместо IP

```bash
CSQTT_HOST=vpn.example.org docker compose up -d
```

Или пропишите `CSQTT_HOST` в `.env`. На чистом томе это даёт доменный режим:
панель на `443`, сертификат с `DNS:vpn.example.org`. В `CSQTT_HOST` можно
указать и IPv4 — тогда включится IP-режим (панель на `46002`, SAN `IP:<host>`).
A-запись домена должна указывать на этот сервер: Let's Encrypt и клиенты ходят
напрямую, Cloudflare-прокси не подходит.

`CSQTT_HOST` читается только при создании `csqtt.env`. Если том уже есть,
смена переменной ничего не изменит: правьте `csqtt-data/csqtt.env`
(`CSQTT_PUBLIC_IP`) и при необходимости `install.json`, либо удалите том и
начните заново.

## Доверенный сертификат (Let's Encrypt) вручную

Автоматического certbot в этом образе нет. Чтобы панель не ругалась на
self-signed, положите готовую пару в том **до** перезапуска и перезапустите
контейнер:

```bash
sudo cp fullchain.pem csqtt-data/web_cert.pem
sudo cp privkey.pem   csqtt-data/web_key.pem
sudo chmod 0644 csqtt-data/web_cert.pem
sudo chmod 0600 csqtt-data/web_key.pem
docker compose restart csqtt
```

`entrypoint.sh` видит готовую пару и не трогает её. Продление остаётся на
хосте: cron/systemd-таймер с `certbot renew` и deploy-hook, который копирует
файлы в том и перезапускает контейнер. Файлы `letsencrypt.env` /
`letsencrypt-ip.env`, если они нужны вашей схеме продления, тоже можно держать
в томе.

## Обновление

```bash
# в .env: CSQTT_IMAGE=ghcr.io/w3struk/recsqtt:<новая версия>
docker compose pull
docker compose up -d
```

Том не затрагивается: identity, база и сертификаты остаются. Тег `latest`
намеренно не используется — версия в `.env` должна быть точной.

## Бэкап и восстановление

SQLite нельзя копировать на живой базе, поэтому сначала остановите сервис:

```bash
docker compose stop
sudo tar czf csqtt-backup-$(date +%F).tgz csqtt-data
docker compose start
```

Восстановление: распаковать `csqtt-data` на место и `docker compose up -d`.
Права каталога — `0700`, файлов — `0600`; владелец root.

## Ограничения

- `network_mode: host` + `NET_ADMIN`/`NET_RAW`/`NET_BIND_SERVICE` +
  `seccomp=unconfined`: контейнер меняет сетевую конфигурацию хоста. Это цена
  TUN/NAT, а не настройка по умолчанию для недоверенных хостов.
- Порт туннеля и порт панели фиксированы в `install.json`; два экземпляра на
  одном хосте не уживутся (`container_name: csqtt`, общие порты).
- Панель по умолчанию на self-signed сертификате: браузер покажет
  предупреждение, пока вы не положите доверенную пару.
- Первый старт печатает пароль в `docker logs` — журнал контейнера на это
  время считается чувствительным.
- IPv6-маршрутизация для TUN не настраивается (только IPv4 `10.66.67.0/24`).

## Файлы

| Файл | Назначение |
| --- | --- |
| `Dockerfile` | `alpine:3.21` + `ca-certificates`, `curl`, `iproute2`, `iptables`, `openssl`; ждёт бинарь `csqtt` в контексте сборки (его кладёт CI). |
| `entrypoint.sh` | Первый старт (identity, `install.json`, TLS), затем NAT/TUN и `exec csqtt`. |
| `healthcheck.sh` | TUN `csqtt1` + TCP-листенер панели; exit 0/1, без секретов. |
| `compose.yml` | Сервис `csqtt`: host-сеть, caps, `/dev/net/tun`, том `./csqtt-data`. |
| `.env.example` | Шаблон `CSQTT_IMAGE` / `CSQTT_HOST`. |
