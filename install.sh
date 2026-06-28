#!/bin/bash
# AmneziaWG + Telegram Bot Installer v4 (с раздельным туннелированием)

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== AmneziaWG + Telegram Bot Installer v4 ===${NC}"

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Пожалуйста, запустите скрипт с правами root (sudo).${NC}"
    exit 1
fi

# Проверка наличия .env, если нет — копируем из примера
if [ ! -f ".env" ]; then
    if [ -f ".env.example" ]; then
        cp .env.example .env
    else
        echo -e "${RED}Файл .env.example отсутствует.${NC}"
        exit 1
    fi
fi

# Запрос переменных окружения (оставьте пустым для сохранения текущих)
echo -e "${YELLOW}Настройка переменных окружения (оставьте пустым для сохранения текущих)${NC}"
read -p "Введите TELEGRAM_BOT_TOKEN: " token
read -p "Введите ADMIN_IDS (Telegram ID, через запятую): " admins
read -p "Введите SERVER_PUBLIC_IP (автоопределение): " ip
ip=${ip:-$(curl -s ifconfig.me)}
read -p "Введите SERVER_PORT (по умолчанию 443): " port
port=${port:-443}
read -p "Введите VPN_SUBNET (по умолчанию 10.0.0.): " subnet
subnet=${subnet:-10.0.0.}

# Сохраняем только если не пустые
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
apt install -y python3 python3-pip python3-venv curl wget jq qrencode iptables-persistent net-tools git

# ---------------------------------------------------------------------
# Установка AmneziaWG (только если НЕ установлен)
# ---------------------------------------------------------------------
if [ ! -x /usr/bin/awg ]; then
    echo -e "${YELLOW}AmneziaWG не найден. Запуск установщика bivlked...${NC}"
    mkdir -p scripts
    if [ ! -f "scripts/install_amneziawg.sh" ]; then
        wget -O scripts/install_amneziawg.sh https://raw.githubusercontent.com/bivlked/amneziawg-installer/v5.18.1/install_amneziawg.sh
    fi
    chmod +x scripts/install_amneziawg.sh
    # Запускаем установщик с автоматическим согласием на перезагрузку
    yes | bash scripts/install_amneziawg.sh
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

# ---------------------------------------------------------------------
# Настройка бота и сервера (выполняется всегда, если awg есть)
# ---------------------------------------------------------------------
echo -e "${GREEN}Настройка бота и сервера...${NC}"

# Создание папок
mkdir -p /etc/amneziawg /root/amneziawg-clients /opt/amneziawg-bot/app /opt/amneziawg-bot/scripts

# Копирование файлов бота
cp -r app/* /opt/amneziawg-bot/app/
cp scripts/awg-manager.sh /usr/local/bin/awg-manager
chmod +x /usr/local/bin/awg-manager
cp .env /opt/amneziawg-bot/
cp requirements.txt /opt/amneziawg-bot/

# Установка Python-зависимостей
pip3 install -r /opt/amneziawg-bot/requirements.txt

# Генерация конфига сервера, если отсутствует
if [ ! -f /etc/amneziawg/awg0.conf ]; then
    server_priv=$(/usr/bin/awg genkey)
    server_pub=$(echo "$server_priv" | /usr/bin/awg pubkey)
    cat > /etc/amneziawg/awg0.conf <<EOF
[Interface]
PrivateKey = $server_priv
Address = ${subnet}1/24
ListenPort = $port
MTU = 1420
Jc = 5
Jmin = 40
Jmax = 70
S1 = 85
S2 = 89
H1 = 9784561
H2 = 5421786
EOF
    echo -e "${GREEN}Конфиг сервера создан.${NC}"
else
    echo -e "${GREEN}Конфиг сервера уже существует.${NC}"
fi

# Включение IP-форвардинга
sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

# Настройка NAT и firewall
DEFAULT_IF=$(ip route | grep default | awk '{print $5}')
if [ -z "$DEFAULT_IF" ]; then
    echo -e "${RED}Не удалось определить интерфейс по умолчанию.${NC}"
    exit 1
fi
if ! iptables -t nat -C POSTROUTING -o "$DEFAULT_IF" -j MASQUERADE 2>/dev/null; then
    iptables -t nat -A POSTROUTING -o "$DEFAULT_IF" -j MASQUERADE
    iptables -A FORWARD -i awg0 -j ACCEPT
    iptables -A FORWARD -o awg0 -j ACCEPT
    iptables-save > /etc/iptables/rules.v4
fi

# Открытие портов (если установлен ufw, иначе пропускаем)
if command -v ufw &> /dev/null; then
    ufw allow $port/udp
    ufw allow 8000/tcp
fi

# Поднятие интерфейса, если не поднят
if ! ip link show awg0 &>/dev/null; then
    /usr/bin/awg-quick up awg0
fi

# Копирование systemd-юнитов
cp systemd/awg-bot.service /etc/systemd/system/
cp systemd/awg-api.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable awg-bot awg-api
systemctl restart awg-bot awg-api

# Таймер очистки просроченных клиентов
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

# Финальная проверка
if systemctl is-active --quiet awg-bot && systemctl is-active --quiet awg-api; then
    echo -e "${GREEN}=== Установка завершена успешно! ===${NC}"
    echo -e "Бот запущен. Используйте /menu в Telegram."
    echo -e "При добавлении клиента вы сможете указать ресурсы (IP/домены) для туннелирования."
else
    echo -e "${YELLOW}Проверьте логи: journalctl -u awg-bot -f${NC}"
fi
