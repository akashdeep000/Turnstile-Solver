#!/bin/bash

start_xrdp_services() {
    rm -rf /var/run/xrdp-sesman.pid
    rm -rf /var/run/xrdp.pid
    rm -rf /var/run/xrdp/xrdp-sesman.pid
    rm -rf /var/run/xrdp/xrdp.pid

    xrdp-sesman &
    xrdp -n &

    echo "Waiting for RDP service to be ready..."
    for i in {1..30}; do
        if ss -ltn 2>/dev/null | grep -q ':3389'; then
            echo "RDP is listening on port 3389."
            return
        fi
        sleep 1
    done

    echo "RDP service not detected after timeout."
}

stop_xrdp_services() {
    xrdp --kill
    xrdp-sesman --kill
    exit 0
}

if id "root" &>/dev/null; then
    echo "root:root" | chpasswd || {
        echo "Failed to update password."
        exit 1
    }
else
    if ! getent group root >/dev/null; then
        addgroup root
    fi

    useradd -m -s /bin/bash -g root root || {
        echo "Failed to create user."
        exit 1
    }
    echo "root:root" | chpasswd || {
        echo "Failed to set password."
        exit 1
    }
    usermod -aG sudo root || {
        echo "Failed to add user to sudo."
        exit 1
    }
fi

if [ -n "$TZ" ]; then
    ln -snf /usr/share/zoneinfo/$TZ /etc/localtime
    echo $TZ >/etc/timezone
fi

mkdir -p /root/Desktop

cd /root/Desktop || {
    echo "Failed to change directory to /root/Desktop"
    exit 1
}

git clone https://github.com/akashdeep000/Turnstile-Solver.git
cd Turnstile-Solver || {
    echo "Failed to change directory to Turnstile-Solver"
    exit 1
}

pip3 install -r requirements.txt --break-system-packages

trap "stop_xrdp_services" SIGKILL SIGTERM SIGHUP SIGINT EXIT
start_xrdp_services

start_ipv6_proxy_pool() {
    command -v 3proxy >/dev/null 2>&1 || { echo "IPv6 proxy pool: SKIPPED (3proxy not installed)"; return 0; }

    python3 - <<'PYEOF'
import ipaddress, re, subprocess, sys, time
PROXIES_FILE = "/root/Desktop/Turnstile-Solver/proxies.txt"

try:
    out = subprocess.check_output(["ip", "-6", "addr", "show", "scope", "global"], stderr=subprocess.DEVNULL, text=True)
except Exception:
    out = ""

assigned = set()
nets = []
for m in re.finditer(r"inet6\s+([0-9a-fA-F:]+)/(\d+)", out):
    raw, plen = m.group(1), int(m.group(2))
    addr = ipaddress.IPv6Address(raw)
    assigned.add(addr)
    if 0 < plen <= 64:
        net = ipaddress.IPv6Network(f"{addr}/{plen}", strict=False)
        if net not in nets:
            nets.append(net)

if not nets:
    print("IPv6 proxy pool: NO IPv6 found (enable host networking / routed IPv6 block in Dokploy)")
    open(PROXIES_FILE, "w").close()
    sys.exit(0)

addrs = []
for net in nets:
    for host in net.hosts():
        if host not in assigned:
            addrs.append(str(host))
        if len(addrs) >= 8:
            break
    if len(addrs) >= 8:
        break

dev = "eth0"
m = re.search(r"^\d+: (\S+):", out, re.M)
if m:
    dev = m.group(1)

for a in addrs:
    subprocess.run(["ip", "-6", "addr", "add", f"{a}/128", "dev", dev], stderr=subprocess.DEVNULL)
subprocess.run(["sysctl", "-w", "net.ipv6.ip_nonlocal_bind=1"], stderr=subprocess.DEVNULL)

cfg = ["daemon", "pidfile /tmp/3proxy.pid", "log /tmp/3proxy.log", "nscache 65536", "auth none", "allow *"]
ports = []
for i, a in enumerate(addrs):
    port = 12080 + i
    ports.append(port)
    cfg.append(f"proxy -a -n -p{port} -i127.0.0.1 -e{a}")
with open("/etc/3proxy.cfg", "w") as f:
    f.write("\n".join(cfg) + "\n")

subprocess.run(["pkill", "-f", "3proxy"], stderr=subprocess.DEVNULL)
subprocess.run(["3proxy", "/etc/3proxy.cfg"])
time.sleep(1)
listen = ""
try:
    listen = subprocess.check_output(["ss", "-ltn"], stderr=subprocess.DEVNULL, text=True)
except Exception:
    pass

alive = [p for p in ports if f":{p}" in listen]
if alive:
    with open(PROXIES_FILE, "w") as f:
        for p in alive:
            f.write(f"http://127.0.0.1:{p}\n")
    print(f"IPv6 proxy pool: {len(alive)} proxies on 127.0.0.1:{alive[0]}-{alive[-1]} - {', '.join(addrs[:3])}...")
else:
    print("IPv6 proxy pool: FAILED to bind (check container privileges / routed block); falling back to direct")
    open(PROXIES_FILE, "w").close()
PYEOF
}

if [ "$RUN_API_SOLVER" = "true" ]; then
    start_ipv6_proxy_pool
    PROXY_FLAG="false"
    [ -s /root/Desktop/Turnstile-Solver/proxies.txt ] && PROXY_FLAG="true"
    [ "${PROXY_SOLVER:-false}" = "true" ] && PROXY_FLAG="true"
    echo "Starting API solver in headful mode... (proxy: $PROXY_FLAG)"
    xvfb-run -a python3 /root/Desktop/Turnstile-Solver/api_solver.py --browser_type chrome --host 0.0.0.0 --default_timeout "${DEFAULT_TIMEOUT:-60}" --debug "${DEBUG_SOLVER:-false}" --proxy "$PROXY_FLAG"
else
    echo "API solver disabled. Container running for RDP access on port 3389..."
    tail -f /dev/null
fi
