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

## 5. Два Dockerfile расходятся (2026-11-13, follow-up)

`scripts/install.sh` строит локальный образ из генерируемых helper'ов
(`network-up.sh`/`tun-recover.sh`, запечённые порты), а GHCR-образ
(`docker/Dockerfile` + `docker/entrypoint.sh`) — self-bootstrap с динамическим
чтением `install.json`. Установщик пока использует свой образ, поэтому не
ломается, но паритет ничем не проверяется: если переключить установщик на
GHCR-образ, его `$@` (`--listen/--web-port/--config-dir`) будет проигнорирован.

## 6. Версия образа продублирована вне гейта (follow-up)

`docker/compose.yml` и `docker/.env.example` содержат тег `2.5.4`, а
`check_versions.sh` их не читает. Следующий бамп разъедется; нужен либо единый
источник тега, либо проверка в `check_versions.sh`.

## 7. Нет поведенческих тестов entrypoint (follow-up)

`docker/entrypoint.sh` проверяется только `sh -n`/shellcheck; генерация
identity, bootstrap частичного тома и iptables — без автотестов. Смоук-прогоны
делались вручную.
