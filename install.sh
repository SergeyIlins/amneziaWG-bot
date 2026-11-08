#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== AmneziaWG 3.1 + Telegram Bot Installer ===${NC}"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Пожалуйста, запустите скрипт с правами root (sudo).${NC}"
  exit 1
fi

if [ ! -f ".env" ]; then
  if [ -f ".env.example" ]; then
    cp .env.example .env
  else
    echo -e "${RED}Файл .env.example отсутствует.${NC}"
    exit 1
  fi
fi

echo -e "${YELLOW}Настройка переменных окружения (оставьте пустым для сохранения текущих)${NC}"
read -p "Введите TELEGRAM_BOT_TOKEN: " token
read -p "Введите ADMIN_IDS (Telegram ID, через запятую): " admins
read -p "Введите SERVER_PUBLIC_IP (автоопределение): " ip
ip=${ip:-$(curl -s ifconfig.me)}
read -p "Введите SERVER_PORT (по умолчанию 443): " port
port=${port:-443}
read -p "Введите VPN_SUBNET (по умолчанию 10.9.9.): " subnet
subnet=${subnet:-10.9.9.}

[ -n "$token" ] && sed -i "s/^TELEGRAM_BOT_TOKEN=.*/TELEGRAM_BOT_TOKEN=$token/" .env
[ -n "$admins" ] && sed -i "s/^ADMIN_IDS=.*/ADMIN_IDS=$admins/" .env
[ -n "$ip" ] && sed -i "s/^SERVER_PUBLIC_IP=.*/SERVER_PUBLIC_IP=$ip/" .env
[ -n "$port" ] && sed -i "s/^SERVER_PORT=.*/SERVER_PORT=$port/" .env
[ -n "$subnet" ] && sed -i "s/^VPN_SUBNET=.*/VPN_SUBNET=$subnet/" .env

export SERVER_PUBLIC_IP=$ip
export SERVER_PORT=$port
export VPN_SUBNET=$subnet

# Убран iptables-persistent, так как в Ubuntu 24.04 он вызывает ошибку
apt install -y python3 python3-pip python3-venv python3-full net-tools dnsutils qrencode

if [ ! -x /usr/bin/awg ]; then
  echo -e "${YELLOW}AmneziaWG не найден. Запуск автоматической установки версии 3.1...${NC}"
  mkdir -p scripts
  # Скачиваем актуальную версию установщика
  wget -O scripts/install_amneziawg.sh https://github.com/bivlked/amneziawg-installer/releases/latest/download/install_amneziawg.sh
  chmod +x scripts/install_amneziawg.sh
  
  # Передаем ответы: порт, режим (2 - AmneziaWG), перезагрузка (y)
  echo -e "${port}\n2\ny" | sudo bash scripts/install_amneziawg.sh
  
  echo -e "${YELLOW}Установка AmneziaWG завершена. Требуется перезагрузка.${NC}"
  echo -e "${YELLOW}Перезагрузить сейчас? (y/N)${NC}"
  read -r reboot_now
  if [[ "$reboot_now" =~ ^[Yy]$ ]]; then
    reboot
  else
    exit 0
  fi
else
  echo -e "${GREEN}AmneziaWG уже установлен (найден /usr/bin/awg).${NC}"
fi

mkdir -p /etc/amnezia/amneziawg /root/amneziawg-clients /opt/amneziawg-bot/app /opt/amneziawg-bot/scripts

if [ ! -f /etc/amneziawg/clients_meta.json ]; then
  mkdir -p /etc/amneziawg
  echo '{}' | tee /etc/amneziawg/clients_meta.json > /dev/null
  chmod 644 /etc/amneziawg/clients_meta.json
fi

cp -r app/* /opt/amneziawg-bot/app/
cp scripts/awg-manager.sh /usr/local/bin/awg-manager
chmod +x /usr/local/bin/awg-manager
cp .env /opt/amneziawg-bot/
cp requirements.txt /opt/amneziawg-bot/

python3 -m venv /opt/amneziawg-bot/venv
source /opt/amneziawg-bot/venv/bin/activate
pip install -r /opt/amneziawg-bot/requirements.txt
deactivate

# Создание симлинка (установщик 3.1 сам создает конфиг, мы его не перезаписываем!)
ln -sf /etc/amnezia/amneziawg/awg0.conf /etc/amneziawg/awg0.conf

sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

DEFAULT_IF=$(ip route | grep default | awk '{print $5}')
if [ -n "$DEFAULT_IF" ]; then
  iptables -t nat -A POSTROUTING -o "$DEFAULT_IF" -j MASQUERADE 2>/dev/null || true
  iptables -A FORWARD -i awg0 -j ACCEPT 2>/dev/null || true
  iptables -A FORWARD -o awg0 -j ACCEPT 2>/dev/null || true
fi

if command -v ufw &> /dev/null; then
  ufw allow $port/udp
fi

if ! ip link show awg0 &>/dev/null; then
  /usr/bin/awg-quick up awg0 || true
fi

cat > /etc/systemd/system/awg-bot.service << 'EOF'
[Unit]
Description=AmneziaWG Telegram Bot
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/amneziawg-bot
EnvironmentFile=/opt/amneziawg-bot/.env
ExecStart=/opt/amneziawg-bot/venv/bin/python -m app.bot
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/awg-api.service << 'EOF'
[Unit]
Description=AmneziaWG API
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/amneziawg-bot
EnvironmentFile=/opt/amneziawg-bot/.env
ExecStart=/opt/amneziawg-bot/venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8000
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/awg-cleanup.service << 'EOF'
[Unit]
Description=AmneziaWG Cleanup Expired Clients
[Service]
Type=oneshot
ExecStart=/usr/local/bin/awg-manager cleanup
EOF

cat > /etc/systemd/system/awg-cleanup.timer << 'EOF'
[Unit]
Description=Run AmneziaWG cleanup daily
[Timer]
OnCalendar=daily
Persistent=true
[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable awg-bot awg-api awg-cleanup.timer
systemctl restart awg-bot awg-api
systemctl start awg-cleanup.timer

echo -e "${GREEN}=== Установка завершена! ===${NC}"
echo -e "Бот запущен. Порт: $port, подсеть: $subnet"
