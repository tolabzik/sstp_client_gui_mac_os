# SSTP Client GUI for macOS

Нативный графический SSTP-клиент для macOS поверх [`sstp-client`](https://gitlab.com/sstp-project/sstp-client).

Приложение предназначено для пользователей и техподдержки, которым нужен SSTP VPN без ручного запуска `sstpc`, настройки PPP и маршрутов через Terminal.

Текущая версия: **1.2.1**.

## Основные возможности

- SwiftUI GUI для macOS;
- macOS 12+;
- Universal Binary: **Apple Silicon (`arm64`) + Intel (`x86_64`)**;
- Server / Login / Password;
- хранение VPN-пароля в macOS Keychain;
- Full Tunnel для IPv4;
- self-signed сертификаты через `--cert-warn`;
- возможность выбрать CA/server certificate;
- автоматическая проверка PPP перед включением Full Tunnel;
- rollback маршрутов при ошибке;
- определение чужих PPP/VPN-интерфейсов;
- проверка оставшихся `0/1` и `128/1` маршрутов;
- приложение не удаляет чужие VPN-маршруты автоматически;
- `Repair this app` очищает только состояние, созданное этим приложением;
- расширенная диагностика DNS / route / ping / TCP / traceroute;
- генерация собственной `.icns` иконки при сборке;
- автоматическая установка собранного приложения в `/Applications`.

---

# Быстрый старт для обычного пользователя

Если есть готовый архив `SSTP-Client-GUI-macOS.zip`, распакуйте его и перенесите:

```text
SSTP Client GUI.app
```

в:

```text
/Applications
```

При первом запуске ad-hoc сборки macOS может потребовать открыть приложение через:

1. ПКМ по приложению.
2. **Open / Открыть**.
3. Повторно подтвердить запуск.

Для публичного распространения без предупреждений Gatekeeper требуется Developer ID + notarization от Apple.

---

# Чистая сборка на Mac с нуля

Ниже сценарий для Mac, на котором исходников проекта больше нет.

## 1. Проверить Xcode Command Line Tools

```bash
xcode-select -p
```

Если инструменты не установлены:

```bash
xcode-select --install
```

После завершения установки снова открыть Terminal.

Xcode Command Line Tools дают необходимые `git`, `swiftc`, `lipo`, `codesign`, `iconutil` и SDK macOS.

## 2. Удалить старый локальный clone, если он есть

```bash
rm -rf ~/Desktop/sstp_client_gui_mac_os
```

Это удаляет только локальный clone репозитория. Установленное приложение в `/Applications` данной командой не удаляется.

## 3. Клонировать проект

```bash
cd ~/Desktop
git clone https://github.com/tolabzik/sstp_client_gui_mac_os.git
cd sstp_client_gui_mac_os
```

Репозиторий публичный, поэтому для HTTPS clone SSH-ключ GitHub не требуется.

## 4. Сделать build script исполняемым

```bash
chmod +x build.sh
```

## 5. Чисто собрать и сразу установить приложение

Рекомендуемый вариант для разработчика:

```bash
./build.sh --install
```

Команда автоматически:

1. удаляет старые `dist` и `.build`;
2. генерирует `.icns`;
3. собирает `arm64`;
4. собирает `x86_64`;
5. объединяет бинарники через `lipo`;
6. выполняет `codesign`;
7. проверяет подпись;
8. создаёт ZIP;
9. закрывает запущенную старую копию GUI;
10. удаляет старый `/Applications/SSTP Client GUI.app`;
11. копирует новую сборку в `/Applications`;
12. проверяет установленную версию и архитектуры;
13. запускает приложение.

macOS запросит пароль локального администратора при замене приложения в `/Applications`.

---

# Один блок команд для чистой пересборки

Если Command Line Tools уже установлены:

```bash
cd ~/Desktop
rm -rf sstp_client_gui_mac_os

git clone https://github.com/tolabzik/sstp_client_gui_mac_os.git
cd sstp_client_gui_mac_os
chmod +x build.sh
./build.sh --install
```

После успешной сборки приложение находится здесь:

```text
/Applications/SSTP Client GUI.app
```

Архив для передачи пользователям:

```text
~/Desktop/sstp_client_gui_mac_os/dist/SSTP-Client-GUI-macOS.zip
```

---

# Ключи `build.sh`

## Обычная сборка

```bash
./build.sh
```

Создаёт:

```text
dist/SSTP Client GUI.app
dist/SSTP-Client-GUI-macOS.zip
```

Но не изменяет `/Applications`.

## Чистая сборка + установка

```bash
./build.sh --install
```

Пересобирает приложение с нуля, заменяет копию в `/Applications` и запускает её.

## Установить уже собранную копию

```bash
./build.sh --install-only
```

Использует уже существующий:

```text
dist/SSTP Client GUI.app
```

Новая компиляция при этом не выполняется.

## Помощь

```bash
./build.sh --help
```

---

# Подпись приложения

По умолчанию используется ad-hoc подпись:

```bash
codesign --sign -
```

Для собственной Developer ID подписи можно передать identity через переменную окружения:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build.sh --install
```

`SIGN_IDENTITY` — это не VPN-пароль и не GitHub token. Это имя сертификата подписи Apple, установленного в Keychain сборочной машины.

Для внешнего распространения также рекомендуется notarization.

---

# Проверка установленной сборки

## Версия

```bash
/usr/libexec/PlistBuddy \
  -c 'Print :CFBundleShortVersionString' \
  "/Applications/SSTP Client GUI.app/Contents/Info.plist"
```

Ожидается:

```text
1.2.1
```

## Архитектуры

```bash
lipo -archs \
  "/Applications/SSTP Client GUI.app/Contents/MacOS/SSTPClientGUI"
```

Ожидается две архитектуры:

```text
x86_64 arm64
```

Порядок архитектур в выводе значения не имеет.

## Подпись

```bash
codesign --verify \
  --deep \
  --strict \
  --verbose=2 \
  "/Applications/SSTP Client GUI.app"
```

---

# Первичная настройка SSTP на пользовательском Mac

Открыть приложение и перейти во вкладку **Setup**.

GUI проверяет:

- Homebrew;
- `sstp-client`;
- `/usr/sbin/pppd`;
- `/etc/ppp/options`.

Если зависимостей нет, нажать **Install components**.

Установщик выполняет необходимые действия, включая:

```bash
brew install sstp-client
sudo mkdir -p /etc/ppp
sudo touch /etc/ppp/options
```

После установки нажать **Check again**.

---

# Настройка VPN

Во вкладке **VPN** заполнить:

```text
Server
Login
Password
```

Для доменной учётной записи:

```text
DOMAIN\username
```

Пароль сохраняется в **macOS Keychain**.

Он не должен быть прописан в исходниках проекта или README.

---

# Сертификат

Рекомендуемый вариант — использовать нормальную проверку сертификата и выбрать CA/server certificate.

Для известных self-signed SSTP-серверов можно включить:

```text
Ignore certificate verification
```

В этом режиме используется:

```text
--cert-warn
```

Это снижает защиту от MITM и должно использоваться осознанно.

---

# Full Tunnel

При Full Tunnel приложение направляет весь IPv4-трафик через PPP.

Используются маршруты:

```text
0.0.0.0/1
128.0.0.0/1
```

Вместе они покрывают весь IPv4, но не удаляют обычный default route macOS.

Перед их установкой приложение:

1. фиксирует физический маршрут до SSTP-сервера;
2. запускает `sstpc`;
3. ждёт новый PPP;
4. проверяет доступ в интернет именно через этот PPP;
5. только после успешной проверки включает Full Tunnel;
6. повторно проверяет маршрутизацию;
7. при ошибке выполняет rollback.

---

# Другие VPN и остаточные маршруты

Во вкладке **Setup** есть проверка VPN conflicts.

Приложение ищет:

- другие `pppX` интерфейсы;
- default-трафик через чужой PPP;
- оставшиеся `0/1` маршруты;
- оставшиеся `128/1` маршруты;
- Full Tunnel, который не принадлежит текущей SSTP-сессии.

Если найден конфликт, отображается **Review**.

Приложение не должно автоматически удалять маршруты другого VPN-клиента.

Кнопка:

```text
Repair this app
```

очищает только SSTP-процесс и маршруты, которыми управляет этот GUI.

---

# Расширенная диагностика

Во вкладке **Diagnostics** можно указать:

```text
Host / IP
TCP port
```

Для указанного узла выполняются:

- DNS resolution;
- `route -n get`;
- ping;
- TCP connect;
- traceroute до 12 hops.

Дополнительно отчёт содержит:

- версию macOS;
- архитектуру;
- Homebrew;
- `sstpc`;
- `pppd`;
- PPP-интерфейсы;
- VPN conflict check;
- default route;
- маршрут до SSTP-сервера;
- TCP/443 до SSTP-сервера;
- traceroute до SSTP-сервера;
- маршрут и traceroute до `1.1.1.1`;
- DNS;
- proxy;
- ARP;
- routing table;
- состояние GUI;
- последние строки SSTP log.

VPN-пароль в диагностический отчёт намеренно не выводится.

`*` в traceroute сам по себе не доказывает проблему: ICMP/UDP может фильтроваться, даже если TCP до конечного узла работает.

---

# Файлы проекта

```text
Sources/SSTPClientGUI.swift   SwiftUI GUI и диагностика
Resources/vpnctl.sh          SSTP, PPP, маршруты и rollback
Resources/setup.sh           установка зависимостей
Tools/make_icon.swift        генерация AppIcon.icns
build.sh                     Universal build + install
.github/workflows/build.yml  GitHub Actions build
```

---

# Временные файлы

Во время работы используются:

```text
/tmp/sstp-gui.log
/tmp/sstp-gui.pid
/tmp/sstp-gui.state
/tmp/sstp-gui.result
```

VPN-пароль передаётся контроллеру через временный файл с правами `0600`, после чтения файл удаляется.

---

# Безопасность

- не публикуйте реальные VPN-пароли;
- не коммитьте приватные корпоративные сертификаты;
- используйте `--cert-warn` только при необходимости;
- диагностические отчёты могут содержать внутренние IP/DNS/маршруты;
- для публичной доставки предпочтительны Developer ID + notarization;
- для Full Tunnel VPN-шлюз должен разрешать выход клиентского трафика в интернет.

---

# Обновление существующего clone

Если репозиторий уже есть локально:

```bash
cd ~/Desktop/sstp_client_gui_mac_os
git pull --ff-only
./build.sh --install
```

Этого достаточно для обычной пересборки после изменений в `main`.
