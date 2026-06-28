#!/bin/bash
# Управление клиентами AmneziaWG с поддержкой раздельного туннелирования

set -e

SERVER_CONF="/etc/amneziawg/awg0.conf"
META_FILE="/etc/amneziawg/clients_meta.json"
CLIENTS_DIR="/root/amneziawg-clients"

SERVER_PUBLIC_IP=${SERVER_PUBLIC_IP:-"$(curl -s ifconfig.me)"}
SERVER_PORT=${SERVER_PORT:-443}
VPN_SUBNET=${VPN_SUBNET:-"10.0.0."}

get_next_ip() {
    local last_ip=$(grep -oP "AllowedIPs = ${VPN_SUBNET}\K\d+" "$SERVER_CONF" | sort -n | tail -1)
    if [ -z "$last_ip" ]; then
        echo "2"
    else
        echo $((last_ip + 1))
    fi
}

add_client() {
    local name=$1
    local duration=$2
    local resources=$3  # список IP/доменов через запятую (опционально)
    local ip=$(get_next_ip)
    if [ -z "$ip" ] || [ "$ip" -ge 255 ]; then
        echo "Нет свободных IP" >&2
        return 1
    fi
    local private_key=$(awg genkey)
    local public_key=$(echo "$private_key" | awg pubkey)
    local server_public_key=$(grep "^PrivateKey" "$SERVER_CONF" | awk '{print $3}' | awg pubkey 2>/dev/null || echo "")

    # Формируем AllowedIPs
    local allowed_ips=""
    if [ -z "$resources" ]; then
        allowed_ips="0.0.0.0/0"
    else
        # Преобразуем домены в IP (если нужно)
        # Простейшая обработка: если ресурс содержит буквы, пытаемся разрешить через dig
        # Но для простоты оставим как есть, клиент сам будет резолвить? Лучше разрешить на сервере.
        # Для простоты будем считать, что пользователь вводит IP-адреса или подсети.
        # Можно добавить вызов dig для каждого.
        IFS=',' read -ra ADDR <<< "$resources"
        for res in "${ADDR[@]}"; do
            # Если содержит не цифры и точки, считаем доменом
            if [[ ! "$res" =~ ^[0-9\./]+$ ]]; then
                # Разрешаем домен в IP
                ip_resolved=$(dig +short "$res" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
                if [ -n "$ip_resolved" ]; then
                    allowed_ips="${allowed_ips}${ip_resolved}/32,"
                else
                    echo "Не удалось разрешить домен $res, пропускаем" >&2
                fi
            else
                allowed_ips="${allowed_ips}${res},"
            fi
        done
        allowed_ips=${allowed_ips%,}  # убираем последнюю запятую
    fi

    cat >> "$SERVER_CONF" <<EOF

# BEGIN_PEER $name
[Peer]
PublicKey = $public_key
AllowedIPs = $allowed_ips
# END_PEER $name
EOF
    awg syncconf awg0 "$SERVER_CONF"
    local client_conf="${CLIENTS_DIR}/${name}.conf"
    mkdir -p "$CLIENTS_DIR"
    cat > "$client_conf" <<EOF
[Interface]
PrivateKey = $private_key
Address = ${VPN_SUBNET}${ip}/32
DNS = 8.8.8.8, 1.1.1.1
MTU = 1420

[Peer]
PublicKey = $server_public_key
Endpoint = ${SERVER_PUBLIC_IP}:${SERVER_PORT}
AllowedIPs = $allowed_ips
PersistentKeepalive = 25
EOF
    qrencode -t png -o "${CLIENTS_DIR}/${name}.png" < "$client_conf"
    local expires=0
    if [ "$duration" -gt 0 ]; then
        expires=$(date +%s -d "+$duration seconds")
    fi
    jq --arg name "$name" --arg ip "$ip" --arg expires "$expires" --arg resources "$resources" '. + {($name): {"ip": $ip, "expires": $expires, "resources": $resources}}' "$META_FILE" > "${META_FILE}.tmp"
    mv "${META_FILE}.tmp" "$META_FILE"
    echo "Клиент $name добавлен. Конфиг: $client_conf, QR: ${CLIENTS_DIR}/${name}.png"
}

del_client() {
    local name=$1
    sed -i "/# BEGIN_PEER $name/,/# END_PEER $name/d" "$SERVER_CONF"
    awg syncconf awg0 "$SERVER_CONF"
    jq "del(.$name)" "$META_FILE" > "${META_FILE}.tmp" && mv "${META_FILE}.tmp" "$META_FILE"
    rm -f "${CLIENTS_DIR}/${name}.conf" "${CLIENTS_DIR}/${name}.png"
    echo "Клиент $name удалён."
}

list_clients() {
    if [ -f "$META_FILE" ]; then
        cat "$META_FILE"
    else
        echo "{}"
    fi
}

cleanup_expired() {
    local current=$(date +%s)
    for name in $(jq -r 'keys[]' "$META_FILE"); do
        local expires=$(jq -r ".\"$name\".expires" "$META_FILE")
        if [ "$expires" -gt 0 ] && [ "$expires" -lt "$current" ]; then
            del_client "$name"
        fi
    done
}

case "$1" in
    add)
        if [ -z "$2" ]; then echo "Использование: $0 add <имя> [duration_seconds] [resources]"; exit 1; fi
        add_client "$2" "$3" "$4"
        ;;
    add-temp)
        if [ -z "$2" ] || [ -z "$3" ]; then echo "Использование: $0 add-temp <имя> <seconds> [resources]"; exit 1; fi
        add_client "$2" "$3" "$4"
        ;;
    del)
        if [ -z "$2" ]; then echo "Использование: $0 del <имя>"; exit 1; fi
        del_client "$2"
        ;;
    list)
        list_clients
        ;;
    cleanup)
        cleanup_expired
        ;;
    *)
        echo "Неизвестная команда: $1"
        echo "Доступные: add, add-temp, del, list, cleanup"
        exit 1
        ;;
esac
