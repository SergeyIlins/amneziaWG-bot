#!/bin/bash
# Управление клиентами AmneziaWG с глобальным списком ресурсов

set -e

SERVER_CONF="/etc/amneziawg/awg0.conf"
META_FILE="/etc/amneziawg/clients_meta.json"
CLIENTS_DIR="/root/amneziawg-clients"
GLOBAL_RESOURCES="/etc/amneziawg/global_resources.txt"

SERVER_PUBLIC_IP=${SERVER_PUBLIC_IP:-"$(curl -s ifconfig.me)"}
SERVER_PORT=${SERVER_PORT:-443}
VPN_SUBNET=${VPN_SUBNET:-"10.0.0."}

# Функция для получения глобального AllowedIPs
get_global_allowed_ips() {
    local allowed=""
    if [ -f "$GLOBAL_RESOURCES" ] && [ -s "$GLOBAL_RESOURCES" ]; then
        while IFS= read -r res; do
            [ -z "$res" ] && continue
            # Если ресурс похож на домен (содержит буквы и не является IP), разрешаем
            if [[ ! "$res" =~ ^[0-9\./]+$ ]]; then
                # Разрешаем домен в IP
                ip_resolved=$(dig +short "$res" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
                if [ -n "$ip_resolved" ]; then
                    allowed="${allowed}${ip_resolved}/32,"
                else
                    echo "Не удалось разрешить домен $res, пропускаем" >&2
                fi
            else
                allowed="${allowed}${res},"
            fi
        done < "$GLOBAL_RESOURCES"
        # Убираем последнюю запятую
        allowed=${allowed%,}
    fi
    if [ -z "$allowed" ]; then
        echo "0.0.0.0/0"
    else
        echo "$allowed"
    fi
}

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
    local ip=$(get_next_ip)
    if [ -z "$ip" ] || [ "$ip" -ge 255 ]; then
        echo "Нет свободных IP" >&2
        return 1
    fi
    local private_key=$(awg genkey)
    local public_key=$(echo "$private_key" | awg pubkey)
    local server_public_key=$(grep "^PrivateKey" "$SERVER_CONF" | awk '{print $3}' | awg pubkey 2>/dev/null || echo "")

    # Формируем AllowedIPs из глобального списка
    local allowed_ips=$(get_global_allowed_ips)

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
    # Сохраняем в метаданные также список ресурсов, которые были применены
    local resources=$(cat "$GLOBAL_RESOURCES" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
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
        if [ -z "$2" ]; then echo "Использование: $0 add <имя> [duration_seconds]"; exit 1; fi
        add_client "$2" "$3"
        ;;
    add-temp)
        if [ -z "$2" ] || [ -z "$3" ]; then echo "Использование: $0 add-temp <имя> <seconds>"; exit 1; fi
        add_client "$2" "$3"
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
