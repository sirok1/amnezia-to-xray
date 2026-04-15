#!/bin/bash

AMN_CONTAINER="amnezia-awg2"
AMN_GATEWAY="172.29.172.1"
AWG_IFACE="awg0"
AWG_SUBNET="10.8.1.0/24"
SOCKS_PORT="12346"
TUN_NAME="tun1"
TUN_GW="198.18.0.2/30"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[✓]${NC} $1"; }
fail() { echo -e "${RED}[✗]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }

echo ""
echo "══════════════════════════════════════"
echo "   Amnezia → Xray"
echo "══════════════════════════════════════"
echo ""

ERRORS=0

if ss -tlnup | grep -q ":$SOCKS_PORT"; then
    ok "Xray слушает socks порт $SOCKS_PORT"
else
    fail "Xray НЕ слушает порт $SOCKS_PORT — добавь inbound в 3x-ui"
    ERRORS=$((ERRORS+1))
fi

if docker exec "$AMN_CONTAINER" true 2>/dev/null; then
    ok "Контейнер $AMN_CONTAINER запущен"
else
    fail "Контейнер $AMN_CONTAINER недоступен"
    exit 1
fi

if docker exec "$AMN_CONTAINER" ping -c1 -W1 "$AMN_GATEWAY" >/dev/null 2>&1; then
    ok "Контейнер видит хост $AMN_GATEWAY"
else
    fail "Контейнер НЕ видит хост $AMN_GATEWAY"
    ERRORS=$((ERRORS+1))
fi

if [ ! -x /usr/local/bin/tun2socks ]; then
    warn "tun2socks не найден на хосте — копируем из контейнера..."
    docker cp "$AMN_CONTAINER":/usr/local/bin/tun2socks /usr/local/bin/tun2socks 2>/dev/null && \
    chmod +x /usr/local/bin/tun2socks && \
    ok "tun2socks скопирован на хост" || {
        warn "В контейнере нет — скачиваем..."
        wget -q --show-progress -O /tmp/tun2socks.zip \
            "https://github.com/xjasonlyu/tun2socks/releases/download/v2.6.0/tun2socks-linux-amd64.zip" && \
        cd /tmp && unzip -o tun2socks.zip tun2socks-linux-amd64 && \
        mv /tmp/tun2socks-linux-amd64 /usr/local/bin/tun2socks && \
        chmod +x /usr/local/bin/tun2socks && \
        docker cp /usr/local/bin/tun2socks "$AMN_CONTAINER":/usr/local/bin/tun2socks && \
        ok "tun2socks установлен" || { fail "Не удалось установить tun2socks"; ERRORS=$((ERRORS+1)); }
    }
else
    VER=$(tun2socks --version 2>&1 | head -1)
    ok "tun2socks на хосте: $VER"
fi

if docker exec "$AMN_CONTAINER" test -x /usr/local/bin/ipt2socks 2>/dev/null; then
    ok "ipt2socks установлен"
else
    warn "ipt2socks не найден — скачиваем..."
    wget -q --show-progress -O /tmp/ipt2socks \
        "https://github.com/zfl9/ipt2socks/releases/download/v1.1.4/ipt2socks%40x86_64-linux-musl%40x86_64" && \
    docker cp /tmp/ipt2socks "$AMN_CONTAINER":/usr/local/bin/ipt2socks && \
    docker exec "$AMN_CONTAINER" chmod +x /usr/local/bin/ipt2socks && \
    ok "ipt2socks установлен" || { fail "Не удалось установить ipt2socks"; ERRORS=$((ERRORS+1)); }
fi

if docker exec "$AMN_CONTAINER" test -c /dev/net/tun 2>/dev/null; then
    ok "/dev/net/tun доступен"
else
    fail "/dev/net/tun недоступен"
    ERRORS=$((ERRORS+1))
fi

NETNS_PID=$(docker inspect "$AMN_CONTAINER" --format '{{.State.Pid}}' 2>/dev/null)
if [ -n "$NETNS_PID" ] && [ "$NETNS_PID" != "0" ]; then
    ok "Network namespace контейнера: PID $NETNS_PID"
else
    fail "Не удалось получить PID контейнера"
    ERRORS=$((ERRORS+1))
    exit 1
fi

if pgrep -f "tun2socks.*$TUN_NAME" >/dev/null 2>&1; then
    ok "tun2socks процесс уже запущен"
else
    warn "tun2socks не запущен — запускаем через nsenter..."
    pkill -f "tun2socks.*$TUN_NAME" 2>/dev/null || true
    nsenter --net=/proc/$NETNS_PID/ns/net -- \
        ip link del "$TUN_NAME" 2>/dev/null || true
    sleep 1

    nsenter --net=/proc/$NETNS_PID/ns/net -- \
        tun2socks \
        -device "$TUN_NAME" \
        -proxy "socks5://$AMN_GATEWAY:$SOCKS_PORT" \
        -loglevel warn &

    TUN2SOCKS_PID=$!
    sleep 3

    if kill -0 $TUN2SOCKS_PID 2>/dev/null; then
        ok "tun2socks запущен (PID $TUN2SOCKS_PID)"
    else
        fail "tun2socks упал сразу после запуска"
        ERRORS=$((ERRORS+1))
    fi
fi

if nsenter --net=/proc/$NETNS_PID/ns/net -- \
        ip link show "$TUN_NAME" 2>/dev/null | grep -q "UP"; then
    ADDR=$(nsenter --net=/proc/$NETNS_PID/ns/net -- \
        ip addr show "$TUN_NAME" 2>/dev/null | grep "inet " | awk '{print $2}')
    ok "TUN интерфейс $TUN_NAME активен${ADDR:+ ($ADDR)}"
else
    warn "TUN интерфейс $TUN_NAME не поднят — настраиваем..."
    nsenter --net=/proc/$NETNS_PID/ns/net -- \
        ip addr add "$TUN_GW" dev "$TUN_NAME" 2>/dev/null || true
    nsenter --net=/proc/$NETNS_PID/ns/net -- \
        ip link set "$TUN_NAME" up && \
    ok "TUN интерфейс поднят" || \
    { fail "Не удалось поднять TUN"; ERRORS=$((ERRORS+1)); }
fi

if nsenter --net=/proc/$NETNS_PID/ns/net -- \
        ip route show table 200 2>/dev/null | grep -q "default"; then
    ok "Маршрут через TUN (table 200) настроен"
else
    warn "Маршрут не настроен — настраиваем..."
    nsenter --net=/proc/$NETNS_PID/ns/net -- \
        ip link set "$TUN_NAME" up 2>/dev/null || true
    nsenter --net=/proc/$NETNS_PID/ns/net -- \
        ip route add default dev "$TUN_NAME" table 200 && \
    ok "Маршрут настроен" || \
    { fail "Не удалось настроить маршрут"; ERRORS=$((ERRORS+1)); }
fi

if nsenter --net=/proc/$NETNS_PID/ns/net -- \
        ip rule show 2>/dev/null | grep -q "200"; then
    ok "ip rule для $AWG_SUBNET → table 200 активен"
else
    warn "ip rule не настроен — настраиваем..."
    nsenter --net=/proc/$NETNS_PID/ns/net -- \
        ip rule add from "$AWG_SUBNET" table 200 priority 100 && \
    ok "ip rule настроен" || \
    { fail "Не удалось настроить ip rule"; ERRORS=$((ERRORS+1)); }
fi

if docker exec "$AMN_CONTAINER" iptables -t nat -L POSTROUTING -n \
        2>/dev/null | grep -q "MASQUERADE"; then
    ok "iptables MASQUERADE настроен"
else
    warn "MASQUERADE не настроен — настраиваем..."
    docker exec "$AMN_CONTAINER" iptables -t nat -F 2>/dev/null || true
    docker exec "$AMN_CONTAINER" iptables -t nat -A POSTROUTING \
        -o eth1 -s "$AWG_SUBNET" -j MASQUERADE && \
    docker exec "$AMN_CONTAINER" iptables -t nat -A PREROUTING \
        -i "$AWG_IFACE" -p udp --dport 53 -j RETURN && \
    docker exec "$AMN_CONTAINER" iptables -t nat -A PREROUTING \
        -i "$AWG_IFACE" -p tcp --dport 53 -j RETURN && \
    ok "MASQUERADE настроен" || \
    { fail "Не удалось настроить MASQUERADE"; ERRORS=$((ERRORS+1)); }
fi

if docker exec "$AMN_CONTAINER" sh -c \
        "echo '' | nc -w2 $AMN_GATEWAY $SOCKS_PORT >/dev/null 2>&1"; then
    ok "Socks порт $SOCKS_PORT доступен из контейнера"
else
    fail "Socks порт $SOCKS_PORT НЕ доступен из контейнера"
    ERRORS=$((ERRORS+1))
fi

CPU=$(ps aux | awk '/xray-linux/ && !/awk/ {printf "%.0f", $3}' | head -1)
if [ "${CPU:-0}" -gt 50 ]; then
    fail "CPU xray высокий: ${CPU}% — возможна петля!"
    ERRORS=$((ERRORS+1))
else
    ok "CPU xray в норме: ${CPU}%"
fi

echo ""
echo "══════════════════════════════════════"
if [ "$ERRORS" -eq 0 ]; then
    echo -e "${GREEN}  Всё настроено корректно!${NC}"
    echo "  Проверь: docker exec 3x-ui tail -f access.log | grep amnezia"
else
    echo -e "${RED}  Обнаружено ошибок: $ERRORS${NC}"
fi
echo "══════════════════════════════════════"
echo ""
