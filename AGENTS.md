# AGENTS.md

Android-приложение (Kotlin/Compose), маскирующее туннель TURN/RTP под медиатрафик звонков.
Приложение — **только участник**: подключается по `csqtt://`-ссылке из панели и не
разворачивает сервер. Rust-**клиент** запускается как дочерний процесс;
Rust-**сервер** ставится и обновляется через `scripts/install.sh`/`csqttctl`
(вход one-liner'а — release-ассет `bootstrap.sh`, он проверяет и запускает
release-ассет `install.sh`).

> Этот файл — только для ИИ-агентов: здесь то, что нельзя вывести из кода за пару минут чтения.
> Механика сборки, флаги, зависимости, provenance и подпись — в **[BUILDING.md](BUILDING.md)**.
> Собирайте по нему; не дублируйте его содержимое здесь и не правьте одно без другого.

## Бренд

Бренд — `reCSQTT`; машинный слаг — `recsqtt`. В отображаемых строках меняем только текст;
идентификаторы, пути, env, юниты, бинарники, wire-константы и схему `csqtt://` не
переименовываем. Прежнее имя CSQTT живёт в контрактах: package id `csqtt.quic.amurcanov`,
ссылки `csqtt://`, пути `/etc/csqtt`, env `CSQTT_*`, юниты и бинарники; обновление
существующих установок и APK идёт поверх, без миграции.

## Доступ к тестовому серверу

На тестовом VPS стоит живая установка reCSQTT (Debian, systemd-режим, панель на
порту 46002). Конкретные адрес, hostname и пользователя **владелец называет в
ответ на запрос** — они меняются, поэтому зашивать их сюда нельзя.

Агент, которому нужно заглянуть на сервер, **не имеет доступа по умолчанию** —
ни ключа, ни агента. Доступ даёт владелец, и только на время задачи.

### Как запросить

Сформулируйте запрос явно и дождитесь ответа, не пытаясь обойти его:

1. **Что именно нужно с сервера** — команда или набор команд и зачем. Диагностика
   (чтение) — отдельно от изменений. Изменения запрашиваются точечно, под
   конкретный шаг плана; общее «дай доступ» без перечня операций не означает
   разрешения на что-то править.
2. **Адрес и пользователь SSH** — их называет владелец.
3. **Ключ** — путь к приватному ключу на машине владельца. Если нужного ключа
   нет, владелец приносит его сам; **пароль или passphrase в чате не передаётся
   никогда**.

### Как владелец даёт доступ

Владелец выполняет на своей стороне — пароль остаётся у него и в переписку не
попадает:

```bash
# агент на фиксированном сокете (путь уже заведён в системе)
eval "$(ssh-agent -a "$HOME/.ssh/agent/opencode.sock")"
# добавить ключ — passphrase спросит у владельца
ssh-add ~/.ssh/id_ed25519
ssh-add -l
```

Если сокет занят засохшим файлом, удалить его: `rm -f "$HOME/.ssh/agent/opencode.sock"`.

Агент использует ключ из `SSH_AUTH_SOCK="$HOME/.ssh/agent/opencode.sock"`; агент
должен быть запущен в этой же сессии оболочки, иначе сокет не ответит.

### Как отозвать

```bash
ssh-agent -k                              # погасить агент целиком
ssh-add -d ~/.ssh/id_ed25519              # убрать только этот ключ
```

### Правила работы с VPS

- Установку и обновление сервера запускают только `scripts/install.sh`/`csqttctl`
  (или release-ассеты `bootstrap.sh` → `install.sh` из CI). Из приложения сервер не
  разворачивается: вкладки «Деплой», SSH-клиента и серверного payload'а в APK нет.
- Снимок состояния, диагностика, чтение логов — по SSH разрешены свободно.
- Любая запись на сервере — только под явно названную операцию: остановить
  таймер, запустить конкретную службу, поправить конкретный файл.
- `/etc/letsencrypt` удалять нельзя.
- Базовый IP-сертификат сервера — эталон для проверки отката: его серийник
  фиксируется в снимке состояния в начале работы. После отката в IP-режим
  серийник обязан совпасть, иначе откат стоил выпуска, а лимит Let’s Encrypt
  израсходован впустую.

## Структура

| Путь | Что это |
| --- | --- |
| `app/` | Единственный Gradle-модуль. AGP 9.2, Kotlin 2.4, Compose, JDK 17, `compileSdk`/`targetSdk` 37, `minSdk` 26. |
| `rust-client/` | Крейт `csqtt-client`. cargo-ndk → `app/build/generated/jniLibs/<variant>/<abi>/libclient.so`. **Не JNI-библиотека** — это исполняемый файл, запускаемый как дочерний процесс через `ProcessBuilder`. |
| `rust-server/` | Крейт `csqtt`. cargo-zigbuild (статический musl, только amd64) → `app/build/generated/assets/` и `rust-server/dist/`. В APK не пакуется: release CI публикует бинарь отдельным ассетом. |
| `shared/` | 3 файла `.rs`, компилируемых в **оба** крейта через `#[path = "../shared/..."] mod ...;` в каждом `main.rs`. Не cargo workspace и не path-зависимость. `dtls.rs` и `wire_protocol.rs` общие; `spsc_ring.rs` только для клиента. |
| `scripts/` | `android_env.sh`, `device_abi.sh` (определяет ABI подключённого устройства), два скрипта provenance, `build_apk.sh`, `install_apk.sh`, `run_system_checks.sh`. Пути артефактов настраиваются флагами `--variant`, `--jni-libs-dir`, `--assets-dir`, `--manifest`; значения по умолчанию — `app/build/generated/`. |
| `scripts/install.sh` | Публичный установщик на ~2.5k строк: скачивает серверный релиз и ставится на сервер вручную или one-liner'ом (режим systemd или docker). |
| `scripts/bootstrap.sh` | Тонкий вход one-liner'а: резолвит тег (`releases/latest`), скачивает `install.sh` и `SHA256SUMS`, сверяет SHA-256 и запускает установщик с проброшенными аргументами. Публикуется ассетом рядом с `install.sh`. |
| `rust-server/data/` | Фиксированные ассеты маршрутизации: `domains_ru.txt` (515 доменов) и `ips_ru.txt` (6 710 CIDR) + `SOURCES.md` с источниками. Подключены `include_str!` в `rust-server/routing_assets.rs`; клиент и приложение своих копий не содержат. |

## Нативная часть: варианты и грабли

Всё генерируемое Rust лежит в `app/build/generated/` — в `app/src` не попадает ничего, и
`./gradlew clean` удаляет нативную часть целиком. Gradle собирает клиентскую часть и
проверяет её по provenance; цепочка и свойства `-Pcsqtt.*` — в
[BUILDING.md](BUILDING.md#provenance-и-защита-от-протухших-бинарников).

| Вариант Android | Каталог | Профиль Cargo |
| --- | --- | --- |
| `debug` | `app/build/generated/jniLibs/debug/` | `dev` (`opt-level = 1`, `debug = "line-tables-only"`) |
| `release` | `app/build/generated/jniLibs/release/` | `release` (`opt-level = 3`, LTO, `strip = true`) |

Серверный бинарник вариантонезависим и всегда собирается в профиле `release`
вне Gradle — `rust-server/build_linux.sh` кладёт его в
`app/build/generated/assets/` и `rust-server/dist/`. В APK он не попадает: это
отдельный release-ассет и вход для `scripts/install.sh`.

Штатный серверный payload один — amd64; ограничение VPS не меняет
три ABI Android-клиента. Поддержки ARM-VPS, включая управление, и специального
ARM-режима нет; подробности сборки и очистки старых payload — в `BUILDING.md`.

Серверный `cargo` пишет **не** в `rust-server/target`, а в общий
`build/csqtt-uring-linux-recsqtt-linux-amd64` — его задаёт `[build] target-dir`
в `rust-server/.cargo/config.toml`, и туда же смотрят `build_linux.sh`,
`build_linux_variants.sh` и CI. Путь относительный, резолвится от каталога
конфига, поэтому нужен `cd rust-server`: из корня репозитория `cargo` конфиг не
увидит и создаст `./target`. `CARGO_TARGET_DIR` перекрывает значение из конфига
(так делает `build_linux.sh`), а `cargo clean` из `rust-server` чистит общий
каталог целиком.

Что важно именно агенту (в `BUILDING.md` этого нет):

- **Каталоги вариантов изолированы, cargo-таргет-директории тоже.** Debug и release не могут
  подмешать артефакты друг друга; переключение вариантов не вызывает пересборку зависимостей.
- **Менять `[profile.dev]` опасно только по размеру.** Полный debuginfo даёт ~200 МБ на ABI
  (замерено на arm64-v8a) — debug-APK раздувается до сотен мегабайт. `line-tables-only`
  сохраняет file:line в паниках и бэктрейсах при умеренном размере.
- **Kotlin-задачи больше не трогают нативную часть.** Гейт висит на
  `merge<Variant>JniLibFolders` / `merge*Assets`, а не на `preBuild`, поэтому
  `./gradlew :app:test` и `:app:testDebugUnitTest` не собирают Rust. Раньше — собирали, отсюда и
  был флаг `-Pcsqtt.skipNativeVerification=true` для юнит-тестов; он остался, но теперь нужен
  редко.
- **`rm -rf build/` в корне репозитория** удаляет промежуточные артефакты cargo, которые
  provenance сверяет с установленными библиотеками. Задачи сборки это учитывают
  (`outputs.upToDateWhen`), так что следующая сборка APK пересоберёт нативную часть сама;
  ручной вызов `scripts/native_client_provenance.sh verify` после такого `rm` честно упадёт.
- **Правка Rust, `shared/`, одного из build-скриптов или `rust-server/data/*.txt`** меняет
  хеш provenance. Клиентскую часть пересоберёт следующая сборка APK; сервер
  пересобирает `rust-server/build_linux.sh` (локально или в CI) — Gradle его больше
  не собирает и `rust-server/data/*.txt` в inputs Gradle не входят.

## Команды

Разбор флагов и сценарии сборки — в [BUILDING.md](BUILDING.md#быстрый-старт). Коротко:

```bash
# Юнит-тесты Kotlin (нативную часть не трогают)
./gradlew :app:testDebugUnitTest
./gradlew :app:testDebugUnitTest --tests "com.csqtt.client.WifiAutoPausePolicyTest"

# Rust-клиент — под хостовую цель; 362 теста, после компиляции проходят за секунды
cd rust-client && cargo test
cd rust-client && cargo test turn_stream        # фильтр по подстроке
cd rust-client && bash check_no_runtime_panics.sh

# Rust-сервер — musl-цель из .cargo/config.toml, нужен musl-тулчейн C/C++ (см. BUILDING.md).
# cd rust-server обязателен: target-dir из конфига относительный и указывает в
# <repo>/build/csqtt-uring-linux-recsqtt-linux-amd64; из корня конфиг не найдётся.
cd rust-server && cargo test
cd rust-server && cargo clippy --release --all-targets -- -D warnings

# Локальная сборка сервера — только с --no-tests: без флага в не-TTY включаются
# fmt/clippy/test, которым нужен musl C/C++ (падают на cc-rs: x86_64-linux-musl-g++).
# Сама сборка идёт через cargo zigbuild и системного musl-g++ не требует;
# musl-проверки — работа CI. Не перекрывайте CC/CXX на "zig cc": cc-rs такое отвергает.
bash rust-server/build_linux.sh --no-tests

# Нативная нагрузка и APK (обычно достаточно просто ./gradlew)
./gradlew :app:assembleDebug                    # dev-профиль клиента; сервер не собирается
./gradlew :app:verifyNativeArtifacts            # проверить клиентские payload'ы обоих вариантов
bash scripts/build_both_parallel.sh             # клиент и сервер параллельно, вне Gradle
bash scripts/build_apk.sh                       # release-APK в app/release/

# Сервер на VPS ставится и обслуживается установщиком, а не Gradle
sudo bash scripts/install.sh --yes
sudo csqttctl status

# Установка на устройство: Gradle сам определяет ABI, один ABI и один APK
./gradlew :app:installCsqttDebug
./gradlew :app:installCsqttRelease
```

Ключи подписи и отладочный `applicationId`-суффикс — в [BUILDING.md](BUILDING.md#release-подпись).

## Контракты — меняйте обе стороны вместе

1. **CLI-флаги.** `TunnelManager.startProcessLocked` (Kotlin) вручную собирает argv; его определяет
   `#[derive(Parser)] struct Arguments` в `rust-client/main.rs`. Новый флаг требует правок в обоих местах.
2. **Канал управления через stdin.** Kotlin пишет строки в stdin дочернего процесса; `rust-client/main.rs`
   в `start_control_input` принимает `PAUSE`, `RESUME`, `STOP`, `FINISH_VK_CALLS`, `CAPTCHA_RESULT|<payload>`,
   `UPDATE_DOMAINS|<json>`, `VK_JS_BOOTSTRAP:<base64>`. Канал считается **обязательным** — закрытый или
   отдавший ошибку stdin отменяет туннель, когда включены события.
3. **События в stdout.** Формат `__CSQTT_EVENT__|KIND|{json}`, отправляются только при `CSQTT_EVENTS=1`
   в окружении (Kotlin всегда его ставит). Определены в `rust-client/events.rs` (`EVENT_PREFIX`),
   продублированы в `Constants.kt` (`CSQTT_EVENT_PREFIX`), разбираются в `TunnelEventParser.kt`.
   Kotlin-парсер принимает надмножество: `STARTED`, `CAPTCHA_REQUEST`, `CAPTCHA_DONE` обрабатываются, но
   текущий Rust-клиент их не отправляет — не считайте их рабочими.
4. **Передача TUN.** Файловый дескриптор TUN пересекает границу процесса через **abstract** Unix-сокет
   `csqtt_tun_uds`: Rust его биндит (`rust-client/tun.rs`), Android подключается
   (`TunVpnService.kt`). Имя — жёстко зашитый литерал с обеих сторон, а не общая константа.
5. **Списки маршрутизации живут только на сервере.** `rust-server/data/domains_ru.txt` и
   `ips_ru.txt` подключены `include_str!` в `rust-server/routing_assets.rs` и хешируются
   `scripts/server_asset_provenance.sh`. Клиент получает домены массивом `domains` в JSON правила,
   адреса — `ips_sha`/`ips_blob` в правиле и stdin-командой `UPDATE_IPS`; копий списков в `app/`
   и корне нет. Манифест `csqtt-server.json` проверяется при `rust-server/build_linux.sh`
   и в CI; Gradle эти файлы не отслеживает и сервер не собирает. Ассет другого формата
   нужно добавить в `build_input_files` в `scripts/server_asset_provenance.sh`.
6. **ABI устройства для install-задач.** `installCsqtt*` читают ABI подключённого устройства **на этапе
   конфигурации Gradle**: `providers.exec` запускает `scripts/device_abi.sh`, который печатает
   `abi=<abi>` и `serial=<serial>`. Список поддерживаемых ABI продублирован в `scripts/device_abi.sh`
   и в `supportedAbis` в `app/build.gradle.kts` — при расхождении Gradle отвергнет значение сам.
   Добавляя ABI, правьте оба места.
7. **Имя выходного APK.** Имя задаёт Gradle: в `app/build.gradle.kts` каждый output получает
   `outputFileName = app-<version>-<abi>-<variant>.apk` (для universal — `app-<version>-universal-<variant>.apk`).
   Версия в имени — это `versionName` из `defaultConfig` **без** суффикса build type: вариант в имени
   уже назван. Оба скрипта собирают то же имя из той же версии, но читают её из
   `app/build.gradle.kts` через `sed` (`apk_version()`), а не держат вторую копию числа.
   `scripts/install_apk.sh` ищет APK по точному имени, `scripts/build_apk.sh` копирует их в
   `app/release/` как `recsqtt-<version>-<abi>.apk`. Меняя формат имени — правьте Gradle и оба скрипта.
8. **Ожидаемый отпечаток подписи.** Лежит в `scripts/release_signing_fingerprint.txt` (одна строка,
   SHA-256 сертификата, uppercase, без двоеточий) — это источник правды, потому что коммит нельзя
   подменить молча. Секрет `ANDROID_KEYSTORE_FINGERPRINT` — второе мнение: релизный workflow сверяет
   keytool ↔ файл ↔ секрет, и расхождение любой пары останавливает публикацию. Ротация ключа
   обновляет файл и секрет вместе (сначала коммит, потом секрет). Значение отпечатка **нельзя
   передавать выходом job'а**: оно равно значению секрета, и GitHub такой выход не передаёт
   («Skip output 'fingerprint' since it may contain secret») — вызывающий получит пустое
   значение без всякой ошибки. Для описания релиза отпечаток читается из файла в репозитории.
9. **Суффикс версии для беты.** `beta-version.sh` считает `-beta.<short-sha>`, а `versionName` в
   `app/build.gradle.kts` приклеивает его свойством `-Pcsqtt.versionSuffix`. Литерал версии обязан
   оставаться **первым** в строке: из неё читают версию пять мест (`build_apk.sh`, `install_apk.sh`,
   `collect-release-assets.sh`, `release-note.sh`, шаг `Verify APK identity`),
   и перестановка выражения сломает их молча. `versionCode` бета не меняет — иначе релиз с меньшим
   кодом стал бы для тестера «понижением».

## Правила Rust, которые роняют сборку

- **У клиента линт строже, чем у сервера:** `rust-client/check_no_runtime_panics.sh` запрещает
  `unwrap`/`expect`/`panic!`/`unreachable!`/`todo!` в рантайм-коде. Так как `shared/` компилируется
  в клиент, правило действует и там — новый код в `shared/` проверяется самым строгим набором.
  Тестовые модули исключены (они за `#[cfg(test)]`).
- Оба крейта гоняют `-D warnings`: любое новое предупреждение роняет сборку.
- Элементы в `shared/`, которые использует только один крейт, требуют `#[allow(dead_code)]`
  (см. `shared/wire_protocol.rs`), потому что каждый крейт видит своё подмножество.
- `rust-client/vendor/{primp,netstack-smoltcp}` **полностью вендорены** и подключены через
  `[patch.crates-io]`. Соответствующие строки версий в `[dependencies]` (`primp = "1.3.1"`,
  `netstack-smoltcp = "0.2.4"`) инертны — патч всегда побеждает, и в `Cargo.lock` у них нет
  `source`/`checksum`. Изменение этих версий ничего не даёт; правьте вендоренное дерево.
  `primp-rustls` / `primp-tokio-rustls` **не** патчатся и закреплены через `=`.
- `WIRE_PROTOCOL_REVISION` в `rust-server/main.rs` вытаскивается **через `sed`** в
  `scripts/server_asset_provenance.sh` и должен присутствовать в каждом собранном бинарнике сервера
  дословно. Сохраняйте форму `NAME: &str = "..."` и само имя.

## Соглашения Kotlin

- Логика, которую нужно тестировать, выносится в файлы вида `internal object *Policy` / top-level
  `internal fun` (`TunnelServicePolicy.kt`, `WifiAutoPausePolicy.kt`, `WorkerCountPolicy.kt`, …), чтобы её
  можно было прогнать на JVM. Добавляя нетривиальную логику внутрь Service/Manager, выносите Policy,
  а не пытайтесь тестировать сам Service.
- `app/src/androidTest/` не существует, несмотря на зависимости — только JVM-юнит-тесты.
- Некоторые тесты читают файлы по путям относительно **модуля** (`app/src/main/AndroidManifest.xml`
  либо `src/main/AndroidManifest.xml`, например `TvManifestTest`). Запускайте их через Gradle: они
  ломаются, если рабочий каталог тестовой JVM — корень репозитория.
- **Логи — два независимых канала, не путать.** `Log.*` идёт в logcat (в release `d`/`v`
  вырезает R8, `i/w/e` остаются); `TunnelManager.logs`/`updateProcessLog` — in-app журнал,
  который пользователь копирует в отчёт. Поток Rust-клиента зеркалируется в logcat под
  тегами `CSQTT/Protocol` (stdout) и `CSQTT/Diagnostic` (stderr) только в debug — через
  `mirrorRustLineToLogcat`. Не считайте журнал отладочным каналом и не убирайте
  `BuildConfig.DEBUG` с этого зеркалирования. Детали — в
  [BUILDING.md](BUILDING.md#логи-и-варианты-сборки).
- Пользовательские строки на русском; они лежат в `strings.xml`, но много текста захардкожено прямо в UI.
- Gradle вырезает у зависимостей `/META-INF/{AL2.0,LGPL2.1,INDEX.LIST,DEPENDENCIES,LICENSE.md,NOTICE.md}`,
  поэтому лицензии, которые приложение обязано распространять, лежат в
  `app/src/main/assets/licenses/` (сейчас `CSQTT-LICENSE` и `primp-LICENSE` — последняя для вендоренного
  форка). Новая зависимость с требованием по редистрибуции требует файла там.

## Бампы версии

`2.5.4` / `versionCode 234` продублированы в: `app/build.gradle.kts` (`versionCode`, `versionName`),
`rust-client/Cargo.toml` + `rust-client/Cargo.lock`, `rust-server/Cargo.toml` + `rust-server/Cargo.lock`,
`scripts/install.sh` (`SCRIPT_VERSION`, `CSQTT_DOCKER_IMAGE`), `rust-server/main.rs` (баннер при старте)
и `rust-server/web_panel.rs` (`CACHE_NAME` PWA service-worker). Согласованность проверяет
`scripts/check_versions.sh` (гейт `Gate: version consistency` в CI); после бампа запускайте
`bash scripts/check_versions.sh --root .`.

## Тулчейн

Rust `1.97.1`, закреплён независимо в `rust-client/rust-toolchain.toml` и `rust-server/rust-toolchain.toml`
(разные наборы таргетов; состав — в [BUILDING.md](BUILDING.md#зависимости)). CI — три workflow:
`build.yml` (общие шаги, `workflow_call`), `release.yml` (тег `v*` → GitHub Release) и `beta.yml`
(пуш в `main` → сообщение с arm64-APK в Telegram-канал; коммит с тегом `v*` бета
пропускает, поэтому порядок выпуска — сначала тег, потом push `main`). Гейты живут только в `build.yml`: в
`release.yml` и `beta.yml` их нет и быть не должно, иначе шаги размножатся. CI на pull request'ах
нет, поэтому в повседневной работе гейты по-прежнему соблюдает тот, кто здесь работает; секреты и
порядок первого релиза — в [BUILDING.md](BUILDING.md#релизный-ci-github-actions).
