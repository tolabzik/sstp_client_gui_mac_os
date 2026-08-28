# Changelog

Все заметные изменения SSTP Client GUI фиксируются здесь.

## 1.3.2 — 2026-08-28

### Safety

- `Disconnect`, `Repair this app` и root watchdog удаляют split-default маршруты только если `0/1` и `128/1` действительно принадлежат PPP-интерфейсу текущей SSTP-сессии;
- перед удалением host route до SSTP server проверяются сохранённые physical gateway и physical interface;
- PID перед завершением дополнительно проверяется как процесс `sstpc`;
- ownership state сохраняется сразу после создания host route и дополняется точным PPP после его появления;
- rollback при ошибке подключения больше не должен затрагивать маршруты параллельно работающего VPN-клиента.

### Changed

- служебная очистка test routes также привязана к PPP текущей SSTP-сессии;
- watchdog использует те же ownership checks, что и штатное отключение.

## 1.3.1 — 2026-08-28

### Added

- автоматическая проверка новых версий через GitHub Releases;
- установка обновления прямо из приложения с запросом прав администратора;
- проверка SHA-256 перед установкой обновления;
- проверка bundle identifier, версии и `codesign` обновляемого `.app`;
- автоматический перезапуск приложения после обновления;
- вкладка **About** с версией, build number, архитектурой и ссылками на GitHub;
- кнопки **Check for updates**, **Install update**, **Open latest release**, **Report a problem**;
- опциональные macOS notifications;
- сохранённые VPN-профили;
- пароли профилей остаются в macOS Keychain;
- live **Network health**: components, PPP, route, Internet TCP, DNS, SSTP server и VPN conflicts;
- menu bar icon с Connect / Disconnect / Repair / Open GitHub;
- **Save report…** для сохранения диагностики в текстовый файл;
- версия приложения и build number в диагностическом отчёте;
- диагностика root watchdog;
- root watchdog, который восстанавливает Full Tunnel маршруты при неожиданном завершении `sstpc`.

### Changed

- интерфейс расширен до четырёх вкладок: VPN, Setup, Diagnostics, About;
- версия приложения постоянно видна в GUI;
- диагностика стала более удобной для техподдержки;
- сборка компилирует все Swift sources проекта;
- исправлен deprecated API выбора сертификатов через `UTType`;
- release pipeline автоматически создаёт versioned ZIP и SHA-256.

### Safety

- приложение не удаляет маршруты, определённые как принадлежащие другому VPN;
- watchdog удаляет split-default маршруты только когда они связаны с PPP текущей SSTP-сессии;
- VPN password не выводится в диагностическом process list;
- self-update принимает assets только из официального GitHub repository проекта.

## 1.2.2 — 2026-08-28

- исправлена локальная генерация AppIcon на Mac с Command Line Tools;
- генератор иконки теперь компилируется через `swiftc` с AppKit вместо Swift JIT;
- при ошибке сборки удаляется недособранный `.app`;
- добавлена автоматическая публикация GitHub Releases.

## 1.2.1 — 2026-08-28

- добавлен `./build.sh --install`;
- чистая Universal сборка может автоматически заменить приложение в `/Applications`;
- добавлены проверки установленной версии, подписи и архитектур.

## 1.2.0 — 2026-08-28

- новый SwiftUI UI;
- собственная AppIcon;
- обнаружение других PPP/VPN и split-default leftovers;
- расширенная диагностика DNS / route / TCP / ping / traceroute.

## 1.1.0

- расширенная диагностика произвольного узла;
- traceroute до target, VPN server и Internet;
- безопасный вывод SSTP process без VPN password.

## 1.0.0

- базовый SwiftUI SSTP client;
- Homebrew / sstp-client setup;
- macOS Keychain;
- Full Tunnel через `0.0.0.0/1` и `128.0.0.0/1`;
- rollback маршрутов;
- Universal arm64 + x86_64 build.
