#!/usr/bin/env bash
#
# 3x-ui автоустановщик / 3x-ui auto-installer
# Ubuntu 22.04 / 24.04
#
# Что делает скрипт / What the script does:
#   * определяет систему, IP и характеристики железа
#   * ставит последнюю версию панели 3x-ui (MHSanaei/3x-ui)
#   * выпускает Let's Encrypt сертификат через <ip>.sslip.io (без своего домена)
#   * поднимает панель по HTTPS
#   * ставит и настраивает Nginx как TLS-фронт
#   * создаёт 4 инбаунда, подобранных под обход ТСПУ/DPI в РФ:
#       1) VLESS TCP Reality  (fingerprint firefox, flow xtls-rprx-vision, порт 8443)
#       2) VLESS gRPC   за Nginx, TLS, порт 2087
#       3) VLESS XHTTP  за Nginx, TLS, порт 2083
#       4) VLESS WebSocket за Nginx, TLS, порт 2096
#
# Использование / Usage:
#   sudo bash install.sh
#
set -o errexit
set -o nounset
set -o pipefail

# ----------------------------------------------------------------------------
# Цвета / Colors
# ----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
PLAIN='\033[0m'

# ----------------------------------------------------------------------------
# Глобальные параметры / Global parameters
# ----------------------------------------------------------------------------
LANG_CHOICE="ru"                       # ru | en, переопределяется в choose_language

PANEL_PORT="${XUI_PANEL_PORT:-2053}"   # порт веб-панели
WEB_BASE_PATH=""                       # случайный путь панели, задаётся ниже
PANEL_USER=""                          # логин панели
PANEL_PASS=""                          # пароль панели

REALITY_PORT=8443                      # VLESS TCP Reality
GRPC_PORT=2087                         # публичный TLS-порт (Nginx) для gRPC
XHTTP_PORT=2083                        # публичный TLS-порт (Nginx) для XHTTP
WS_PORT=2096                           # публичный TLS-порт (Nginx) для WebSocket

# внутренние (localhost) порты xray-инбаундов за Nginx
GRPC_INTERNAL=11087
XHTTP_INTERNAL=11083
WS_INTERNAL=11096

# пути / paths
XUI_BIN="/usr/local/x-ui/x-ui"
CERT_DIR=""                            # /root/cert/<domain>, задаётся после выбора домена
INFO_FILE="/root/3xui-install-info.txt"
NGINX_CONF="/etc/nginx/conf.d/3xui-proxy.conf"

# сетевые данные / network data
SERVER_IPV4=""
SERVER_IPV6=""
DOMAIN=""                              # <ip>.sslip.io
REALITY_DEST=""                        # host:443
REALITY_SNI=""                         # host

# служебные значения инбаундов / inbound runtime values
REALITY_PRIVATE_KEY=""
REALITY_PUBLIC_KEY=""
REALITY_SHORT_ID=""
GRPC_SERVICE_NAME=""
XHTTP_PATH=""
WS_PATH=""

# curl jar для сессии панели / cookie jar for panel session
COOKIE_JAR=""
PANEL_BASE_URL=""                      # https://domain:port/basepath/
CSRF_TOKEN=""

# ============================================================================
# i18n: t <key> [arg1] [arg2] ...
# Возвращает строку на выбранном языке. Подстановка через printf (%s).
# ============================================================================
t() {
    local key="$1"
    shift || true
    local ru="" en=""
    case "$key" in
        need_root)
            ru="Ошибка: запустите скрипт от root (sudo bash install.sh)."
            en="Error: run this script as root (sudo bash install.sh)." ;;
        lang_prompt)
            ru="" ; en="" ;;  # печатается напрямую в choose_language
        starting)
            ru="Запуск установщика 3x-ui..."
            en="Starting the 3x-ui installer..." ;;
        step_detect)
            ru="[1/8] Определение системы и характеристик сервера"
            en="[1/8] Detecting system and server specs" ;;
        step_domain)
            ru="[2/8] Подготовка домена sslip.io"
            en="[2/8] Preparing sslip.io domain" ;;
        step_base)
            ru="[3/8] Установка зависимостей"
            en="[3/8] Installing dependencies" ;;
        step_xui)
            ru="[4/8] Установка последней версии 3x-ui"
            en="[4/8] Installing the latest 3x-ui" ;;
        step_ssl)
            ru="[5/8] Выпуск Let's Encrypt сертификата через sslip.io"
            en="[5/8] Issuing Let's Encrypt certificate via sslip.io" ;;
        step_panel)
            ru="[6/8] Настройка панели и запуск по HTTPS"
            en="[6/8] Configuring the panel and enabling HTTPS" ;;
        step_nginx)
            ru="[7/8] Настройка Nginx (TLS-фронт для gRPC/XHTTP/WS)"
            en="[7/8] Configuring Nginx (TLS front for gRPC/XHTTP/WS)" ;;
        step_inbounds)
            ru="[8/8] Создание 4 инбаундов"
            en="[8/8] Creating 4 inbounds" ;;
        os_detected)
            ru="ОС: %s %s (%s)"
            en="OS: %s %s (%s)" ;;
        os_unsupported)
            ru="Внимание: поддерживаются Ubuntu 22.04/24.04. Обнаружено: %s %s. Продолжаю на свой риск."
            en="Warning: Ubuntu 22.04/24.04 are supported. Detected: %s %s. Continuing at your own risk." ;;
        not_ubuntu)
            ru="Ошибка: этот скрипт рассчитан на Ubuntu. Обнаружено: %s."
            en="Error: this script targets Ubuntu. Detected: %s." ;;
        cpu_info)
            ru="Процессор: %s ядер"
            en="CPU: %s core(s)" ;;
        ram_info)
            ru="Память: %s"
            en="RAM: %s" ;;
        disk_info)
            ru="Диск (/): %s свободно из %s"
            en="Disk (/): %s free of %s" ;;
        ipv4_info)
            ru="Публичный IPv4: %s"
            en="Public IPv4: %s" ;;
        ipv6_info)
            ru="Публичный IPv6: %s"
            en="Public IPv6: %s" ;;
        no_ipv4)
            ru="Ошибка: не удалось определить публичный IPv4. sslip.io требует IPv4."
            en="Error: could not determine a public IPv4. sslip.io requires IPv4." ;;
        domain_is)
            ru="Домен для сертификата: %s"
            en="Certificate domain: %s" ;;
        reality_target)
            ru="Цель (dest) для Reality подобрана автоматически: %s"
            en="Auto-selected Reality target (dest): %s" ;;
        reality_target_fallback)
            ru="Не удалось проверить кандидатов, использую цель по умолчанию: %s"
            en="Could not probe candidates, using default target: %s" ;;
        installing_base)
            ru="Устанавливаю пакеты: curl socat nginx openssl jq и др..."
            en="Installing packages: curl socat nginx openssl jq, etc..." ;;
        xui_installing)
            ru="Скачиваю и ставлю 3x-ui (это может занять пару минут)..."
            en="Downloading and installing 3x-ui (this may take a couple of minutes)..." ;;
        xui_failed)
            ru="Ошибка: установка 3x-ui не удалась."
            en="Error: 3x-ui installation failed." ;;
        xui_ok)
            ru="3x-ui установлен, версия: %s"
            en="3x-ui installed, version: %s" ;;
        ssl_issuing)
            ru="Выпускаю сертификат для %s (порт 80 должен быть открыт)..."
            en="Issuing certificate for %s (port 80 must be open)..." ;;
        ssl_failed)
            ru="Ошибка: не удалось выпустить сертификат. Проверьте, что порт 80 открыт и доступен извне."
            en="Error: failed to issue the certificate. Make sure port 80 is open and reachable from the internet." ;;
        ssl_ok)
            ru="Сертификат Let's Encrypt успешно выпущен и установлен."
            en="Let's Encrypt certificate issued and installed successfully." ;;
        panel_configuring)
            ru="Задаю логин/пароль, порт и путь панели, подключаю HTTPS..."
            en="Setting panel login/password, port and path, enabling HTTPS..." ;;
        panel_waiting)
            ru="Жду запуска панели..."
            en="Waiting for the panel to come up..." ;;
        panel_up)
            ru="Панель доступна по HTTPS."
            en="Panel is reachable over HTTPS." ;;
        panel_down)
            ru="Ошибка: панель не отвечает по HTTPS. Проверьте статус: x-ui status"
            en="Error: panel is not responding over HTTPS. Check status: x-ui status" ;;
        nginx_configuring)
            ru="Настраиваю Nginx и перезапускаю..."
            en="Configuring Nginx and reloading..." ;;
        nginx_failed)
            ru="Ошибка: проверка конфигурации Nginx не прошла."
            en="Error: Nginx configuration test failed." ;;
        login_failed)
            ru="Ошибка: не удалось войти в панель через API."
            en="Error: failed to log into the panel API." ;;
        inbound_creating)
            ru="Создаю инбаунд: %s"
            en="Creating inbound: %s" ;;
        inbound_ok)
            ru="  -> готово"
            en="  -> done" ;;
        inbound_fail)
            ru="  -> не удалось: %s"
            en="  -> failed: %s" ;;
        done_title)
            ru="УСТАНОВКА ЗАВЕРШЕНА"
            en="INSTALLATION COMPLETE" ;;
        summary_saved)
            ru="Все данные сохранены в файл: %s"
            en="All details saved to: %s" ;;
        *)
            ru="$key" ; en="$key" ;;
    esac
    local fmt
    if [[ "$LANG_CHOICE" == "ru" ]]; then fmt="$ru"; else fmt="$en"; fi
    # shellcheck disable=SC2059
    printf "$fmt" "$@"
}

log()    { echo -e "${GREEN}$(t "$@")${PLAIN}"; }
info()   { echo -e "${CYAN}$(t "$@")${PLAIN}"; }
warn()   { echo -e "${YELLOW}$(t "$@")${PLAIN}"; }
err()    { echo -e "${RED}$(t "$@")${PLAIN}" >&2; }
step()   { echo -e "\n${BOLD}${BLUE}$(t "$@")${PLAIN}"; }
die()    { err "$@"; exit 1; }

# ============================================================================
# Выбор языка / Language selection
# ============================================================================
choose_language() {
    # Неинтерактивный режим: язык из XUI_LANG, по умолчанию ru.
    if [[ ! -t 0 ]]; then
        LANG_CHOICE="${XUI_LANG:-ru}"
        return
    fi
    echo -e "${BOLD}${CYAN}"
    echo "==============================================="
    echo "   3x-ui installer / установщик 3x-ui"
    echo "==============================================="
    echo -e "${PLAIN}"
    echo "Choose installation language / Выберите язык установки:"
    echo "  1) English"
    echo "  2) Русский"
    local choice
    while true; do
        read -rp "Enter 1 or 2 / Введите 1 или 2 [2]: " choice
        choice="${choice:-2}"
        case "$choice" in
            1) LANG_CHOICE="en"; break ;;
            2) LANG_CHOICE="ru"; break ;;
            *) echo "Please enter 1 or 2 / Введите 1 или 2." ;;
        esac
    done
}

# ============================================================================
# Утилиты / Utilities
# ============================================================================
require_root() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || die need_root
}

rand_hex() { openssl rand -hex "${1:-8}"; }
rand_str() { openssl rand -base64 "$(( ${1:-16} * 2 ))" | tr -dc 'a-zA-Z0-9' | head -c "${1:-16}"; }

# ============================================================================
# Шаг 1. Определение системы / System detection
# ============================================================================
detect_system() {
    step step_detect

    [[ -f /etc/os-release ]] || die not_ubuntu "unknown"
    # shellcheck disable=SC1091
    source /etc/os-release
    local os_id="${ID:-unknown}" os_ver="${VERSION_ID:-?}" os_name="${PRETTY_NAME:-$os_id}"

    if [[ "$os_id" != "ubuntu" ]]; then
        die not_ubuntu "$os_name"
    fi
    info os_detected "$os_id" "$os_ver" "$(uname -m)"
    if [[ "$os_ver" != "22.04" && "$os_ver" != "24.04" ]]; then
        warn os_unsupported "$os_id" "$os_ver"
    fi

    local cores mem_total disk_avail disk_total
    cores="$(nproc 2>/dev/null || echo '?')"
    mem_total="$(free -h 2>/dev/null | awk '/^Mem:/{print $2}')"
    disk_avail="$(df -h / 2>/dev/null | awk 'NR==2{print $4}')"
    disk_total="$(df -h / 2>/dev/null | awk 'NR==2{print $2}')"
    info cpu_info "$cores"
    info ram_info "${mem_total:-?}"
    info disk_info "${disk_avail:-?}" "${disk_total:-?}"

    detect_ip
}

detect_ip() {
    local v4 v6
    v4="$(curl -fsS4 --max-time 8 https://api.ipify.org 2>/dev/null \
        || curl -fsS4 --max-time 8 https://ifconfig.me 2>/dev/null \
        || curl -fsS4 --max-time 8 https://ipinfo.io/ip 2>/dev/null || true)"
    v4="$(echo "$v4" | tr -d '[:space:]')"
    if [[ ! "$v4" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        # запасной вариант: определить исходящий IP через маршрут
        v4="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
    fi
    [[ "$v4" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die no_ipv4
    SERVER_IPV4="$v4"
    info ipv4_info "$SERVER_IPV4"

    v6="$(curl -fsS6 --max-time 6 https://api64.ipify.org 2>/dev/null || true)"
    v6="$(echo "$v6" | tr -d '[:space:]')"
    if [[ "$v6" == *:* ]]; then
        SERVER_IPV6="$v6"
        info ipv6_info "$SERVER_IPV6"
    fi
}

# ============================================================================
# Шаг 2. Домен sslip.io и цель Reality / sslip.io domain & Reality target
# ============================================================================
prepare_domain() {
    step step_domain
    # sslip.io: A.B.C.D.sslip.io -> A.B.C.D. Никакой собственный домен не нужен.
    DOMAIN="${SERVER_IPV4}.sslip.io"
    CERT_DIR="/root/cert/${DOMAIN}"
    info domain_is "$DOMAIN"

    pick_reality_target
}

# Подбор реального сайта-цели для Reality среди крупных стабильных доменов.
pick_reality_target() {
    local candidates=(
        "www.microsoft.com"
        "www.samsung.com"
        "www.mozilla.org"
        "www.icloud.com"
        "dl.google.com"
        "www.nvidia.com"
    )
    local host
    for host in "${candidates[@]}"; do
        if timeout 6 openssl s_client -connect "${host}:443" -servername "$host" \
                -tls1_3 </dev/null 2>/dev/null | grep -q "TLSv1.3"; then
            REALITY_SNI="$host"
            REALITY_DEST="${host}:443"
            info reality_target "$REALITY_DEST"
            return
        fi
    done
    REALITY_SNI="www.microsoft.com"
    REALITY_DEST="www.microsoft.com:443"
    warn reality_target_fallback "$REALITY_DEST"
}

# ============================================================================
# Шаг 3. Базовые пакеты / Base packages
# ============================================================================
install_base() {
    step step_base
    log installing_base
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y -q
    apt-get install -y -q \
        curl wget tar socat cron openssl ca-certificates \
        jq uuid-runtime nginx ufw iproute2 dnsutils
}

# ============================================================================
# Шаг 4. Установка 3x-ui / Install 3x-ui
# ============================================================================
install_xui() {
    step step_xui
    log xui_installing
    # Неинтерактивная установка последней версии с генерацией случайных данных.
    XUI_NONINTERACTIVE=1 bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) \
        >/tmp/3xui-install.log 2>&1 || {
            tail -n 40 /tmp/3xui-install.log >&2 || true
            die xui_failed
        }
    [[ -x "$XUI_BIN" ]] || die xui_failed
    local ver
    ver="$("$XUI_BIN" -v 2>/dev/null | head -n1 || echo '?')"
    log xui_ok "$ver"
}

# ============================================================================
# Шаг 5. SSL через Let's Encrypt + sslip.io / SSL via Let's Encrypt + sslip.io
# ============================================================================
setup_ssl() {
    step step_ssl

    if [[ ! -f "$HOME/.acme.sh/acme.sh" ]]; then
        curl -s https://get.acme.sh | sh -s -- --home "$HOME/.acme.sh" >/dev/null 2>&1
    fi
    local acme="$HOME/.acme.sh/acme.sh"
    [[ -x "$acme" ]] || die ssl_failed

    "$acme" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
    if [[ -n "${XUI_ACME_EMAIL:-}" ]]; then
        "$acme" --register-account -m "$XUI_ACME_EMAIL" >/dev/null 2>&1 || true
    fi

    mkdir -p "$CERT_DIR"

    # Порт 80 нужен на время HTTP-01. Освобождаем nginx, если он занял его.
    systemctl stop nginx >/dev/null 2>&1 || true

    log ssl_issuing "$DOMAIN"
    if ! "$acme" --issue -d "$DOMAIN" --standalone --httpport 80 --server letsencrypt --force; then
        systemctl start nginx >/dev/null 2>&1 || true
        die ssl_failed
    fi

    "$acme" --installcert --force -d "$DOMAIN" \
        --key-file       "$CERT_DIR/privkey.pem" \
        --fullchain-file "$CERT_DIR/fullchain.pem" \
        --reloadcmd      "systemctl restart x-ui >/dev/null 2>&1; nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true" \
        >/dev/null 2>&1 || true

    "$acme" --upgrade --auto-upgrade >/dev/null 2>&1 || true
    chmod 600 "$CERT_DIR/privkey.pem"  2>/dev/null || true
    chmod 644 "$CERT_DIR/fullchain.pem" 2>/dev/null || true

    [[ -s "$CERT_DIR/fullchain.pem" && -s "$CERT_DIR/privkey.pem" ]] || die ssl_failed
    log ssl_ok
}

# ============================================================================
# Шаг 6. Настройка панели / Panel configuration
# ============================================================================
configure_panel() {
    step step_panel
    log panel_configuring

    PANEL_USER="admin_$(rand_str 6)"
    PANEL_PASS="$(rand_str 20)"
    WEB_BASE_PATH="$(rand_str 12)"

    "$XUI_BIN" setting \
        -port "$PANEL_PORT" \
        -username "$PANEL_USER" \
        -password "$PANEL_PASS" \
        -webBasePath "/${WEB_BASE_PATH}/" >/dev/null 2>&1

    # HTTPS для панели
    "$XUI_BIN" cert \
        -webCert "$CERT_DIR/fullchain.pem" \
        -webCertKey "$CERT_DIR/privkey.pem" >/dev/null 2>&1

    systemctl restart x-ui
    systemctl enable x-ui >/dev/null 2>&1 || true

    PANEL_BASE_URL="https://${DOMAIN}:${PANEL_PORT}/${WEB_BASE_PATH}/"

    log panel_waiting
    for _ in $(seq 1 30); do
        if curl -fsS -k --max-time 5 "${PANEL_BASE_URL}" >/dev/null 2>&1; then
            log panel_up
            return
        fi
        sleep 2
    done
    die panel_down
}

# ============================================================================
# Шаг 7. Nginx как TLS-фронт для gRPC/XHTTP/WS / Nginx TLS front
# ============================================================================
configure_nginx() {
    step step_nginx
    log nginx_configuring

    GRPC_SERVICE_NAME="grpc$(rand_hex 4)"
    XHTTP_PATH="/xh$(rand_hex 4)"
    WS_PATH="/ws$(rand_hex 4)"

    cat > "$NGINX_CONF" <<EOF
# 3x-ui reverse proxy (сгенерировано install.sh)
# TLS терминируется Nginx, трафик уходит на локальные xray-инбаунды.

# --- gRPC (порт ${GRPC_PORT}) ---
# http2 задаётся в listen ради совместимости с Nginx < 1.25 (Ubuntu 22.04/24.04).
server {
    listen ${GRPC_PORT} ssl http2;
    listen [::]:${GRPC_PORT} ssl http2;
    server_name ${DOMAIN};

    ssl_certificate     ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    location /${GRPC_SERVICE_NAME} {
        grpc_pass grpc://127.0.0.1:${GRPC_INTERNAL};
        grpc_set_header Host \$host;
        grpc_read_timeout 1h;
        grpc_send_timeout 1h;
        client_max_body_size 0;
    }
    location / { return 404; }
}

# --- XHTTP (порт ${XHTTP_PORT}) ---
server {
    listen ${XHTTP_PORT} ssl http2;
    listen [::]:${XHTTP_PORT} ssl http2;
    server_name ${DOMAIN};

    ssl_certificate     ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    location ${XHTTP_PATH} {
        proxy_pass http://127.0.0.1:${XHTTP_INTERNAL};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_request_buffering off;
        proxy_buffering off;
        proxy_read_timeout 1h;
        client_max_body_size 0;
    }
    location / { return 404; }
}

# --- WebSocket (порт ${WS_PORT}) ---
# Без http2: WebSocket использует HTTP/1.1 Upgrade.
server {
    listen ${WS_PORT} ssl;
    listen [::]:${WS_PORT} ssl;
    server_name ${DOMAIN};

    ssl_certificate     ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    location ${WS_PATH} {
        proxy_pass http://127.0.0.1:${WS_INTERNAL};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 1h;
        proxy_send_timeout 1h;
    }
    location / { return 404; }
}
EOF

    nginx -t >/dev/null 2>&1 || { nginx -t >&2 || true; die nginx_failed; }
    systemctl enable nginx >/dev/null 2>&1 || true
    systemctl restart nginx
}

# ============================================================================
# Firewall / брандмауэр
# ============================================================================
configure_firewall() {
    command -v ufw >/dev/null 2>&1 || return 0
    # Не трогаем ufw, если он не активен, чтобы не заблокировать SSH случайно.
    if ! ufw status 2>/dev/null | grep -q "Status: active"; then
        return 0
    fi
    local p
    for p in 22 80 "$PANEL_PORT" "$REALITY_PORT" "$GRPC_PORT" "$XHTTP_PORT" "$WS_PORT"; do
        ufw allow "${p}/tcp" >/dev/null 2>&1 || true
    done
}

# ============================================================================
# Шаг 8. Работа с API панели / Panel API helpers
# ============================================================================
api_login() {
    COOKIE_JAR="$(mktemp)"
    # 1) получить CSRF-токен (публичный GET, заводит сессию)
    CSRF_TOKEN="$(curl -fsS -k -c "$COOKIE_JAR" --max-time 10 \
        "${PANEL_BASE_URL}csrf-token" 2>/dev/null | jq -r '.obj // empty')"
    # 2) залогиниться (username/password + CSRF)
    local resp
    resp="$(curl -fsS -k -b "$COOKIE_JAR" -c "$COOKIE_JAR" --max-time 15 \
        -H "X-CSRF-Token: ${CSRF_TOKEN}" \
        --data-urlencode "username=${PANEL_USER}" \
        --data-urlencode "password=${PANEL_PASS}" \
        "${PANEL_BASE_URL}login" 2>/dev/null || true)"
    [[ "$(echo "$resp" | jq -r '.success // false' 2>/dev/null)" == "true" ]] || return 1
    # 3) обновить CSRF-токен уже в авторизованной сессии
    CSRF_TOKEN="$(curl -fsS -k -b "$COOKIE_JAR" -c "$COOKIE_JAR" --max-time 10 \
        "${PANEL_BASE_URL}csrf-token" 2>/dev/null | jq -r '.obj // empty')"
    return 0
}

# GET к API панели (безопасный метод, CSRF не нужен)
api_get() {
    curl -fsS -k -b "$COOKIE_JAR" --max-time 15 "${PANEL_BASE_URL}panel/api/${1}" 2>/dev/null
}

# POST JSON к API панели с CSRF
api_post_json() {
    local path="$1" data="$2"
    curl -fsS -k -b "$COOKIE_JAR" -c "$COOKIE_JAR" --max-time 20 \
        -H "X-CSRF-Token: ${CSRF_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "$data" \
        "${PANEL_BASE_URL}panel/api/${path}" 2>/dev/null
}

new_uuid() {
    local u
    u="$(api_get "server/getNewUUID" | jq -r '.obj // empty')"
    [[ -n "$u" ]] || u="$(cat /proc/sys/kernel/random/uuid)"
    echo "$u"
}

gen_reality_keys() {
    local resp
    resp="$(api_get "server/getNewX25519Cert")"
    REALITY_PRIVATE_KEY="$(echo "$resp" | jq -r '.obj.privateKey // empty')"
    REALITY_PUBLIC_KEY="$(echo "$resp" | jq -r '.obj.publicKey // empty')"
    [[ -n "$REALITY_PRIVATE_KEY" && -n "$REALITY_PUBLIC_KEY" ]]
}

add_inbound() {
    local name="$1" payload="$2"
    info inbound_creating "$name"
    local resp ok
    resp="$(api_post_json "inbounds/add" "$payload")"
    ok="$(echo "$resp" | jq -r '.success // false' 2>/dev/null)"
    if [[ "$ok" == "true" ]]; then
        log inbound_ok
        return 0
    fi
    warn inbound_fail "$(echo "$resp" | jq -r '.msg // "unknown error"' 2>/dev/null)"
    return 1
}

# ============================================================================
# Создание инбаундов / Create inbounds
# ============================================================================
create_inbounds() {
    step step_inbounds
    api_login || die login_failed
    gen_reality_keys || die login_failed
    REALITY_SHORT_ID="$(rand_hex 4)"

    local u_reality u_grpc u_xhttp u_ws
    u_reality="$(new_uuid)"
    u_grpc="$(new_uuid)"
    u_xhttp="$(new_uuid)"
    u_ws="$(new_uuid)"

    # 1) VLESS TCP Reality — fingerprint firefox, flow xtls-rprx-vision, порт 8443
    local reality_payload
    reality_payload="$(jq -nc \
        --arg remark "VLESS-Reality-TCP" \
        --argjson port "$REALITY_PORT" \
        --arg id "$u_reality" \
        --arg dest "$REALITY_DEST" \
        --arg sni "$REALITY_SNI" \
        --arg priv "$REALITY_PRIVATE_KEY" \
        --arg pub "$REALITY_PUBLIC_KEY" \
        --arg sid "$REALITY_SHORT_ID" \
        '{
          enable: true, remark: $remark, listen: "", port: $port,
          protocol: "vless", expiryTime: 0, total: 0,
          settings: {
            clients: [ { id: $id, email: "reality", flow: "xtls-rprx-vision", enable: true } ],
            decryption: "none", fallbacks: []
          },
          streamSettings: {
            network: "tcp",
            tcpSettings: { header: { type: "none" } },
            security: "reality",
            realitySettings: {
              show: false, xver: 0, target: $dest,
              serverNames: [ $sni ],
              privateKey: $priv, shortIds: [ $sid ],
              settings: { publicKey: $pub, fingerprint: "firefox", serverName: "", spiderX: "/" }
            }
          },
          sniffing: { enabled: true, destOverride: ["http","tls","quic"] }
        }')"
    add_inbound "VLESS TCP Reality (:$REALITY_PORT)" "$reality_payload" || true

    # 2) VLESS gRPC за Nginx (xray слушает 127.0.0.1, TLS снимает Nginx)
    local grpc_payload
    grpc_payload="$(jq -nc \
        --arg remark "VLESS-gRPC-Nginx" \
        --argjson port "$GRPC_INTERNAL" \
        --arg id "$u_grpc" \
        --arg svc "$GRPC_SERVICE_NAME" \
        '{
          enable: true, remark: $remark, listen: "127.0.0.1", port: $port,
          protocol: "vless", expiryTime: 0, total: 0,
          settings: { clients: [ { id: $id, email: "grpc", flow: "", enable: true } ], decryption: "none", fallbacks: [] },
          streamSettings: {
            network: "grpc",
            grpcSettings: { serviceName: $svc, multiMode: false },
            security: "none"
          },
          sniffing: { enabled: true, destOverride: ["http","tls","quic"] }
        }')"
    add_inbound "VLESS gRPC (:$GRPC_PORT via Nginx)" "$grpc_payload" || true

    # 3) VLESS XHTTP за Nginx
    local xhttp_payload
    xhttp_payload="$(jq -nc \
        --arg remark "VLESS-XHTTP-Nginx" \
        --argjson port "$XHTTP_INTERNAL" \
        --arg id "$u_xhttp" \
        --arg path "$XHTTP_PATH" \
        --arg host "$DOMAIN" \
        '{
          enable: true, remark: $remark, listen: "127.0.0.1", port: $port,
          protocol: "vless", expiryTime: 0, total: 0,
          settings: { clients: [ { id: $id, email: "xhttp", flow: "", enable: true } ], decryption: "none", fallbacks: [] },
          streamSettings: {
            network: "xhttp",
            xhttpSettings: { path: $path, host: $host, mode: "auto" },
            security: "none"
          },
          sniffing: { enabled: true, destOverride: ["http","tls","quic"] }
        }')"
    add_inbound "VLESS XHTTP (:$XHTTP_PORT via Nginx)" "$xhttp_payload" || true

    # 4) VLESS WebSocket за Nginx
    local ws_payload
    ws_payload="$(jq -nc \
        --arg remark "VLESS-WS-Nginx" \
        --argjson port "$WS_INTERNAL" \
        --arg id "$u_ws" \
        --arg path "$WS_PATH" \
        --arg host "$DOMAIN" \
        '{
          enable: true, remark: $remark, listen: "127.0.0.1", port: $port,
          protocol: "vless", expiryTime: 0, total: 0,
          settings: { clients: [ { id: $id, email: "ws", flow: "", enable: true } ], decryption: "none", fallbacks: [] },
          streamSettings: {
            network: "ws",
            wsSettings: { path: $path, host: $host },
            security: "none"
          },
          sniffing: { enabled: true, destOverride: ["http","tls","quic"] }
        }')"
    add_inbound "VLESS WebSocket (:$WS_PORT via Nginx)" "$ws_payload" || true

    # Сохранить готовые ссылки/данные для клиентов
    write_summary "$u_reality" "$u_grpc" "$u_xhttp" "$u_ws"
}

# ============================================================================
# Итоговая сводка / Final summary
# ============================================================================
write_summary() {
    local u_reality="$1" u_grpc="$2" u_xhttp="$3" u_ws="$4"

    local reality_link
    reality_link="vless://${u_reality}@${DOMAIN}:${REALITY_PORT}?type=tcp&security=reality&pbk=${REALITY_PUBLIC_KEY}&fp=firefox&sni=${REALITY_SNI}&sid=${REALITY_SHORT_ID}&spx=%2F&flow=xtls-rprx-vision#VLESS-Reality-TCP"
    local grpc_link
    grpc_link="vless://${u_grpc}@${DOMAIN}:${GRPC_PORT}?type=grpc&serviceName=${GRPC_SERVICE_NAME}&security=tls&sni=${DOMAIN}&fp=firefox#VLESS-gRPC"
    local xhttp_link
    xhttp_link="vless://${u_xhttp}@${DOMAIN}:${XHTTP_PORT}?type=xhttp&path=${XHTTP_PATH}&host=${DOMAIN}&mode=auto&security=tls&sni=${DOMAIN}&fp=firefox#VLESS-XHTTP"
    local ws_link
    ws_link="vless://${u_ws}@${DOMAIN}:${WS_PORT}?type=ws&path=${WS_PATH}&host=${DOMAIN}&security=tls&sni=${DOMAIN}&fp=firefox#VLESS-WS"

    {
        echo "=================== 3x-ui ==================="
        echo "Panel URL : ${PANEL_BASE_URL}"
        echo "Username  : ${PANEL_USER}"
        echo "Password  : ${PANEL_PASS}"
        echo "Domain    : ${DOMAIN}"
        echo "Server IP : ${SERVER_IPV4}"
        echo
        echo "--- Inbounds / client links ---"
        echo "1) VLESS TCP Reality (:${REALITY_PORT})"
        echo "   ${reality_link}"
        echo
        echo "2) VLESS gRPC (:${GRPC_PORT}, Nginx TLS)"
        echo "   serviceName=${GRPC_SERVICE_NAME}"
        echo "   ${grpc_link}"
        echo
        echo "3) VLESS XHTTP (:${XHTTP_PORT}, Nginx TLS)"
        echo "   path=${XHTTP_PATH}"
        echo "   ${xhttp_link}"
        echo
        echo "4) VLESS WebSocket (:${WS_PORT}, Nginx TLS)"
        echo "   path=${WS_PATH}"
        echo "   ${ws_link}"
        echo "============================================="
    } > "$INFO_FILE"
    chmod 600 "$INFO_FILE" 2>/dev/null || true

    print_final "$reality_link" "$grpc_link" "$xhttp_link" "$ws_link"
}

print_final() {
    echo
    echo -e "${BOLD}${GREEN}==================================================${PLAIN}"
    echo -e "${BOLD}${GREEN}   $(t done_title)${PLAIN}"
    echo -e "${BOLD}${GREEN}==================================================${PLAIN}"
    echo -e "${BOLD}Panel:${PLAIN} ${CYAN}${PANEL_BASE_URL}${PLAIN}"
    echo -e "${BOLD}Login:${PLAIN} ${PANEL_USER}"
    echo -e "${BOLD}Pass :${PLAIN} ${PANEL_PASS}"
    echo
    echo -e "${BOLD}1) VLESS TCP Reality (:${REALITY_PORT})${PLAIN}"
    echo -e "   ${1}"
    echo -e "${BOLD}2) VLESS gRPC (:${GRPC_PORT}, Nginx)${PLAIN}"
    echo -e "   ${2}"
    echo -e "${BOLD}3) VLESS XHTTP (:${XHTTP_PORT}, Nginx)${PLAIN}"
    echo -e "   ${3}"
    echo -e "${BOLD}4) VLESS WebSocket (:${WS_PORT}, Nginx)${PLAIN}"
    echo -e "   ${4}"
    echo
    log summary_saved "$INFO_FILE"
    rm -f "$COOKIE_JAR" 2>/dev/null || true
}

# ============================================================================
# main
# ============================================================================
main() {
    require_root
    choose_language
    log starting
    detect_system
    prepare_domain
    install_base
    install_xui
    setup_ssl
    configure_panel
    configure_nginx
    configure_firewall
    create_inbounds
}

main "$@"
