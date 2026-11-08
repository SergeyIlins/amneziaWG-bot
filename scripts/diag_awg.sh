#!/bin/bash
# Диагностика AmneziaWG 3.1
# Запускать на сервере во время попытки подключения с Android

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SERVER_CONF="/etc/amnezia/amneziawg/awg0.conf"
IFACE="awg0"

echo -e "${CYAN}=================================================${NC}"
echo -e "${CYAN}   ДИАГНОСТИКА AMNEZIAWG 3.1${NC}"
echo -e "${CYAN}=================================================${NC}"

# --- 1. Проверка серверного конфига ---
echo -e "\n${YELLOW}[1] Серверный конфиг${NC}"
if [ ! -f "$SERVER_CONF" ]; then
    echo -e "${RED}✗ Файл $SERVER_CONF не найден${NC}"
    exit 1
fi

for param in HeaderProtectionKey ContentPaddingAddition S1 S2 S3 S4 H1 H2 H3 H4 I1; do
    val=$(grep -E "^${param}[[:space:]]*=" "$SERVER_CONF" | head -1 | cut -d'=' -f2- | xargs)
    if [ -n "$val" ]; then
        # Обрезаем длинные значения для читаемости
        display_val="$val"
        if [ ${#val} -gt 40 ]; then
            display_val="${val:0:20}...${val: -10}"
        fi
        echo -e "  ${GREEN}✓${NC} $param = $display_val"
    else
        echo -e "  ${RED}✗${NC} $param отсутствует!"
    fi
done

# Проверка обязательного условия: S1-S4 >= 12 для 3.1
s3_val=$(grep -E "^S3[[:space:]]*=" "$SERVER_CONF" | cut -d'=' -f2 | xargs)
s4_val=$(grep -E "^S4[[:space:]]*=" "$SERVER_CONF" | cut -d'=' -f2 | xargs)
if [[ "$s3_val" =~ ^[0-9]+$ ]] && [ "$s3_val" -lt 12 ]; then
    echo -e "  ${RED}⚠ S3=$s3_val < 12 — нарушение требований 3.1!${NC}"
fi
if [[ "$s4_val" =~ ^[0-9]+$ ]] && [ "$s4_val" -lt 12 ]; then
    echo -e "  ${RED}⚠ S4=$s4_val < 12 — нарушение требований 3.1!${NC}"
fi

# --- 2. Сверка с клиентским конфигом ---
echo -e "\n${YELLOW}[2] Сверка с последним созданным клиентом${NC}"
CLIENT_FILE=$(ls -t /root/amneziawg-clients/*.conf 2>/dev/null | head -1)
if [ -n "$CLIENT_FILE" ]; then
    echo -e "  Клиент: $(basename "$CLIENT_FILE")"
    for param in HeaderProtectionKey S1 S2 S3 S4 H1 H2 H3 H4 I1; do
        srv_val=$(grep -E "^${param}[[:space:]]*=" "$SERVER_CONF" | head -1 | cut -d'=' -f2- | xargs)
        cli_val=$(grep -E "^${param}[[:space:]]*=" "$CLIENT_FILE" | head -1 | cut -d'=' -f2- | xargs)

        if [ "$srv_val" == "$cli_val" ]; then
            echo -e "  ${GREEN}✓${NC} $param совпадает"
        else
            if [ -z "$srv_val" ] || [ -z "$cli_val" ]; then
                echo -e "  ${RED}✗${NC} $param: на сервере '$srv_val', на клиенте '$cli_val' (один отсутствует!)"
            else
                echo -e "  ${YELLOW}⚠${NC} $param: сервер '$srv_val' ≠ клиент '$cli_val'"
            fi
        fi
    done
else
    echo -e "  ${YELLOW}⚠ Клиентские конфиги не найдены${NC}"
fi

# --- 3. Перехват трафика в реальном времени ---
echo -e "\n${YELLOW}[3] Перехват трафика (tcpdump)${NC}"
echo -e "  ${CYAN}Подключитесь на Android сейчас. Ждем 15 секунд...${NC}"

PORT=$(grep -E "^ListenPort" "$SERVER_CONF" | cut -d'=' -f2 | xargs)
PORT=${PORT:-443}

timeout 15s tcpdump -i any -n "udp port $PORT" -c 10 2>/dev/null | tail -n 15

# --- 4. Логи ядра ---
echo -e "\n${YELLOW}[4] Логи ядра (dmesg)${NC}"
DMESG_OUT=$(dmesg -T 2>/dev/null | tail -n 30 | grep -i "amnezia\|awg" || true)
if [ -n "$DMESG_OUT" ]; then
    echo "$DMESG_OUT"
else
    echo -e "  ${GREEN}✓ Ошибок в dmesg не обнаружено${NC}"
fi

# --- 5. Состояние интерфейса ---
echo -e "\n${YELLOW}[5] Состояние интерфейса${NC}"
awg show "$IFACE" 2>/dev/null | head -n 30

echo -e "\n${CYAN}=================================================${NC}"
echo -e "${CYAN}   ДИАГНОСТИКА ЗАВЕРШЕНА${NC}"
echo -e "${CYAN}=================================================${NC}"
