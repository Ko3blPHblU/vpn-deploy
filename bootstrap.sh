#!/usr/bin/env bash
# bootstrap.sh — первичная подготовка чистого VPS (Debian 12/13, Ubuntu 22.04+).
# Обновления, SSH, ufw, fail2ban, sysctl. Запуск: sudo bash bootstrap.sh [путь к node.conf]
# SSH остаётся на порту 22; вход по паролю отключается только при заданном ключе.
set -Eeuo pipefail
umask 077
export LC_ALL=C.UTF-8 DEBIAN_FRONTEND=noninteractive

say()  { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[ОШИБКА] %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die 'Запуск от root (sudo).'
. /etc/os-release
case "${ID:-}" in debian|ubuntu) ;; *) die "Неподдерживаемая ОС: ${ID:-unknown}" ;; esac

CONF="${1:-}"
if [[ -z "$CONF" ]]; then
    for c in ./node.conf /opt/vpn-deploy/node.conf; do [[ -f "$c" ]] && CONF="$c" && break; done
fi
ADMIN_USER=deploy; ADMIN_PUBKEY=''; DISABLE_PASSWORD_AUTH=0
EXTRA_PORTS=''; SKIP_UPGRADE=0; TZ=UTC
if [[ -n "$CONF" ]]; then
    say "Конфиг: $CONF"
    # shellcheck disable=SC1090
    source "$CONF"
else
    warn 'node.conf не найден — используются значения по умолчанию.'
fi
(( DISABLE_PASSWORD_AUTH )) && [[ -z "$ADMIN_PUBKEY" ]] && \
    die 'DISABLE_PASSWORD_AUTH=1 без ADMIN_PUBKEY — потеряете доступ. Отказ.'

say 'Обновление списка пакетов и установка базовых утилит...'
apt-get update -qq
apt-get install -y -qq ufw fail2ban curl ca-certificates jq unzip openssl \
    unattended-upgrades apt-listchanges >/dev/null
if (( SKIP_UPGRADE )); then warn 'apt-get upgrade пропущен (SKIP_UPGRADE=1).'
else
    say 'Обновление системы (может занять минуту)...'
    apt-get upgrade -y -qq >/dev/null
fi

say "Часовой пояс: $TZ"
timedatectl set-timezone "$TZ" || warn "Не удалось установить TZ=$TZ"

say 'Автоматические обновления безопасности...'
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

say 'sysctl: ip_forward + BBR...'
cat > /etc/sysctl.d/99-vpn-node.conf <<'EOF'
net.ipv4.ip_forward = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
sysctl -p /etc/sysctl.d/99-vpn-node.conf >/dev/null

if [[ -n "$ADMIN_PUBKEY" ]]; then
    say "Пользователь $ADMIN_USER с ключом SSH..."
    id "$ADMIN_USER" &>/dev/null || useradd -m -s /bin/bash "$ADMIN_USER"
    usermod -aG sudo "$ADMIN_USER"
    install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "/home/$ADMIN_USER/.ssh"
    printf '%s\n' "$ADMIN_PUBKEY" > "/home/$ADMIN_USER/.ssh/authorized_keys"
    chmod 600 "/home/$ADMIN_USER/.ssh/authorized_keys"
    chown "$ADMIN_USER:$ADMIN_USER" "/home/$ADMIN_USER/.ssh/authorized_keys"
else
    warn 'ADMIN_PUBKEY не задан — пользователь не создан, SSH не меняется.'
fi

if (( DISABLE_PASSWORD_AUTH )); then
    say 'Отключение входа по паролю (ключ уже добавлен)...'
    install -d -m 755 /etc/ssh/sshd_config.d
    printf 'PasswordAuthentication no\n' > /etc/ssh/sshd_config.d/99-vpn-node.conf
    sshd -t || die 'sshd -t: конфигурация SSH невалидна, изменения НЕ применены.'
    systemctl reload ssh || systemctl reload sshd || true
fi

say 'ufw: политики и порты...'
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow 22/tcp >/dev/null          # SSH — всегда первым, иначе потеря доступа
ufw allow 80/tcp >/dev/null          # ACME / Caddy
ufw allow 443/tcp >/dev/null
ufw allow 443/udp >/dev/null
for p in $EXTRA_PORTS; do ufw allow "$p" >/dev/null; done
ufw --force enable >/dev/null

say 'fail2ban: защита sshd...'
cat > /etc/fail2ban/jail.d/vpn-node.conf <<'EOF'
[sshd]
enabled = true
maxretry = 5
bantime = 1h
EOF
systemctl enable --now fail2ban >/dev/null 2>&1 || true
systemctl restart fail2ban

say 'Готово. Проверьте: ufw status verbose; fail2ban-client status sshd'
warn 'Перед закрытием сессии откройте НОВОЕ подключение и убедитесь, что SSH работает.'
