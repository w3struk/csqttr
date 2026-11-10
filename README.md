<div align="center">

# CSQTT-Rebirth

<br>

<img src="https://img.shields.io/badge/Android-SDK_28--37-3DDC84?style=for-the-badge&logo=android&logoColor=white" alt="Android SDK" />
<img src="https://img.shields.io/badge/Rust-2024-000000?style=for-the-badge&logo=rust&logoColor=white" alt="Rust Core" />
<img src="https://img.shields.io/badge/Kotlin-Compose-7F52FF?style=for-the-badge&logo=kotlin&logoColor=white" alt="Kotlin" />

</div>

<br>

**CSQTT** — Android-приложение и высокопроизводительный сервер для создания защищённого туннеля поверх TURN/RTP. Клиент поднимает локальный интерфейс на устройстве, маскируя транспорт под зашифрованный медиатрафик звонка.

**Кросс., проекты с поддержкой CSQTT**: 
- Windows & Linux порт - [luminescq/focsq](https://github.com/luminescq/focsq)
- ios совместимый клиент - [anton48/vk-turn-proxy-ios](https://github.com/anton48/vk-turn-proxy-ios)

**Прекрасный аналог csqtt / wdtt**: [hackdiaz-dev/turn-proxy-android](https://github.com/hackdiaz-dev/turn-proxy-android)


> [!NOTE]
> Подробная техническая информация и документация по архитектуре **CSQTT** будут опубликованы позже в отдельном окне заметок.

---

## Сборка (Linux)

Подробная инструкция — [BUILDING.md](BUILDING.md). 

## Обновление и откат

Начиная со следующего релиза (2.5.2) владелец сервера — обычная запись клиента
в панели; отдельного `main_password` в базе больше нет. Первый клиент создаётся
в панели или мигрируется из старой установки один раз.

- `--password` / `CSQTT_MAIN_PASSWORD` / `deploy-overrides.json` принимаются
  только как legacy-засев **пустой** базы (первый клиент «Владелец»).
- На базе со `schema_version >= 2` эти значения игнорируются с предупреждением
  `legacy main_password ignored: schema_version>=2; create clients in the panel`.
  Старый APK и старый `deploy.sh` не могут завести нового владельца поверх
  мигрированной базы. Если версию схемы прочитать не удалось, legacy-засев
  тоже отключается (fail-closed).
- Импорт экспорта v1 создаёт владельца только при `import_clients=true`;
  при `import_clients=false` учётные данные владельца из файла не переносятся.
- Копия `csqtt.db.pre-owner-migration` снимается **один раз**, перед первой
  миграцией, и не обновляется. Откат на старый бинарник поддерживается
  **только** восстановлением базы из этой копии или снапшота: старый бинарник
  без `main_password` сгенерирует случайный пароль и потеряет владельца.
  Повторный апгрейд после отката использует всё ту же первую копию.

## Пресет RU приложений

Пресет российских приложений лежит в `rust-server/ru_apps_preset.json` и включается
тумблером «Готовый список RU приложений» у правила маршрутизации в панели. Состав списка правится только в этом JSON-файле: код, протокол и база
данных не трогаются, сервер отдаёт актуальный список в `ROUTING`.

Пресет работает только с клиентом, который понимает `version` 3 протокола `ROUTING`:
поля `preset_red`/`preset_orange` в нём новые, а старый клиент их игнорирует и
пресет не применяет.
