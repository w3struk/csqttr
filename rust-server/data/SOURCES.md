# Источники серверных списков маршрутизации

Оба файла в этом каталоге — фиксированные снимки (pinned snapshots). В рантайме сервер
не ходит в upstream: список обновляется коммитом вместе с сервером.

## `domains_ru.txt`

- Происхождение: объединение нашего корневого `domains.txt` и категории `whitelist`
  из [roscomvpn-geosite](https://github.com/hydraponique/roscomvpn-geosite).
- URL: <https://raw.githubusercontent.com/hydraponique/roscomvpn-geosite/143d1c2ed7a4e5d26c68310f04fc6e4fcfdb8f9d/data/whitelist>
- Коммит: `143d1c2ed7a4e5d26c68310f04fc6e4fcfdb8f9d`
- Дата коммита: 2026-04-13
- Лицензия: MIT (Copyright (c) 2018-2019 V2Ray). Атрибуция обязательна.
- Снято: 2026-11-05
- Итог: 515 записей, 5 967 байт (LF, сортировка, дедупликация, без префиксов).
  Из них 505 — наш список, 467 — upstream, пересечение 457.

## `ips_ru.txt`

- Происхождение: категория `whitelist` из
  [roscomvpn-geoip](https://github.com/hydraponique/roscomvpn-geoip).
- URL: <https://raw.githubusercontent.com/hydraponique/roscomvpn-geoip/6029bb51f358a1ec824c8daa5559496eae53d417/release/text/whitelist.txt>
- Коммит: `6029bb51f358a1ec824c8daa5559496eae53d417`
- Дата коммита: 2026-04-23
- Лицензия: файл LICENSE в репозитории отсутствует, явного упоминания лицензии нет.
  Решение владельца: коммитим ассет как есть; этот файл фиксирует источник, коммит и
  дату, чтобы список можно было быстро заменить или удалить.
- Снято: 2026-11-05
- Итог: 6 710 CIDR, 115 173 байта (LF, сортировка по числовому значению сети и префиксу).
- sha256 нормализованного текста:
  `5cf0b8862ad4f3318831dcf2e94076e221320ff47d77f1a12ebe661f613f70f6`
