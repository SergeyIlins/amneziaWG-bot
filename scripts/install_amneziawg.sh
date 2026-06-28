#!/bin/bash
set -e

echo "Установка AmneziaWG..."
wget -q -O /tmp/install_amneziawg.sh https://raw.githubusercontent.com/amnezia-vpn/amneziawg-tools/master/install.sh
chmod +x /tmp/install_amneziawg.sh
yes | bash /tmp/install_amneziawg.sh

if ! command -v awg &> /dev/null; then
    echo "Ошибка: awg не установлен."
    exit 1
fi
echo "AmneziaWG успешно установлен."