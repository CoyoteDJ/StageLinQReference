#!/usr/bin/env python3
"""Duplicate StageLinq discovery packets for Resolume and the reference app."""
import socket
import ipaddress

PORT = 51337
APP = ("127.0.0.1", 51338)
RESOLUME = ("10.0.0.45", 51337)

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
sock.bind(("", PORT))
forward = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

print(f"StageLinq discovery proxy listening on UDP {PORT}")
print(f"  app:      {APP[0]}:{APP[1]}")
print(f"  Resolume: {RESOLUME[0]}:{RESOLUME[1]}")
while True:
    packet, sender = sock.recvfrom(65535)
    # Preserve the hardware sender address across the local relay.
    envelope = b"SLPX" + ipaddress.ip_address(sender[0]).packed + packet
    forward.sendto(envelope, APP)
    # Do not send Resolume's own discovery packet back to its socket.
    # Hardware and mixer announcements are copied to both consumers.
    if not (sender[0] == RESOLUME[0] and sender[1] == RESOLUME[1]):
        forward.sendto(packet, RESOLUME)
    print(f"{sender[0]}:{sender[1]} -> app + Resolume {len(packet)} bytes", flush=True)
