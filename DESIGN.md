---
version: alpha
name: CSQTT Android
description: Дизайн-система Android-клиента CSQTT (Jetpack Compose, Material 3)
colors:
  primary: "#1A73E8"
  on-primary: "#FFFFFF"
  primary-container: "#E8F0FE"
  on-primary-container: "#111215"
  secondary: "#1A73E8"
  on-secondary: "#FFFFFF"
  secondary-container: "#E8F0FE"
  on-secondary-container: "#111215"
  tertiary: "#D27D00"
  on-tertiary: "#FFFFFF"
  tertiary-container: "#FFE4B7"
  on-tertiary-container: "#241400"
  background: "#FDFDFE"
  on-background: "#111215"
  surface: "#FFFFFF"
  on-surface: "#111215"
  surface-variant: "#F2F2F4"
  on-surface-variant: "#5F6067"
  outline: "#898B92"
  outline-variant: "#D7D8DD"
  error: "#BA1A1A"
  on-error: "#FFFFFF"
  error-container: "#FFDAD6"
  on-error-container: "#410002"
  success: "#356A4C"
  on-success: "#FFFFFF"
  success-container: "#B8F2CE"
  on-success-container: "#082014"
  warning: "#7B5800"
  on-warning: "#FFFFFF"
  warning-container: "#FFDEA2"
  on-warning-container: "#271900"
  info: "#475D92"
  on-info: "#FFFFFF"
  info-container: "#D9E2FF"
  on-info-container: "#001A43"
  terminal-background: "#15171B"
  terminal-text: "#DDE1E8"
  terminal-muted: "#9DA3AE"
  terminal-error: "#FFB4AB"
  terminal-success: "#9BD4AF"
typography:
  display-large:
    fontFamily: Roboto
    fontSize: 57px
    fontWeight: 700
    lineHeight: 64px
  display-medium:
    fontFamily: Roboto
    fontSize: 45px
    fontWeight: 700
    lineHeight: 52px
  display-small:
    fontFamily: Roboto
    fontSize: 36px
    fontWeight: 700
    lineHeight: 44px
  headline-large:
    fontFamily: Roboto
    fontSize: 32px
    fontWeight: 600
    lineHeight: 40px
  headline-medium:
    fontFamily: Roboto
    fontSize: 28px
    fontWeight: 600
    lineHeight: 36px
  headline-small:
    fontFamily: Roboto
    fontSize: 24px
    fontWeight: 600
    lineHeight: 32px
  title-large:
    fontFamily: Roboto
    fontSize: 22px
    fontWeight: 600
    lineHeight: 28px
  title-medium:
    fontFamily: Roboto
    fontSize: 16px
    fontWeight: 600
    lineHeight: 24px
    letterSpacing: 0.15px
  title-small:
    fontFamily: Roboto
    fontSize: 14px
    fontWeight: 500
    lineHeight: 20px
    letterSpacing: 0.1px
  body-large:
    fontFamily: Roboto
    fontSize: 16px
    fontWeight: 400
    lineHeight: 24px
    letterSpacing: 0.5px
  body-medium:
    fontFamily: Roboto
    fontSize: 14px
    fontWeight: 400
    lineHeight: 20px
    letterSpacing: 0.25px
  body-small:
    fontFamily: Roboto
    fontSize: 12px
    fontWeight: 400
    lineHeight: 16px
    letterSpacing: 0.4px
  label-large:
    fontFamily: Roboto
    fontSize: 14px
    fontWeight: 500
    lineHeight: 20px
    letterSpacing: 0.1px
  label-medium:
    fontFamily: Roboto
    fontSize: 12px
    fontWeight: 500
    lineHeight: 16px
    letterSpacing: 0.5px
  label-small:
    fontFamily: Roboto
    fontSize: 11px
    fontWeight: 500
    lineHeight: 16px
    letterSpacing: 0.5px
rounded:
  small: 22px
  card: 34px
  dialog: 40px
  large-card: 42px
  control: 9999px
  pill: 9999px
spacing:
  none: 0px
  xxs: 4px
  xs: 8px
  sm: 12px
  md: 16px
  lg: 20px
  xl: 24px
  xxl: 32px
  xxxl: 40px
---

## Overview

Клиентское приложение Android для маскировки сетевого туннеля под медиатрафик звонков. Интерфейс выполнен на Jetpack Compose с использованием принципов Material 3, адаптированных под эргономику мобильного клиента: мягкие укрупненные радиусы скругления поверхностей, строгая информационная плотность и контрастная системная индикация сетевых состояний.

## Colors

Цветовая палитра строится на брендовом синем цвете активных элементов с контрастными вспомогательными контейнерами и специализированной палитрой консоли:

- **Primary:** основной цвет ключевых действий, переключателей и индикаторов активного туннеля.
- **Secondary:** вторичный акцент интерфейса, синхронизированный с основным для поддержания монохромной дисциплины бренда.
- **Tertiary:** предупреждающий янтарный акцент для промежуточных состояний и сервисных уведомлений.
- **Surface & Background:** базовые поверхности экрана и карточек, создающие мягкую контрастную подложку контента.
- **Terminal Palette:** специализированная группа оттенков (фон, основной текст, приглушенный текст, маркеры успеха и ошибки) для встроенного журнала событий и сетевой телеметрии.

## Themes

| Token | Light (Default) | Dark |
| --- | --- | --- |
| primary | #1A73E8 | #1565D8 |
| on-primary | #FFFFFF | #FFFFFF |
| primary-container | #E8F0FE | #173B72 |
| on-primary-container | #111215 | #FFFFFF |
| secondary | #1A73E8 | #1565D8 |
| on-secondary | #FFFFFF | #FFFFFF |
| secondary-container | #E8F0FE | #173B72 |
| on-secondary-container | #111215 | #FFFFFF |
| tertiary | #D27D00 | #FFB74D |
| on-tertiary | #FFFFFF | #271500 |
| tertiary-container | #FFE4B7 | #5A3900 |
| on-tertiary-container | #241400 | #FFE5BD |
| background | #FDFDFE | #09090A |
| on-background | #111215 | #FAFAFA |
| surface | #FFFFFF | #121214 |
| on-surface | #111215 | #FAFAFA |
| surface-variant | #F2F2F4 | #202024 |
| on-surface-variant | #5F6067 | #C9C9CF |
| outline | #898B92 | #8C8C94 |
| outline-variant | #D7D8DD | #35353A |
| error | #BA1A1A | #FFB4AB |
| on-error | #FFFFFF | #690005 |
| error-container | #FFDAD6 | #93000A |
| on-error-container | #410002 | #FFDAD6 |
| success | #356A4C | #9BD4AF |
| on-success | #FFFFFF | #06391E |
| success-container | #B8F2CE | #1D5134 |
| on-success-container | #082014 | #B7F1CD |
| warning | #7B5800 | #F2C25B |
| on-warning | #FFFFFF | #402D00 |
| warning-container | #FFDEA2 | #5C4200 |
| on-warning-container | #271900 | #FFDEA2 |
| info | #475D92 | #B2C5FF |
| on-info | #FFFFFF | #172E60 |
| info-container | #D9E2FF | #304577 |
| on-info-container | #001A43 | #D9E2FF |
| terminal-background | #15171B | #101216 |
| terminal-text | #DDE1E8 | #DDE1E8 |
| terminal-muted | #9DA3AE | #9DA3AE |
| terminal-error | #FFB4AB | #FFB4AB |
| terminal-success | #9BD4AF | #9BD4AF |

## Typography

Типографическая шкала опирается на системный шрифт платформы с каноническими ролями Material 3. Значения в спецификации приведены в px, так как схема не поддерживает единицу `sp`, а корневая тема фиксирует `fontScale = 1.0f`, гарантируя независимость верстки от системного масштаба шрифта.

- **Заголовки (`headline-small`, `title-medium`):** начертание Semi-Bold формирует четкую структуру экранов и карточек разделов.
- **Основной текст (`body-large`, `body-medium`):** стандартное начертание Regular с оптимизированным межбуквенным интервалом обеспечивает беглое чтение технических параметров.
- **Подписи и ярлыки (`label-large`, `label-medium`):** начертание Medium используется внутри компактных кнопок, переключателей и бейджей статуса.

## Layout

Пространственная организация экрана оптимизирована под мобильное использование одной рукой:

- **Ограничение ширины:** весь основной контент центрируется с максимальной шириной 720dp (`content-max-width`), исключая чрезмерное растягивание на планшетах.
- **Экранные поля:** горизонтальные поля экрана составляют 20dp (`screen-horizontal-padding`), верхнее поле — 12dp (`screen-top-padding`), нижнее поле для скролла — 32dp (`screen-bottom-padding`).
- **Интерактивные габариты:** высота основных кнопок и полей ввода составляет 52dp (`control-height`), компактных селекторов — 44dp (`compact-control-height`), минимальная область касания — 48dp (`minimum-touch-target`).

## Elevation & Depth

Иерархия глубины выражается через тональное наслоение и составные градиенты:

- **Градиентный фон (`AppBackdrop`):** динамический вертикальный трехточечный градиент между фоном и оттенками поверхностей формирует визуальную глубину без монотонности.
- **Карточки разделов (`AppSectionCard`):** контент группируется на приподнятых поверхностях с динамическим расчетом цвета заливки и тонким контуром (1dp, `outline-variant` с прозрачностью 0.24–0.32).
- **Тени:** приподнятость карточек выражается через тень 10dp с тональным подъемом 2dp в светлой теме и сдержанную тень 4dp без тонального подъема в тёмной теме.

## Shapes

Геометрия системы выражена мягкими крупными радиусами скругления. Пилюли заданы в исходном коде как `percent = 50` (скругление по половине меньшей стороны), а в спецификации токенов выражены техническим эквивалентом полного скругления и не должны читаться как буквальный радиус.

- **Карточки контента (`card`, `large-card`):** выраженное смягчение углов группирующих контейнеров и модальных листов.
- **Диалоговые окна (`dialog`):** органичное скругление модальных поверхностей.
- **Контролы и пилюли (`control`, `pill`):** полное скругление для кнопок, чипов, переключателей и полей ввода.
- **Вспомогательные элементы (`small`):** промежуточный радиус для внутренних блоков и компактных панелей.

## Components

Стилистические правила ключевых составных примитивов:

- **Экранный контейнер (`CsqttScreen`):** стандартизирует шапку приложения с логотипом и векторным бейджем версии высотой 22dp, заголовком раздела и слотом для контекстных действий.
- **Секционная карточка (`AppSectionCard`):** изолирует смысловые блоки настроек с предустановленными внутренними полями по шкале отступов.
- **Строка настроек (`CsqttSettingRow`):** полноширинная интерактивная строка с вертикальным шагом отступа, пояснительным текстом и тумблером переключения.
- **Сегментированный переключатель (`CsqttSegmentedControl`):** полноширинный переключатель взаимоисключающих опций со скруглением пилюли и индикацией активного выбора.

## Do's and Don'ts

- Do: обновляйте геометрию бейджа версии исключительно через генератор `scripts/gen_version_lockup.py` для сохранения единого оптического канона с вордмарком логотипа.
- Do: определяйте масштаб текста только через корневой провайдер темы (`fontScale = 1.0f`) для сохранения визуальной целостности интерфейса.
- Don't: не редактируйте векторные координаты в файле `app/src/main/res/drawable/ic_version.xml` вручную.
