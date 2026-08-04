"""Phone pairing payload and QR for the authenticated WebUI.

The payload is a compact JSON document the iPhone and Android apps scan:

    {"v":1,"url":"http://192.168.1.20:8765","token":"..."}

The QR must encode a host the phone can reach (LAN / Tailscale), not loopback.
"""

from __future__ import annotations

import ipaddress
import json
import os
import socket
import subprocess
from dataclasses import dataclass
from typing import Any
from urllib.parse import urlparse

PAIRING_VERSION = 1
PAIRING_SCHEME_HINT = "localflow-pair-v1"


@dataclass(frozen=True, slots=True)
class PairingPayload:
    url: str
    token: str
    version: int = PAIRING_VERSION

    def encode(self) -> str:
        if self.version != PAIRING_VERSION:
            raise ValueError(f"Unsupported pairing version: {self.version}")
        if not self.token.strip():
            raise ValueError("Pairing token must not be empty.")
        url = normalize_gateway_url(self.url)
        return json.dumps(
            {"v": self.version, "url": url, "token": self.token},
            separators=(",", ":"),
            ensure_ascii=True,
        )


def encode_pairing_payload(url: str, token: str, *, version: int = PAIRING_VERSION) -> str:
    return PairingPayload(url=url, token=token, version=version).encode()


def decode_pairing_payload(raw: str) -> PairingPayload:
    text = raw.strip()
    if not text:
        raise ValueError("Pairing code is empty.")
    try:
        data: Any = json.loads(text)
    except json.JSONDecodeError as error:
        raise ValueError("Pairing code is not valid JSON.") from error
    if not isinstance(data, dict):
        raise ValueError("Pairing code must be a JSON object.")
    version = data.get("v", data.get("version"))
    if version != PAIRING_VERSION:
        raise ValueError(f"Unsupported pairing version: {version!r}")
    url = data.get("url")
    token = data.get("token")
    if not isinstance(url, str) or not url.strip():
        raise ValueError("Pairing code is missing a gateway URL.")
    if not isinstance(token, str) or not token.strip():
        raise ValueError("Pairing code is missing a bearer token.")
    return PairingPayload(url=normalize_gateway_url(url), token=token.strip(), version=int(version))


def normalize_gateway_url(url: str) -> str:
    trimmed = url.strip()
    parsed = urlparse(trimmed)
    if parsed.scheme not in {"http", "https"}:
        raise ValueError("Gateway URL must use http:// or https://.")
    if not parsed.hostname:
        raise ValueError("Gateway URL is missing a host.")
    if parsed.username or parsed.password:
        raise ValueError("Gateway URL must not include credentials.")
    if parsed.query or parsed.fragment:
        raise ValueError("Gateway URL must not include a query or fragment.")
    host = parsed.hostname
    if ":" in host and not host.startswith("["):
        host = f"[{host}]"
    port = f":{parsed.port}" if parsed.port else ""
    path = (parsed.path or "").rstrip("/")
    return f"{parsed.scheme}://{host}{port}{path}"


def normalize_gateway_input(raw: str, default_port: int) -> str:
    """Normalize free-text pairing input into a gateway URL.

    Lets a user paste a bare address — a Tailscale IP (``100.x.x.x``), a
    Tailscale MagicDNS name (``phone.tailnet-name.ts.net``), or a LAN IP —
    without typing a scheme or port. A full ``http://`` / ``https://`` URL is
    also accepted and passed through to :func:`normalize_gateway_url`.
    """
    trimmed = raw.strip()
    if not trimmed:
        raise ValueError("Address must not be empty.")
    if "://" not in trimmed:
        trimmed = f"http://{trimmed}"
    parsed = urlparse(trimmed)
    if parsed.hostname and parsed.port is None:
        host = parsed.hostname
        if ":" in host:
            host = f"[{host}]"
        path = parsed.path or ""
        trimmed = f"{parsed.scheme}://{host}:{default_port}{path}"
    return normalize_gateway_url(trimmed)


_AMBIENT_LAN_NETWORKS = (
    ipaddress.IPv4Network("100.64.0.0/10"),  # Tailscale / CGNAT, not flagged by is_private
)


def is_ambient_lan_address(url: str) -> bool:
    """True when *url*'s host is a bare LAN-or-tailnet IPv4 address.

    Such an address (a plain LAN or Tailscale IP, not a hostname) reflects
    whichever network the gateway happens to be on right now, so it should
    track fresh discovery rather than being remembered indefinitely — unlike
    a MagicDNS name, custom domain, or public IP, which the user chose
    deliberately and isn't tied to a particular Wi-Fi network.
    """
    host = urlparse(url).hostname or ""
    try:
        ip = ipaddress.IPv4Address(host)
    except ValueError:
        return False
    return ip.is_private or any(ip in network for network in _AMBIENT_LAN_NETWORKS)


def discover_gateway_base_urls(port: int) -> list[str]:
    """Return phone-reachable gateway bases, preferred first.

    Loopback is omitted: a phone cannot use 127.0.0.1 on the gateway host.
    Override with LOCALFLOW_PUBLIC_URL or LOCALFLOW_PAIRING_URL when automatic
    discovery is wrong (multiple NICs, reverse proxy, etc.).
    """
    overrides: list[str] = []
    for key in ("LOCALFLOW_PUBLIC_URL", "LOCALFLOW_PAIRING_URL"):
        value = os.environ.get(key, "").strip()
        if value:
            try:
                overrides.append(normalize_gateway_url(value))
            except ValueError:
                continue

    addresses = _local_ipv4_addresses()
    ranked = sorted(addresses, key=_address_rank)
    discovered = [f"http://{ip}:{port}" for ip in ranked]

    ordered: list[str] = []
    for candidate in overrides + discovered:
        if candidate not in ordered:
            ordered.append(candidate)
    return ordered


def primary_gateway_base_url(port: int) -> str | None:
    urls = discover_gateway_base_urls(port)
    return urls[0] if urls else None


def _local_ipv4_addresses() -> list[str]:
    found: set[str] = set()
    try:
        hostname = socket.gethostname()
        for info in socket.getaddrinfo(hostname, None, socket.AF_INET, socket.SOCK_STREAM):
            sockaddr = info[4]
            address = sockaddr[0]
            if isinstance(address, str) and _is_phone_reachable_ipv4(address):
                found.add(address)
    except OSError:
        pass

    # Also probe via UDP connect so multi-homed hosts report the outbound NIC.
    for probe in ("1.1.1.1", "8.8.8.8"):
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
                sock.connect((probe, 80))
                address = sock.getsockname()[0]
                if isinstance(address, str) and _is_phone_reachable_ipv4(address):
                    found.add(address)
        except OSError:
            continue

    # Prefer iproute on Linux when available (reliable multi-NIC listing).
    try:
        result = subprocess.run(
            ["ip", "-4", "-o", "addr", "show", "scope", "global"],
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        )
        if result.returncode == 0:
            for line in result.stdout.splitlines():
                parts = line.split()
                if "inet" in parts:
                    idx = parts.index("inet")
                    if idx + 1 < len(parts):
                        address = parts[idx + 1].split("/")[0]
                        if _is_phone_reachable_ipv4(address):
                            found.add(address)
    except (OSError, subprocess.TimeoutExpired):
        pass

    return list(found)


def _is_phone_reachable_ipv4(address: str) -> bool:
    try:
        ip = ipaddress.IPv4Address(address)
    except ValueError:
        return False
    return not (ip.is_loopback or ip.is_link_local or ip.is_unspecified or ip.is_multicast)


def _address_rank(address: str) -> tuple[int, str]:
    """Prefer typical home Wi-Fi (192.168) over VPN tunnels (often 10.x)."""
    try:
        ip = ipaddress.IPv4Address(address)
    except ValueError:
        return (90, address)
    if ip in ipaddress.IPv4Network("192.168.0.0/16"):
        return (0, address)
    if ip in ipaddress.IPv4Network("172.16.0.0/12"):
        return (1, address)
    # Tailscale / CGNAT
    if ip in ipaddress.IPv4Network("100.64.0.0/10"):
        return (2, address)
    if ip in ipaddress.IPv4Network("10.0.0.0/8"):
        return (3, address)
    if ip.is_private:
        return (4, address)
    return (5, address)


def qr_svg_for_payload(payload: str, *, box_size: int = 6, border: int = 2) -> str:
    """Return a self-contained SVG QR for *payload* without Pillow."""
    import qrcode
    import qrcode.image.svg

    qr = qrcode.QRCode(
        version=None,
        error_correction=qrcode.constants.ERROR_CORRECT_M,
        box_size=box_size,
        border=border,
        image_factory=qrcode.image.svg.SvgPathImage,
    )
    qr.add_data(payload)
    qr.make(fit=True)
    image = qr.make_image()
    svg = image.to_string(encoding="unicode")
    return str(svg)
