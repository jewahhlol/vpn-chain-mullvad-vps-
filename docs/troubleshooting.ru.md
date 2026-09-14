# Решение проблем

## Цепочка не запускается

### wireproxy-awg не стартует
```bash
# Проверить что конфиг существует и читается
sudo cat /etc/wireproxy-awg.conf

# Запустить на переднем плане чтобы увидеть ошибки
sudo pkill -f wireproxy-awg
sudo /usr/local/bin/wireproxy-awg -c /etc/wireproxy-awg.conf
```

### wireproxy-awg: "Handshake did not complete"

**Причина**: Клиент не может установить AmneziaWG туннель с VPS.

Чеклист:
1. VPS доступен: `ping IP_VPS`
2. AWG сервер запущен на VPS: `ssh root@VPS "awg show"`
3. Порт 5000 открыт: `ssh root@VPS "ss -ulnp | grep 5000"`
4. Ключи совпадают: PublicKey в клиентском [Peer] = публичный ключ сервера
5. Публичный ключ клиента есть в серверном [Peer] AllowedIPs
6. Параметры обфускации (Jc, Jmin, Jmax, S1-S4, H1-H4, I1) одинаковые на обеих сторонах
7. В forward mode: Mullvad подключён (`mullvad status`)

**Вывести публичный ключ клиента из приватного:**
```bash
grep PrivateKey /etc/wireproxy-awg.conf | awk '{print $3}' | wg pubkey
```
Должен совпадать с тем что в серверном `[Peer] PublicKey`.

### Mullvad не подключается (висит на "Connecting")

**Причина 1: Устройство отозвано.** Mullvad разрешает максимум 5 устройств на аккаунт. Если твоё выкинули — будет бесконечно пытаться подключиться без внятной ошибки.

Проверить:
```bash
mullvad account get
```
Если пишет "The current device has been revoked" — перелогинься:
```bash
mullvad account login НОМЕР_АККАУНТА
```

**Причина 2: Неправильный режим обфускации.** В России и странах с DPI голый WireGuard заблокирован. Mullvad может показать "Connected" но трафик не пройдёт.

Решение — включить QUIC обфускацию:
```bash
# Mullvad 2026+:
mullvad anti-censorship set mode quic

# Старые версии:
mullvad obfuscation set mode default
```
Потом переподключиться:
```bash
mullvad disconnect && mullvad connect
```

**Причина 3: VirtualBox Bridged WiFi.** Некоторые WiFi адаптеры плохо работают с Bridged Adapter. Попробуй:
- Другие серверы Mullvad (`mullvad relay set location de`)
- Проводное (Ethernet) подключение вместо WiFi
- Другие режимы обфускации

> **Для России / сетей с цензурой**: Forward mode требует подключения Mullvad из VM. Если провайдер блокирует WireGuard, **обязательно** используй QUIC обфускацию. Если даже QUIC не работает — используй reverse mode, ему нужен только AmneziaWG до VPS (устойчив к DPI по дизайну).

### Forward mode: Mullvad "Connected" но интернета нет

**Причина**: Mullvad показывает Connected, но трафик молча дропается DPI (типично для России с голым WireGuard).

Симптомы:
- `curl ifconfig.me` висит или возвращает пустоту
- `ping 8.8.8.8` — "Destination Port Unreachable" или 100% потерь
- `mullvad status` показывает "Connected"

Решение:
```bash
mullvad anti-censorship set mode quic
mullvad reconnect
```

Если QUIC тоже не работает — используй reverse mode. Он обходит проблему полностью, потому что внешний туннель — AmneziaWG (не Mullvad).

### AmneziaWG "Configuration parsing error" на VPS

**Причина**: Параметры H1-H4 в `awg0.conf` имеют неправильный формат. Должны быть целые числа, не строки с дефисами.

Неправильно: `H1 = 123-456`
Правильно: `H1 = 123456`

Если видишь это после `install.sh` — в установщике баг. Обнови репо и запусти заново.

## Неправильный exit IP

### Показывает IP Mullvad вместо IP VPS (forward mode)
redsocks/iptables не активны. Проверь:
```bash
sudo vpn-chain status
sudo iptables -t nat -L REDSOCKS
```

### Показывает реальный/домашний IP
Цепочка вообще не запущена:
```bash
sudo vpn-chain start  # или: start reverse
```

### Показывает IPv6 адрес
IPv6 утекает. Решение:
```bash
sudo ip6tables -P OUTPUT DROP
sudo ip6tables -A OUTPUT -o lo -j ACCEPT
```
Делается автоматически при `vpn-chain start`.

## Потерян SSH к VPS

### После установки приложения Mullvad на VPS
Kill switch Mullvad (nftables) блокирует SSH. Никогда не ставь приложение Mullvad на VPS.

**Решение**: зайди через веб-консоль провайдера (VNC/KVM), потом:
```bash
mullvad disconnect
mullvad auto-connect set off
apt remove -y mullvad-vpn
iptables -F
iptables -P INPUT ACCEPT
iptables -P OUTPUT ACCEPT
nft flush ruleset 2>/dev/null
```

Если и через консоль не зайти — переустанови ОС через панель провайдера.

### После включения Mullvad WG (plain WireGuard) на VPS
Не должно случаться с `Table = 42`. Если случилось:
```bash
# Через консоль провайдера:
wg-quick down mullvad
ip rule del from 10.9.9.0/24 table 42
ip route flush table 42
```

## Утечки DNS

Проверить DNS сервер:
```bash
nslookup example.com
```

Должен показать `127.0.0.53` (dnscrypt-proxy), не DNS провайдера.

Если DNS утекает:
```bash
# Проверить resolv.conf — должен указывать на dnscrypt-proxy
cat /etc/resolv.conf
# Должно быть: nameserver 127.0.0.53

# Если неправильно — исправить и заблокировать:
sudo chattr -i /etc/resolv.conf
echo "nameserver 127.0.0.53" | sudo tee /etc/resolv.conf
sudo chattr +i /etc/resolv.conf

# Проверить что dnscrypt-proxy работает
systemctl status dnscrypt-proxy
```

## Реальный IP утекает в Google (QUIC/HTTP3 обход)

**Симптом**: сайты проверки IP показывают VPN IP, но Google показывает реальный IP в капче или местоположении.

**Причина**: Firefox использует HTTP/3 (протокол QUIC = UDP). Redsocks перехватывает только TCP, поэтому QUIC трафик идёт напрямую в интернет мимо VPN цепочки.

**Решение 1** — vpn-chain уже блокирует исходящий UDP через iptables (с v2). Если у тебя старая версия — обнови `vpn-chain.sh`.

**Решение 2** — Отключить HTTP/3 в Firefox (защита в глубину):
```
about:config → network.http.http3.enable → false
```

**Как проверить**:
```bash
# Должен показать VPN IP, а не реальный
sudo vpn-chain check
```

## Нет интернета после перезагрузки VM

**Симптом**: `ping 8.8.8.8` работает но `curl` нет, или вообще ничего не работает.

**Причина**: `resolv.conf` залочен на `127.0.0.53` (dnscrypt-proxy), но dnscrypt-proxy нужен SOCKS5 прокси (wireproxy) который не запущен.

**Решение**:
```bash
sudo vpn-chain stop    # восстанавливает DNS на 8.8.8.8
```

Если vpn-chain установлен через последний `install.sh`, сервис `vpn-chain-dns-guard` делает это автоматически при загрузке.

## Проблемы с производительностью

### Низкая скорость
- wireproxy-awg работает в юзерспейсе — нагрузка на CPU выше чем у ядерного WireGuard
- Двойное шифрование добавляет задержку
- Попробуй VPS/Mullvad сервер географически ближе

### Высокий пинг
Ожидаемо с двойным VPN. Уменьшить можно:
- VPS и Mullvad серверы в одном регионе
- Forward mode: Mullvad сервер ближе к VPS
- Reverse mode: Mullvad сервер ближе к цели

## SSH "REMOTE HOST IDENTIFICATION HAS CHANGED"

**Причина**: Ты переустановил ОС на VPS. Новая установка имеет другие SSH host keys, а твоя машина помнит старые.

Это **не атака** — это ожидаемое поведение после переустановки VPS.

Решение — удалить старый ключ на **каждой машине** которая подключалась к VPS:
```bash
# На хост-машине:
ssh-keygen -f ~/.ssh/known_hosts -R IP_VPS

# На Kali VM (от пользователя kali):
ssh-keygen -f ~/.ssh/known_hosts -R IP_VPS

# На Kali VM (от root, используется vpn-chain):
sudo ssh-keygen -R IP_VPS
```

**Правило**: ошибка вылезла — чини на той машине где вылезла. SSH сам подсказывает какой файл и какую строку в тексте ошибки.

## `sudo ssh-copy-id`: "No identities found"

**Причина**: У root нет SSH ключа. `vpn-chain` работает от root (через sudo), поэтому SSH ключ должен быть у root.

Решение:
```bash
sudo ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519
sudo ssh-copy-id root@IP_VPS
```

Проверить:
```bash
sudo ssh root@IP_VPS "echo ok"
```

> **Важно**: `ssh root@VPS` (без sudo) использует ключ kali. `sudo ssh root@VPS` использует ключ root. `vpn-chain` использует ключ root.

## `ssh root@VPS`: просит пароль (а `sudo ssh` работает)

SSH ключ лежит только в `/root/.ssh/`. Когда заходишь без sudo, используется `/home/kali/.ssh/` где ключа нет.

Либо всегда используй `sudo ssh`, либо скопируй ключ kali тоже:
```bash
ssh-copy-id root@IP_VPS
```

## VPS: `git: command not found`

На чистом Debian нет git. Поставь:
```bash
apt-get update && apt-get install -y git
```

## После перезагрузки VM

Ничего не сохраняется. Запусти:
```bash
sudo vpn-chain start          # или: start reverse
```

## После перезагрузки VPS

AWG сервер стартует автоматически (если включён через systemctl). Для reverse mode:
```bash
mullvad-wg-start.sh
# или
systemctl start mullvad-wg
```
