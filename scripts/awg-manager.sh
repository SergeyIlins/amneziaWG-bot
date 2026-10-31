#!/bin/bash
set -e

SERVER_CONF="/etc/amnezia/amneziawg/awg0.conf"
META_FILE="/etc/amneziawg/clients_meta.json"
CLIENTS_DIR="/root/amneziawg-clients"

# АВТОМАТИЧЕСКОЕ ЧТЕНИЕ ПОРТА ИЗ КОНФИГА СЕРВЕРА
SERVER_PORT=$(grep "^ListenPort" "$SERVER_CONF" | awk -F'= ' '{print $2}')
SERVER_PORT=${SERVER_PORT:-443} # Если не найден, ставим 443 по умолчанию

SERVER_PUBLIC_IP=${SERVER_PUBLIC_IP:-"$(curl -s ifconfig.me)"}
VPN_SUBNET=${VPN_SUBNET:-"10.9.9."}

get_obfuscation_params() {
    local conf="$1"
    local in_interface=0
    local params=""
    while IFS= read -r line; do
        if [[ "$line" =~ ^\[Interface\] ]]; then in_interface=1; continue; fi
        if [[ "$line" =~ ^\[ ]] && [ $in_interface -eq 1 ]; then break; fi
        if [ $in_interface -eq 1 ]; then
            if [[ ! "$line" =~ ^(PrivateKey|Address|ListenPort|PostUp|PostDown|MTU|#) ]]; then
                if [[ ! "$line" =~ ^(I[1-5]|S[34])[[:space:]]*= ]]; then
                    if [ -n "$line" ]; then params="$params$line\n"; fi
                fi
            fi
        fi
    done < "$conf"
    echo -e "$params"
}

get_next_ip() {
    local last_ip=$(grep -oP "AllowedIPs = ${VPN_SUBNET}\K\d+" "$SERVER_CONF" | sort -n | tail -1)
    # Если last_ip пустой (клиентов нет), начинаем с 2.
    # Если есть, прибавляем 1.
    echo $(( ${last_ip:-1} + 1 ))
}

add_client() {
    local name=$1
    local duration=$2
    local ip=$(get_next_ip)
    if [ "$ip" -ge 255 ]; then echo "Нет свободных IP" >&2; return 1; fi
    
    local private_key=$(awg genkey)
    local public_key=$(echo "$private_key" | awg pubkey)
    local server_public_key=$(grep "^PrivateKey" "$SERVER_CONF" | awk '{print $3}' | awg pubkey)
    local client_ip="${VPN_SUBNET}${ip}"

    cat >> "$SERVER_CONF" <<EOT

# BEGIN_PEER $name
[Peer]
PublicKey = $public_key
AllowedIPs = $client_ip/32
# END_PEER $name
EOT

    awg-quick down awg0 2>/dev/null || true
    awg-quick up awg0

    local obf_params=$(get_obfuscation_params "$SERVER_CONF")
    mkdir -p "$CLIENTS_DIR"

    cat > "${CLIENTS_DIR}/${name}.conf" <<EOT
[Interface]
PrivateKey = $private_key
Address = $client_ip/24
DNS = 1.1.1.1, 8.8.8.8
MTU = 1280
$obf_params

[Peer]
PublicKey = $server_public_key
Endpoint = ${SERVER_PUBLIC_IP}:${SERVER_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOT

    qrencode -t png -o "${CLIENTS_DIR}/${name}.png" < "${CLIENTS_DIR}/${name}.conf"

    local expires=0
    if [ -n "$duration" ] && [ "$duration" -gt 0 ]; then
        expires=$(( $(date +%s) + duration ))
    fi

    if [ -f "$META_FILE" ] && [ -s "$META_FILE" ]; then
        jq --arg name "$name" --arg ip "$ip" --arg expires "$expires" '. + {($name): {"ip": $ip, "expires": $expires}}' "$META_FILE" > "${META_FILE}.tmp" && mv "${META_FILE}.tmp" "$META_FILE"
    else
        echo "{}" | jq --arg name "$name" --arg ip "$ip" --arg expires "$expires" '. + {($name): {"ip": $ip, "expires": $expires}}' > "$META_FILE"
    fi
    echo "Клиент $name добавлен. Порт: $SERVER_PORT."
}

del_client() {
    local name=$1
    sed -i "/# BEGIN_PEER $name/,/# END_PEER $name/d" "$SERVER_CONF" 2>/dev/null || true
    awg-quick down awg0 2>/dev/null || true
    awg-quick up awg0
    jq "del(.$name)" "$META_FILE" > "${META_FILE}.tmp" 2>/dev/null && mv "${META_FILE}.tmp" "$META_FILE"
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
