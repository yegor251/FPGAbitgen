# FPGAbitgen

**FPGAbitgen** — CLI-инструмент, который превращает VHDL-дизайн в битстрим для
плат на Xilinx 7-series одной командой. Полностью нативный open-source поток
без Vivado и лицензий:

```
VHDL ──GHDL+Yosys──▶ нетлист ──nextpnr──▶ FASM ──fpga-as──▶ .bit
```

Позиционируется как удобный аналог генерации битстрима в Vivado: выбрали
плату (или указали чип) — получили `.bit`, при желании — сразу прошили плату
через openFPGALoader. Никаких графических IDE, только команда в терминале.

Поддержка: **macOS Apple Silicon** (проверено end-to-end: сборка, P&R,
битстрим, прошивка). **Linux x86_64 — в планах**: компоненты потока
официально поддерживают Linux, но упаковка relocatable-бандла пока
реализована только macOS-инструментами (otool); нужна patchelf-версия
бандлера. Платы Xilinx 7-series (Artix/Kintex/Spartan/Zynq —
см. [Поддерживаемые чипы](#поддерживаемые-чипы)).

---

## Установка

### Способ 1 — из GitHub Releases

Скачайте архив под вашу платформу со страницы
[Releases](https://github.com/yegor251/FPGAbitgen/releases) и выполните:

```bash
./install.sh fpgabitgen-<версия>-darwin-arm64.tar.xz
```

`install.sh` принимает и прямую ссылку:

```bash
./install.sh https://github.com/yegor251/FPGAbitgen/releases/download/v1.0/fpgabitgen-1.0-darwin-arm64.tar.xz
```

Скрипт распакует тулчейн в `~/.local/share/fpgabitgen`, создаст симлинк
`~/.local/bin/bitgen` и снимет карантинную метку macOS (Gatekeeper).
Проверьте, что `~/.local/bin` есть в `PATH` (скрипт подскажет, если нет):

```bash
export PATH="$HOME/.local/bin:$PATH"   # добавить в ~/.zshrc
bitgen --version
```

**Удаление:**

```bash
rm -rf ~/.local/share/fpgabitgen ~/.local/bin/bitgen
```

### Способ 2 — из локального архива

```bash
./install.sh ~/Downloads/fpgabitgen-2026.11.26-darwin-arm64.tar.xz
```

### Каталоги установки можно переопределить

```bash
BITGEN_HOME=~/tools/fpgabitgen BITGEN_BIN=~/bin ./install.sh <архив>
```

Требование к системе: `python3 ≥ 3.8` (на macOS есть с Command Line Tools,
на Linux — в любом дистрибутиве). Всё остальное уже внутри архива.

---

## Использование

### Базовые примеры

```bash
# сборка для платы по умолчанию (basys3): design.bit рядом с дизайном
bitgen board_top.vhd

# указать имя результата
bitgen board_top.vhd -o task4.bit

# другая плата из реестра + сразу прошить плату по USB
bitgen --board arty blinky.vhd --flash

# произвольный чип и свой констрейн-файл (Vivado-диалект XDC)
bitgen --part xc7a100tcsg324-1 --xdc my_board.xdc top.vhd -o top.bit

# дизайн, где top-модуль называется не board_top
bitgen --top my_top_entity design.vhd

# посмотреть, какие платы известны
bitgen --boards
```

### Все флаги

| Флаг | Описание |
|---|---|
| `design` | VHDL-файл дизайна (позиционный аргумент) |
| `-o, --output FILE` | путь к итоговому `.bit` (по умолчанию `<design>.bit` рядом с дизайном) |
| `--board NAME` | плата из реестра `share/boards.json` — задаёт part, xdc и имя для прошивки |
| `--part CHIP` | полный номер чипа, например `xc7a35tcsg324-1` (перекрывает `--board`) |
| `--xdc FILE` | констрейн-файл пинов (по умолчанию — вшитый XDC выбранной платы) |
| `--loader NAME` | имя платы для `openFPGALoader` при `--flash` |
| `--top NAME` | имя top-модуля (по умолчанию `board_top`) |
| `--workdir DIR` | папка для промежуточных файлов (по умолчанию — временная) |
| `--keep` | не удалять промежуточные файлы (нетлист, fasm — полезно для отладки) |
| `--flash` | после сборки прошить плату через openFPGALoader |
| `-q, --quiet` | печатать только шаги и итог, без потока логов |
| `--boards` | показать список плат и выйти |
| `--version` | версия |

### Флаги сборки из исходников (`build.sh`)

| Флаг | Описание |
|---|---|
| `--prefix DIR` | куда установить (по умолчанию `./prefix`) |
| `--suite DIR` | где лежит OSS CAD Suite (по умолчанию `~/fpga/oss-cad-suite`, env `BITGEN_SUITE`) |
| `--dies "…"` | какие кристаллы собирать (по умолчанию `xc7a50t`, env `BITGEN_DIES`) |
| `--parts "…"` | для каких частей создать chipdb-алиасы (env `BITGEN_PARTS`) |
| `--jobs N` | параллельность сборки |
| `--clean` | полная пересборка с нуля |

---

## Платы

### Реестр (`--board`)

| Плата | Чип | Констрейн | openFPGALoader |
|---|---|---|---|
| `basys3` | xc7a35tcpg236-1 | boards/basys3.xdc | `basys3` |
| `arty` | xc7a35tcsg324-1 | boards/arty.xdc | `arty` |

```bash
bitgen --boards                        # актуальный список
bitgen --board basys3 top.vhd --flash  # сборка + прошивка
```

### Добавить свою плату — три шага

1. `share/boards/<имя>.xdc` — констрейн-файл платы (Vivado-диалект:
   `set_property -dict { PACKAGE_PIN … IOSTANDARD LVCMOS33 } [get_ports …]`);
2. строка в `share/boards.json`:

   ```json
   "myboard": {"part": "xc7a35tftg256-1", "xdc": "myboard.xdc", "loader": "myboard"}
   ```

3. если чип на другом кристалле — добавить die в `build.sh` (см. ниже), и
   пересобрать.

Констрейн можно взять из готового Vivado-проекта платы — XDC читается как есть
(строки `get_drc_checks` игнорируются автоматически).

### Поддерживаемые чипы

Чип задаётся как в Vivado — целиком: `<device><package>-<speed>`, например
`xc7a35tcpg236-1`. Внутри он сводится к кристаллу (die), для которого
генерируется база:

| Чип (примеры) | Кристалл (die) базы | Статус |
|---|---|---|
| xc7a35t*, xc7a50t* | xc7a50t | ✅ в комплекте |
| xc7a100t*, xc7a200t* | xc7a100t / xc7a200t | сборка: `--dies "xc7a100t xc7a200t"` |
| xc7k70t*, xc7k160t*, xc7k325t* | xc7k70t и т.д. | сборка: `--dies "xc7k70t …"` |
| xc7z010*, xc7z020* (Zynq) | xc7z010 | сборка: `--dies "xc7z010"` |

Алиасы кристаллов применяются автоматически: `xc7a35t` — это тот же
кремний, что `xc7a50t` (с урезанными ресурсами), `xc7z007s` → `xc7z010`.

**Speed grade `-1L`:** базы prjxray не содержит `-1L`-частей, используется
база `-1`. Кадры идентичны; openFPGALoader может предупредить о
несовпадении IDCODE — это безвредно.

---

## Как это работает

1. **GHDL + Yosys** — анализ и синтез: `ghdl`-плагин читает VHDL,
   `synth_xilinx -arch xc7` раскладывает дизайн в примитивы Artix-7 (LUT,
   FF, CARRY, IOB);
2. **nextpnr** — размещение и трассировка по базе prjxray (chipdb);
3. **fpga-as** — сборка кадров конфигурации в `.bit` (заменяет пару
   `fasm2frames + xc7frames2bit`, в разы быстрее).

Результат — стандартный битстрим Xilinx: прошивается и Vivado Hardware
Manager, и openFPGALoader. Размер ~2 МБ (несжатые кадры; Vivado сжимает до
~200 КБ — содержательно файлы эквивалентны, сжатие аппаратно распаковывается
чипом при загрузке).

---

## Сборка из исходников

```bash
git clone https://github.com/yegor251/FPGAbitgen.git
cd FPGAbitgen
./build.sh
./package.sh            # dist/fpgabitgen-<ver>-<os>-<arch>.tar.xz + SHA256SUMS
```

Что происходит:

- **ghdl + yosys** — берутся готовыми из [OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build)
  (`--suite`, по умолчанию `~/fpga/oss-cad-suite`) и упаковываются в
  перемещаемый бандл (dylib-замыкание через otool);
- **nextpnr** — собирается из [openXC7/nextpnr](https://github.com/openXC7/nextpnr)
  (пин `8ad136c`) с xilinx-microarchitecture;
- **fpga-as** — собирается из [lromor/fpga-assembler](https://github.com/lromor/fpga-assembler)
  (пин `4939337a`, bazel 9.1.1 скачивается автоматически);
- **chipdb** — генерируется из [openXC7/prjxray-db](https://github.com/openXC7/prjxray-db)
  (пин `0c3504f2`) скриптом `xilinx_gen.py`, компилируется `bbasm`.

Время полной сборки: ~10–15 минут. Зависимости Homebrew ставятся
автоматически при первом запуске.

GHDL сознательно не собирается из исходников (требует Ada-компилятор GNAT) —
берётся из OSS CAD Suite. Поэтому для сборки проекта нужна установленная
сюита, а готовый архив — нет (всё уже внутри).

---

## Устранение неполадок

**`command not found: bitgen`**
`~/.local/bin` не в PATH: `export PATH="$HOME/.local/bin:$PATH"` — добавьте
в `~/.zshrc` или `~/.bashrc`.

**`python: нужная версия не найдена` / старый python**
Нужен python ≥ 3.8. На macOS: `xcode-select --install` даёт
`/usr/bin/python3`; либо `brew install python`.

**`chipdb для … не найдена`**
Чип относится к кристаллу, базы которого нет в бандле. Соберите с нужным
die: `./build.sh --dies "xc7a100t"` — и переустановите архив.

**`part … отсутствует в prjxray-db`**
Проверьте написание чипа. Для `-1L`-скоростей используйте соответствующую
`-1`-часть — инструмент делает это автоматически с предупреждением.

**macOS блокирует запуск («не удалось проверить разработчика»)**
`install.sh` снимает карантин автоматически. Если делали ручную распаковку:
`xattr -dr com.apple.quarantine ~/.local/share/fpgabitgen`.

**`openFPGALoader: permission denied`**
Запустите с `sudo` — это доступ к USB-устройству, а не ошибка.

**`openFPGALoader: board not found / unable to open ftdi device`**
Проверьте USB-кабель (нужен порт JTAG), что плата определяется:
`system_profiler SPUSBDataType | grep -i ft`. Кабель должен быть
data-кабелем, не зарядным.

**Ошибки nextpnr про порты (`port … not found`, unconstrained IO)**
Имена портов в XDC не совпадают с портами дизайна. Сверьте `get_ports` в
XDC с `port (...)` в VHDL/Verilog.

**Битстрим собрался, но плата не работает**
Убедитесь, что XDC соответствует вашей плате (пины Basys3 и Arty — разные),
и что top-модуль правильный (`--top`). Проверьте сборку эталонным blinky из
[openXC7 demo-projects](https://github.com/openXC7/demo-projects).

**Сборка из исходников падает на cmake/bazel**
Нужны brew-пакеты: `cmake boost eigen llvm libomp zstd` (ставятся
автоматически). Bazel 9.1.1 скачивается сам с проверкой контрольной суммы.

---

## Вопросы дизайна

**Чем это лучше «просто поставить Vivado»?**
Ни лицензий, ни 60 ГБ установки, ни аккаунта AMD — архив 44 МБ, установка
одной командой, работает на любой машине с python3. Для учебных и хобби
проектов на Dev-платах этого достаточно.

**Ограничения.** Нет тайминг-замыкания сложных дизайнов (для учебных
проектов запас огромный), нет симуляции (используйте GHDL напрямую),
не поддержаны серии старше/младше 7-series и PCIe-трансиверы.

---

## Лицензии компонентов

Проект — обёртка и сборочные скрипты. Внутри распространяются:

- Yosys — ISC; nextpnr — BSD-подобная; prjxray-db — CC0/ISC;
  fpga-as — Apache-2.0;
- **GHDL — GPL-2.0**: при публичном распространении архивов репозиторий
  обязан предоставлять исходники GHDL (ссылка на апстрим + пин версии
  удовлетворяет требованию offer of source).

Для личного и учебного использования — без оговорок.
