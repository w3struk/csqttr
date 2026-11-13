# Архитектура reCSQTT

## Оглавление

- [Границы описания](#границы-описания)
- [Топология и границы доверия](#топология-и-границы-доверия)
- [Android: интерфейс, настройки и жизненный цикл](#android-интерфейс-настройки-и-жизненный-цикл)
- [Граница Android и Rust: процесс, TUN и IPC](#граница-android-и-rust-процесс-tun-и-ipc)
- [VK: получение звонков, авторизация и капча](#vk-получение-звонков-авторизация-и-капча)
- [Транспорт и формат пакетов](#транспорт-и-формат-пакетов)
- [Клиентский dataplane и восстановление](#клиентский-dataplane-и-восстановление)
- [Сервер: сессии и выходной трафик](#сервер-сессии-и-выходной-трафик)
- [Маршрутизация, ассеты и синхронизация правил](#маршрутизация-ассеты-и-синхронизация-правил)
- [DNS, IPv4, IPv6 и split tunneling](#dns-ipv4-ipv6-и-split-tunneling)
- [Панель, аутентификация и хранение](#панель-аутентификация-и-хранение)
- [Развёртывание, TLS и обслуживание](#развёртывание-tls-и-обслуживание)
- [Диагностика и проверяемые ограничения](#диагностика-и-проверяемые-ограничения)
- [Сборка и карта проверок](#сборка-и-карта-проверок)
- [Термины](#термины)

## Границы описания

Документ описывает reCSQTT 2.5.4 (`versionCode 234`) как работающую систему, а не историю её
появления: предмет — границы компонентов, инварианты и контракты, которые нельзя менять
одной стороной. Версия продублирована в `app/build.gradle.kts`, `Cargo.toml`/`Cargo.lock`
обоих крейтов, `scripts/install.sh`, стартовом баннере `rust-server/main.rs` и `CACHE_NAME`
в `rust-server/web_panel.rs`; согласованность проверяет `scripts/check_versions.sh`.

Покрытые компоненты:

- `app/` — единственный Gradle-модуль: Compose-интерфейс, `VpnService`, служба-контроллер и
  запуск дочернего процесса. Приложение — **только участник**: адрес, порт и пароль приходят
  исключительно из ссылки `csqtt://`, сервер из приложения не разворачивается.
- `rust-client/` — крейт `csqtt-client`; на Android это исполняемый файл `libclient.so`
  (не JNI), который приложение запускает через `ProcessBuilder`.
- `rust-server/` — крейт `csqtt`: UDP-приём, TUN, маршрутизация, веб-панель.
- `scripts/install.sh` и `csqttctl` — единственный путь установки, обновления и обслуживания
  сервера; release-ассет `install.sh` публикуется CI.
- `shared/` — три файла, компилируемых в оба крейта через `#[path = "../shared/…"] mod …;`
  (`dtls.rs`, `wire_protocol.rs`, `spsc_ring.rs`); cargo workspace и path-зависимости нет.

Чего в документе нет:

- истории проекта, сравнения с аналогами и пользовательской инструкции — это `README.md`;
- пошагового развёртывания сервера на конкретном VPS (сертификаты, firewall, режимы
  systemd/docker): здесь только границы и контракты, процедуры — в `scripts/install.sh --help`
  и `README.md`;
- сборки, флагов, provenance, подписи и CI — это `BUILDING.md`; правил и грабель для
  ИИ-агентов — `AGENTS.md`;
- байтового формата протокола, серверных сессий, панели и DNS — это соответствующие
  разделы ниже, а не предмет этого введения.

Факты ниже получены из кода этого коммита, числа взяты из констант, а не из документации.
Утверждения, которые кодом не подтверждаются, помечены как «не подтверждено» и не являются
инвариантом.

## Топология и границы доверия

Путь одного пакета:

1. `TunVpnService` поднимает `VpnService.Builder`: адрес клиента `/32`, маршрут `0.0.0.0/0`, MTU 1500,
   DNS из `TUNCONF` (иначе `77.88.8.8`), `setMetered(false)`, список приложений из настроек и правила.
2. FD интерфейса пересекает границу процесса по abstract-сокету `csqtt_tun_uds`
   (`TunVpnService.sendTunFd` → `rust-client/tun.rs::FdReceiver`).
3. Rust читает IP-пакеты из TUN; адреса и домены, попавшие в правило, уходят в direct-relay
   (`direct_relay.rs`, netstack-smoltcp) мимо туннеля, остальное — воркерам через `Dispatcher`.
4. Пакет получает RTP-подобную обёртку (`obfs.rs`: SSRC, sequence, timestamp, padding) и
   шифруется: WRAP (ChaCha20-Poly1305, ключ HKDF-SHA256 из пароля, `wrap.rs`) либо SRTP-ключами
   из DTLS 1.2 (`shared/dtls.rs`).
5. Внутри TURN-аллокации VK пакет уходит Send/Data indication на peer — адрес reCSQTT-сервера из
   ссылки (сервер по умолчанию слушает UDP `0.0.0.0:46000`); сервер демультиплексирует трафик по
   сессии (пароль + `-gen` + `-salt`), пишет в свой TUN и выпускает в интернет через NAT.

TURN-креды выдаёт VK API по хешу или токену (`auth.rs` → `TurnCredentials`), своих TURN-серверов
у проекта нет. Панель — HTTPS на 46002 в IP-режиме (443 в доменном), авторизация cookie-токеном,
`x-api-key` или `Bearer` (`web_panel.rs::authorized`); она — единственный источник клиентов.

| Объект | Граница доверия |
| --- | --- |
| Приложение и его дочерний Rust | Один uid, общий `filesDir`; считаются доверенными |
| Abstract-сокет `csqtt_tun_uds` | Аутентификации нет: Rust принимает первый пришедший FD и подтверждает его; изоляция опирается на Android/SELinux (не проверено) |
| stdin/stdout дочернего процесса | Канал управления и событий; доверенный, потому что его держит само приложение |
| Ссылка `csqtt://` | Bearer-секрет: внутри пароль. Payload зашифрован AES-GCM ключом из константы в APK (`UiUtils.kt`) — это обфускация, а не защита от владельца APK |
| VK | Видит метаданные TURN-сессий, выдаёт креды, требует капчу; не доверенная сторона |
| Сеть между клиентом и TURN | Видит TURN-сигнализацию и RTP-подобный поток; содержимое защищено WRAP/DTLS-SRTP |
| Сервер | Точка выхода: видит открытый IP-трафик клиентов, а пароль клиента служит идентификатором |

Секреты и их транспорт:

- пароль подключения (из ссылки) — только переменная окружения `CSQTT_PASSWORD`, в argv его нет;
  VK access token — только stdin-команда `VK_JS_BOOTSTRAP:<base64>`, в argv и env не попадает;
- VK-хеши — argv `-vk` (Rust берёт первые 6 из присланных): это не секрет уровня пароля,
  поэтому вынос в env не делался; результат капчи — stdin `CAPTCHA_RESULT|…`, в журнал Rust
  такие строки пишутся как `<скрыто>` (`loggable_stdin_line`);
- ссылка и VK-токен в профиле зашифрованы через AndroidKeyStore (`SecureStringStore`); пароль
  панели — `/etc/csqtt/csqtt.env`; в APK ни он, ни серверный payload не попадают.

## Android: интерфейс, настройки и жизненный цикл

Экран приложения — `MainScreen` (`MainActivity.kt`): нижняя навигация и одно
содержимое под ней. Активная вкладка хранится в `selectedTab`
(`rememberSaveable`), набор доступных вкладок считает
`resolveActiveNavIds(participantShowLogs)`, а `resolveSelectedTab` возвращает
вкладку «Подключение» (id 0), если сохранённая вкладка перестала быть
доступной. Видимость вкладки «Логи» берётся из профильной настройки
`participant_show_logs`, поэтому она следует за активным профилем. Настройки —
полноправная вкладка (id 3), а не модальное окно: в диалогах решаются точечные
операции — переименование профиля, выбор TURN-подсетей, «Список приложений» и
предложение обновления.

- Вкладки: **«Подключение»**, **«Туннель»**, **«Настройки»**; вкладка
  **«Логи»** появляется после включения тумблера **«Показывать логи»** во
  вкладке **«Настройки»** — он же включает подробный журнал (выключенный ведёт
  только ошибки и статус: гейт `TunnelManager.isLoggingEnabled` и
  `TunnelLogPolicy`).
- **«Подключение»** — состояние туннеля и кнопка включения VPN.
- **«Туннель»** — поле ссылки `csqtt://` и параметры клиента: режим кредов,
  SRTP, транспорт и число воркеров.
- **«Настройки»** — профиль (с переименованием), отпечаток, оформление,
  автопауза при Wi-Fi, тумблер логов, «Выбор TURN-подсетей», «Обновление»
  (проверка обновлений) и маршрутизация приложений: режим списка и кнопка
  «Список приложений». Импорта и экспорта конфигурации нет.

QR-сканер — единственная иконка в шапке экрана: она приходит в `CsqttScreen`
из `LocalCsqttHeaderActions` (`FloatingToolbar`), поэтому доступна с любой
вкладки.

## Граница Android и Rust: процесс, TUN и IPC

Приложение запускает `libclient.so` из `applicationInfo.nativeLibraryDir` через `ProcessBuilder`
(`TunnelManager.startProcessLocked`): рабочий каталог — `filesDir`, `redirectErrorStream(false)`,
`LD_LIBRARY_PATH`, `CSQTT_EVENTS=1`, `RAYON_NUM_THREADS=2`, `CSQTT_PASSWORD`. Без пароля, `-peer`
или хешей клиент печатает ошибку в stderr и завершается; в APK бинарник лежит с `useLegacyPackaging`.

argv собирается вручную, разбирается `#[derive(Parser)] struct Arguments` (`rust-client/main.rs`);
Kotlin пишет один дефис, Rust нормализует в двойной (`normalize_cli_argument`), `-vk` = `--vk`.
Флаги, которые передаёт Kotlin (подмножество `Arguments` из `rust-client/main.rs`): `-peer`, `-n`, `-listen`, `-tun-uds`, `-vk`, `-vk-hash-mode`, `-fingerprint`, `-client-ids`,
`-obfs`, `-turn-transport`, `-srtp-mode`, `-custom-turn-ips`, `-vk-auth-mode`, `-gen`, `-salt`,
`-captcha-mode`, `-routing-ips-sha`, `-routing-content-sha-file`; с `-tun-uds csqtt_tun_uds` флаг
`-listen` сокета не открывает — единственный вход TUN FD. Канал управления — stdin, по одной команде в строке:

- `PAUSE` / `RESUME` — `PauseGate`: воркеры ждут возобновления, сессии не рвутся;
- `STOP` — отмена токена и штатное завершение; `FINISH_VK_CALLS` — завершить VK-звонки при выходе;
- `CAPTCHA_RESULT|<token>` — ответ WebView в канал капчи, устаревший ответ отклоняется;
- `UPDATE_DOMAINS|<payload>` — доменное правило (`enabled=…;domains=…;ip_whitelist=…`);
- `UPDATE_IPS|<sha>|<base64-gzip>` — шаблон адресов, `UPDATE_IPS|` без тела — очистка;
- `VK_JS_BOOTSTRAP:<base64>` — bootstrap Auto JS до старта воркеров (таймаут 15 с, ≤32 КиБ).

События идут в stdout строками `__CSQTT_EVENT__|KIND|{json}` и только при `CSQTT_EVENTS=1`:
`PROCESS`, `READY`, `DTLS`, `CONFIG`, `ROUTING`, `ROUTING_ABSENT`, `WORKERS`, `STATS`,
`ACTIVE_ZERO`, `TUN_LOST`, `ERROR`, `SERVER_RESTART`, `PROGRESS`, `NETWORK_SUSPECT`,
`CALL_UNAVAILABLE`, `STOPPED` (`events.rs`). `TunnelEventParser` принимает надмножество:
`STARTED`, `CAPTCHA_REQUEST`, `CAPTCHA_DONE` он понимает, но Rust их не шлёт. Payload, не влезший в
лимит строки, заменяется `ERROR` (для `ROUTING` — фатальным); запрос капчи — строка `CAPTCHA_SOLVE|…`;
stderr — диагностика, stdout — протокол, в debug оба дублируются в logcat (`CSQTT/Protocol`, `CSQTT/Diagnostic`).

TUN: Rust биндит abstract-сокет `csqtt_tun_uds` (до 30 попыток по 100 мс при `EADDRINUSE`),
Android подключается `LocalSocket` в `Namespace.ABSTRACT`, отдаёт FD через
`setFileDescriptorsForSend`, пишет байт и ждёт ACK (`soTimeout` 3 с); повтор — до 60 раз по 500 мс.
Rust подтверждает SCM_RIGHTS байтом и слушает сокет дальше — замена FD не требует перезапуска.

Смерть и остановка: Rust проверяет `getppid` раз в 2 с и отменяет работу, если родитель исчез;
закрытый или отдавший ошибку stdin при `CSQTT_EVENTS=1` тоже отменяет туннель — канал обязателен.
По EOF обоих потоков Kotlin решает судьбу процесса по `TunnelLifecycleState`, а не по коду возврата
(`0`/`1`/`3` пишутся только в журнал): без перезапуска шлётся `CLOSE_INTERFACE`, иначе интерфейс
остаётся новому процессу; остановка — `STOP`, `destroy`, `destroyForcibly`, `killProcess` (грейс 3.5 с).

## VK: получение звонков, авторизация и капча

Клиент не работает без VK-кредов: ему нужны либо хеши звонков, либо VK access token. Хеши — это идентификаторы join-ссылок (`vk.ru/call/join/<hash>`); из них Rust-клиент получает TURN-креды через VK API. Источник кредов задают две независимые настройки профиля: `vk_hash_mode` (откуда берутся хеши) и `vk_auth_mode` (каким путём добываются TURN-креды).

| `vk_auth_mode` | Значение | Поведение в `rust-client/auth.rs` |
| --- | --- | --- |
| `vkcalls` | `CsqttConstants.VkAuth.MODE_CALLS` | Анонимная цепочка `auth.getAnonymToken` → `messages.getCallPreview` → `messages.getAnonymCallToken` → `auth.anonymLogin` → `vchat.joinConversationByLink` (client_id `8093730`, API `5.276`). VK-аккаунт не нужен. При сбое (кроме `CallUnavailable`, rate limit и сетевых ошибок) — переход в `legacy`. |
| `legacy` | `CsqttConstants.VkAuth.MODE_CAPTCHA` | Пары `client_id`/`client_secret` из `BUILTIN_VK_CREDENTIALS` (или `CSQTT_VK_CREDENTIALS`), до 4 попыток; капча решается внутри `calls.getAnonymousToken` (до 3 попыток). |
| `auto_js` | `CsqttConstants.VkAuth.MODE_AUTO_JS` | Нужен пользовательский токен: `messages.getCallToken` → `vchat.startConversation` → join-link (hash). TURN-креды выдаёт `CredentialBroker` по независимой сессии на «бота»; при ошибке — fallback в `vkcalls`. |

`vk_auth_mode` санитизируется в `TunnelService.sanitizeVkAuthMode` (по умолчанию `vkcalls`), `VkAuth::new` так же сводит неизвестное значение к `vkcalls`. `auto_js` без `vk_hash_mode=auto_js` понижается до `vkcalls` с предупреждением — и в Kotlin (`effectiveAuthMode`), и в Rust.

| `vk_hash_mode` | Откуда хеши |
| --- | --- |
| `manual` | Из ссылки `csqtt://…hashes=` или сохранённого списка профиля; хеш короче 16 символов отбрасывается. |
| `auto_api` | `VkAutoCallsManager.startAutoCalls` вызывает `VkApi.startCall` (`calls.start`) нужное число раз; хеш — `ok_join_link` или хвост `join_link`. |
| `auto_js` | Создаётся один звонок через `vchat.startConversation`; дополнительные TURN-креды брокер выдаёт на группы воркеров. |

- **Ссылка** — единственный источник хоста, порта и пароля. `parseCsqttV2` принимает либо `hashes=`, либо `token=`, но не оба сразу. Хеши из ссылки приоритетнее локального списка (`ConnectionSource`), токен из ссылки переключает режим хешей на `auto_api`.
- **Панель** кладёт те же креды в ссылку (`hashes=` для группы/клиента, `token=` — VK-токен), отдельного API у приложения нет.
- **Локальный вход**: `VkAuthWebViewManager` открывает OAuth (`client_id=7793118`, `scope=1073737727`, redirect `oauth.vk.ru/blank.html`) в WebView; после появления cookie `remixsid` токен добывает `VkTokenScraper` по цепочке редиректов. Токен хранится зашифрованным (`saveVkAccessToken` → `SecureStringStore`, AES/GCM + AndroidKeyStore).
- **`VK_JS_BOOTSTRAP`** — не WebView, а stdin-канал: сразу после `ProcessBuilder.start()` Kotlin пишет `VK_JS_BOOTSTRAP:<base64(JSON{"token":…})>`. Rust читает первую строку с таймаутом 15 с и лимитом 32 КиБ; пустой токен валит старт ещё в Kotlin (`vk_token_error`).
- **Проверка хешей** — отдельный запуск того же бинаря с `--validate-vk-hashes`, который печатает `HASH_CHECK:{json}`; `VkHashValidator` ждёт 75 с и помечает невалидные хеши, после чего `VkHashValidationCodec.active` их выкидывает.

Капча обслуживает путь `legacy`; в `vkcalls` её нет (при исчерпании попыток клиент уходит в `legacy`). Режим задаёт `captcha_mode`, а для Android-WebView — `captcha_solve_method`:

| `captcha_mode` | Цепочка (`rust-client/captcha.rs`) |
| --- | --- |
| `auto` | Rust v2 ×2 → WBV Auto ×2 (по 10 с) → Rust v2 ×1 → ручной WebView (60 с) |
| `rjs` | Rust v2 ×2; при ошибке — WBV Auto (10 с) |
| `wv` | Только Android WebView, режим `selected`, таймаут Rust 120 с |

- Rust пишет в stdout строку `CAPTCHA_SOLVE|mode|redirect_uri|session_token`; `TunnelManager` проверяет URI через `CaptchaUriPolicy` (только https и хосты `vk.com`, `vk.ru`, `ok.ru`, `okcdn.ru`) и решает: авто-WebView (`CaptchaWebViewManager`, бюджет 10 с) или ручной (`ManlCaptchaWebViewManager`, 60 с, отдельная Activity и уведомление, если приложение не на переднем плане). Ответ уходит в stdin как `CAPTCHA_RESULT|<token|error:…>`; канал результата — `mpsc::channel(1)`, поэтому устаревший второй ответ отклоняется.
- `captcha_solve_method` различает только `"auto"` и всё остальное (ручной WebView). `captcha_wbv_solve_method` — память UI-переключателя: в `TunnelParams` она не уходит, но `saveWbvCaptchaSolveMethod` дублирует её в `captcha_solve_method`, когда режим `wv`.
- `FINISH_VK_CALLS` — stdin-команда: при выходе Rust вызывает `ActiveCalls::finish()` (завершает созданный в `auto_js` звонок), иначе — `leave_creator()`. Kotlin посылает `FINISH_VK_CALLS\nSTOP\n` при остановке без перезапуска; в режиме `auto_api` звонки завершает `VkAutoCallsManager.finishActiveCalls()` через `calls.forceFinish`.
- Ограничения и деградации: после 3 неудачных капч Rust отдаёт `CAPTCHA_WAIT_REQUIRED` и ставит 60-секундную глобальную паузу капчи; flood-control/rate-limit дают паузу и на путь авторизации; коды невалидного токена `4, 5, 27, 28` очищают сохранённый токен, если он не пришёл из ссылки. Rust берёт не более 6 хешей (`MAX_VK_HASHES = 6` в `rust-client/main.rs`), хотя `CsqttConstants.Tunnel.MAX_VK_HASHES = 7` и в UI шесть полей; Kotlin при передаче тоже режет список до шести (`TunnelManager`); в `auto_js` одновременно живёт не более `MAX_ACCOUNT_CREDENTIALS = 15` независимых сессий, а создатель звонка выходит из него после готовности 1–2 ботов.

## Транспорт и формат пакетов

Транспорт выбирается двумя осями: `turn_transport` (как клиент соединяется с TURN) и `srtp_mode` (откуда берутся ключи шифрования полезной нагрузки). `obfs_mode` поверх этого задаёт форму RTP-метаданных и паддинга.

| `turn_transport` | Значение в Android | Реализация |
| --- | --- | --- |
| `udp` | по умолчанию | `TurnTransportMode::Udp`, только `TurnWireTransport::Udp`; `turns:` и `?transport=tcp` отвергаются |
| `tcp_tls` | `CsqttConstants.Tunnel.TURN_TRANSPORT_TCP_TLS`, в UI подписан «TCP» | `TurnTransportMode::TcpTls`: `turn:` без параметра → сырой TCP, `turns:` → TLS (нужно DNS-имя, IP-литерал запрещён), `?transport=udp` отвергается |

- **Выбор эндпоинта.** TURN-адреса приходят из VK-кредов (`TurnCredentials.server_addresses`).
  `select_turn_address` перебирает их по курсору сессии и пропускает несовместимые с выбранным транспортом.
  `--turn`/`--port` перекрывают хост и порт, но не схему.
- **Пул IP (`turn_ip_pool`).** `-custom-turn-ips` (его заполняет выбор TURN-подсети в настройках, `TurnSubnetRegistry`)
  дедуплицируется по хосту и обрезается до числа воркеров.
  Воркер с id `n` берёт `(n-1) % len` среди здоровых адресов; при неудаче адрес помечается
  сломанным (`mark_failed`) и пропускается. Срок исключения и снятие пометки после успешной
  аллокации кодом не подтверждены. Порт из пула приоритетнее `--port`.
- **TURN-аллокация.** `turn_core` использует Allocate/Refresh/CreatePermission/ChannelBind, запрашивает lifetime 600 с
  и обновляет аллокацию каждые 300 с (обслуживание — 175 с). Полезная нагрузка идёт через relay-адрес аллокации.
- **`obfs_mode`** (`audio`/`video`/`unified`) меняет только RTP-обёртку: payload type 111/96, SSRC, sequence/timestamp, padding.
  `unified` держит кадр в пределах 1350 байт, `audio` — 100–150 байт на малых пакетах.
  Android санитизирует значение до `unified` (`SettingsStore.obfsMode` и `TunnelService`), остальные два режима доступны только из CLI.
- **`srtp_mode`**: `wrap-srtp` (в Kotlin `wrap`) выводит ключи из пароля (`derive_wrap_key`, HKDF-SHA256, salt `CSQTT-WRAP-v1`);
  `dtls-srtp` выполняет DTLS-рукопожатие; `auto` (по умолчанию) пробует DTLS и при ошибке откатывается на WRAP.
  В `shared/dtls.rs` — собственный DTLS 1.2: клиентский и серверный handshake, сертификат ECDSA P-256 с CN `WebRTC`
  и сроком 30 дней, TLS 1.2 PRF, SRTP-профили `SRTP_AES128_CM_SHA1_80`, `SRTP_AEAD_AES_256_GCM`, `SRTP_AEAD_AES_128_GCM` (`shared/dtls.rs`); `_32` не предлагается, ключевой блок 60 байт.
  Клиент ждёт рукопожатие 8 с и повторяет полёт каждые 500 мс.
- **`WIRE_PROTOCOL_REVISION = "CSQTT-WIRE-3"`** объявлена только в `rust-server/main.rs`, печатается флагом `--protocol-revision`
  и вытаскивается `sed`-ом в `scripts/server_asset_provenance.sh`: каждый собранный серверный бинарь обязан содержать строку дословно.
  Клиент понимает отказ `DENIED:protocol_mismatch` и превращает его в `FATAL_PROTOCOL`, после чего приложение останавливает туннель
  с сообщением о разных версиях; но в текущем серверном коде этот `DENIED:` не отправляется — рантайм-проверка версии не подтверждена.
  Совместимость держится на аддитивности: новые поля `GETCONF` дописываются в конец и старым сервером игнорируются, `ROUTING2:` — owner-only,
  неизвестные пакеты старый клиент молча отбрасывает.
- **Кадрирование** (`shared/wire_protocol.rs`). Диспетчер отправляет целиком пакеты `≤1280` байт
  (`rust-client/dispatcher.rs`); более крупные `fragment_packet` режет на фрагменты по 1272 байта
  с 8-байтовым заголовком: magic `0xCF`, `frag_idx`, `total_frags` (до 32), `packet_id` (u16), `total_len` (до 2048).
  Сборка — `ShardedReassembler`: 16 шардов по 512 слотов, слот живёт 300 мс; ключ учитывает peer, поэтому одинаковые `packet_id`
  разных пиров не смешиваются. На приёме допускается 24-байтовый префикс перед IP-заголовком, не-IP пакеты отбрасываются со счётчиком.
- **`shared/spsc_ring.rs`** компилируется только в клиент: это lock-free SPSC-кольцо с `Notify`, через которое TURN-драйвер отдаёт
  входящие пакеты (`INCOMING_QUEUE_CAPACITY = 256`); переполнение — не блокировка, а дроп с инкрементом `queue_full_drops`.
  Очередь на отправку (`ArrayQueue`, 8 слотов) устроена иначе и живёт в `turn.rs`.

## Клиентский dataplane и восстановление

Число воркеров задаёт Kotlin (`WorkerCountPolicy`): ≤5 → 5, иначе кратное 10 в диапазоне 5..100;
Rust нормализует так же, но флаг `-exact-workers` допускает 3..100 без округления (приложение его не
передаёт). Воркеры — группы по 10; номер группы → хеш по `group_index % hash_count`, у группы свой
TURN-кред. Супервизор перезапускает воркера, пока id в пределах цели и кред не исчерпан; сервер
может менять число потоков, и Rust масштабирует группы через `scale_notify` (`WORKERS` — только UI).

**Жизненный цикл.** Штатный старт и стоп сериализуются `startStopMutex` в `TunnelManager`;
решение о перезапуске принимает `TunnelLifecycleState.desiredRunning`, а интерфейсом TUN владеет
`TunVpnService`, передавая FD в Rust через `csqtt_tun_uds`.

Пакетный путь: TUN → `Dispatcher` → direct-relay для адресов/доменов правила → иначе обфускация
и шифрование (SRTP по умолчанию `auto`: DTLS-SRTP с откатом в WRAP) → TURN Send/Data на peer.
Пакеты до 1280 байт идут как есть, крупные режутся `wire_protocol` (`MAX_FRAG_PAYLOAD = 1272`) и
собираются реасемблером. Конфиг — `GETCONF` (400/800/1600/3000 мс) → `TUNCONF` с адресом, DNS и
правилом; изменение правила приходит уведомлением, и config-owner повторяет `GETCONF`.

Переподключение внутри Rust:

- обычная ошибка воркера — 250 мс · 2^(attempt−1) с потолком 4000 мс плюс джиттер ≤250 мс
  (наблюдаемый предел 4250 мс); `FATAL_AUTH`, `FATAL_PROTOCOL` и «хеш мёртв» — 5 с · 2^(streak−1)
  с потолком 300 с, готовность сбрасывает лестницу; обрыв TCP в `tcp_tls` — 100/300/500/800/1500 мс;
- шесть таймаутов за 15 с дают `NETWORK_SUSPECT`, и приложение отдельно проверяет доступность VK;
- квота TURN (486), mismatch аллокации (437/400) и недействительные креды (401/438/441) лечатся
  обновлением или ротацией креда, а не повтором того же.

Восстановление на стороне Android (`TunnelManager`):

- смерть процесса без запрошенной остановки — перезапуск через 2 с · 2^(streak−1), не выше 60 с;
  streak обнуляется после ≥30 с работы, новая попытка получает новые `-gen`/`-salt`;
- `TUN_LOST` — сначала переиспользование FD, при повторной потере в течение 60 с — пересборка
  (`TunRecoveryPolicy.shouldReuse` требует полного совпадения плана); отказ доставки FD — до 60
  попыток, затем восстановление интерфейса, после трёх неудач пауза 2 с и `onVpnRecoverableFailure`;
- ноль активных воркеров — `WorkerRecoveryPolicy` (пик ≥ 10, пауза 4 с), проверка VK и перезапуск
  транспорта; `SERVER_RESTART` из панели — перезапуск через 4 с;
- потеря сети — грейс 2 с и пробы VK, затем `PAUSE`, возврат — `RESUME`; смена сети процесс не
  перезапускает (`restartForNetworkSwap` объявлен, но вызовов не имеет); отзыв VPN и терминальный
  отказ TUN — остановка;
- автопауза на Wi-Fi гасит dataplane, но оставляет службу-контроллер живой и сохраняет намерение
  «туннель был запущен» — иначе возобновление после ухода с Wi-Fi стало бы невозможным.

Капча не останавливает туннель: Rust решает её сам (AUTO-цепочка), при неудаче просит WebView у
Android и ждёт ответа до 60 с; ждёт при этом только воркер, проходящий авторизацию. Жизнью процесса
управляет `TunnelManager` под `startStopMutex` и эпохами `TunnelLifecycleState`; служба лишь просит старт и стоп.

## Сервер: сессии и выходной трафик

Сервер — один бинарник `csqtt` (`rust-server/main.rs`): UDP-приём клиентов, kernel-TUN, веб-панель и диагностика
в одном процессе. Нужен root; `<config-dir>/.server.lock` под `flock` не даёт поднять второй экземпляр. Туннель
— UDP `--listen` (`0.0.0.0:46000`), панель — TCP `--web-port` (46002, в доменном режиме 443).

- **Протокол.** Ревизия `CSQTT-WIRE-3` (`WIRE_PROTOCOL_REVISION`). Клиент приходит
  `GETCONF:<port>|<password>|<generation>|<salt>|<worker>|<desired_streams>|<owner>` (легаси-формат без
  generation принимается), ответ — `TUNCONF:<tunnel_ip>:<dns>:0:stream-v1`, отказ — `DENIED:<reason>`; после
  DTLS-рукопожатия `GETCONF` ждётся внутри SRTP.
- **Клиент ≠ сессия.** Клиент — запись `PasswordEntry`: пароль-ключ, имя, `ip`, `expires_at`, `is_deactivated`,
  `group_id`, `routing_rule_id`, VK-креды, `workers`, счётчики. Группа задаёт правило, лимит воркеров и VK-креды
  для ссылок клиентов. Сессия живёт только в памяти (`App.sessions`), привязана к endpoint `peer + local_ip` и
  хранит generation/salt, `worker_id`, `tunnel_ip`.
- **Лимиты.** `MAX_ACTIVE_SESSIONS = 3072` (плюс 256 запасных слотов в реестре приложения), воркеров — до
  `MAX_STREAM_WORKERS = 100`.
  Неаутентифицированная сессия живёт 15 с, после аутентификации — 10 ч. `session_janitor` тикает
  каждые 5 с и раз в 30 с сбрасывает счётчики трафика; истёкшие клиенты удаляет `password_janitor`
  раз в час.
- **TUN и выход.** Сервер поднимает kernel-TUN `csqtt1` (`10.66.67.1/24`) через `/dev/net/tun` и ставит на него
  firewall-правила; адреса клиентов — `10.66.67.2`–`.250` (`get_next_ip`). Пакет из TUN выбирает маршрут по
  tunnel-IP в `tun_device::RouteTable` и уходит в воркер, обратно — в TUN. `ip_forward` и `MASQUERADE` для
  `10.66.67.0/24` ставит установщик.
- **БД: SQLite `csqtt.db` в WAL.** `meta`, `passwords`, `client_groups`, `routing_rules`, `local_proxy_*`;
  `meta.schema_version = 2`. Сохранение асинхронное (`DatabasePersistence`), при остановке — финальный сброс (1
  с).
- **Только schema 2.** Сервер поддерживает базы, созданные 2.5.2+ (`schema_version = 2`). Если `csqtt.db`
  старше или версию прочитать нельзя, старт отклоняется до открытия writer-соединения, TUN и панели:
  сначала нужно поставить 2.5.2, затем текущую версию. JSON-файлы старых баз (`passwords.json*`) не
  импортируются; установщик сохраняет их как данные. Копия `csqtt.db.pre-owner-migration` больше не
  создаётся, существующая — не читается.
- **Рестарт и апдейт.** Сессии в памяти, поэтому рестарт рвёт туннели — клиенты переподключаются и повторяют
  `GETCONF`; БД сохраняет клиентов, группы, правила и настройки. Остановка: `drop_all_sessions`,
  `flush_traffic`, финальное сохранение. Перезапуск инициируют панель (`POST /api/reboot`, 750 мс через
  `systemd-run` или self-SIGTERM) и `auto_restart_interval_hours` (0/12/24/48/72; 0 — выключен).

## Маршрутизация, ассеты и синхронизация правил

Списки — pinned-снимки в репозитории, в рантайме сервер в upstream не ходит: `rust-server/data/domains_ru.txt`
(515 доменов, 5 967 байт) и `ips_ru.txt` (6 710 CIDR, 115 173 байта); источники, коммиты и лицензии — в
`rust-server/data/SOURCES.md`.

- **Компиляция.** `routing_assets.rs` подключает оба файла `include_str!` в `static ASSETS`; инициализация
  намеренно паникует на невалидной строке, и `main` трогает `ASSETS` до открытия сокетов — битый ассет
  отказывает старту. Домены нормализуются (lowercase, сортировка, LF), адреса — по значению сети; считаются
  `sha256` и gzip+base64 blob (≤27 000 байт, проверяется тестом).
- **Пресет RU-приложений.** `rust-server/ru_apps_preset.json` через `include_str!` (`preset_apps.rs`), уровни
  `red`/`orange`; сломанный уровень парсится в пустой список с `ERROR` в лог при старте. Файл валидируется
  `python3` в `rust-server/build_linux.sh` на каждой сборке, включая `--no-tests`.
- **Provenance.** `rust-server/build_linux.sh` пишет/проверяет
  `app/build/generated/provenance/csqtt-server.json` (схема v4). В `build_input_files` входят `data/*.txt`;
  `WIRE_PROTOCOL_REVISION` извлекается из `main.rs` через `sed` и обязан присутствовать в бинарнике.
- **Как правило уезжает клиенту.** `GETCONF` с меткой `owner` (7-е поле) запрашивает решение; приходит JSON
  `ROUTING` `version: 3` с `packages`, `preset_red`, `preset_orange`, `domains`, `ips`, `content_sha`,
  `content_cached`. `template_domains` подмешивает `domains_ru.txt` (предел 1024); `template_ips` всегда даёт
  `ips_sha`, а `ips_blob` — только при несовпадении с клиентским `ips_sha`. Совпавший `content_sha` экономит
  массивы.
- **Доставка.** `ROUTING:START:<total>` → `ROUTING:<i>:<total>:<chunk>` → `ROUTING:FINISH:<total>` (новый клиент
  получает `ROUTING2:` с delivery-nonce); повторный `GETCONF` внутри 1 с подавляется. Отвязанное правило
  приходит как `ROUTING:ABSENT`, об изменении уведомляет `ROUTING_CHANGED_NOTICE`.
- **Клиентская сторона.** Приложение кеширует `ServerRoutingRule`; в Rust-клиент по stdin уходят
  `UPDATE_IPS|<sha>|<gzip-base64>` и `UPDATE_DOMAINS|...`, причём `UPDATE_IPS` — первым
  (`RoutingCommandPolicy`).
- **Источник правды — сервер.** Копий списков в `app/` и корне нет; Gradle не отслеживает
  `rust-server/data/*.txt` и сервер не собирает, поэтому правка списков требует пересборки сервера и
  проверки provenance.

## DNS, IPv4, IPv6 и split tunneling

Сервер отдаёт в `TUNCONF:{ip}:{dns}:0:stream-v1` IPv4-адрес клиента и список DNS через запятую; `TunnelManager` разбирает первые два поля и передаёт их в `TunVpnService`. Android строит интерфейс только из IPv4: `addAddress(<ip>/32)`, `addRoute("0.0.0.0", 0)`, MTU из `CsqttConstants.Vpn.DEFAULT_MTU` (1500).

- **DNS внутри TUN.**
  Каждый DNS-сервер из `TUNCONF` добавляется как `addDnsServer` и отдельный маршрут `/32`;
  всё, что содержит `:`, отбрасывается, то есть IPv6-DNS не поддерживается. Если валидных IPv4-DNS нет,
  подставляется `77.88.8.8`; если не разобрался и он — VPN не поднимается.
- **Rust-резолвер** (`dns.rs`) обслуживает собственные HTTP-клиенты (VK, капча) и `--peer`:
  три тира по два сервера (Яндекс `77.88.8.8/77.88.8.1`, НСДИ `195.208.4.1/195.208.5.1`,
  Ростелеком `95.189.32.74/212.48.193.36`), таймаут 900 мс, затем системный резолвер.
  Кэш — до 1024 записей и TTL не более 900 с; при недоступности DNS отдаётся просроченный кэш,
  запомненный удачный тир опрашивается первым. Пока туннель активен (`mark_tunnel_active` по `TUNCONF`),
  повторный круг с задержкой 200 мс не делается.
- **`excludeRoutes`.**
  Единственный источник — явный список `ips` серверного правила, и только в чёрном режиме
  (`VpnExcludeRoutePolicy` возвращает пусто при `ipIsWhite` или без правила). Работает на Android 13+ (`TIRAMISU`), только IPv4.
  Шаблонные тысячи CIDR (`ips_sha`/`ips_blob`) в `excludeRoute` не попадают никогда — они уходят в Rust командой
  `UPDATE_IPS|sha|blob` и используются `direct_relay`; смена влияющего на маршруты правила требует пересборки VPN
  (`IpRoutingPolicy.needsVpnRebuild`).
- **Маршрутизация приложений.**
  Под серверным правилом режим задаёт оператор (`is_whitelist`), а локальный слой — только чёрный список:
  `MergedRoutingPolicy.effectivePackages` даёт `rule − localBlack` в белом режиме и `rule + localBlack` в чёрном;
  локальный белый список читается лишь когда правила нет.
  `VpnAppRouting.build` всегда исключает транспортные пакеты (`com.vkontakte.android`, `com.vk.calls`) и сам reCSQTT,
  красный пресет исключён безусловно, оранжевый — пока пользователь не вернул его в туннель (`orange_tunnel_enabled`).
- **Пустой белый список — отказ, а не «все».**
  Если эффективный набор пуст, `VpnAppRouting.build` возвращает `VpnAppsPlan.Failure` с причиной и советом; VPN не поднимается.
  Отдельный случай — «подмена»: сырое белое правило непусто, но ни один его пакет не установлен
  (приватное пространство/другой пользователь), тогда план становится device-wide disallow минус пресет, транспорт
  и пользовательские исключения (`isServerWhitelistInvisible`).
- **Прямые домены и IP.**
  `dispatcher.inspect_domain_routing` учит пары домен→IP из DNS-ответов (UDP/53) и TLS SNI.
  Список прямых доменов приходит из правила в `UPDATE_DOMAINS|enabled=…;whitelist=…;domains=…;ip_enabled=…;ip_whitelist=…;ips=…`,
  шаблон адресов — в `UPDATE_IPS`. Совпавшие потоки `direct_relay` уводит мимо TURN; режимы «белый/чёрный»
  для доменов и IP независимы (`domains_is_whitelist`, `ip_is_whitelist`).
- **Ограничения.**
  Сопоставление идёт по именам пакетов (`addAllowedApplication`/`addDisallowedApplication`), собственных диапазонов UID в коде нет;
  смена состава пакетов требует пересборки VPN (`PackageChangePolicy`), иначе UID-набор остаётся прежним.
  IPv6 в TUN не маршрутизируется: нет ни IPv6-адреса, ни маршрута, а IPv6-DNS отфильтрован — трафик v6 остаётся вне туннеля. Ключ `no_dns` зарегистрирован в `SettingsStore` и списке миграции, но потребителей в коде нет — приложения резолвятся только через выданные сервером DNS.

## Панель, аутентификация и хранение

Панель — `axum`-роутер (`web_panel.rs`) на `--web-port` (443 в доменном режиме), TLS из
`web_cert.pem`/`web_key.pem` в config-dir: отсутствующая пара генерируется self-signed через `rcgen` при первом
старте, неполная — отказ старта, перезагрузка по `SIGUSR1`. Разметка — константы в бинарнике (`PANEL_HTML`,
`LOGIN_HTML`, `GROUP_ADMIN_HTML`).

- **Вход.** Креды — `CSQTT_WEB_USER`/`CSQTT_WEB_PASS` (`--web-user`, `--web-pass-stdin`), установщик пишет их в
  `/etc/csqtt/csqtt.env`. `POST /api/login` сравнивает constant-time (`secret_eq`), поля раскодируются
  (`c1:`-обфускация, `caesar_decode`); после трёх неудач с одного IP — `429` на 180 с.
- **Сессии панели.** Токен в cookie `csqtt_session`, в памяти — только `SHA-256`, максимум 256 сессий.
  `web_sessions` не персистятся (при старте очищаются), поэтому рестарт разлогинивает всех; запрос без
  заголовков авторизации обрывается (`stealth_abort_response`), протухшая cookie даёт `401`.
- **REST API.** `/api/clients[/{password}]`, `/api/groups`, `/api/routing-rules`, `/api/links`,
  `/api/template-domains`, `/api/template-ips`, `/api/preset-apps`, `/api/settings`, `/api/logs`, `/api/export`,
  `/api/import`, `/api/reboot` и batch-операции; в панели — окно «Документация REST API» (`X-API-Key`/`Bearer`,
  вкладки «Клиенты», «Группы», «Подписки», «Маршрутизация», «Система»); capability-страницы
  `/{admin_uuid}/admin` и подписки `/{sub_uuid}/sub` — по UUID без логина панели.
- **QR и `csqtt://`.** `make_client_link` собирает
  `connect?v=2&host=...&peer=...&password=...[&hashes=h1+h2|&token=...]`; payload шифруется AES-256-GCM с ключом
  из `CSQTT_CIPHER_KEY_SEED` и кодируется base64url (`csqtt://<base64>`); QR рисует `qrcode.min.js`, ссылки
  отдают `/api/links` и карточки клиентов/групп.
- **VK-креды.** У группы — `vk_token`/`vk_hashes`, у клиента — `vk_hashes` и `vk_token_enabled`; в ссылку
  приоритетно попадают хеши, иначе токен (для клиента группы — токен группы, затем глобальный
  `vk_access_token`).
- **Хранение.** `/etc/csqtt` (0700): `csqtt.db` (+WAL), `csqtt.env`, `install.json`, сертификаты,
  `letsencrypt.env`, `csqtt.log`; клиенты, группы, правила, DNS и `local_proxy` — в БД, сессии панели — в памяти.
- **Импорт/экспорт.** `GET /api/export` — `version: 2` (владелец — обычная запись `clients`); `POST /api/import`
  принимает только `version: 2` с флагами `import_clients`/`import_settings`; занятый или чужой IP
  заменяется следующим свободным.
- **PWA и заголовки.** `CACHE_NAME = 'csqtt-panel-shell-2.5.4-pwa6'` (версию сверяет `check_versions.sh`).
  Ответы получают `nosniff`, `X-Frame-Options: DENY`, CSP, HSTS `max-age=15552000`; HTML панели — `no-store`;
  имена и JSON в страницах подписок экранируются (`html_escape`, `js_json_embed`).

## Развёртывание, TLS и обслуживание

`scripts/install.sh` — единственный путь установки/обновления сервера (`SCRIPT_VERSION = 2.5.4`, образ
`csqtt:2.5.4`). Режимы: `systemd` (по умолчанию) и `docker`; в Docker — `--network host`, контейнер `csqtt`,
caps `NET_ADMIN`/`NET_RAW`/`NET_BIND_SERVICE`, `--restart unless-stopped`, кандидат тегируется как основной
образ только после health-check. Требования: root, `/etc/os-release`; apt (ubuntu/debian/linuxmint/pop), dnf/yum
(rhel-семейство, fedora), pacman (arch/manjaro); архитектура до переключения runtime — только `x86_64`/`amd64`.

- **Cutover.** Аргументы → preflight → скачивание релиза (redirect `releases/latest` → тег `vX.Y.Z` →
  `recsqtt-linux-amd64` + `SHA256SUMS`, сверка SHA-256) → запуск кандидата с `--version` **до** остановки старого
  → снимок → остановка/очистка → NAT/firewall → env → TLS → бинарник → служба/контейнер → health-check. Ошибка
  или `INT`/`TERM` до/после arming запускают откат.
- **Снимок и откат.** `snapshot_runtime` сначала останавливает runtime (SQLite нельзя копировать на живом
  файле), затем копирует БД с `-wal`/`-shm`, env, `install.json`, сертификаты, unit-файлы, LE-env, сеть, прежний
  бинарник и Docker-образ; хранятся три последних снимка. Откат возвращает файлы, правила, LE-таймер и прежний
  runtime, маркеры ошибок — в журнал.
- **Adopt.** `detect_existing_install` распознаёт systemd/docker, `adopt_existing_install` читает режим, порты и
  хост из `install.json`, `csqtt.env`, `ExecStart` или командной строки контейнера; unit/env/БД не
  переписываются. Чужой `--config-dir` в unit — жёсткая ошибка; неоднозначный host/режим требует `--host` или
  `--reconfigure` (`--check` только печатает найденное).
- **TLS и Let's Encrypt.** Без пары сертификатов — self-signed (`rcgen`; SAN:
  localhost/127.0.0.1/hostname/локальный IP). IP-режим: панель на `--web-port` (46002), certbot `--ip-address`
  (сначала `shortlived`), при неудаче остаётся self-signed. Доменный режим: панель на 443, certbot `--domains`,
  http-01 на `LE_HTTP_PORT` (80), self-signed откат запрещён — неудача `die`. Продление: helper +
  `csqtt-letsencrypt.timer` (раз в 24 ч), порог — 3 дня для IP и 30 дней для домена.
- **`/etc/letsencrypt` не удаляется никогда** — даже `uninstall --purge`; установщик трогает только сертификаты в
  config-dir и `letsencrypt.env`.
- **Обновление.** `csqttctl update` скачивает свежий `install.sh` + `SHA256SUMS` и делает re-exec с теми же argv
  (`CSQTT_UPDATE_REEXEC=1` защищает от петли); `--version` пинит версию, `--force` переустанавливает ту же,
  `--reconfigure` разрешает смену host/портов/режима; `install.json` (0600) хранит версию, режим, host, порты и
  тип TLS; даунгрейд — только восстановлением снимка runtime.
- **`csqttctl`** — симлинк на `/usr/local/lib/csqtt-installer/install.sh`: `status`, `credentials`, `logs [-f]`,
  `panel`, `update`, `uninstall [--purge]`; `credentials` печатает пароль в stdout и не пишет в журнал,
  `uninstall` сохраняет `/etc/csqtt` и БД без `--purge`.

## Диагностика и проверяемые ограничения

Диагностика разделена на независимые каналы, и build type влияет на них по-разному:

| Канал | Куда идёт | Debug | Release |
| --- | --- | --- | --- |
| Kotlin `Log.*` | logcat, теги по компонентам (`TunVpnService`, `TunnelManager`, …) | всё | `Log.d`/`Log.v` вырезаны R8 (`app/proguard-rules.pro`, `-assumenosideeffects`) |
| Rust stdout | протокол (`GETCONF`, `TUNCONF`, `CAPTCHA_SOLVE`, `__CSQTT_EVENT__`) | зеркалируется в logcat под `CSQTT/Protocol` | не зеркалируется |
| Rust stderr | `log_error!`/`log_info!` | зеркалируется под `CSQTT/Diagnostic` | не зеркалируется |
| In-app журнал (`TunnelManager.logs`) | экран и копирование в отчёт | работает | работает; детализация зависит от тумблера «Показывать логи» |

- **Зеркалирование только в debug.**
  `mirrorRustLineToLogcat` выходит сразу при `!BuildConfig.DEBUG`; severity — эвристика по содержимому (`ошибка`, `fail`, `timeout`, …), потому что Rust пишет информационные строки через `log_error!`.
  Лимит записи logcat — 4000 байт, бюджет чанка — 3900 байт, длинная строка режется с маркером `[часть N/M]` (`RustLogSinkPolicy`).
- **События.**
  Формат `__CSQTT_EVENT__|KIND|{json}`, префикс задан в `rust-client/events.rs` (`EVENT_PREFIX`) и продублирован
  в `CsqttConstants.General.CSQTT_EVENT_PREFIX`; отправка включается только `CSQTT_EVENTS=1` (Kotlin ставит всегда).
  Реально эмитятся `READY`, `STOPPED`, `PROCESS`, `CONFIG`, `ROUTING`, `ROUTING_ABSENT`, `WORKERS`, `STATS`, `ERROR`, `ACTIVE_ZERO`,
  `TUN_LOST`, `DTLS`, `SERVER_RESTART`, `PROGRESS`, `NETWORK_SUSPECT`, `CALL_UNAVAILABLE`; `STARTED`, `CAPTCHA_REQUEST` и `CAPTCHA_DONE`
  `TunnelEventParser` разбирает, но текущий Rust их не отправляет.
- **Границы журнала.**
  Сообщение обрезается до 4096 символов (`MAX_LOG_MESSAGE_LENGTH`), в журнале держится 500 записей (`LogJournalPolicy.MAX_ENTRIES`), pending-буфер — 128 ключей с вытеснением не-терминальных записей и флашем через 120 мс; терминальная строка `[СТОП]`
  переживает инвалидацию процесса (`TunnelLogPolicy`), повторные строки сливаются со счётчиком.
- **Границы Rust-логов.**
  Диагностическая строка — не более 4096 байт, протокольная — не более 65536 байт; очереди вывода — 128 (protocol) и 512 (diagnostic). Слишком длинное событие заменяется на `ERROR` с кодом `event_payload_too_large`,
  а слишком большое правило маршрутизации — на фатальный `routing_payload_too_large`, чтобы туннель не жил без исключений оператора.
- **Проверяемые ограничения продукта.**
  Серверный payload один — `recsqtt-linux-amd64`; ARM-VPS и специального ARM-режима нет, `recsqtt-x86_64.apk` отдельным ассетом
  не публикуется (x86_64 остаётся внутри universal), серверного бинаря в APK нет (шаг `Guard: APK carries no server payload`).
  В `app/src` нет `androidTest/`, поэтому тесты только JVM-юнит (`:app:testDebugUnitTest`), а читающие `AndroidManifest.xml`
  тесты требуют рабочего каталога модуля и запускаются через Gradle.
- **Гейты.**
  Все проверки живут в `.github/workflows/build.yml` (`workflow_call`): `Gate: version consistency`, `Gate: installer shell tests`,
  `Gate: Kotlin unit tests`, `Gate: APK runtime dependencies` (запрет SSH/BouncyCastle в `releaseRuntimeClasspath`),
  `Gate: Rust client` (`check_no_runtime_panics.sh`, fmt, clippy `-D warnings`, `cargo test`), `Build server binary`
  (`build_linux.sh --tests`: fmt, clippy и тесты в общем `build/csqtt-uring-linux-recsqtt-linux-amd64`),
  плюс `verify native provenance` и проверки подписи/идентичности APK; триггера `pull_request` нет, а `release.yml` и `beta.yml`
  вызывают общий workflow и своих гейтов не имеют.
- **Воспроизводимость проверок.**
  Клиент: `cd rust-client && cargo test` и `bash check_no_runtime_panics.sh`; сервер: `cd rust-server && cargo test`
  (musl-цель из `.cargo/config.toml`). Согласованность версий — `bash scripts/check_versions.sh --root .`;
  целостность — `scripts/native_client_provenance.sh verify` и `scripts/server_asset_provenance.sh verify`; системные проверки TUN/systemd — `scripts/run_system_checks.sh`, требует root.

## Сборка и карта проверок

| Компонент | Инструмент | Цель | Выход |
| --- | --- | --- | --- |
| Rust-клиент | `cargo-ndk` (`build_so.sh`) | `arm64-v8a`, `armeabi-v7a`, `x86_64` | `app/build/generated/jniLibs/<variant>/<abi>/libclient.so` |
| Rust-сервер | `cargo-zigbuild`, musl | `x86_64-unknown-linux-musl` | `app/build/generated/assets/recsqtt-linux-amd64`, `rust-server/dist/` |
| APK | Gradle/AGP 9.2.0, JDK 17 | `compileSdk`/`targetSdk` 37, `minSdk` 26 | `app/build/outputs/apk/...`, `app/release/recsqtt-*.apk` |

- **Профили.** Клиент: `debug` → Cargo `android-debug` (`inherits = "dev"`, `opt-level = 1`, `strip =
  "debuginfo"`), `release` → `opt-level = 3`, LTO, `codegen-units = 1`, `strip = true`; хостовый `dev` сохраняет
  `debug = "line-tables-only"`. Сервер всегда `release`, собирается вне Gradle.
- **Gradle.** `buildNativeClientDebug/Release` → `build_so.sh`; `verifyNativeClientDebug/Release` →
  `native_client_provenance.sh verify`; гейт висит на `merge*JniLibFolders`, поэтому `:app:testDebugUnitTest`
  натив не собирает; `verifyNativeArtifacts` — ручная проверка. Свойства: `-Pcsqtt.abis`, `-Pcsqtt.cargoJobs`,
  `-Pcsqtt.nativeTests`, `-Pcsqtt.buildNativeClient`, `-Pcsqtt.skipNativeVerification`.
- **Provenance.** Клиент — схема v6: ELF-класс/машина, `ET_DYN`, отсутствие Go-метаданных, маркер транспорта,
  SHA-256 против манифеста, совпадение с промежуточным выводом cargo и хеш входов (скрипты, `*.rs`,
  `shared/*.rs`, `vendor/**`, `Cargo.lock`); сервер — схема v4: ELF amd64, `WIRE_PROTOCOL_REVISION`, features,
  SHA-256 и хеш входов с `data/*.txt`.
- **CI-гейты.** Только в `.github/workflows/build.yml` (release/beta его вызывают; своих гейтов у них нет):
  `build-version.sh` (версия+коммит), `check_versions.sh`, `deploy_shell_tests.sh`, `./gradlew
  :app:testDebugUnitTest`, отсутствие `sshj`/BouncyCastle в `releaseRuntimeClasspath`, Rust client
  (`check_no_runtime_panics.sh`, `fmt`, `clippy -D warnings`, `test`), Rust server (musl-`clippy`/`test` через
  zig-обёртки), затем provenance, guard «в APK нет серверного payload и есть `libclient.so`», подпись и identity
  (package `csqtt.quic.amurcanov`, versionName/versionCode).
- **Релиз и ручное.** `release.yml` — тег `vX.Y.Z` (строгий regex, коммит достижим из `origin/main`), публикация
  трёх APK, `recsqtt-linux-amd64`, `install.sh`, `SHA256SUMS`; `beta.yml` на пуш в `main` — один `arm64-v8a` с
  `-Pcsqtt.versionSuffix=-beta.<sha>` в Telegram. Вручную: release-APK требует
  `KEYSTORE_FILE`/`KEYSTORE_PASSWORD`/`KEY_ALIAS`/`KEY_PASSWORD`; device-smoke (`androidTest/` нет);
  `run_system_checks.sh` (TUN, standalone-панель, systemd, docker) — root; VPS-проверки и удаление релиза/тега.

## Термины

| Термин | Значение |
| --- | --- |
| Участник | Роль Android-приложения: подключается по ссылке и не разворачивает сервер |
| Владелец | Обычная запись `passwords` с именем «Владелец» и предпочтительным IP `10.66.67.2` |
| Профиль конфигурации | Набор настроек приложения (в т.ч. `participant_show_logs`), переключаемый в UI |
| `csqtt://`-ссылка | Зашифрованный base64url-payload `connect?v=2&host&peer&password[&hashes|&token]`; единственный источник хоста, порта и пароля |
| Группа | `ClientGroup`: общее правило маршрутизации, лимит воркеров и VK-креды для входящих в неё клиентов |
| Клиент панели | Запись `PasswordEntry`: туннельный пароль-ключ, IP, срок, группа, правило, VK-креды, счётчики |
| VK-хеш | Идентификатор VK-звонка (строка ≥16 символов), из которого клиент строит TURN-подключение |
| VK-токен | Токен VK-аккаунта, по которому приложение само получает хеши через API |
| TURN-подсеть | Один из выбираемых в приложении диапазонов TURN-серверов VK для исходящих медиа-потоков |
| Серверное правило | `RoutingRule`: режимы whitelist/blacklist для приложений, доменов и IP, шаблоны RU-списков и пресет |
| TUN | Виртуальный интерфейс: на сервере kernel-`csqtt1` (`10.66.67.1/24`), на Android — `VpnService` с передачей fd |
| Abstract-сокет | Unix-сокет `csqtt_tun_uds` без файла в ФС, через который fd TUN переходит из Kotlin в Rust-клиент |
| Provenance | Манифест с SHA-256 артефактов и хешем входов сборки; защищает от протухшего или подменённого бинарника |
| Воркер | Один поток данных внутри сессии; клиент держит 1–100 воркеров, сервер маршрутизирует пакеты по ним |
| Generation / salt | Идентификаторы поколения и соли сессии; смена любого из них ретирует прежнюю сессию |
| TUNCONF | Ответ сервера `TUNCONF:<ip>:<dns>:0:stream-v1`, выдающий клиенту туннельный адрес и DNS |
| Снимок (snapshot) | Копия runtime-состояния перед cutover: БД, env, сертификаты, unit-файлы, сеть, прежний бинарник |
| Capability-URL | Ссылка с UUID (`/{admin_uuid}/admin`, `/{sub_uuid}/sub`), дающая доступ без логина панели |
