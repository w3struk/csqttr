---
version: alpha
name: reCSQTT Android
description: Дизайн-система Android-клиента reCSQTT (Jetpack Compose, Material 3)
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

Android-клиент маскирует сетевой туннель под медиатрафик звонков. Интерфейс собран на Jetpack Compose по Material 3, с поправкой на мобильный клиент: крупные радиусы скругления, плотная раскладка и контрастная индикация сетевых состояний.

## Colors

Цветовая палитра строится на брендовом синем для активных элементов; вспомогательные контейнеры контрастные, у консоли отдельная палитра:

- **Primary:** основной цвет ключевых действий, переключателей и индикаторов активного туннеля.
- **Secondary:** вторичный акцент; совпадает с основным, чтобы бренд оставался монохромным.
- **Tertiary:** предупреждающий янтарный акцент для промежуточных состояний и сервисных уведомлений.
- **Surface & Background:** поверхности экрана и карточек; контрастная подложка контента.
- **Terminal Palette:** отдельные оттенки (фон, основной текст, приглушенный текст, маркеры успеха и ошибки) для встроенного журнала событий и сетевой телеметрии.

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

Шкала использует системный шрифт платформы и канонические роли Material 3. Значения в спецификации заданы в px: схема не поддерживает единицу `sp`, а корневая тема фиксирует `fontScale = 1.0f`, поэтому верстка не зависит от системного масштаба шрифта.

- **Заголовки (`headline-small`, `title-medium`):** Semi-Bold задаёт структуру экранов и карточек разделов.
- **Основной текст (`body-large`, `body-medium`):** Regular, межбуквенный интервал 0.25–0.5px; используется для технических параметров.
- **Подписи и ярлыки (`label-large`, `label-medium`):** Medium для компактных кнопок, переключателей и бейджей статуса.

## Layout

Пространство экрана рассчитано на работу одной рукой:

- **Ограничение ширины:** весь основной контент центрируется с максимальной шириной 720dp (`content-max-width`), исключая чрезмерное растягивание на планшетах.
- **Экранные поля:** горизонтальные поля экрана составляют 20dp (`screen-horizontal-padding`), верхнее поле — 12dp (`screen-top-padding`), нижнее поле для скролла — 32dp (`screen-bottom-padding`).
- **Интерактивные габариты:** высота основных кнопок и полей ввода составляет 52dp (`control-height`), компактных селекторов — 44dp (`compact-control-height`), минимальная область касания — 48dp (`minimum-touch-target`).

## Elevation & Depth

Глубину задают тональные слои и составные градиенты:

- **Градиентный фон (`AppBackdrop`):** вертикальный градиент из трёх точек между фоном и оттенками поверхностей.
- **Карточки разделов (`AppSectionCard`):** приподнятые поверхности; цвет заливки считается от темы, контур 1dp из `outline-variant` с прозрачностью 0.24–0.32.
- **Тени:** в светлой теме 10dp и тональный подъем 2dp, в тёмной — 4dp без подъема.

## Shapes

Геометрия — мягкие крупные радиусы. Пилюли в коде заданы как `percent = 50` (скругление по половине меньшей стороны); в токенах спецификации это технический эквивалент полного скругления, а не буквальный радиус.

- **Карточки контента (`card`, `large-card`):** смягчённые углы группирующих контейнеров и модальных листов.
- **Диалоговые окна (`dialog`):** скругление модальных поверхностей.
- **Контролы и пилюли (`control`, `pill`):** полное скругление для кнопок, чипов, переключателей и полей ввода.
- **Вспомогательные элементы (`small`):** промежуточный радиус для внутренних блоков и компактных панелей.

## Components

Правила для ключевых примитивов:

- **Экранный контейнер (`CsqttScreen`):** шапка с логотипом, векторным бейджем версии высотой 22dp, заголовком раздела и слотом для контекстных действий.
- **Секционная карточка (`AppSectionCard`):** группирует блоки настроек; внутренние поля заданы шкалой отступов.
- **Строка настроек (`CsqttSettingRow`):** полноширинная интерактивная строка с шагом отступа, пояснительным текстом и тумблером переключения.
- **Сегментированный переключатель (`CsqttSegmentedControl`):** полноширинный переключатель взаимоисключающих опций; скругление пилюли, активный выбор подсвечен.

## Do's and Don'ts

- Do: задавайте масштаб текста только через корневой провайдер темы (`fontScale = 1.0f`), как в этой спецификации.
