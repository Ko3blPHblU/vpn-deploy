#!/usr/bin/env python3
"""Генерация config-profile Remnawave для выходной ноды (selfsteal).

Собирает полный конфиг xray: один вход VLESS+XHTTP+Reality,
target — локальная заглушка selfsteal (127.0.0.1:9443),
outbounds freedom/blackhole, приватные адреса -> block.
Приватный ключ Reality генерируется локально через openssl (X25519),
формат как у `xray x25519`; публичный ключ панель выводит сама.
"""
import argparse
import base64
import json
import subprocess
import sys


def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode().rstrip('=')


def x25519_private() -> str:
    """Сырой приватный ключ X25519 через openssl; формат как у `xray x25519`."""
    pem = subprocess.run(['openssl', 'genpkey', '-algorithm', 'X25519'],
                         capture_output=True, check=True).stdout
    priv = subprocess.run(['openssl', 'pkey', '-outform', 'DER'],
                          input=pem, capture_output=True, check=True).stdout[-32:]
    return b64url(priv)


def build_config(tag: str, port: int, path: str, target: str, sni: str, priv: str) -> dict:
    return {
        'log': {'loglevel': 'warning'},
        'inbounds': [{
            'tag': tag,
            'listen': '0.0.0.0',
            'port': port,
            'protocol': 'vless',
            'settings': {'clients': [], 'decryption': 'none'},
            'streamSettings': {
                'network': 'xhttp',
                'xhttpSettings': {'path': path},
                'security': 'reality',
                'realitySettings': {
                    'target': target,
                    'serverNames': [sni],
                    'privateKey': priv,
                    'shortIds': ['00'],
                },
            },
            'sniffing': {'enabled': True, 'destOverride': ['http', 'tls', 'quic']},
        }],
        'outbounds': [
            {'protocol': 'freedom', 'tag': 'direct'},
            {'protocol': 'blackhole', 'tag': 'block'},
        ],
        'routing': {
            'domainStrategy': 'IPIfNonMatch',
            'rules': [{
                'type': 'field',
                'ip': ['geoip:private'],
                'outboundTag': 'block',
            }],
        },
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--tag', required=True, help='тег инбаунда (уникален среди ВСЕХ профилей панели)')
    ap.add_argument('--port', type=int, default=443)
    ap.add_argument('--path', default='/t1', help='путь XHTTP')
    ap.add_argument('--target', required=True, help='realitySettings.target, напр. 127.0.0.1:9443')
    ap.add_argument('--sni', required=True, help='домен выхода (serverNames)')
    ap.add_argument('--out', required=True, help='куда записать JSON профиля')
    a = ap.parse_args()

    priv = x25519_private()
    config = build_config(a.tag, a.port, a.path, a.target, a.sni, priv)
    with open(a.out, 'w', encoding='utf-8') as f:
        json.dump(config, f, ensure_ascii=False, indent=2)
        f.write('\n')
    print(f'[+] Профиль записан: {a.out}')
    print(f'    tag={a.tag} port={a.port} path={a.path} target={a.target} sni={a.sni}')
    print('    ВНИМАНИЕ: файл содержит приватный ключ Reality — хранить как секрет.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
