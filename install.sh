#!/bin/bash
# AmneziaWG + Telegram Bot Installer

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== AmneziaWG Telegram Bot Installer ===${NC}"

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Пожалуйста, запустите скрипт с правами root (sudo).${NC}"
    exit 1
fi

# Проверка наличия .env
if [ ! -f ".env" ]; then
    if [ -f ".env.example" ]; then
        cp .env.example .env
    else
        echo -e "${RED}Файл .env.example отсутствует.${NC}"
        exit 1
    fi
fi

# Запрос переменных
echo -e "${YELLOW}Настройка переменных окружения (текущие значения в скобках)${NC}"
read -p "Введите TELEGRAM_BOT_TOKEN: " -r token
read -p "Введите ADMIN_IDS (Telegram ID, через запятую): " -r admins
read -p "Введите SERVER_PUBLIC_IP (публичный IP сервера, автоопределение): " -r ip
if [ -z "$ip" ]; then
    ip=$(curl -s ifconfig.me)
    echo "Определён IP: $ip"
fi
read -p "Введите SERVER_PORT (по умолчанию 443): " -r port
port=${port:-443}
read -p "Введите VPN_SUBNET (по умолчанию 10.0.0.): " -r subnet
subnet=${subnet:-10.0.0.}

# Сохраняем в .env
sed -i "s/^TELEGRAM_BOT_TOKEN=.*/TELEGRAM_BOT_TOKEN=$token/" .env
sed -i "s/^ADMIN_IDS=.*/ADMIN_IDS=$admins/" .env
sed -i "s/^SERVER_PUBLIC_IP=.*/SERVER_PUBLIC_IP=$ip/" .env
sed -i "s/^SERVER_PORT=.*/SERVER_PORT=$port/" .env
sed -i "s/^VPN_SUBNET=.*/VPN_SUBNET=$subnet/" .env

export SERVER_PUBLIC_IP=$ip
export SERVER_PORT=$port
export VPN_SUBNET=$subnet

echo -e "${GREEN}Переменные сохранены в .env${NC}"

# Обновление системы
apt update

# Установка зависимостей
apt install -y python3 python3-pip python3-venv curl wget jq qrencode iptables-persistent net-tools

# Установка AmneziaWG
if [ -f "scripts/install_amneziawg.sh" ]; then
    chmod +x scripts/install_amneziawg.sh
    ./scripts/install_amneziawg.sh
else
    echo -e "${RED}Скрипт установки AmneziaWG не найден!${NC}"
    exit 1
fi

if ! command -v awg &> /dev/null; then
    echo -e "${RED}Ошибка: awg не установлен.${NC}"
    exit 1
fi

# Создание папок
mkdir -p /etc/amneziawg
mkdir -p /root/amneziawg-clients
mkdir -p /opt/amneziawg-bot/app
mkdir -p /opt/amneziawg-bot/scripts

# Копирование файлов
cp -r app/* /opt/amneziawg-bot/app/
cp scripts/awg-manager.sh /usr/local/bin/awg-manager
chmod +x /usr/local/bin/awg-manager
cp .env /opt/amneziawg-bot/.env
cp requirements.txt /opt/amneziawg-bot/

# Установка Python-зависимостей
pip3 install -r /opt/amneziawg-bot/requirements.txt

# Генерация конфига сервера
if [ ! -f "/etc/amneziawg/awg0.conf" ]; then
    server_priv=$(awg genkey)
    server_pub=$(echo "$server_priv" | awg pubkey)
    cat > /etc/amneziawg/awg0.conf <<EOF
[Interface]
PrivateKey = $server_priv
Address = ${subnet}1/24
ListenPort = $port
MTU = 1420

# Параметры обфускации (рекомендованные)
Jc = 5
Jmin = 40
Jmax = 70
S1 = 85
S2 = 89
H1 = 9784561
H2 = 5421786
EOF
fi

# Включаем форвардинг
if ! sysctl net.ipv4.ip_forward | grep -q "1"; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    sysctl -p
fi

# Настройка NAT (используем интерфейс по умолчанию)
DEFAULT_IF=$(ip route | grep default | awk '{print $5}')
if [ -z "$DEFAULT_IF" ]; then
    echo -e "${RED}Не удалось определить интерфейс по умолчанию.${NC}"
    exit 1
fi
if ! iptables -t nat -C POSTROUTING -o "$DEFAULT_IF" -j MASQUERADE 2>/dev/null; then
    iptables -t nat -A POSTROUTING -o "$DEFAULT_IF" -j MASQUERADE
    if command -v netfilter-persistent &> /dev/null; then
        netfilter-persistent save
    else
        iptables-save > /etc/iptables/rules.v4
    fi
fi

# Открываем порты
if command -v ufw &> /dev/null; then
    ufw allow $port/udp
    ufw allow 8000/tcp
fi

# Создание systemd-юнитов
cp systemd/awg-bot.service /etc/systemd/system/
cp systemd/awg-api.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable awg-bot awg-api
systemctl restart awg-bot awg-api

# Таймер для автоочистки
cat > /etc/systemd/system/awg-cleanup.service <<EOF
[Unit]
Description=AmneziaWG Cleanup Expired Clients
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/awg-manager cleanup
EOF

cat > /etc/systemd/system/awg-cleanup.timer <<EOF
[Unit]
Description=Run cleanup daily
Requires=awg-cleanup.service

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF
systemctl enable awg-cleanup.timer
systemctl start awg-cleanup.timer

echo -e "${GREEN}=== Установка завершена! ===${NC}"
echo -e "Бот запущен. Используйте команду /menu в Telegram для управления."
echo -e "Проверка статуса: systemctl status awg-bot"
echo -e "Логи: journalctl -u awg-bot -f"