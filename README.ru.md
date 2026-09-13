# vpn-chain

Двойная VPN-цепочка для пентест-операций. Системный прозрачный проксинг — все приложения в VM выходят через цепочку автоматически.

## Что делает

Два режима работы одной командой:

```
sudo vpn-chain start           # FORWARD: Ты → Mullvad → VPS → Цель
sudo vpn-chain start reverse   # REVERSE: Ты → VPS → Mullvad → Цель
sudo vpn-chain stop            # Убить всё
```

**Forward** — максимальная анонимность. VPS никогда не узнает твой реальный IP (видит только выход Mullvad). Цель видит IP VPS. Фиксированный exit IP.

**Reverse** — операционная гибкость. Мгновенная ротация exit IP через 500+ серверов Mullvad. Цель видит IP Mullvad. Одна команда — смена страны.

## Кто что видит

### Forward

| Сторона | Видит | Не видит |
|---------|-------|----------|
| Провайдер | Зашифрованный QUIC к Mullvad | Куда идёшь, контент |
| Mullvad | Твой IP → зашифрованный блоб к VPS | Контент (AmneziaWG шифрует) |
| VPS | IP выхода Mullvad → оригинальный запрос | Твой реальный IP |
| Цель | IP VPS | Ничего о тебе |

### Reverse

| Сторона | Видит | Не видит |
|---------|-------|----------|
| Провайдер | Зашифрованный AmneziaWG к VPS | Куда идёшь, контент |
| VPS | Твой IP → зашифрованный WG к Mullvad | Контент (WireGuard шифрует) |
| Mullvad | IP VPS → оригинальный запрос | Твой реальный IP |
| Цель | IP выхода Mullvad | Ничего о тебе |

## Архитектура

```
FORWARD:
┌────────────┐     ┌───────────────┐     ┌─────────────────┐     ┌────────┐
│  Kali VM   │ ──→ │ Mullvad (QUIC)│ ──→ │ VPS (AmneziaWG) │ ──→ │  Цель  │
│            │     │  1-й туннель  │     │  2-й туннель     │     │        │
│ wireproxy  │     │               │     │  Расшифровывает  │     │        │
│ redsocks   │     │  Прячет тебя  │     │  AWG, форвардит  │     │        │
│ iptables   │     │  от VPS       │     │  напрямую        │     │        │
└────────────┘     └───────────────┘     └─────────────────┘     └────────┘

REVERSE:
┌────────────┐     ┌─────────────────┐     ┌─────────────┐     ┌────────┐
│  Kali VM   │ ──→ │ VPS (AmneziaWG) │ ──→ │ Mullvad (WG)│ ──→ │  Цель  │
│            │     │  1-й туннель     │     │ 2-й туннель │     │        │
│ wireproxy  │     │  Расшифровывает  │     │             │     │        │
│ redsocks   │     │  AWG, шифрует WG │     │ Ротируемый  │     │        │
│ iptables   │     │                  │     │ exit IP     │     │        │
└────────────┘     └─────────────────┘     └─────────────┘     └────────┘
```

## Как это работает (под капотом)

Проблема: файрвол Mullvad (`nftables`) блокирует весь трафик кроме своего интерфейса (`wg0-mullvad`). Любой новый VPN-интерфейс (WireGuard, AmneziaWG, TUN) дропается. Просто поставить два VPN-интерфейса нельзя.

Решение: **wireproxy-awg** запускает AmneziaWG полностью в юзерспейсе — без ядерного интерфейса, без конфликта с nftables. Открывает UDP-сокет через туннель Mullvad и выставляет SOCKS5 прокси. **redsocks** + **iptables** прозрачно перенаправляют весь TCP трафик системы через этот прокси. Ни одно приложение не знает, что его проксируют.

```
Приложение шлёт пакет на 93.184.216.34:80
  ↓
iptables REDIRECT → 127.0.0.1:12345
  ↓
redsocks принимает, читает оригинальный адрес (SO_ORIGINAL_DST)
  ↓
redsocks → SOCKS5 connect к 127.0.0.1:1080
  ↓
wireproxy-awg оборачивает в AmneziaWG, шлёт через туннель Mullvad
  ↓
VPS расшифровывает, форвардит на 93.184.216.34:80
```

## Требования

### Клиент (атакующая VM)
- Kali Linux / Debian-based VM
- VirtualBox с **Bridged Adapter** (не NAT — NAT пускает трафик через VPN хоста)
- Аккаунт Mullvad VPN (для forward режима)

### Сервер (VPS)
- Debian 12 / Ubuntu 22.04+
- KVM виртуализация (не OpenVZ)
- Публичный IPv4 адрес
- Рекомендуется: покупать за крипту, без KYC

## Быстрый старт

### 1. Поднять VPS

Берёшь VPS с Debian 12 / Ubuntu 22.04+ (KVM, не OpenVZ). Заходишь по SSH и ставишь:

```bash
ssh root@IP_ТВОЕГО_VPS

apt-get update && apt-get install -y git
git clone https://github.com/jewahhlol/vpn-chain-mullvad-vps-.git vpn-chain
cd vpn-chain/server
chmod +x *.sh
./install.sh
```

> **Если видишь "AmneziaWG module not loaded"**: модуль ядра собран под более новое ядро. Запусти `reboot`, зайди обратно по SSH, запусти `./install.sh` снова. Это нормально на свежих Debian.

Установщик в конце выведет **клиентский конфиг** — скопируй его, понадобится в шаге 3.

### 2. Установить клиент на VM

Теперь на твоей **Kali / Debian VM** (не на VPS — это твоя атакующая машина, обязательно **Bridged Adapter** в VirtualBox, не NAT):

```bash
git clone https://github.com/jewahhlol/vpn-chain-mullvad-vps-.git vpn-chain
cd vpn-chain/client
chmod +x install.sh
sudo ./install.sh
```

Установит wireproxy-awg, redsocks, dnscrypt-proxy и команду `vpn-chain` на VM.

### 3. Вставить клиентский конфиг

Берёшь конфиг, который `install.sh` напечатал на VPS (шаг 1) и вставляешь:

```bash
sudo nano /etc/wireproxy-awg.conf
```

Замени всё содержимое на конфиг с VPS. Выглядит так:

```ini
[Interface]
Address = 10.9.9.3/32
PrivateKey = <сгенерированный ключ>
DNS = 1.1.1.1
...

[Peer]
PublicKey = <публичный ключ сервера>
Endpoint = IP_VPS:5000
...

[Socks5]
BindAddress = 127.0.0.1:1080
```

### 4. Настроить SSH ключ для автопереключения

Скрипт `vpn-chain` ходит на VPS по SSH чтобы включать/выключать Mullvad WG при смене режимов. Поскольку скрипт работает через sudo, SSH ключ должен быть у root:

```bash
# Сгенерировать SSH ключ для root (пропусти если /root/.ssh/id_ed25519 уже есть)
sudo ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519

# Скопировать на VPS (введи пароль root VPS когда попросит)
sudo ssh-copy-id root@IP_VPS

# Проверить что работает без пароля
sudo ssh root@IP_VPS "echo ok"
```

> **Без этого шага**: сама цепочка работает, но переключать режимы придётся вручную через SSH на VPS (`mullvad-wg-start.sh` / `mullvad-wg-stop.sh`).

### 5. Настроить reverse mode (опционально)

Если хочешь ротацию exit IP (рекомендуется), запусти на VPS:

```bash
cd vpn-chain/server
./setup-mullvad-wg.sh
```

Скрипт:
1. Сгенерирует пару ключей WireGuard
2. Покажет команду `curl` для регистрации ключа в Mullvad
3. Попросит вставить IP который вернул Mullvad

> **Как зарегистрировать**: открой второй терминал на VPS, выполни команду `curl` которую показал скрипт (замени `YOUR_ACCOUNT_NUMBER` на номер аккаунта Mullvad). Вернёт IP вида `10.68.x.x/32` — вставь его в первый терминал.

### 6. Проверить

```bash
# Reverse mode (VM → VPS → Mullvad)
sudo vpn-chain start reverse

# Проверить exit IP
curl ifconfig.me

# Полный тест на утечки
sudo vpn-chain check

# Сменить страну (работает в обоих режимах)
sudo vpn-chain switch us

# Переключиться на forward mode (VM → Mullvad → VPS)
sudo vpn-chain start forward

# Остановить всё
sudo vpn-chain stop
```

### 7. Для forward mode: установить Mullvad на VM

Forward mode требует приложение Mullvad на VM. См. [docs/mullvad-setup.md](docs/mullvad-setup.md).

## Команды

```bash
sudo vpn-chain start            # Forward mode (exit = IP VPS)
sudo vpn-chain start reverse    # Reverse mode (exit = IP Mullvad)
sudo vpn-chain stop             # Остановить все цепочки
sudo vpn-chain status           # Статус компонентов + exit IP
sudo vpn-chain check            # Полный тест на утечки (IP, DNS, IPv6)
sudo vpn-chain switch           # Показать текущий сервер + доступные
sudo vpn-chain switch us        # Сменить на US (авто-определяет режим)
sudo vpn-chain switch de ber    # Сменить на Берлин
sudo vpn-chain switch jp        # Сменить на Японию
```

## Замена / ротация VPS

Когда VPS истёк или хочешь свежий:

**1. Взять новый VPS** (чистый Debian 12)

**2. Очистить старые SSH ключи** — у нового VPS другие host keys, SSH откажет с ошибкой "REMOTE HOST IDENTIFICATION HAS CHANGED". Исправить, удалив старый ключ на каждой машине:

```bash
# На хост-машине
ssh-keygen -f ~/.ssh/known_hosts -R СТАРЫЙ_IP

# На Kali VM (от пользователя kali)
ssh-keygen -f ~/.ssh/known_hosts -R СТАРЫЙ_IP

# На Kali VM (от root, используется vpn-chain)
sudo ssh-keygen -R СТАРЫЙ_IP
```

> **Почему так**: SSH запоминает отпечаток каждого сервера для защиты от MITM-атак. При переустановке ОС сервер получает новые ключи, и SSH думает что кто-то выдаёт себя за сервер. Удаление старой записи говорит SSH принять новый ключ.

**3. Поднять новый VPS** — запусти `install.sh` и `setup-mullvad-wg.sh` (как в шагах 1 и 5)

**4. Обновить клиентский конфиг** — вставь новый конфиг в `/etc/wireproxy-awg.conf` на VM

**5. Настроить SSH ключ** — `sudo ssh-copy-id root@НОВЫЙ_IP`

**6. Погнали** — `sudo vpn-chain start reverse`

## Структура файлов

```
vpn-chain/
├── README.md                   # Документация (EN)
├── README.ru.md                # Документация (RU)
├── client/
│   ├── install.sh              # Установщик клиента
│   ├── vpn-chain.sh            # Главный скрипт управления
│   ├── redsocks.conf           # Шаблон redsocks
│   └── wireproxy-awg.conf.example
├── server/
│   ├── install.sh              # Установщик VPS (AmneziaWG сервер)
│   ├── setup-mullvad-wg.sh     # Настройка Mullvad WG для reverse mode
│   ├── mullvad-rotate.sh       # Скрипт ротации серверов
│   ├── mullvad-wg-start.sh     # Безопасный старт Mullvad (сохраняет SSH)
│   └── mullvad-wg-stop.sh      # Остановка Mullvad
└── docs/
    ├── how-it-works.md         # Глубокое техническое объяснение
    ├── mullvad-setup.md        # Гайд по установке Mullvad
    ├── troubleshooting.md      # Частые проблемы и решения
    └── threat-model.md         # Анализ безопасности
```

## Заметки по безопасности

- **Kill switch архитектурный**: если Mullvad падает (forward mode), VPS становится недоступен, весь трафик останавливается. Ручной kill switch не нужен.
- **IPv6 заблокирован**: `ip6tables -P OUTPUT DROP` предотвращает утечки.
- **DNS идёт через цепочку**: dnscrypt-proxy резолвит через DNS-over-HTTPS (TCP/443), который redsocks ловит и гонит через цепочку. Никаких UDP DNS утечек.
- **Ограничения UDP**: redsocks обрабатывает только TCP. Чистый UDP (некоторый VoIP, игровой трафик) не пойдёт через цепочку.
- **Изоляция хоста**: используй Bridged Adapter в VirtualBox, не NAT. NAT пускает трафик VM через сетевой стек хоста (и любой VPN хоста).

## Протестировано на

- Клиент: Kali Linux 2026.2 (VirtualBox, Bridged WiFi)
- Сервер: Debian 12 (Bookworm)
- wireproxy-awg: 1.0.17
- AmneziaWG kernel module: 1.0.20210914
- Mullvad VPN: 2026.4

## Лицензия

MIT
