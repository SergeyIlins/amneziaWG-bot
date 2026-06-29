#!/bin/bash
# AmneziaWG + Telegram Bot Installer (упрощённый)

set -e
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
echo -e "${GREEN}=== AmneziaWG + Telegram Bot Installer (Simple) ===${NC}"

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Запустите с правами root (sudo).${NC}"
    exit 1
fi

# .env
if [ ! -f ".env" ]; then cp .env.example .env; fi

# Запрос переменных
echo -e "${YELLOW}Настройка переменных (оставьте пустым для сохранения)${NC}"
read -p "TELEGRAM_BOT_TOKEN: " token
read -p "ADMIN_IDS: " admins
read -p "SERVER_PUBLIC_IP (авто): " ip; ip=${ip:-$(curl -s ifconfig.me)}
read -p "SERVER_PORT (по умолчанию 443): " port; port=${port:-443}
read -p "VPN_SUBNET (по умолчанию 10.9.9.): " subnet; subnet=${subnet:-10.9.9.}

[ -n "$token" ] && sed -i "s/^TELEGRAM_BOT_TOKEN=.*/TELEGRAM_BOT_TOKEN=$token/" .env
[ -n "$admins" ] && sed -i "s/^ADMIN_IDS=.*/ADMIN_IDS=$admins/" .env
[ -n "$ip" ] && sed -i "s/^SERVER_PUBLIC_IP=.*/SERVER_PUBLIC_IP=$ip/" .env
[ -n "$port" ] && sed -i "s/^SERVER_PORT=.*/SERVER_PORT=$port/" .env
[ -n "$subnet" ] && sed -i "s/^VPN_SUBNET=.*/VPN_SUBNET=$subnet/" .env

export SERVER_PUBLIC_IP=$ip SERVER_PORT=$port VPN_SUBNET=$subnet

# Базовые пакеты
apt update
apt install -y python3 python3-pip python3-venv python3-full curl wget jq qrencode iptables-persistent net-tools git dnsutils

# Установка AmneziaWG (если нет)
if [ ! -x /usr/bin/awg ]; then
    echo -e "${YELLOW}Установка AmneziaWG...${NC}"
    mkdir -p scripts
    wget -O scripts/install_amneziawg.sh https://raw.githubusercontent.com/bivlked/amneziawg-installer/v5.18.1/install_amneziawg.sh
    chmod +x scripts/install_amneziawg.sh
    yes | bash scripts/install_amneziawg.sh
    echo -e "${YELLOW}Требуется перезагрузка. Перезагрузиться? (y/N)${NC}"
    read -r reboot_now
    if [[ "$reboot_now" =~ ^[Yy]$ ]]; then reboot; else exit 0; fi
else
    echo -e "${GREEN}AmneziaWG уже установлен.${NC}"
fi

# --- Настройка бота ---
echo -e "${GREEN}Настройка бота...${NC}"
mkdir -p /etc/amneziawg /root/amneziawg-clients /opt/amneziawg-bot/app /opt/amneziawg-bot/scripts

# Копирование
cp -r app/* /opt/amneziawg-bot/app/
cp scripts/awg-manager.sh /usr/local/bin/awg-manager
chmod +x /usr/local/bin/awg-manager
cp .env /opt/amneziawg-bot/
cp requirements.txt /opt/amneziawg-bot/

# Виртуальное окружение
python3 -m venv /opt/amneziawg-bot/venv
source /opt/amneziawg-bot/venv/bin/activate
pip install -r /opt/amneziawg-bot/requirements.txt
deactivate

# Конфиг сервера (с правильной подсетью)
if [ ! -f /etc/amneziawg/awg0.conf ]; then
    SERVER_PRIV=$(/usr/bin/awg genkey)
    cat > /etc/amneziawg/awg0.conf <<EOF
[Interface]
PrivateKey = $SERVER_PRIV
Address = ${subnet}1/24
ListenPort = $port
MTU = 1280
Jc = 5
Jmin = 40
Jmax = 70
S1 = 85
S2 = 89
H1 = 9784561
H2 = 5421786
EOF
fi

# Форвардинг и NAT
sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
DEFAULT_IF=$(ip route | grep default | awk '{print $5}')
iptables -t nat -A POSTROUTING -o "$DEFAULT_IF" -j MASQUERADE 2>/dev/null || true
iptables -A FORWARD -i awg0 -j ACCEPT 2>/dev/null || true
iptables -A FORWARD -o awg0 -j ACCEPT 2>/dev/null || true
iptables-save > /etc/iptables/rules.v4
if command -v ufw &> /dev/null; then
    ufw allow $port/udp
    ufw allow 8000/tcp
fi

# Поднятие интерфейса
if ! ip link show awg0 &>/dev/null; then
    /usr/bin/awg-quick up awg0
fi

# Systemd юниты
cat > /etc/systemd/system/awg-bot.service <<EOF
[Unit]
Description=AmneziaWG Bot
After=network.target
[Service]
Type=simple
User=root
WorkingDirectory=/opt/amneziawg-bot
EnvironmentFile=/opt/amneziawg-bot/.env
ExecStart=/opt/amneziawg-bot/venv/bin/python3 /opt/amneziawg-bot/app/bot.py
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/awg-api.service <<EOF
[Unit]
Description=AmneziaWG API
After=network.target
[Service]
Type=simple
User=root
WorkingDirectory=/opt/amneziawg-bot
EnvironmentFile=/opt/amneziawg-bot/.env
ExecStart=/opt/amneziawg-bot/venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8000
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable awg-bot awg-api
systemctl restart awg-bot awg-api

# Таймер очистки
cat > /etc/systemd/system/awg-cleanup.service <<EOF
[Unit]
Description=Cleanup Expired Clients
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

echo -e "${GREEN}Установка завершена! Бот запущен. Используйте /menu в Telegram.${NC}"
