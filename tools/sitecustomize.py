# Force IPv4 name resolution, for hosts where outbound IPv6 is blackholed.
#
# emsdk's downloader and aqtinstall both hang forever rather than falling back,
# and the symptom looks like a dead mirror. Opt in with FORCE_IPV4=1; the build
# scripts set it only around those two downloads. Left unconditional this file
# would break the build on an IPv6-only host, which is the opposite problem.
import os
import socket

if os.environ.get("FORCE_IPV4") == "1":
    _orig = socket.getaddrinfo

    def getaddrinfo(host, port, family=0, *args, **kwargs):
        return _orig(host, port, family or socket.AF_INET, *args, **kwargs)

    socket.getaddrinfo = getaddrinfo
