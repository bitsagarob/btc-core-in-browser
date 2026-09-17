# emsdk's downloader hangs where outbound IPv6 is blackholed. Pin IPv4.
# Use by putting this directory on PYTHONPATH before running ./emsdk install.
import socket

_orig = socket.getaddrinfo


def getaddrinfo(host, port, family=0, type=0, proto=0, flags=0):
    return _orig(host, port, socket.AF_INET, type, proto, flags)


socket.getaddrinfo = getaddrinfo
