# SSTP Client GUI — Emergency Recovery

Этот сценарий нужен, если после аварийного SSTP подключения на macOS остались фоновые PPP helper-процессы, `ppp0/ppp1/...`, split-default routes или DNS resolver, привязанный к уже мёртвому PPP.

## Что было обнаружено

`sstp-client` может запускать PPP helper, полная command line которого содержит временный файл вида:

```text
/tmp/sstp-pppd.XXXXXX
```

На macOS такой процесс не всегда находится через:

```bash
killall pppd
```

Поэтому SSTP процесс уже может завершиться, а helper продолжит держать PPP interface и DNS resolver.

Начиная с `1.3.3` приложение отслеживает PID и temp files helper-процессов своей SSTP-сессии и очищает их при Disconnect, Repair, rollback и watchdog recovery.

## Штатное восстановление

Сначала используйте кнопку:

```text
Setup -> Repair this app
```

В `1.3.3+` она дополнительно удаляет legacy orphan helpers, если живого `sstpc` уже нет.

## Emergency cleanup из установленного приложения

```bash
sudo bash "/Applications/SSTP Client GUI.app/Contents/Resources/emergency_cleanup.sh"
```

Если известен SSTP server и нужно удалить также явный host route до него:

```bash
sudo bash "/Applications/SSTP Client GUI.app/Contents/Resources/emergency_cleanup.sh" VPN_SERVER
```

## Emergency cleanup из git clone

```bash
cd ~/Desktop/sstp_client_gui_mac_os
git pull --ff-only
sudo bash Resources/emergency_cleanup.sh
```

## Что делает emergency cleanup

- завершает SSTP GUI watchdog;
- завершает `sstpc`;
- ищет процессы по полной command line с `/tmp/sstp-pppd.*`;
- сначала отправляет `TERM`, затем `KILL` зависшим процессам;
- ждёт teardown PPP;
- удаляет stale `0.0.0.0/1` и `128.0.0.0/1` на PPP interfaces, которые существовали до cleanup;
- удаляет SSTP GUI temp/state files;
- удаляет `/tmp/sstp-pppd.*`;
- при необходимости делает `ifconfig pppX down` только для PPP, существовавших до cleanup;
- выполняет `dscacheutil -flushcache`;
- отправляет `HUP` `mDNSResponder`;
- выводит состояние после cleanup.

`utun` interfaces скрипт не трогает.

> Emergency cleanup является агрессивным режимом. Он может завершить другие активные процессы `sstpc` на этом Mac. Для обычного Disconnect используется session-owned cleanup.

## Лог cleanup

```bash
cat /tmp/sstp-gui-purge.log
```

## Проверка после cleanup

```bash
printf '\n=== SSTP helpers ===\n'
pgrep -lf 'sstpc|sstp-pppd' || true

printf '\n=== PPP interfaces ===\n'
ifconfig -l | tr ' ' '\n' | grep '^ppp[0-9]' || true

printf '\n=== Split default routes ===\n'
netstat -rn -f inet | awk '$1=="0/1" || $1=="0.0.0.0/1" || $1=="128.0/1" || $1=="128.0.0.0/1" {print}'

printf '\n=== PPP DNS ===\n'
scutil --dns | grep -B2 -A4 -E '\(ppp[0-9]+\)' || true

printf '\n=== Internet ===\n'
ping -c 2 1.1.1.1
```

В нормальном состоянии после cleanup нет `sstp-pppd.*` helper процессов, нет ненужных `pppX`, нет split-default routes от SSTP и DNS снова использует физический network service.
