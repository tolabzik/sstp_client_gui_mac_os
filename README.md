# SSTP Client GUI for macOS

[![Latest Release](https://img.shields.io/github/v/release/tolabzik/sstp_client_gui_mac_os)](https://github.com/tolabzik/sstp_client_gui_mac_os/releases/latest)
[![Build macOS app](https://github.com/tolabzik/sstp_client_gui_mac_os/actions/workflows/build.yml/badge.svg)](https://github.com/tolabzik/sstp_client_gui_mac_os/actions/workflows/build.yml)
![macOS](https://img.shields.io/badge/macOS-12%2B-black)
![Universal](https://img.shields.io/badge/macOS-arm64%20%2B%20x86__64-blue)

Нативный GUI-клиент SSTP VPN для macOS поверх `sstp-client`.

Проект рассчитан как на обычного пользователя, так и на техподдержку: приложение устанавливает необходимые компоненты, хранит пароль в Keychain, безопасно включает Full Tunnel, отслеживает конфликты с другими VPN, собирает расширенную диагностику и умеет обновляться из GitHub Releases.

**Актуальная ветка приложения: 1.3.x.**

## Скачать готовую версию

Для обычного пользователя **ничего компилировать не нужно**.

Откройте:

https://github.com/tolabzik/sstp_client_gui_mac_os/releases/latest

Скачайте файл вида:

```text
SSTP-Client-GUI-macOS-vX.Y.Z.zip
```

Внутри находится один Universal `.app`, который работает на:

- Apple Silicon — `arm64`;
- Intel Mac — `x86_64`.

Также к релизу прикладывается `.sha256` файл для проверки архива.

---

# Возможности

## VPN

- SSTP через `sstp-client`;
- Server / Login / Password;
- поддержка `DOMAIN\username`;
- VPN password хранится в macOS Keychain;
- Full Tunnel для всего IPv4;
- self-signed certificates через `--cert-warn`;
- выбор CA/server certificate;
- сохранённые VPN-профили;
- Connect / Disconnect;
- menu bar icon для быстрого управления.

## Защита маршрутизации

Перед включением Full Tunnel приложение:

1. определяет физический default gateway;
2. фиксирует маршрут до самого SSTP-сервера через физический интерфейс;
3. запускает SSTP;
4. ждёт новый PPP-интерфейс;
5. проверяет выход в Internet именно через этот PPP;
6. только после успешной проверки включает Full Tunnel;
7. повторно проверяет маршрут и доступность Internet.

Для Full Tunnel используются:

```text
0.0.0.0/1
128.0.0.0/1
```

Вместе они покрывают весь IPv4, но обычный default route macOS не удаляется.

Если проверка не проходит, выполняется rollback.

## Watchdog

После успешного подключения запускается root watchdog.

Если `sstpc` неожиданно завершается, watchdog:

- проверяет состояние текущей SSTP-сессии;
- удаляет только split-default маршруты, относящиеся к PPP этой сессии;
- убирает собственный host route до SSTP server;
- возвращает обычную маршрутизацию;
- записывает причину в state/result и watchdog log.

Это снижает вероятность оставить Mac без Internet после аварийного обрыва VPN.

## Другие VPN

Приложение обнаруживает:

- другие `pppX` interfaces;
- default traffic через чужой PPP;
- оставшиеся `0/1` routes;
- оставшиеся `128/1` routes;
- Full Tunnel, который не относится к текущей SSTP-сессии.

Чужие VPN routes автоматически не удаляются.

Если найден конфликт, Setup показывает статус **Review**.

## Network Health

Во вкладке Setup отображается быстрый live health check:

- Homebrew / sstpc / pppd / PPP options;
- PPP state;
- route до `1.1.1.1`;
- Internet TCP test;
- DNS resolution;
- TCP/443 до SSTP server;
- VPN conflicts.

## Diagnostics

Для произвольного Host/IP и TCP port выполняются:

- DNS lookup;
- `route -n get`;
- ping;
- TCP connect;
- traceroute до 12 hops.

Дополнительно отчёт содержит:

- версию и build SSTP Client GUI;
- macOS version;
- CPU architecture;
- Homebrew;
- `sstpc`;
- `pppd`;
- PPP interfaces;
- root watchdog state;
- VPN conflict check;
- default route;
- route / ping / TCP / traceroute до SSTP server;
- route / ping / TCP / traceroute до Internet;
- proxy configuration;
- ARP;
- DNS;
- routing table;
- app state;
- SSTP log.

Отчёт можно:

- Copy;
- сохранить через **Save report…**.

VPN password в диагностический process list не выводится.

---

# Автообновление

Начиная с 1.3.x приложение умеет проверять GitHub Releases самостоятельно.

Во вкладке **About** есть:

```text
Check for updates
Install update
Open latest release
```

По умолчанию включена автоматическая проверка наличия новой версии при запуске.

Алгоритм установки обновления:

```text
GitHub Releases API
        ↓
поиск более новой SemVer версии
        ↓
скачивание ZIP + SHA-256
        ↓
проверка SHA-256
        ↓
распаковка
        ↓
codesign --verify
        ↓
проверка Bundle ID
        ↓
проверка версии
        ↓
замена /Applications/SSTP Client GUI.app
        ↓
перезапуск приложения
```

Обновление принимается только из Releases этого репозитория:

```text
https://github.com/tolabzik/sstp_client_gui_mac_os
```

Для замены приложения в `/Applications` macOS запросит пароль локального администратора.

> Текущие публичные сборки имеют ad-hoc подпись. Для полностью бесшовной публичной установки без предупреждений Gatekeeper нужен Apple Developer ID + notarization.

---

# Первый запуск

Распакуйте ZIP и перенесите:

```text
SSTP Client GUI.app
```

в:

```text
/Applications
```

При первом запуске ad-hoc build macOS может потребовать:

1. ПКМ по приложению;
2. **Open / Открыть**;
3. подтвердить запуск ещё раз.

Для доверенной внутренней сборки при необходимости quarantine можно снять вручную:

```bash
xattr -dr com.apple.quarantine "/Applications/SSTP Client GUI.app"
```

---

# Первичная настройка Mac

Откройте вкладку **Setup**.

Приложение проверит:

```text
Homebrew
sstp-client
/usr/sbin/pppd
/etc/ppp/options
```

Если компонентов нет, нажмите:

```text
Install components
```

Установщик при необходимости установит Homebrew и выполнит:

```bash
brew install sstp-client
sudo mkdir -p /etc/ppp
sudo touch /etc/ppp/options
```

После этого нажмите **Check again**.

---

# Настройка подключения

Во вкладке **VPN** заполните:

```text
Server
Login
Password
```

Доменная учётная запись:

```text
DOMAIN\username
```

## Сертификат

Рекомендуемый режим — выбрать CA/server certificate и оставить нормальную проверку сертификата.

Для известного self-signed SSTP server можно включить:

```text
Ignore certificate verification
```

В этом случае используется:

```text
--cert-warn
```

Это снижает защиту от MITM и должно использоваться осознанно.

---

# VPN Profiles

Можно сохранить несколько профилей.

В профиль сохраняются:

- profile name;
- server;
- login;
- Full Tunnel;
- certificate mode;
- certificate path.

Пароль в profile JSON не записывается. Он остаётся в macOS Keychain.

---

# Menu Bar

После запуска появляется значок SSTP Client GUI в menu bar macOS.

Через него доступны:

```text
Status
Show SSTP Client GUI
Connect / Disconnect
Repair this app
Open GitHub
```

---

# Notifications

Во вкладке **About** можно включить macOS notifications.

Уведомления используются для:

- VPN connected;
- VPN disconnected;
- VPN error;
- new application version;
- successful update.

---

# Сборка из исходников

## Требования

- macOS 12+;
- Xcode или Xcode Command Line Tools.

Проверка:

```bash
xcode-select -p
xcrun --find swiftc
```

Если CLT отсутствуют:

```bash
xcode-select --install
```

## Чистая сборка

```bash
cd ~/Desktop
rm -rf sstp_client_gui_mac_os

git clone https://github.com/tolabzik/sstp_client_gui_mac_os.git
cd sstp_client_gui_mac_os
chmod +x build.sh
./build.sh
```

Результат:

```text
dist/SSTP Client GUI.app
dist/SSTP-Client-GUI-macOS.zip
```

## Сборка + установка

```bash
./build.sh --install
```

Команда:

- очищает старые `.build` и `dist`;
- генерирует `.icns`;
- собирает arm64;
- собирает x86_64;
- объединяет их через `lipo`;
- подписывает приложение;
- проверяет `codesign`;
- создаёт ZIP;
- заменяет `/Applications/SSTP Client GUI.app`;
- проверяет установленную версию и архитектуры;
- запускает приложение.

## Только установить существующий dist

```bash
./build.sh --install-only
```

## Проверить Universal binary

```bash
lipo -archs \
  "dist/SSTP Client GUI.app/Contents/MacOS/SSTPClientGUI"
```

Должны присутствовать обе архитектуры:

```text
arm64 x86_64
```

Порядок не имеет значения.

---

# GitHub Releases

GitHub Actions выполняется на push в `main` и на pull request.

Pipeline:

```text
Checkout
  ↓
Universal build
  ↓
codesign verification
  ↓
read CFBundleShortVersionString
  ↓
versioned ZIP
  ↓
SHA-256
  ↓
Actions artifact
  ↓
GitHub Release vX.Y.Z
```

Если Release с текущим номером версии уже существует, повторный релиз не создаётся.

Чтобы выпустить новую версию, нужно увеличить:

```text
CFBundleShortVersionString
```

в `build.sh`.

Release автоматически получает название:

```text
SSTP Client GUI vX.Y.Z
```

и assets:

```text
SSTP-Client-GUI-macOS-vX.Y.Z.zip
SSTP-Client-GUI-macOS-vX.Y.Z.zip.sha256
```

---

# Developer ID

Локально можно собрать приложение с реальным Developer ID:

```bash
SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" ./build.sh
```

Для публичного распространения также требуется notarization.

Без Developer ID используется ad-hoc signature:

```text
-
```

---

# Файлы проекта

```text
Sources/SSTPClientGUI.swift   основная VPN логика и SwiftUI UI
Sources/AppSupport.swift      updates, profiles, health, menu bar, notifications
Resources/vpnctl.sh           SSTP, PPP, routes, rollback и root watchdog
Resources/setup.sh            установка зависимостей
Tools/make_icon.swift         генерация AppIcon.icns
build.sh                      Universal build + local install
.github/workflows/build.yml  CI + GitHub Releases
CHANGELOG.md                  история версий
```

---

# Служебные файлы

Во время работы используются:

```text
/tmp/sstp-gui.log
/tmp/sstp-gui.pid
/tmp/sstp-gui.state
/tmp/sstp-gui.result
/tmp/sstp-gui-watchdog.pid
/tmp/sstp-gui-watchdog.log
```

Временный password handoff имеет права `0600` и удаляется контроллером сразу после чтения.

---

# Безопасность

- не добавляйте VPN passwords в repository;
- не публикуйте приватные corporate certificates;
- VPN password хранится в Keychain;
- `--cert-warn` используйте только для известного SSTP server;
- self-update проверяет SHA-256, `codesign`, Bundle ID и version;
- auto-update принимает assets только из официального GitHub repository;
- приложение не удаляет routes другого VPN автоматически;
- diagnostic report может содержать internal IP, DNS suffix и routing information.

Проект использует upstream `sstp-client`. При передаче password через `--password` upstream клиент предпринимает меры для сокрытия credentials из process arguments после запуска, однако для чувствительных окружений всё равно рекомендуется дополнительно оценить требования вашей модели угроз.

---

# Troubleshooting

Если VPN не работает:

1. Setup → **Check again**;
2. Setup → **Check VPN leftovers**;
3. убедитесь, что другой Full Tunnel VPN выключен;
4. Diagnostics → укажите Host/IP и port;
5. **Run extended diagnostics**;
6. **Save report…** или **Copy**;
7. приложите отчёт к обращению в поддержку.

Если приложение считает, что от него остались routes:

```text
Repair this app
```

Функция предназначена только для состояния, созданного SSTP Client GUI.

---

# Changelog

См. [CHANGELOG.md](CHANGELOG.md).
