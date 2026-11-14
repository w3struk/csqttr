# Открытые вопросы

Технические дефекты, найденные при разборе флейка TURN-тестов (2026-11-12).
Оба воспроизводятся под нагрузкой на CPU и не лечатся увеличением таймаутов.

## 1. `deallocate()` не ждёт in-flight отправку: `Refresh(lifetime=0)` может обогнать последний ChannelData

**Где:** `rust-client/turn.rs`.

- `TurnAllocation::deallocate()` ждёт только опустошения очереди
  (`while !queue.queue.is_empty()`), но не завершения отправки.
- Writer снимает пакет с очереди и отправляет его не атомарно с точки зрения
  наблюдателя: между `queue.pop()` и `socket.try_send(...)` очередь уже пуста,
  а пакет ещё не ушёл.
- В это окно `deallocate()`/`pump_native` отправляет `Refresh(lifetime=0)`, и
  он может обогнать последний ChannelData. Хвост данных уезжает после запроса
  на снос аллокации.

**Симптом:** тест
`turn::integration_tests::data_packets_preserve_channel_order_and_release_idle_pool_leases`
под нагрузкой падает на проверке «deallocate refresh arrived before the channel
batch completed» и затем по `Elapsed` в teardown.

**Как лечить:** счётчик/флаг in-flight у writer'а; `deallocate()` ждёт
`queue empty && in_flight == 0`. Подтверждение от writer'а (канал/condvar)
предпочтительнее sleep.

**Как проверять:** тот же стресс, что для пула: 300 прогонов под
`taskset -c 0,1` + занятые CPU; после фикса — 0 падений и срабатывание
assert'а порядка, а не таймаута.

## 2. `recv_stream_message` читает без таймаута — частичная запись вешает suite

**Где:** `rust-client/turn_integration_tests.rs`, функция `recv_stream_message`.

- Заголовок читается под `timeout(3s, read_exact(...))`.
- Следующее чтение тела — `stream.read_exact(&mut wire[20..])` **без таймаута**.
- Если сервер отправит частичную запись и замолчит, suite повиснет навсегда:
  даже `Elapsed` не появится, CI-таймаут job'а — единственный предохранитель.

**Как лечить:** обернуть второе чтение в тот же таймаут (или общий
`STEP_TIMEOUT`), чтобы частичная запись давала диагностируемый `Elapsed`.

**Как проверять:** юнит-сценарий с сервером, который пишет заголовок и половину
тела и закрывает соединение; тест должен упасть по таймауту, а не зависнуть.

## Контекст

- Флейк пула (`authenticated_flow_survives_pool_deficit_and_keeps_channel_data_zero_copy`)
  уже исправлен: тест ждёт возврата лизинга до ответа сервера, коммит `3de9c85`.
  Увеличение таймаута до 10 c не помогало (CI run 43187005542) и откачено.
- Оба пункта выше — продакшн/tests-дефекты, а не проблемы раннера; изоляция
  тестов (`--test-threads=1`) их не лечит.

## 5–7. Docker follow-ups — закрыты (2026-11-13)

- **§5 Паритет entrypoint.** `docker/entrypoint.sh` принимает `--listen/--web-port/--config-dir`;
  при существующем полном `install.json` CLI игнорируется с предупреждением (state wins),
  `--config-dir` допускается только как `/etc/csqtt`. Установщик и GHCR-образ теперь
  совместимы по контракту портов; stale `CSQTT_MANAGED` ACCEPT-правила чистятся по принципу
  «dport ≠ эффективного» (LE-порт 80 не трогается).
- **§6 Версия образа.** `scripts/check_versions.sh` сверяет тег `recsqtt:<ver>` в
  `docker/compose.yml` (включая форму `${CSQTT_IMAGE:-…}`) и `docker/.env.example` с
  `versionName`; фикстура ловит отставший и отсутствующий файл.
- **§7 Поведенческие тесты.** `.github/tests/docker-entrypoint.sh` (106 ассертов) гоняет
  shipped entrypoint через три env-хука и шимы `ip`/`iptables`/`csqtt`: bootstrap домен/IP,
  state-wins на повторном старте, частичная TLS-пара (уцелевший файл не меняется),
  stale netfilter с произвольным портом, неполный `install.json` + CLI, порты вне диапазона,
  отсутствие TUN, ошибки флагов.
- Вне тестов остаётся реальный netfilter/TUN/`docker run` и busybox-`sh` образа.
