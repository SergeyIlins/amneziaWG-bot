#!/bin/bash
# Управление клиентами AmneziaWG (полный туннель)

set -e
SERVER_CONF="/etc/amneziawg/awg0.conf"
META_FILE="/etc/amneziawg/clients_meta.json"
CLIENTS_DIR="/root/amneziawg-clients"
SERVER_PUBLIC_IP=${SERVER_PUBLIC_IP:-"$(curl -s ifconfig.me)"}
SERVER_PORT=${SERVER_PORT:-443}
VPN_SUBNET=${VPN_SUBNET:-"10.9.9."}

get_next_ip() {
    local last_ip=$(grep -oP "AllowedIPs = ${VPN_SUBNET}\K\d+" "$SERVER_CONF" | sort -n | tail -1)
    echo ${last_ip:-2}
}

add_client() {
    local name=$1
    local duration=$2
    local ip=$(get_next_ip)
    if [ "$ip" -ge 255 ]; then echo "Нет свободных IP" >&2; return 1; fi
    local private_key=$(awg genkey)
    local public_key=$(echo "$private_key" | awg pubkey)
    local server_public_key=$(grep "^PrivateKey" "$SERVER_CONF" | awk '{print $3}' | awg pubkey)
    cat >> "$SERVER_CONF" <<EOF

# BEGIN_PEER $name
[Peer]
PublicKey = $public_key
AllowedIPs = ${VPN_SUBNET}${ip}/32
# END_PEER $name
EOF
    awg syncconf awg0 "$SERVER_CONF"
    mkdir -p "$CLIENTS_DIR"
    cat > "${CLIENTS_DIR}/${name}.conf" <<EOF
[Interface]
PrivateKey = $private_key
Address = ${VPN_SUBNET}${ip}/32
DNS = 8.8.8.8, 1.1.1.1
MTU = 1280

[Peer]
PublicKey = $server_public_key
Endpoint = ${SERVER_PUBLIC_IP}:${SERVER_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
    qrencode -t png -o "${CLIENTS_DIR}/${name}.png" < "${CLIENTS_DIR}/${name}.conf"
    local expires=0
    [ "$duration" -gt 0 ] && expires=$(date +%s -d "+$duration seconds")
    jq --arg name "$name" --arg ip "$ip" --arg expires "$expires" '. + {($name): {"ip": $ip, "expires": $expires}}' "$META_FILE" > "${META_FILE}.tmp" && mv "${META_FILE}.tmp" "$META_FILE"
    echo "Клиент $name добавлен. Конфиг: ${CLIENTS_DIR}/${name}.conf, QR: ${CLIENTS_DIR}/${name}.png"
}

del_client() {
    local name=$1
    sed -i "/# BEGIN_PEER $name/,/# END_PEER $name/d" "$SERVER_CONF"
    awg syncconf awg0 "$SERVER_CONF"
    jq "del(.$name)" "$META_FILE" > "${META_FILE}.tmp" && mv "${META_FILE}.tmp" "$META_FILE"
    rm -f "${CLIENTS_DIR}/${name}.conf" "${CLIENTS_DIR}/${name}.png"
    echo "Клиент $name удалён."
}

list_clients() { [ -f "$META_FILE" ] && cat "$META_FILE" || echo "{}"; }

cleanup_expired() {
    local current=$(date +%s)
    for name in $(jq -r 'keys[]' "$META_FILE"); do
        local expires=$(jq -r ".\"$name\".expires" "$META_FILE")
        [ "$expires" -gt 0 ] && [ "$expires" -lt "$current" ] && del_client "$name"
    done
}

case "$1" in
    add) [ -z "$2" ] && echo "Использование: $0 add <имя> [duration_seconds]" && exit 1; add_client "$2" "$3" ;;
    add-temp) [ -z "$2" ] || [ -z "$3" ] && echo "Использование: $0 add-temp <имя> <seconds>" && exit 1; add_client "$2" "$3" ;;
    del) [ -z "$2" ] && echo "Использование: $0 del <имя>" && exit 1; del_client "$2" ;;
    list) list_clients ;;
    cleanup) cleanup_expired ;;
    *) echo "Доступные: add, add-temp, del, list, cleanup"; exit 1 ;;
esac
