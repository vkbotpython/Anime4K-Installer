<div align="center">
    <a href="https://www.youtube.com/@avencores/" target="_blank">
      <img src="https://github.com/user-attachments/assets/338bcd74-e3c3-4700-87ab-7985058bd17e" alt="YouTube" height="40">
    </a>
    <a href="https://t.me/avencoresyt" target="_blank">
      <img src="https://github.com/user-attachments/assets/939f8beb-a49a-48cf-89b9-d610ee5c4b26" alt="Telegram" height="40">
    </a>
    <a href="https://vk.ru/avencoresreuploads" target="_blank">
      <img src="https://github.com/user-attachments/assets/dc109dda-9045-4a06-95a5-3399f0e21dc4" alt="VK" height="40">
    </a>
    <a href="https://dzen.ru/avencores" target="_blank">
      <img src="https://github.com/user-attachments/assets/bd55f5cf-963c-4eb8-9029-7b80c8c11411" alt="Dzen" height="40">
    </a>
</div>

# 🎬 mpv.net + Anime4K — установщик

Однофайловый установщик на чистом PowerShell (без внешних модулей): ставит mpv.net системно, проверяет и при необходимости добавляет .NET Desktop Runtime, а затем разворачивает GLSL-пресет Anime4K v4.0.1 в конфиг mpv.net. Интерфейс — тёмный WPF с эффектом Mica на Windows 11, поддержкой RU/EN, живым прогрессом и логами.

## ✨ Возможности

- Системная установка mpv.net через официальный setup (Inno Setup, ключи `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /ALLUSERS`).
- Актуальная версия mpv.net определяется через GitHub API; если API недоступен — закреплённая v7.1.2.0.
- Надёжное определение уже установленного mpv.net: PATH, стандартные папки, ключи реестра Uninstall.
- Установка .NET WindowsDesktop Runtime 10.0.13 x64 выполняется тихо и только если он не найден (проверка через `dotnet --list-runtimes`, папку shared framework и реестр).
- Распаковка пресетов Anime4K v4.0.1 (сборка Tama47) Low-end / High-end в `%APPDATA%\mpv.net` с перезаписью.
- Порядок и приоритет шейдеров не правятся: берутся как есть из `mpv.conf` внутри архива.
- Из архивов вычищается macOS-мусор (`__MACOSX`, `._*`, `.DS_Store`).
- Определение уже установленного пресета Anime4K (Low-end / High-end) по `mpv.conf` / `input.conf` — индикатор на шаге 2 и запись в лог перед установкой.
- Окно «О программе»: соцсети автора (YouTube, Telegram, VK, Dzen) и реквизиты для поддержки; номер карты копируется в буфер обмена одним кликом.
- Живой UI: прогресс загрузки, статусные строки, раскрывающийся лог, кнопка проверки компонентов.
- Тёмная тема, Mica/Acrylic на Windows 11, сплошной тёмный фон как fallback на Windows 10.
- Два языка (RU/EN) с переключением на лету; подробная инструкция по Anime4K — отдельным окном на текущем языке.
- Из GUI можно повысить права через UAC одним нажатием; есть полностью тихий режим для автоматизации.
- Подробный лог пишется в `%TEMP%\Anime4K-Install.log`.

## 📋 Требования

| Параметр | Значение |
|---|---|
| ОС | Windows 10 или Windows 11 (x64) |
| PowerShell | 5.1 и новее |
| Права | Администратор (установка системная) |
| Интернет | Нужен для загрузки компонентов |

## 🚀 Быстрый старт

### ⚡ Установка одной командой (PowerShell)

Откройте PowerShell и выполните одну строку:

```powershell
irm https://gitlab.com/avencores/anime4k-installer/-/raw/main/Install-Anime4K.ps1 -OutFile "$env:TEMP\Install-Anime4K.ps1"; powershell -NoProfile -ExecutionPolicy Bypass -STA -File "$env:TEMP\Install-Anime4K.ps1"
```

Команда скачивает установщик в `%TEMP%` и запускает его в STA-режиме (нужен для WPF). Если требуются права администратора, появится запрос UAC — согласитесь, и установщик перезапустится сам.

Тихий режим одной командой (запускать из консоли с правами администратора):

```powershell
irm https://gitlab.com/avencores/anime4k-installer/-/raw/main/Install-Anime4K.ps1 -OutFile "$env:TEMP\Install-Anime4K.ps1"; powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\Install-Anime4K.ps1" -Silent -Preset High
```

### 🖱 Графический режим

```powershell
powershell -ExecutionPolicy Bypass -STA -File .\Install-Anime4K.ps1
```

Выберите пресет и нажмите «Установить / Обновить всё». Если прав администратора нет, установщик предложит перезапуститься с повышением. Без флага `-STA` скрипт при необходимости сам перезапустится в STA-режиме (он нужен для WPF).

### 🤫 Тихий режим

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-Anime4K.ps1 -Silent
powershell -ExecutionPolicy Bypass -File .\Install-Anime4K.ps1 -Silent -Preset Low
```

- `-Preset` принимает `Low` или `High` (по умолчанию `High`).
- Тихий режим требует запуска от имени администратора, иначе скрипт завершится с ошибкой.
- Прогресс выводится в консоль, в конце печатается путь к папке конфига.

## 📦 Что устанавливается

| Компонент | Источник | Режим |
|---|---|---|
| mpv.net | GitHub releases, ассет `*-setup-x64.exe` (fallback — v7.1.2.0) | Системно, в Program Files. Setup прогоняется всегда: идемпотентно и гарантирует нужную версию |
| .NET WindowsDesktop Runtime 10.0.13 x64 | builds.dotnet.microsoft.com | Только если не найден; коды возврата 0 и 3010 считаются успехом |
| Anime4K GLSL v4.0.1 | github.com/Tama47/Anime4K (Low-end / High-end zip) | Всегда, с перезаписью в `%APPDATA%\mpv.net` |

## 🎚 Пресеты Anime4K

| Пресет | Для кого | Архив |
|---|---|---|
| Low-end GPU | GTX 980, GTX 1060, RX 570. Быстрые шейдеры, меньше нагрузка | `GLSL_Windows_Low-end.zip` |
| High-end GPU | GTX 1080, RTX 2070/3060, RX 590, Vega 56, 5700XT, 6600XT | `GLSL_Windows_High-end.zip` |

## ⌨️ Горячие клавиши

Mode A включается автоматически (так задано в `mpv.conf` из шаблона). Переключение вручную:

| Комбинация | Действие |
|---|---|
| Ctrl+1 | Mode A — оптимально для 1080p |
| Ctrl+2 | Mode B — оптимально для 720p |
| Ctrl+3 | Mode C — оптимально для 480p |
| Ctrl+4/5/6 | Усиленные режимы (двойной проход: A+A / B+B / C+A) |
| Ctrl+0 | Сбросить шейдеры (выключить Anime4K) |

## 🗂 Куда всё сохраняется

- Конфиги и шейдеры: `%APPDATA%\mpv.net` (`mpv.conf`, `input.conf`, `shaders\`).
- Лог установки: `%TEMP%\Anime4K-Install.log`.
- Временные загрузки кладутся в `%TEMP%` и удаляются после установки.

## 🧩 Интерфейс

- Шаг 1 — проверка компонентов: карточки mpv.net и .NET с индикаторами, кнопка повторной проверки.
- Шаг 2 — выбор пресета Anime4K (Low-end / High-end) со строкой состояния: какой пресет уже установлен (Low / High / не распознан / нет).
- Шаг 3 — установка: большая кнопка запуска, прогресс-бар, статус и раскрывающийся блок логов.
- Блок Quick Usage с горячими клавишами, кнопки «Подробная инструкция», «Открыть папку конфига» и «О программе» (соцсети и донат), переключатель языка EN/RU в шапке.

## 🛠 Решение проблем

| Проблема | Решение |
|---|---|
| Нужны права администратора | Запустите скрипт от имени администратора или согласитесь на перезапуск с UAC |
| GitHub API недоступен | Ничего делать не нужно: скрипт автоматически поставит закреплённую сборку mpv.net v7.1.2.0 |
| Нет эффекта Mica | Нужны Windows 11 и включённые эффекты прозрачности; на Windows 10 окно будет сплошным тёмным |
| Ошибка во время установки | Смотрите `%TEMP%\Anime4K-Install.log` — там каждый шаг с таймстампом и стек ошибки |
| Установщик зависает на этапе setup | У процесса есть таймаут; по истечении он будет завершён с ошибкой в логе |

## 📚 Источники

- mpv.net — [github.com/mpvnet-player/mpv.net](https://github.com/mpvnet-player/mpv.net)
- .NET — [builds.dotnet.microsoft.com](https://builds.dotnet.microsoft.com)
- Anime4K GLSL-сборка (Tama47, v4.0.1) — [github.com/Tama47/Anime4K](https://github.com/Tama47/Anime4K)
- Anime4K, документация (bloc97) — [github.com/bloc97/Anime4K](https://github.com/bloc97/Anime4K)

# 📜 Лицензия

Проект распространяется под лицензией GPL-3.0. Полный текст лицензии содержится в файле [`LICENSE`](LICENSE).

---

# 💰 Поддержать автора
+ **SBER**: `2202 2050 1464 4675`
