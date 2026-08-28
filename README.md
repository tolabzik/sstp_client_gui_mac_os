# SSTP Client GUI for macOS

Простой графический SSTP-клиент для macOS поверх [`sstp-client`](https://gitlab.com/sstp-project/sstp-client).

Проект рассчитан на пользователей, которым неудобно поднимать SSTP через Terminal вручную. Приложение проверяет зависимости, помогает установить Homebrew и `sstp-client`, хранит VPN-пароль в macOS Keychain, умеет подключать/отключать Full Tunnel и собирать расширенную сетевую диагностику для техподдержки.

## Возможности

- нативный GUI на SwiftUI;
- macOS 12+;
- Universal Binary: Apple Silicon (`arm64`) + Intel (`x86_64`);
- поля Server / Login / Password;
- пароль хранится в macOS Keychain;
- проверка сертификата или режим `--cert-warn` для self-signed сертификатов;
- выбор CA-сертификата через GUI;
- режим Full Tunnel;
- защита от потери сети: Full Tunnel включается только после проверки выхода через новый PPP-интерфейс;
- автоматический откат маршрутов при ошибке;
- корректная работа при наличии других PPP/VPN-клиентов: приложение отслеживает PPP, созданный текущей SSTP-сессией;
- кнопка `Disconnect` завершает SSTP-процесс, запущенный приложением;
- вкладка `Setup` с проверкой Homebrew, `sstpc`, `pppd` и `/etc/ppp/options`;
- кнопка `Install components`;
- расширенная вкладка `Diagnostics`;
- тест произвольного узла по DNS, route, ICMP, TCP и traceroute;
- отдельная трассировка до SSTP-сервера и до публичного узла;
- снимок сетевого пути macOS, proxy, PPP, DNS, ARP и таблицы маршрутизации;
- кнопка `Repair network` для безопасного удаления собственных маршрутов приложения.

## Как это работает

```text
GUI
  |
  +-- проверяет Homebrew / sstpc / pppd
  |
  +-- запускает sstpc от администратора
  |
  +-- ждёт новый PPP-интерфейс
  |
  +-- проверяет интернет через этот PPP
  |
  +-- при Full Tunnel добавляет:
  |      0.0.0.0/1       -> PPP
  |      128.0.0.0/1     -> PPP
  |
  +-- оставляет VPN-сервер через физический шлюз
  |
  +-- повторно проверяет маршрутизацию и доступ в интернет
         |
         +-- OK    -> статус Connected
         +-- ERROR -> автоматический rollback
```

Две сети `/1` вместе покрывают весь IPv4 и имеют больший приоритет, чем обычный default route `/0`. Обычный default route macOS не удаляется. Это позволяет безопаснее вернуть исходную сеть при отключении VPN.

## Быстрый старт для пользователя

### 1. Скачать приложение

Если у проекта опубликован готовый ZIP в Releases или Actions — скачайте его, распакуйте и перенесите `SSTP Client GUI.app` в `Applications` или на рабочий стол.

При первом запуске ad-hoc сборки macOS может потребовать:

1. ПКМ по приложению.
2. `Открыть`.
3. Ещё раз `Открыть`.

Для публичного распространения без предупреждений Gatekeeper приложение следует подписывать Apple Developer ID и notarize через Apple.

### 2. Установить компоненты

Откройте вкладку **Setup**.

Приложение проверяет:

- Homebrew;
- `sstp-client`;
- `/usr/sbin/pppd`;
- `/etc/ppp/options`.

Если чего-то не хватает, нажмите **Install components**. Откроется Terminal с установщиком. macOS может запросить пароль локального администратора.

### 3. Настроить VPN

Во вкладке **VPN** заполните:

- **Server** — IP или DNS-имя SSTP-сервера;
- **Login** — имя пользователя, включая `DOMAIN\\user`, если это требуется сервером;
- **Password** — пароль VPN.

Пароль сохраняется в **macOS Keychain**, а не в открытом конфигурационном файле.

### 4. Сертификат

Безопасный вариант — отключить **Ignore certificate verification** и выбрать CA/сертификат, которому должен доверять SSTP-клиент.

Если включена галочка **Ignore certificate verification**, клиент запускается с:

```bash
--cert-warn
```

Это позволяет подключаться к self-signed сертификатам, но снижает защиту от MITM. Для постоянной эксплуатации рекомендуется проверять сертификат.

### 5. Full Tunnel

Если включён **Full Tunnel**, весь IPv4-трафик направляется через VPN.

Перед переключением маршрутов приложение:

1. поднимает SSTP;
2. определяет новый PPP-интерфейс;
3. отправляет только тестовый IP через него;
4. проверяет TCP/443 через VPN;
5. только после успешной проверки включает Full Tunnel.

Если интернет через VPN отсутствует, приложение не переключает весь трафик и выполняет rollback. Это снижает риск потерять удалённый доступ к Mac.

## Другой VPN уже запущен

При наличии других PPP/VPN-клиентов важно не считать любой `pppX` интерфейс своим. Контроллер фиксирует состояние PPP до запуска SSTP и определяет интерфейс, появившийся после текущего подключения.

Приложение управляет своим PID и собственными маршрутами и не должно намеренно завершать чужие VPN-процессы.

## Расширенная диагностика

Вкладка **Diagnostics** предназначена для пользователя и техподдержки. В неё можно ввести произвольный узел:

```text
Host / IP: 10.30.0.200
TCP port: 443
```

Можно также нажать **Use VPN server**, чтобы использовать адрес SSTP-сервера как тестовый узел.

После нажатия **Run extended diagnostics** приложение собирает единый отчёт.

### Общая информация

- дата и время;
- версия macOS;
- архитектура CPU;
- версия Homebrew;
- версия и путь `sstpc`;
- наличие `pppd` и `/etc/ppp/options`;
- PID и исполняемый файл SSTP-процесса без вывода VPN-пароля.

### Состояние сети macOS

- `scutil --nwi`;
- proxy configuration;
- обычный default route;
- список PPP-интерфейсов;
- маршрут до `1.1.1.1`;
- таблица IPv4-маршрутизации;
- ARP cache;
- DNS configuration;
- служебное состояние приложения;
- последние строки SSTP log.

### Проверка обычного интернет-маршрута

Для `1.1.1.1` выполняются:

- `route -n get`;
- `ping`;
- TCP connect на `443`;
- `traceroute`.

### Проверка SSTP-сервера

Для настроенного VPN Server выполняются:

- DNS resolution;
- `route -n get`;
- `ping`;
- TCP connect на `443`;
- `traceroute`.

Это позволяет увидеть, не завернулся ли маршрут до самого VPN-сервера внутрь PPP-туннеля.

### Проверка произвольного узла

Для поля **Host / IP** выполняются:

- DNS resolution;
- определение маршрута и интерфейса;
- 4 ICMP echo request;
- TCP connect на указанный порт;
- traceroute до 12 hops, один probe на hop.

Например, для проверки корпоративного сервера:

```text
Host / IP: 10.30.0.200
TCP port: 443
```

В отчёте будут отдельные секции:

```text
=== TARGET DNS ===
=== TARGET ROUTE ===
=== TARGET ICMP ===
=== TARGET TCP 443 ===
=== TARGET TRACEROUTE ===
```

`*` в traceroute не обязательно означает обрыв связи: промежуточный маршрутизатор или firewall может не отвечать на traceroute/ICMP, при этом TCP до конечного узла может работать. Поэтому при разборе отчёта нужно сравнивать **route + ping + TCP + traceroute**, а не только трассировку.

### Конфиденциальность диагностического отчёта

Диагностика не выводит VPN-пароль. Для SSTP process показываются PID, пользователь, elapsed time и executable (`comm`) без аргумента `--password`.

При этом отчёт содержит IP-адреса, DNS-настройки, маршруты и внутренние имена. Перед публикацией отчёта в открытом интернете проверьте его содержимое.

Результат можно скопировать одной кнопкой и отправить администратору.

## Сборка из исходников

### Требования для сборочной машины

- macOS;
- Xcode Command Line Tools или Xcode;
- Swift compiler из Xcode toolchain.

Проверка:

```bash
xcrun --find swiftc
```

Если инструменты отсутствуют:

```bash
xcode-select --install
```

### Сборка

```bash
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

Проверить архитектуры:

```bash
lipo -archs "dist/SSTP Client GUI.app/Contents/MacOS/SSTPClientGUI"
```

Ожидается:

```text
arm64 x86_64
```

### Подпись

По умолчанию `build.sh` делает ad-hoc подпись:

```bash
codesign --sign -
```

Можно передать настоящий Developer ID:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build.sh
```

Для распространения вне собственной инфраструктуры дополнительно рекомендуется notarization.

## Установка зависимостей вручную

```bash
brew install sstp-client
sudo mkdir -p /etc/ppp
sudo touch /etc/ppp/options
```

Проверка:

```bash
brew --version
sstpc --version
ls -l /usr/sbin/pppd /etc/ppp/options
```

## Файлы проекта

```text
Sources/SSTPClientGUI.swift   SwiftUI GUI + diagnostics
Resources/vpnctl.sh          подключение, маршруты и rollback
Resources/setup.sh           установка Homebrew/sstp-client/PPP
build.sh                     Universal arm64 + x86_64 build
```

## Служебные файлы во время работы

Приложение использует временные файлы:

```text
/tmp/sstp-gui.log
/tmp/sstp-gui.pid
/tmp/sstp-gui.state
/tmp/sstp-gui.result
```

В них нет сохранённого VPN-пароля. Пароль передаётся контроллеру через временный файл с правами `0600`, удаляемый сразу после чтения.

## Безопасность

- Не добавляйте реальные VPN-пароли в исходный код.
- Не публикуйте корпоративные сертификаты без необходимости.
- `--cert-warn` следует использовать только когда вы понимаете последствия.
- Для конечных пользователей предпочтительна Developer ID подпись + notarization.
- Для Full Tunnel VPN-шлюз должен разрешать/NAT-ить клиентский интернет-трафик. Если этого нет, приложение откатит Full Tunnel.
- Диагностические отчёты могут содержать внутренние IP, DNS suffix и маршруты — не публикуйте их без проверки.

## Ограничения

- Используется системный `pppd`, доступный в поддерживаемых версиях macOS на момент разработки.
- Приложение не является Network Extension и использует `sstp-client` + PPP.
- Для установки зависимостей и управления маршрутами нужны права локального администратора.
- IPv6 намеренно не переводится в SSTP Full Tunnel этой версией.
- ICMP и traceroute могут фильтроваться сетью, поэтому отрицательный результат этих двух тестов сам по себе не доказывает недоступность узла.

## Для разработчиков

Основная логика маршрутизации находится в `Resources/vpnctl.sh`. GUI не выполняет команды `route` для управления Full Tunnel напрямую: он вызывает контроллер с правами администратора. Диагностические команды выполняются read-only от обычного пользователя.

При изменениях особенно важно проверить сценарии:

1. обычное подключение и отключение;
2. неправильный пароль;
3. недоступный сервер;
4. self-signed сертификат;
5. отсутствие выхода в интернет через VPN;
6. параллельно запущенный другой PPP VPN;
7. обрыв SSTP во время Full Tunnel;
8. повторный запуск приложения после аварийного завершения;
9. diagnostic target по IP;
10. diagnostic target по DNS;
11. target с закрытым TCP-портом;
12. traceroute с фильтрацией ICMP/UDP промежуточными узлами.

---

### English summary

A small native SwiftUI GUI for `sstp-client` on macOS. It can install dependencies, store credentials in Keychain, validate a newly created PPP interface before enabling a full IPv4 tunnel, roll back routes on failure, and collect extended support diagnostics including DNS resolution, route lookup, ping, TCP connection tests and traceroute for a user-defined target. Build script produces a Universal `arm64 + x86_64` app bundle.
