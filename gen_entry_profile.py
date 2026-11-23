#!/usr/bin/env python3
"""Генерация config-profile Remnawave для входной ноды (каскад I -> O).

Читает vless://-ссылки на выходы (из панели, транзитный пользователь),
собирает полный конфиг xray: два входа VLESS+XHTTP+Reality (по одному на
каждый выход), outbounds на выходы, маршрутизация RU -> DIRECT.
Ключи Reality генерируются локально через openssl (X25519).
"""
import argparse
import base64
import json
import subprocess
import sys
import urllib.parse
import uuid as uuidlib


def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode().rstrip('=')


def x25519_keypair():
    """Сырой ключ X25519 через openssl; формат как у `xray x25519`."""
    pem = subprocess.run(['openssl', 'genpkey', '-algorithm', 'X25519'],
                         capture_output=True, check=True).stdout
    priv = subprocess.run(['openssl', 'pkey', '-outform', 'DER'],
                          input=pem, capture_output=True, check=True).stdout[-32:]
    pub = subprocess.run(['openssl', 'pkey', '-pubout', '-outform', 'DER'],
                         input=pem, capture_output=True, check=True).stdout[-32:]
    return b64url(priv), b64url(pub)


def parse_vless(link: str) -> dict:
    u = urllib.parse.urlparse(link.strip())
    if u.scheme != 'vless':
        raise ValueError(f'Ожидалась vless-ссылка, получено: {u.scheme or link[:20]}')
    q = dict(urllib.parse.parse_qsl(u.query))
    port = u.port or 443
    outbound = {
        'protocol': 'vless',
        'settings': {'vnext': [{
            'address': u.hostname,
            'port': port,
            'users': [{'id': u.username, 'encryption': q.get('encryption', 'none'),
                       **({'flow': q['flow']} if q.get('flow') else {})}],
        }]},
        'streamSettings': {
            'network': q.get('type', 'xhttp'),
            'security': q.get('security', 'reality'),
        },
        'tag': '',
    }
    net = outbound['streamSettings']['network']
    if net == 'xhttp':
        outbound['streamSettings']['xhttpSettings'] = {
            'path': q.get('path', '/'),
            **({'mode': q['mode']} if q.get('mode') else {}),
        }
    elif net == 'ws':
        outbound['streamSettings']['wsSettings'] = {
            'path': q.get('path', '/'),
            'headers': {'Host': q.get('host', u.hostname)},
        }
    elif net == 'tcp':
        pass
    else:
        raise ValueError(f'Неподдержанный транспорт в ссылке: {net}')
    if outbound['streamSettings']['security'] == 'reality':
        outbound['streamSettings']['realitySettings'] = {
            'serverName': q.get('sni', ''),
            'publicKey': q.get('pbk', ''),
            'shortId': q.get('sid', ''),
            'fingerprint': q.get('fp', 'firefox'),
        }
    elif outbound['streamSettings']['security'] == 'tls':
        outbound['streamSettings']['tlsSettings'] = {
            'serverName': q.get('sni', u.hostname),
            'fingerprint': q.get('fp', 'firefox'),
        }
    return outbound


def inbound(tag: str, port: int, uid: str, priv: str, target: str, sni: str, path: str) -> dict:
    return {
        'tag': tag,
        'listen': '0.0.0.0',
        'port': port,
        'protocol': 'vless',
        'settings': {'clients': [{'id': uid, 'flow': ''}], 'decryption': 'none'},
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
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--exit', action='append', required=True,
                    help='vless-ссылка на выход (можно несколько, порядок = приоритет)')
    ap.add_argument('--target', default='www.microsoft.com:443')
    ap.add_argument('--sni', default='www.microsoft.com')
    ap.add_argument('--port', type=int, default=443, help='порт входа для первого выхода')
    ap.add_argument('--port-step', type=int, default=1000,
                    help='шаг порта для следующих выходов (443, 1443, ...)')
    ap.add_argument('--path-prefix', default='/t',
                    help='префикс секретных путей XHTTP (/t1, /t2, ...)')
    ap.add_argument('--out', required=True, help='куда записать JSON профиля')
    a = ap.parse_args()

    exits = [parse_vless(link) for link in a.exit]
    priv, pub = x25519_keypair()

    inbounds, rules, creds = [], [], []
    for i, out in enumerate(exits, start=1):
        tag_in, tag_out = f'entry-o{i}', f'exit-o{i}'
        out['tag'] = tag_out
        uid = str(uuidlib.uuid4())
        port = a.port + (i - 1) * a.port_step
        path = f'{a.path_prefix}{i}'
        inbounds.append(inbound(tag_in, port, uid, priv, a.target, a.sni, path))
        rules.append({'type': 'field', 'inboundTag': [tag_in], 'outboundTag': tag_out})
        host = urllib.parse.urlparse(a.exit[i - 1]).hostname
        creds.append(
            f'O{i}: vless://{uid}@<IP_ЭТОЙ_НОДЫ>:{port}'
            f'?encryption=none&security=reality&type=xhttp&path={path}'
            f'&sni={a.sni}&pbk={pub}&sid=00&fp=firefox#entry-o{i}-to-{host}')

    # Русские направления и служебные адреса — напрямую, до транзита.
    rules.insert(0, {'type': 'field', 'ip': ['geoip:private'], 'outboundTag': 'direct'})
    rules.insert(1, {'type': 'field', 'outboundTag': 'direct',
                     'domain': ['geosite:category-ru', 'regexp:.*\\.(ru|su|xn--p1ai)$']})
    rules.insert(2, {'type': 'field', 'ip': ['geoip:ru'], 'outboundTag': 'direct'})

    profile = {
        'log': {'loglevel': 'warning'},
        'inbounds': inbounds,
        'outbounds': exits + [
            {'protocol': 'freedom', 'tag': 'direct'},
            {'protocol': 'blackhole', 'tag': 'block'},
        ],
        'routing': {'domainStrategy': 'IPIfNonMatch', 'rules': rules},
    }
    with open(a.out, 'w', encoding='utf-8') as f:
        json.dump(profile, f, ensure_ascii=False, indent=2)
        f.write('\n')
    with open(a.out + '.links.txt', 'w', encoding='utf-8') as f:
        f.write('# Клиентские ссылки входа (подставьте публичный IP ноды)\n')
        f.write('\n'.join(creds) + '\n')
    print(f'[+] Профиль: {a.out}')
    print(f'[+] Ссылки:  {a.out}.links.txt')
    return 0


if __name__ == '__main__':
    sys.exit(main())
