#!/bin/bash
# AmneziaWG + Telegram Bot Installer v11 (Fixed & Secure)
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== AmneziaWG + Telegram Bot Installer v11 ===${NC}"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Пожалуйста, запустите скрипт с правами root (sudo).${NC}"
  exit 1
fi

# Проверка интернета
echo -e "${YELLOW}Проверка подключения к интернету...${NC}"
if ! ping -c 1 8.8.8.8 &> /dev/null; then
  echo -e "${RED}Нет интернета.${NC}"
  exit 1
fi
echo -e "${GREEN}Интернет доступен.${NC}"

# .env
if [ ! -f ".env" ]; then
  if [ -f ".env.example" ]; then
    cp .env.example .env
  else
    echo -e "${RED}Файл .env.example отсутствует.${NC}"
    exit 1
  fi
fi

# Запрос переменных
echo -e "${YELLOW}Настройка переменных окружения (оставьте пустым для сохранения текущих)${NC}"
read -p "Введите TELEGRAM_BOT_TOKEN: " token
read -p "Введите ADMIN_IDS (Telegram ID, через запятую): " admins
read -p "Введите SERVER_PUBLIC_IP (автоопределение): " ip
ip=${ip:-$(curl -s ifconfig.me)}
read -p "Введите SERVER_PORT (по умолчанию 587): " port
port=${port:-587}
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

# Базовые пакеты
apt update
apt install -y python3 python3-pip python3-venv python3-full curl wget jq qrencode iptables-persistent net-tools git dnsutils

# Установка AmneziaWG (если отсутствует)
if [ ! -x /usr/bin/awg ]; then
  echo -e "${YELLOW}AmneziaWG не найден. Запуск автоматической установки...${NC}"
  mkdir -p scripts
  if [ ! -f "scripts/install_amneziawg.sh" ]; then
    wget -O scripts/install_amneziawg.sh https://raw.githubusercontent.com/bivlked/amneziawg-installer/v5.18.1/install_amneziawg.sh
    chmod +x scripts/install_amneziawg.sh
  fi
  # Автоматические ответы: порт, режим, перезагрузка
  echo -e "${port}\n2\ny" | sudo bash scripts/install_amneziawg.sh
  echo -e "${YELLOW}Установка AmneziaWG завершена. Требуется перезагрузка.${NC}"
  echo -e "${YELLOW}После перезагрузки запустите скрипт снова: sudo ./install.sh${NC}"
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

# --- Настройка бота ---
echo -e "${GREEN}Настройка бота и сервера...${NC}"

# Создание папок
mkdir -p /etc/amnezia/amneziawg /root/amneziawg-clients /opt/amneziawg-bot/app /opt/amneziawg-bot/scripts

# Мета-файл клиентов
if [ ! -f /etc/amneziawg/clients_meta.json ]; then
  mkdir -p /etc/amneziawg
  echo '{}' | tee /etc/amneziawg/clients_meta.json > /dev/null
  chmod 644 /etc/amneziawg/clients_meta.json
fi

# Копирование файлов бота
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

# Конфиг сервера (если нет) с правильной подсетью, портом и обфускацией
if [ ! -f /etc/amnezia/amneziawg/awg0.conf ]; then
  SERVER_PRIV=$(/usr/bin/awg genkey)
  # Генерация случайных параметров обфускации
  JC=$((5 + RANDOM % 5))          # 5-9
  JMIN=$((10 + RANDOM % 41))      # 10-50
  JMAX=$((JMIN + 50 + RANDOM % 100)) # > JMIN + 50
  S1=$((15 + RANDOM % 135))       # 15-150
  S2=$((15 + RANDOM % 135))       # 15-150
  H1=$((100000 + RANDOM % 900000))
  H2=$((100000 + RANDOM % 900000))
  H3=$((100000 + RANDOM % 900000))
  H4=$((100000 + RANDOM % 900000))
  I1=$(openssl rand -base64 32)

  cat > /etc/amnezia/amneziawg/awg0.conf << 'EOF'
[Interface]
PrivateKey = ${SERVER_PRIV}
Address = ${VPN_SUBNET}1/24
ListenPort = ${SERVER_PORT}
Jc = ${JC}
Jmin = ${JMIN}
Jmax = ${JMAX}
S1 = ${S1}
S2 = ${S2}
H1 = ${H1}
H2 = ${H2}
H3 = ${H3}
H4 = ${H4}
I1 = ${I1}
PostUp = iptables -A FORWARD -i awg0 -j ACCEPT; iptables -A FORWARD -o awg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o $(ip route | grep default | awk '{print $5}') -j MASQUERADE
PostDown = iptables -D FORWARD -i awg0 -j ACCEPT; iptables -D FORWARD -o awg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o $(ip route | grep default | awk '{print $5}') -j MASQUERADE
EOF
  # Заменяем переменные в конфиге
  sed -i "s|\${SERVER_PRIV}|$SERVER_PRIV|g; s|\${VPN_SUBNET}|$subnet|g; s|\${SERVER_PORT}|$port|g; s|\${JC}|$JC|g; s|\${JMIN}|$JMIN|g; s|\${JMAX}|$JMAX|g; s|\${S1}|$S1|g; s|\${S2}|$S2|g; s|\${H1}|$H1|g; s|\${H2}|$H2|g; s|\${H3}|$H3|g; s|\${H4}|$H4|g; s|\${I1}|$I1|g" /etc/amnezia/amneziawg/awg0.conf
  echo -e "${GREEN}Конфиг сервера создан с случайными параметрами обфускации.${NC}"
else
  echo -e "${GREEN}Конфиг сервера уже существует.${NC}"
fi

# Симлинк для совместимости
ln -sf /etc/amnezia/amneziawg/awg0.conf /etc/amneziawg/awg0.conf

# Форвардинг
sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

# NAT и firewall
DEFAULT_IF=$(ip route | grep default | awk '{print $5}')
if [ -n "$DEFAULT_IF" ]; then
  iptables -t nat -A POSTROUTING -o "$DEFAULT_IF" -j MASQUERADE 2>/dev/null || true
  iptables -A FORWARD -i awg0 -j ACCEPT 2>/dev/null || true
  iptables -A FORWARD -o awg0 -j ACCEPT 2>/dev/null || true
  iptables-save > /etc/iptables/rules.v4
fi

if command -v ufw &> /dev/null; then
  ufw allow $port/udp
  # НЕ открываем 8000/tcp наружу — API будет слушать только localhost
fi

# Поднятие интерфейса
if ! ip link show awg0 &>/dev/null; then
  /usr/bin/awg-quick up awg0
fi

# Systemd юниты (API слушает только 127.0.0.1)
cat > /etc/systemd/system/awg-bot.service << 'EOF'
[Unit]
Description=AmneziaWG Telegram Bot
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/amneziawg-bot
EnvironmentFile=/opt/amneziawg-bot/.env
ExecStart=/opt/amneziawg-bot/venv/bin/python -m app.main
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

# Активация сервисов
systemctl daemon-reload
systemctl enable awg-bot awg-api awg-cleanup.timer
systemctl restart awg-bot awg-api
systemctl start awg-cleanup.timer

# Проверки
if ip link show awg0 &>/dev/null; then
  echo -e "${GREEN}✓ Интерфейс awg0 поднят.${NC}"
else
  echo -e "${RED}✗ Интерфейс awg0 не найден.${NC}"
fi

if systemctl is-active --quiet awg-bot && systemctl is-active --quiet awg-api; then
  echo -e "${GREEN}✓ Сервисы активны.${NC}"
else
  echo -e "${RED}✗ Сервисы не активны.${NC}"
fi

if curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8000/health | grep -q 200; then
  echo -e "${GREEN}✓ API отвечает.${NC}"
else
  echo -e "${RED}✗ API не отвечает.${NC}"
fi

if [ -x /usr/local/bin/awg-manager ]; then
  echo -e "${GREEN}✓ awg-manager найден.${NC}"
else
  echo -e "${RED}✗ awg-manager отсутствует.${NC}"
fi

if [ -f /etc/amneziawg/clients_meta.json ]; then
  echo -e "${GREEN}✓ Мета-файл существует.${NC}"
else
  echo -e "${RED}✗ Мета-файл отсутствует.${NC}"
fi

echo -e "${GREEN}=== Установка завершена! ===${NC}"
echo -e "Бот запущен. Используйте /menu в Telegram."
echo -e "Порт: $port, подсеть: $subnet"
