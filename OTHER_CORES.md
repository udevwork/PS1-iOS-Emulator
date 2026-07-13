# Добавление других эмуляторов (libretro-ядер)

> Заметка на будущее. Сейчас **не делаем**, просто зафиксировали идею и план.

## Ключевой факт

`ps1/Emulator/EmulatorCore.swift` — это уже **обобщённый libretro-фронтенд**, а не что-то
специфичное для PS1. Мы дёргаем стандартный libretro API:

- `retro_init` / `retro_load_game` / `retro_run` / `retro_get_system_av_info`
- колбэки: video refresh, audio sample batch, input poll/state
- core options через `GET_VARIABLE`
- disk control (`retro_disk_control_ext_callback`)

Этот API **одинаков для всех libretro-ядер**. PCSX-ReARMed — просто одно из сотен ядер
(`Vendor/pcsx_rearmed/lib/libpcsx_rearmed_iphoneos.a`). Поэтому добавить новую систему —
это в основном **задача сборки нового ядра**, а не переписывание фронтенда.

## Главная загвоздка: символы

Сейчас ядро **статически слинковано**, Swift зовёт глобальные символы `retro_*` напрямую.
Два статических ядра в один бинарь не положить — они экспортируют одинаковые имена
(`retro_run`, `retro_init`, …) → коллизия.

**Решение (как в самом RetroArch):**
1. Собрать каждое ядро как **динамический framework** (`.dylib`/`.framework`).
2. `dlopen` его, разложить `retro_*` через `dlsym` в структуру указателей (`retro_core_t`).
3. `EmulatorCore` зовёт не глобальные символы, а поля этой структуры.

Легально для App Store: динамические фреймворки едут **внутри бандла** приложения, никакой
загрузки исполняемого кода из сети. Рефакторинг разовый; дальше ядра добавляются легко.

## Реальное ограничение iOS — JIT, не BIOS

- **Интерпретаторные ядра (8/16-бит)** идут на полной скорости, без BIOS и без JIT.
- **Тяжёлые 3D-системы** (N64, PSP, PS2, Dreamcast) без рекомпилятора медленные, а JIT на
  стоковом iOS недоступен без спец-entitlement/джейлбрейка. Их не берём.

## Кандидаты без BIOS

| Система | libretro-ядро | BIOS | Заметка |
|---|---|---|---|
| Game Boy / Color | Gambatte, SameBoy | не нужен | boot ROM опционален |
| **GBA** | **mGBA** | не нужен | встроенный HLE-BIOS; покрывает GB/GBC/GBA одним ядром |
| NES | FCEUmm / Nestopia / Mesen | не нужен | |
| SNES | Snes9x | не нужен | интерпретатор, лёгкий |
| Genesis / Master System / Game Gear | Genesis Plus GX | не нужен | Sega CD — уже с BIOS |
| PC Engine (HuCard) | Beetle PCE Fast | не нужен | CD-версия — с BIOS |
| Atari 2600 | Stella | не нужен | |
| WonderSwan / Neo Geo Pocket / Virtual Boy | Beetle-ядра | не нужен | |

## Рекомендация для первого шага

**mGBA** — одно ядро закрывает GB + GBC + GBA, чистый интерпретатор, крохотное, без BIOS,
идеально для мобилки. Хороший кандидат №1, чтобы заодно обкатать переход на dlopen-модель
с несколькими ядрами.

## Набросок плана (когда решим делать)

1. Рефакторинг `EmulatorCore`: вынести вызовы `retro_*` в структуру `retro_core_t`
   (указатели на функции), пока по-прежнему указывающую на статический PCSX-ReARMed.
2. Перевести загрузку ядра на `dlopen` + `dlsym`; PCSX-ReARMed пересобрать как dylib.
3. Собрать mGBA под iOS-arm64 как второй dylib, положить в бандл.
4. UI: выбор системы/ядра по расширению ROM (`.gb/.gbc/.gba` → mGBA, `.bin/.cue/.chd` → PCSX).
5. Проверить, что путь PS1 не сломался.
