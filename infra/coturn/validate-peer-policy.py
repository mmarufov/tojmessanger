#!/usr/bin/env python3
"""Fail if Toj's coturn peer policy loses a required security boundary."""

from __future__ import annotations

import ipaddress
from pathlib import Path


CONFIG_PATH = Path(__file__).with_name("turnserver.conf.example")


def fail(message: str) -> None:
    raise SystemExit(f"coturn peer policy invalid: {message}")


lines = [
    line.split("#", 1)[0].strip()
    for line in CONFIG_PATH.read_text(encoding="utf-8").splitlines()
]
options = {line.split("=", 1)[0] for line in lines if line}

for required in (
    "bps-capacity",
    "max-bps",
    "no-cli",
    "no-multicast-peers",
    "no-tcp-relay",
    "pidfile",
    "prometheus-address",
    "static-auth-secret",
    "total-quota",
    "use-auth-secret",
):
    if required not in options:
        fail(f"missing {required}")

for forbidden in (
    "allow-loopback-peers",
    "allowed-peer-ip",
    "lt-cred-mech",
    "no-tcp",
    "no-tls",
    "no-udp-relay",
    "server-relay",
    "tlsv1",
    "tlsv1_1",
):
    if forbidden in options:
        fail(f"forbidden option {forbidden}")

ranges: list[tuple[ipaddress._BaseAddress, ipaddress._BaseAddress]] = []
for line in lines:
    if not line.startswith("denied-peer-ip="):
        continue
    value = line.split("=", 1)[1]
    first, separator, last = value.partition("-")
    start = ipaddress.ip_address(first)
    end = ipaddress.ip_address(last if separator else first)
    if start.version != end.version or int(start) > int(end):
        fail(f"invalid range {value}")
    ranges.append((start, end))


def is_denied(value: str) -> bool:
    address = ipaddress.ip_address(value)
    return any(
        address.version == start.version and int(start) <= int(address) <= int(end)
        for start, end in ranges
    )


required_denies = {
    "IPv4 this-network": "0.1.2.3",
    "RFC1918 10/8": "10.1.2.3",
    "CGNAT and Alibaba metadata": "100.100.100.200",
    "IPv4 loopback": "127.0.0.1",
    "Azure platform address": "168.63.129.16",
    "link-local and common metadata": "169.254.169.254",
    "RFC1918 172.16/12": "172.31.255.254",
    "protocol assignments": "192.0.0.192",
    "documentation IPv4": "192.0.2.1",
    "RFC1918 192.168/16": "192.168.1.1",
    "benchmark IPv4": "198.18.1.1",
    "documentation IPv4 second block": "198.51.100.1",
    "documentation IPv4 third block": "203.0.113.1",
    "IPv4 multicast": "239.255.255.250",
    "IPv4 reserved/broadcast": "255.255.255.255",
    "IPv6 unspecified": "::",
    "IPv6 loopback": "::1",
    "IPv4-mapped IPv6 metadata": "::ffff:169.254.169.254",
    "IPv6 discard-only": "100::1",
    "IPv6 benchmarking": "2001:2::1",
    "IPv6 documentation": "2001:db8::1",
    "IPv6 documentation second block": "3fff::1",
    "IPv6 ULA and cloud metadata": "fd00:ec2::254",
    "IPv6 link-local": "fe80::1",
    "IPv6 deprecated site-local": "fec0::1",
    "IPv6 multicast": "ff02::1",
}

for label, address in required_denies.items():
    if not is_denied(address):
        fail(f"{label} address {address} is not denied")

required_public = {
    "Cloudflare IPv4": "1.1.1.1",
    "Google IPv4": "8.8.8.8",
    "NAT64 well-known prefix": "64:ff9b::808:808",
    "Cloudflare IPv6": "2606:4700:4700::1111",
    "Google IPv6": "2001:4860:4860::8888",
}

for label, address in required_public.items():
    if is_denied(address):
        fail(f"{label} address {address} is unexpectedly denied")

print(f"coturn peer policy OK: {len(ranges)} deny rules, TCP/TLS client transports preserved")
