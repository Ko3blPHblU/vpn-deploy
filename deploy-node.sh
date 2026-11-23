#!/usr/bin/env bash
# deploy-node.sh — установка роли ноды: panel | exit | entry (Remnawave).
# Debian 12/13, Ubuntu 22.04+; root; systemd; публичный VPS.
# Порядок: sudo bash bootstrap.sh, затем sudo bash deploy-node.sh [путь к node.conf].
# Реквизиты читаются из node.conf; чего не хватает — спрашивается интерактивно.
set -Eeuo pipefail
umask 077
export LC_ALL=C.UTF-8 DEBIAN_FRONTEND=noninteractive

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
STATE=/opt/vpn-deploy
STEP='инициализация'

say()  { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[ОШИБКА] %s\n' "$*" >&2; exit 1; }
trap 'rc=$?; (( rc )) && printf "[ОШИБКА] Шаг [%s] прерван (код %s). Лог: %s\n" "$STEP" "$rc" "$STATE/deploy-node.log" >&2' EXIT

usage() {
    cat <<'EOF'
Использование: sudo bash deploy-node.sh [путь к node.conf]
  node.conf также ищется в ./node.conf, рядом со скриптом и /opt/vpn-deploy/node.conf.
  NODE_ROLE=panel  — панель Remnawave + PostgreSQL + Valkey + Caddy (HTTPS, «стук»).
  NODE_ROLE=exit   — выходная нода (remnawave-node за границей); при заданном
                     SELFSTEAL_DOMAIN — также nginx+certbot selfsteal-стек
                     и генерация config-profile для панели.
  NODE_ROLE=entry  — входная нода (РФ) + генерация config-profile каскада на выходы.
EOF
}

# --- аргументы и конфиг ------------------------------------------------------
CONF=''
while (( $# )); do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        *) [[ -z "$CONF" ]] && CONF="$1" || { usage; die "Лишний аргумент: $1"; } ;;
    esac
    shift
done
if [[ -z "$CONF" ]]; then
    for c in ./node.conf "$HERE/node.conf" "$STATE/node.conf"; do [[ -f "$c" ]] && CONF="$c" && break; done
fi

# значения по умолчанию (до source, чтобы не поймать set -u)
NODE_ROLE=''; NODE_NAME=node; TZ=UTC
ADMIN_USER=deploy; ADMIN_PUBKEY=''; DISABLE_PASSWORD_AUTH=0; EXTRA_PORTS=''; SKIP_UPGRADE=0
PANEL_DOMAIN=''; PANEL_KNOCK=''; SUB_DOMAIN=''; REMNAWAVE_API_TOKEN=''
SITE_DOMAIN=''; SITE_DIR=/opt/site
REMNA_NODE_COMPOSE_B64=''
EXIT1_LINK=''; EXIT2_LINK=''
ENTRY_REALITY_TARGET=www.microsoft.com:443; ENTRY_SNI=www.microsoft.com
ENTRY_PORT=443; ENTRY_PORT2=1443
# роль exit: selfsteal-стек и генерация профиля
SELFSTEAL_DOMAIN=''; SELFSTEAL_PORT=9443; ACME_EMAIL=''
EXIT_PORT=443; EXIT_XHTTP_PATH=/t1; EXIT_TAG=''

if [[ -n "$CONF" ]]; then
    [[ -f "$CONF" ]] || die "Конфиг не найден: $CONF"
    say "Конфиг: $CONF"
    # shellcheck disable=SC1090
    source "$CONF"
else
    warn 'node.conf не найден — недостающее будет спрошено интерактивно.'
fi

[[ $EUID -eq 0 ]] || die 'Запуск от root (sudo).'
. /etc/os-release
case "${ID:-}" in debian|ubuntu) ;; *) die "Неподдерживаемая ОС: ${ID:-unknown}" ;; esac

ask() { # ask VAR "подсказка" [secret] — спросить, если переменная пуста
    local var=$1 prompt=$2 secret=${3:-} v
    [[ -n "${!var}" ]] && return 0
    [[ -t 0 ]] || return 0
    if [[ -n "$secret" ]]; then read -rsp "$prompt: " v; echo; else read -rp "$prompt: " v; fi
    printf -v "$var" '%s' "$v"
}

STEP='подготовка каталога состояния'
install -d -m 700 "$STATE"
exec > >(tee -a "$STATE/deploy-node.log") 2>&1
say "=== deploy-node.sh $(date -Is) | роль: ${NODE_ROLE:-?} | нода: $NODE_NAME ==="

save_conf() { # собранные реквизиты — в $STATE/node.conf (только root)
    {
        printf 'NODE_ROLE=%q\n' "$NODE_ROLE"
        printf 'NODE_NAME=%q\n' "$NODE_NAME"
        printf 'TZ=%q\n' "$TZ"
        printf 'PANEL_DOMAIN=%q\n' "$PANEL_DOMAIN"
        printf 'PANEL_KNOCK=%q\n' "$PANEL_KNOCK"
        printf 'SUB_DOMAIN=%q\n' "$SUB_DOMAIN"
        printf 'REMNAWAVE_API_TOKEN=%q\n' "$REMNAWAVE_API_TOKEN"
        printf 'SITE_DOMAIN=%q\n' "$SITE_DOMAIN"
        printf 'SITE_DIR=%q\n' "$SITE_DIR"
        printf 'REMNA_NODE_COMPOSE_B64=%q\n' "$REMNA_NODE_COMPOSE_B64"
        printf 'EXIT1_LINK=%q\n' "$EXIT1_LINK"
        printf 'EXIT2_LINK=%q\n' "$EXIT2_LINK"
        printf 'ENTRY_REALITY_TARGET=%q\n' "$ENTRY_REALITY_TARGET"
        printf 'ENTRY_SNI=%q\n' "$ENTRY_SNI"
        printf 'ENTRY_PORT=%q\n' "$ENTRY_PORT"
        printf 'ENTRY_PORT2=%q\n' "$ENTRY_PORT2"
        # ACME_EMAIL сознательно не сохраняем: личный адрес не храним (см. AGENTS.md)
        printf 'SELFSTEAL_DOMAIN=%q\n' "$SELFSTEAL_DOMAIN"
        printf 'SELFSTEAL_PORT=%q\n' "$SELFSTEAL_PORT"
        printf 'EXIT_PORT=%q\n' "$EXIT_PORT"
        printf 'EXIT_XHTTP_PATH=%q\n' "$EXIT_XHTTP_PATH"
        printf 'EXIT_TAG=%q\n' "$EXIT_TAG"
    } > "$STATE/node.conf"
    chmod 600 "$STATE/node.conf"
}

ensure_docker() {
    STEP='установка Docker'
    if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
        say 'Docker уже установлен.'
    else
        say 'Установка Docker (get.docker.com)...'
        curl -fsSL https://get.docker.com | sh
        systemctl enable --now docker
    fi
}

# --- роль: panel -------------------------------------------------------------
install_panel() {
    ask PANEL_DOMAIN 'Домен панели (A-запись на этот сервер, напр. panel.example.com)'
    [[ -n "$PANEL_DOMAIN" ]] || die 'PANEL_DOMAIN обязателен: панель работает только за HTTPS-прокси.'
    [[ -n "$PANEL_KNOCK" ]] || PANEL_KNOCK=$(openssl rand -hex 16)
    save_conf

    ensure_docker
    STEP='файлы панели Remnawave'
    install -d -m 700 /opt/remnawave
    cd /opt/remnawave
    local new_env=0
    if [[ ! -f docker-compose.yml ]]; then
        curl -fsSL -o docker-compose.yml \
            https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/docker-compose-prod.yml
    fi
    if [[ ! -f .env ]]; then
        curl -fsSL -o .env \
            https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/.env.sample
        new_env=1
    fi

    if (( new_env )); then
        STEP='секреты и домены в .env'
        local app_secret metrics_pass webhook_secret pg_pass sub_public
        app_secret=$(openssl rand -hex 48)
        metrics_pass=$(openssl rand -hex 24)
        webhook_secret=$(openssl rand -hex 32)   # ровно 64 символа [0-9a-f] — требование панели
        pg_pass=$(openssl rand -hex 24)
        if [[ -n "$SUB_DOMAIN" ]]; then sub_public="$SUB_DOMAIN"; else sub_public="$PANEL_DOMAIN/api/sub"; fi
        sed -i "s|^APP_SECRET=.*|APP_SECRET=$app_secret|" .env
        sed -i "s|^METRICS_PASS=.*|METRICS_PASS=$metrics_pass|" .env
        sed -i "s|^WEBHOOK_SECRET_HEADER=.*|WEBHOOK_SECRET_HEADER=$webhook_secret|" .env
        sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$pg_pass|" .env
        sed -i "s|^\(DATABASE_URL=\"postgresql://postgres:\)[^@]*\(@.*\"\)|\1$pg_pass\2|" .env
        sed -i "s|^PANEL_DOMAIN=.*|PANEL_DOMAIN=$PANEL_DOMAIN|" .env
        sed -i "s|^FRONT_END_DOMAIN=.*|FRONT_END_DOMAIN=$PANEL_DOMAIN|" .env
        sed -i "s|^SUB_PUBLIC_DOMAIN=.*|SUB_PUBLIC_DOMAIN=$sub_public|" .env
        say '.env заполнен случайными секретами (в консоль не выводятся).'
    else
        say '.env уже существует — оставлен без изменений.'
    fi

    STEP='Caddy: HTTPS + «стук» по секретной ссылке'
    cat > Caddyfile <<EOF
$PANEL_DOMAIN {
	@knock query rw=$PANEL_KNOCK
	@gate header Cookie *rw_gate=$PANEL_KNOCK*
	route {
		header @knock Set-Cookie "rw_gate=$PANEL_KNOCK; Path=/; Max-Age=2592000; HttpOnly; Secure; SameSite=Lax"
		reverse_proxy @knock remnawave:3000
		reverse_proxy @gate remnawave:3000
		abort
	}
}
EOF
    if [[ -n "$SUB_DOMAIN" && -n "$REMNAWAVE_API_TOKEN" ]]; then
        cat >> Caddyfile <<EOF

$SUB_DOMAIN {
	reverse_proxy remnawave-subscription-page:3010
}
EOF
    elif [[ -n "$SUB_DOMAIN" ]]; then
        warn 'SUB_DOMAIN задан, но REMNAWAVE_API_TOKEN пуст — страница подписок пропущена.'
        warn 'Создайте токен в панели (Settings → API Tokens), заполните конфиг и перезапустите.'
    fi

    if [[ -n "$SITE_DOMAIN" ]]; then
        local site_auth=''
        if [[ -f /etc/caddy/site.users ]]; then
            site_auth='
	basic_auth {
		import /etc/caddy/site.users
	}'
        else
            warn 'SITE_DOMAIN задан, но /etc/caddy/site.users не найден — сайт открыт без basic_auth.'
        fi
        cat >> Caddyfile <<EOF

# Сайт-прикрытие (selfsteal): публично на 443 и локально на 9443
# (9443 — target для Reality-входов, публикуется только на 127.0.0.1).
$SITE_DOMAIN {
	root * /srv/site$site_auth
	header Cache-Control "private, no-store"
	file_server
}

https://$SITE_DOMAIN:9443 {
	root * /srv/site$site_auth
	header Cache-Control "private, no-store"
	file_server
}
EOF
    fi

    local site_ports='' site_vols=''
    if [[ -n "$SITE_DOMAIN" ]]; then
        site_ports='
      - "127.0.0.1:9443:9443"'
        site_vols="
      - $SITE_DIR:/srv/site:ro"
        if [[ -f /etc/caddy/site.users ]]; then
            site_vols+='
      - /etc/caddy/site.users:/etc/caddy/site.users:ro'
        fi
    fi

    cat > docker-compose.override.yml <<EOF
services:
  caddy:
    image: caddy:2
    container_name: remnawave-caddy
    restart: always
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"$site_ports
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy-data:/data
      - caddy-config:/config$site_vols
    networks:
      - remnawave-network
EOF
    if [[ -n "$SUB_DOMAIN" && -n "$REMNAWAVE_API_TOKEN" ]]; then
        cat >> docker-compose.override.yml <<EOF

  remnawave-subscription-page:
    image: remnawave/subscription-page:latest
    container_name: remnawave-subscription-page
    restart: always
    environment:
      - APP_PORT=3010
      - REMNAWAVE_PANEL_URL=http://remnawave:3000
      - REMNAWAVE_API_TOKEN=$REMNAWAVE_API_TOKEN
      - TRUST_PROXY=1
    networks:
      - remnawave-network

volumes:
  caddy-data:
  caddy-config:
EOF
    else
        cat >> docker-compose.override.yml <<EOF

volumes:
  caddy-data:
  caddy-config:
EOF
    fi

    STEP='запуск панели'
    docker compose pull -q || warn 'pull: не все образы скачались, compose попробует сам.'
    docker compose up -d

    STEP='проверка панели'
    local i ok=0
    for i in $(seq 1 45); do
        if curl -fsS -o /dev/null http://localhost:3001/health; then ok=1; break; fi
        sleep 2
    done
    (( ok )) || die 'Панель не отвечает на /health. Смотрите: docker compose -f /opt/remnawave/docker-compose.yml logs'
    docker compose ps

    STEP='сохранение реквизитов'
    local sub_line
    if [[ -n "$SUB_DOMAIN" ]]; then
        sub_line="https://$SUB_DOMAIN/"
    else
        sub_line="не настроена (SUB_DOMAIN пуст)"
    fi
    cat > /opt/remnawave/credentials.txt <<EOF
Панель Remnawave ($NODE_NAME)
=============================
URL первого входа:  https://$PANEL_DOMAIN/?rw=$PANEL_KNOCK
  Первый зарегистрировавшийся пользователь становится супер-админом —
  откройте ссылку сами до того, как её найдёт кто-то ещё.
  После «стука» ставится cookie rw_gate на 30 дней; дальше вход
  по обычному адресу https://$PANEL_DOMAIN/
Страница подписок:  $sub_line
Консоль восстановления: docker exec -it remnawave remnawave
Логи:   cd /opt/remnawave && docker compose logs -f
EOF
    chmod 600 /opt/remnawave/credentials.txt
    say 'Готово. Реквизиты: /opt/remnawave/credentials.txt'
}

# --- роль: exit / entry — нода Remnawave --------------------------------------
install_node() {
    ensure_docker
    STEP='нода Remnawave'
    install -d -m 700 /opt/remnanode
    cd /opt/remnanode
    if [[ -n "$REMNA_NODE_COMPOSE_B64" ]]; then
        printf '%s' "$REMNA_NODE_COMPOSE_B64" | base64 -d > docker-compose.yml \
            || die 'REMNA_NODE_COMPOSE_B64 не декодируется как base64.'
        grep -qi 'remnawave' docker-compose.yml \
            || die 'Декодированный файл не похож на compose ноды Remnawave.'
        chmod 600 docker-compose.yml
        docker compose up -d
        docker compose ps
        say 'Нода запущена. В панели: Nodes → статус должен стать Online.'
    else
        warn 'REMNA_NODE_COMPOSE_B64 пуст — нода НЕ запущена.'
        cat <<'EOF'
    Что сделать:
    1. В панели: Nodes → Management → «+», создайте ноду для этого сервера.
    2. Скопируйте сгенерированный docker-compose.yml.
    3. На своём ПК:  base64 -w0 node-compose.yml   → вставьте строку
       в node.conf (REMNA_NODE_COMPOSE_B64=...) и перезапустите deploy-node.sh.
       Либо просто положите файл в /opt/remnanode/docker-compose.yml
       и выполните:  cd /opt/remnanode && docker compose up -d
EOF
    fi
    save_conf
}

# --- роль: exit — selfsteal-стек (nginx + certbot + заглушка) -----------------
setup_selfsteal() {
    [[ -n "$SELFSTEAL_DOMAIN" ]] || return 0
    STEP='selfsteal: пакеты'
    apt-get update -qq
    apt-get install -y -qq nginx certbot curl >/dev/null

    STEP='selfsteal: сайт-заглушка'
    install -d -m 755 /var/www/selfsteal
    if [[ ! -f /var/www/selfsteal/index.html ]]; then
        printf '<!DOCTYPE html><html><head><title>Welcome</title></head><body><h1>It works</h1></body></html>\n' \
            > /var/www/selfsteal/index.html
    fi

    STEP='selfsteal: nginx (порт 80 под ACME)'
    cat > /etc/nginx/sites-available/selfsteal <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $SELFSTEAL_DOMAIN;
    root /var/www/selfsteal;
    index index.html;
    location / { try_files \$uri \$uri/ =404; }
}
EOF
    ln -sf /etc/nginx/sites-available/selfsteal /etc/nginx/sites-enabled/selfsteal
    rm -f /etc/nginx/sites-enabled/default
    nginx -t
    systemctl enable --now nginx
    systemctl reload nginx

    STEP="selfsteal: сертификат Let's Encrypt"
    if [[ -f "/etc/letsencrypt/live/$SELFSTEAL_DOMAIN/fullchain.pem" ]]; then
        say 'Сертификат уже есть — выпуск пропущен.'
    else
        local -a email_args=(--register-unsafely-without-email)
        [[ -n "$ACME_EMAIL" ]] && email_args=(--email "$ACME_EMAIL")
        certbot certonly --webroot -w /var/www/selfsteal -d "$SELFSTEAL_DOMAIN" \
            -n --agree-tos "${email_args[@]}" \
            || die "certbot не выпустил сертификат для $SELFSTEAL_DOMAIN (A-запись в DNS на этот сервер? порт 80 открыт?)"
    fi

    STEP='selfsteal: nginx (TLS-заглушка на 127.0.0.1)'
    cat > /etc/nginx/sites-available/selfsteal-ssl <<EOF
server {
    listen 127.0.0.1:$SELFSTEAL_PORT ssl http2;
    server_name $SELFSTEAL_DOMAIN;
    ssl_certificate     /etc/letsencrypt/live/$SELFSTEAL_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$SELFSTEAL_DOMAIN/privkey.pem;
    ssl_protocols TLSv1.3;
    root /var/www/selfsteal;
    index index.html;
    location / { try_files \$uri \$uri/ =404; }
}
EOF
    ln -sf /etc/nginx/sites-available/selfsteal-ssl /etc/nginx/sites-enabled/selfsteal-ssl
    nginx -t
    systemctl reload nginx

    STEP='selfsteal: хук продления сертификата'
    install -d -m 755 /etc/letsencrypt/renewal-hooks/deploy
    cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'EOF'
#!/bin/bash
systemctl reload nginx
EOF
    chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

    STEP='selfsteal: самопроверка заглушки'
    # Без -k: curl сам проверяет сертификат по домену — 200 значит, что отвечает
    # именно наш LE-сертификат и наш сайт.
    if [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
            --resolve "$SELFSTEAL_DOMAIN:$SELFSTEAL_PORT:127.0.0.1" \
            "https://$SELFSTEAL_DOMAIN:$SELFSTEAL_PORT")" == "200" ]]; then
        say "Заглушка на 127.0.0.1:$SELFSTEAL_PORT отвечает сертификатом $SELFSTEAL_DOMAIN."
    else
        warn 'Самопроверка не прошла. Диагностика:'
        { ss -tlnp | grep ":$SELFSTEAL_PORT" || echo "порт $SELFSTEAL_PORT никто не слушает"; } >&2
        curl -v --max-time 10 --resolve "$SELFSTEAL_DOMAIN:$SELFSTEAL_PORT:127.0.0.1" \
            "https://$SELFSTEAL_DOMAIN:$SELFSTEAL_PORT" 2>&1 | tail -20 >&2 || true
        die "Заглушка на 127.0.0.1:$SELFSTEAL_PORT не отвечает сертификатом $SELFSTEAL_DOMAIN."
    fi
}

# --- роль: exit — config-profile для панели -----------------------------------
exit_profile() {
    [[ -n "$SELFSTEAL_DOMAIN" ]] || return 0
    local gen="$HERE/gen_exit_profile.py"
    [[ -f "$gen" ]] || { warn "Не найден $gen — профиль пропущен."; return 0; }
    command -v python3 >/dev/null || { STEP='установка python3'; apt-get update -qq && apt-get install -y -qq python3 >/dev/null; }
    command -v openssl  >/dev/null || { apt-get update -qq && apt-get install -y -qq openssl  >/dev/null; }

    [[ -n "$EXIT_TAG" ]] || EXIT_TAG="exit-transit-$NODE_NAME"
    STEP='генерация config-profile выходной ноды'
    local out="$STATE/exit-profile-$NODE_NAME.json"
    python3 "$gen" --tag "$EXIT_TAG" --port "$EXIT_PORT" --path "$EXIT_XHTTP_PATH" \
        --target "127.0.0.1:$SELFSTEAL_PORT" --sni "$SELFSTEAL_DOMAIN" --out "$out"
    chmod 600 "$out"
    cat <<EOF
[+] Дальше в панели:
    1. Config Profiles → создать профиль (напр. exit-$NODE_NAME), вставить JSON из
       $out
    2. Назначить профиль этой ноде (Nodes → $NODE_NAME → Config profile).
    3. Hosts: для каскада — Address = IP этого сервера, порт $EXIT_PORT,
       SNI = $SELFSTEAL_DOMAIN, fp firefox; для прямого выхода — Address = $SELFSTEAL_DOMAIN.
    ВНИМАНИЕ: тег $EXIT_TAG должен быть уникален среди ВСЕХ профилей панели.
EOF
}

install_exit() {
    setup_selfsteal
    install_node
    exit_profile
}

# --- роль: entry — профиль каскада -------------------------------------------
entry_profile() {
    [[ -n "$EXIT1_LINK" ]] || { warn 'EXIT1_LINK пуст — config-profile не генерируется.'; return 0; }
    local gen="$HERE/gen_entry_profile.py"
    [[ -f "$gen" ]] || { warn "Не найден $gen — профиль пропущен."; return 0; }
    command -v python3 >/dev/null || { STEP='установка python3'; apt-get update -qq && apt-get install -y -qq python3 >/dev/null; }
    command -v openssl  >/dev/null || { apt-get update -qq && apt-get install -y -qq openssl  >/dev/null; }

    STEP='генерация config-profile входной ноды'
    local step=1000
    if (( ENTRY_PORT2 > ENTRY_PORT )); then step=$(( ENTRY_PORT2 - ENTRY_PORT )); fi
    local -a args=(--exit "$EXIT1_LINK" --target "$ENTRY_REALITY_TARGET" --sni "$ENTRY_SNI"
                   --port "$ENTRY_PORT" --port-step "$step"
                   --out "$STATE/entry-config-profile.json")
    [[ -n "$EXIT2_LINK" ]] && args+=(--exit "$EXIT2_LINK")
    python3 "$gen" "${args[@]}"
    chmod 600 "$STATE/entry-config-profile.json" "$STATE/entry-config-profile.json.links.txt"
    cat <<EOF
[+] Дальше в панели:
    1. Config Profiles → создать профиль, вставить JSON из
       $STATE/entry-config-profile.json
    2. Назначить профиль этой входной ноде и нужным пользователям.
    3. Клиентские ссылки для проверки: $STATE/entry-config-profile.json.links.txt
       (в обычном режиме клиенты получают конфиги через подписку панели).
EOF
}

# --- запуск -------------------------------------------------------------------
STEP="роль $NODE_ROLE"
case "$NODE_ROLE" in
    panel) install_panel ;;
    exit)  install_exit ;;
    entry) install_node; entry_profile ;;
    '')    usage; die 'NODE_ROLE не задана (panel | exit | entry).' ;;
    *)     die "Неизвестная NODE_ROLE: $NODE_ROLE (panel | exit | entry)" ;;
esac

trap - EXIT
say "=== Готово $(date -Is) ==="
