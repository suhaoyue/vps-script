#!/bin/bash
set -u

echo "========================================"
echo "    vnStat 中文流量 + 端口流量一键部署"
echo "========================================"

if [ "$(id -u)" -ne 0 ]; then
    echo "错误：请使用 root 用户运行"
    exit 1
fi

[ -f /etc/os-release ] || { echo "错误：无法识别系统"; exit 1; }
. /etc/os-release
echo "系统：${PRETTY_NAME:-Unknown}"

echo
echo "[1/6] 安装/检查依赖..."

MISSING_PACKAGES=""
for command_name in vnstat python3 nft; do
    if command -v "$command_name" >/dev/null 2>&1; then
        continue
    fi

    case "$command_name" in
        vnstat) MISSING_PACKAGES="$MISSING_PACKAGES vnstat" ;;
        python3) MISSING_PACKAGES="$MISSING_PACKAGES python3" ;;
        nft) MISSING_PACKAGES="$MISSING_PACKAGES nftables" ;;
    esac
done

if [ -n "$MISSING_PACKAGES" ]; then
    echo "需要安装：$MISSING_PACKAGES"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update || exit 1
        apt-get install -y $MISSING_PACKAGES || exit 1
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y $MISSING_PACKAGES || exit 1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y $MISSING_PACKAGES || exit 1
    elif command -v apk >/dev/null 2>&1; then
        apk add $MISSING_PACKAGES || exit 1
    else
        echo "错误：找不到支持的包管理器"
        exit 1
    fi
else
    echo "vnStat、Python 3、nftables 均已安装"
fi

command -v python3 >/dev/null 2>&1 || { echo "错误：python3 不可用"; exit 1; }
command -v nft >/dev/null 2>&1 || { echo "错误：nft 不可用"; exit 1; }

echo
echo "[2/6] 自动识别公网网卡..."

IFACE=$(ip -4 route show default 2>/dev/null | awk 'NR==1 {print $5}')
[ -n "$IFACE" ] || IFACE=$(ip -6 route show default 2>/dev/null | awk 'NR==1 {print $5}')
[ -n "$IFACE" ] || IFACE=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
[ -n "$IFACE" ] || IFACE=$(ip -br link 2>/dev/null | awk '$1 != "lo" && $2 ~ /UP/ {print $1}' | head -n1)

if [ -z "$IFACE" ] || [ "$IFACE" = "lo" ] || ! ip link show "$IFACE" >/dev/null 2>&1; then
    echo "错误：无法自动识别公网网卡"
    ip -br link
    exit 1
fi

echo "检测到网卡：$IFACE"

echo
echo "[3/6] 配置 vnStat..."

if ! vnstat --iflist 2>/dev/null | grep -qw "$IFACE"; then
    vnstat --add -i "$IFACE" 2>/dev/null || true
fi

SERVICE=""
if systemctl list-unit-files 2>/dev/null | grep -q '^vnstat.service'; then
    SERVICE="vnstat"
elif systemctl list-unit-files 2>/dev/null | grep -q '^vnstatd.service'; then
    SERVICE="vnstatd"
fi

[ -n "$SERVICE" ] || { echo "错误：找不到 vnStat systemd 服务"; exit 1; }

echo "vnStat 服务：$SERVICE"

echo
echo "[4/6] 部署端口流量统计..."

STAT_DIR="/etc/vps-port-stat"
STAT_STATE_DIR="/var/lib/vps-port-stat"
PORT_CONFIG="$STAT_DIR/ports.conf"
STAT_MANAGER="/usr/local/bin/vps-port-stat"

install -d -m 0755 "$STAT_DIR"
install -d -m 0700 "$STAT_STATE_DIR"

cat > "$STAT_MANAGER" <<'VPSPORT'
#!/usr/bin/env python3
import contextlib
import fcntl
import json
import os
import re
import subprocess
import sys
import tempfile

TABLE = "vps_port_stat"
PORT_CONFIG = "/etc/vps-port-stat/ports.conf"
NFT_FILE = "/etc/vps-port-stat/counters.nft"
STATE_DIR = "/var/lib/vps-port-stat"
STATE_FILE = os.path.join(STATE_DIR, "totals.json")
LOCK_FILE = os.path.join(STATE_DIR, "totals.lock")


def fail(message):
    print(f"错误：{message}", file=sys.stderr)
    return 1


def atomic_write(path, content, mode=0o644):
    directory = os.path.dirname(path)
    os.makedirs(directory, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".tmp-", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def parse_port(token):
    match = re.fullmatch(r"(\d{1,5})(?:-(\d{1,5}))?", token)
    if not match:
        return None
    first = int(match.group(1))
    last = int(match.group(2) or first)
    if not (1 <= first <= 65535 and 1 <= last <= 65535 and first <= last):
        return None
    return str(first) if first == last else f"{first}-{last}"


def normalize_spec(spec):
    tokens = [item for item in re.split(r"[\s,]+", spec.strip()) if item]
    ports = []

    for token in tokens:
        token = token.lower()
        protocols = None
        port_text = ""

        if ":" in token:
            protocol_text, port_text = token.split(":", 1)
            if protocol_text in ("tcp", "udp"):
                protocols = [protocol_text]
        elif "/" in token:
            left, right = token.split("/", 1)
            if left in ("tcp", "udp"):
                protocols = [left]
                port_text = right
            elif right in ("tcp", "udp"):
                protocols = [right]
                port_text = left

        if protocols is None:
            protocols = ["tcp", "udp"]
            port_text = token

        port = parse_port(port_text)
        if port is None:
            raise ValueError(f"无效端口：{token}")

        for protocol in protocols:
            key = f"{protocol}:{port}"
            if key not in ports:
                ports.append(key)

    if not ports:
        raise ValueError("端口列表为空")
    return ports


def load_ports():
    if not os.path.isfile(PORT_CONFIG):
        raise ValueError("端口配置文件不存在，请重新运行安装脚本")

    ports = []
    with open(PORT_CONFIG, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            for key in normalize_spec(line):
                if key not in ports:
                    ports.append(key)
    if not ports:
        raise ValueError("端口配置文件为空")
    return ports


def counter_name(key, direction):
    protocol, port = key.split(":", 1)
    safe_port = port.replace("-", "_")
    return f"port_{protocol}_{safe_port}_{direction}"


def counter_to_key(name):
    if not name.startswith("port_"):
        return None
    body = name[5:]
    if body.endswith("_rx"):
        direction = "rx"
        body = body[:-3]
    elif body.endswith("_tx"):
        direction = "tx"
        body = body[:-3]
    else:
        return None
    protocol, separator, port = body.partition("_")
    if not separator or protocol not in ("tcp", "udp"):
        return None
    return f"{protocol}:{port.replace('_', '-')}", direction


def render_nft(ports):
    lines = [f"table inet {TABLE} {{"]
    for key in ports:
        for direction in ("rx", "tx"):
            lines.append(f"    counter {counter_name(key, direction)} {{}}")

    lines.extend([
        "    chain input {",
        "        type filter hook input priority 0; policy accept;",
    ])
    for key in ports:
        protocol, port = key.split(":", 1)
        name = counter_name(key, "rx")
        lines.append(f'        {protocol} dport {port} counter name "{name}"')
    lines.append("    }")

    lines.extend([
        "    chain output {",
        "        type filter hook output priority 0; policy accept;",
    ])
    for key in ports:
        protocol, port = key.split(":", 1)
        name = counter_name(key, "tx")
        lines.append(f'        {protocol} sport {port} counter name "{name}"')
    lines.extend(["    }", "}", ""])
    return "\n".join(lines)


def table_exists():
    result = subprocess.run(
        ["nft", "list", "table", "inet", TABLE],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return result.returncode == 0


def apply_rules():
    if not os.path.isfile(NFT_FILE):
        raise RuntimeError("nftables 规则文件不存在，请重新运行安装脚本")
    result = subprocess.run(
        ["nft", "-f", NFT_FILE],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "nftables 规则加载失败")


def ensure_table():
    if not table_exists():
        apply_rules()


def read_nft_counters():
    result = subprocess.run(
        ["nft", "-j", "list", "table", "inet", TABLE],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        if "No such file" in result.stderr or "does not exist" in result.stderr:
            return {}
        raise RuntimeError(result.stderr.strip() or "无法读取 nftables 计数器")

    counters = {}
    document = json.loads(result.stdout)
    for item in document.get("nftables", []):
        counter = item.get("counter")
        if not counter:
            continue
        key = counter_to_key(counter.get("name", ""))
        if key is None:
            continue
        port_key, direction = key
        counters.setdefault(port_key, {})[direction] = {
            "bytes": int(counter.get("bytes", 0)),
            "packets": int(counter.get("packets", 0)),
        }
    return counters


def load_state():
    try:
        with open(STATE_FILE, "r", encoding="utf-8") as handle:
            state = json.load(handle)
        if not isinstance(state, dict):
            state = {}
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        state = {}

    state.setdefault("version", 1)
    ports_state = state.setdefault("ports", {})
    if not isinstance(ports_state, dict):
        state["ports"] = {}
    return state


@contextlib.contextmanager
def state_lock():
    os.makedirs(STATE_DIR, exist_ok=True)
    handle = open(LOCK_FILE, "a+", encoding="utf-8")
    try:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
        handle.close()


def snapshot():
    ensure_table()

    with state_lock():
        live = read_nft_counters()
        state = load_state()
        reset_names = []
        for port_key, directions in live.items():
            totals = state["ports"].get(port_key)
            if not isinstance(totals, dict):
                totals = {
                    "rx_bytes": 0,
                    "tx_bytes": 0,
                    "rx_packets": 0,
                    "tx_packets": 0,
                }
                state["ports"][port_key] = totals
            for direction, counter in directions.items():
                byte_field = f"{direction}_bytes"
                packet_field = f"{direction}_packets"
                totals[byte_field] = int(totals.get(byte_field, 0)) + counter["bytes"]
                totals[packet_field] = int(totals.get(packet_field, 0)) + counter["packets"]
                if counter["bytes"] or counter["packets"]:
                    reset_names.append(counter_name(port_key, direction))

        for name in reset_names:
            result = subprocess.run(
                ["nft", "reset", "counter", "inet", TABLE, name],
                capture_output=True,
                text=True,
                check=False,
            )
            if result.returncode != 0:
                raise RuntimeError(result.stderr.strip() or "重置 nftables 计数器失败")

        atomic_write(
            STATE_FILE,
            json.dumps(state, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            mode=0o600,
        )


def human_bytes(value):
    value = float(value)
    units = ("B", "KiB", "MiB", "GiB", "TiB", "PiB")
    for unit in units:
        if abs(value) < 1024 or unit == units[-1]:
            if unit == "B":
                return f"{int(value)} {unit}"
            return f"{value:.2f} {unit}"
        value /= 1024
    return f"{value:.2f} PiB"


def show():
    ports = load_ports()
    snapshot()
    state = load_state()

    print()
    print("========================================")
    print("          端口上下行流量统计")
    print("========================================")
    for key in ports:
        protocol, port = key.split(":", 1)
        totals = state["ports"].get(key, {})
        rx = int(totals.get("rx_bytes", 0))
        tx = int(totals.get("tx_bytes", 0))
        print(
            f"{protocol.upper():<3} {port:<11} "
            f"下行 RX {human_bytes(rx):>10}   "
            f"上行 TX {human_bytes(tx):>10}   "
            f"合计 {human_bytes(rx + tx):>10}"
        )
    print("----------------------------------------")
    print("下行 RX = VPS 收到、目的端口为该端口的数据")
    print("上行 TX = VPS 发出、源端口为该端口的数据")
    print("统计量为累计值，包含 IP/TCP/UDP 等协议头部")
    print("========================================")
    print()


def set_ports(spec):
    ports = normalize_spec(spec)
    if table_exists():
        snapshot()

    atomic_write(PORT_CONFIG, "\n".join(ports) + "\n")
    atomic_write(NFT_FILE, render_nft(ports))

    if table_exists():
        result = subprocess.run(
            ["nft", "delete", "table", "inet", TABLE],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            raise RuntimeError(result.stderr.strip() or "无法更新 nftables 规则")
    apply_rules()
    print("端口流量统计已配置：" + "、".join(ports))


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else "show"
    try:
        if command in ("show", "status"):
            show()
        elif command == "snapshot":
            snapshot()
        elif command == "apply":
            ensure_table()
        elif command == "set":
            if len(sys.argv) < 3:
                return fail("用法：vps-port-stat set 22/tcp 80/tcp 443/tcp")
            set_ports(" ".join(sys.argv[2:]))
        elif command == "ports":
            print("\n".join(load_ports()))
        elif command in ("help", "-h", "--help"):
            print("用法：")
            print("  vps-port-stat                 查看端口累计流量")
            print("  vps-port-stat set 端口...     修改统计端口")
            print("  vps-port-stat ports           查看当前端口列表")
            print("  端口格式：22、22/tcp、udp:53、10000-20000/tcp")
            print("  未指定协议时同时统计 TCP 和 UDP")
        else:
            return fail(f"未知命令：{command}")
    except (ValueError, RuntimeError, OSError, json.JSONDecodeError) as error:
        return fail(str(error))
    return 0


if __name__ == "__main__":
    sys.exit(main())
VPSPORT

chmod 0755 "$STAT_MANAGER"

discover_ports() {
    ss -H -lntu 2>/dev/null | awk '
        $1 == "LISTEN" { protocol = "tcp" }
        $1 == "UNCONN" { protocol = "udp" }
        protocol != "" {
            address = $4
            if (address ~ /^127\./ ||
                address ~ /^\[::1\]/ ||
                address ~ /^\[::1%/ ||
                address ~ /^\[::ffff:127\./) {
                next
            }
            count = split(address, parts, ":")
            port = parts[count]
            if (port ~ /^[0-9]+$/ && port > 0) {
                print protocol ":" port
            }
        }
    ' | sort -u
}

if [ -n "${VPS_STAT_PORTS:-}" ]; then
    PORT_SPEC="$VPS_STAT_PORTS"
    echo "使用 VPS_STAT_PORTS 指定的端口：$PORT_SPEC"
elif [ -s "$PORT_CONFIG" ]; then
    PORT_SPEC=$(tr '\n' ' ' < "$PORT_CONFIG")
    echo "保留已配置的统计端口"
else
    PORT_SPEC=$(discover_ports)
    if [ -z "$PORT_SPEC" ]; then
        PORT_SPEC="tcp:22"
        echo "未检测到监听端口，默认统计 TCP 22"
    else
        echo "自动检测到监听端口："
        printf '%s\n' "$PORT_SPEC" | tr '\n' ' '
        echo
    fi
fi

"$STAT_MANAGER" set "$PORT_SPEC" || {
    echo "错误：端口流量统计部署失败"
    exit 1
}

cat > /etc/systemd/system/vps-port-stat.service <<'UNIT'
[Unit]
Description=VPS per-port traffic counters
After=network.target nftables.service firewalld.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/vps-port-stat apply
ExecStop=-/usr/local/bin/vps-port-stat snapshot
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

cat > /etc/systemd/system/vps-port-stat-snapshot.service <<'UNIT'
[Unit]
Description=Save VPS per-port traffic counters

[Service]
Type=oneshot
ExecStart=/usr/local/bin/vps-port-stat snapshot
UNIT

cat > /etc/systemd/system/vps-port-stat-snapshot.timer <<'UNIT'
[Unit]
Description=Periodically save VPS per-port traffic counters

[Timer]
OnBootSec=30s
OnUnitActiveSec=1min
AccuracySec=10s

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload || exit 1
systemctl enable --now vps-port-stat.service || exit 1
systemctl enable --now vps-port-stat-snapshot.timer || exit 1

echo
echo "[5/6] 启动 vnStat..."

systemctl enable "$SERVICE" || exit 1
systemctl restart "$SERVICE" || exit 1
sleep 3

if ! systemctl is-active --quiet "$SERVICE"; then
    systemctl status "$SERVICE" --no-pager
    exit 1
fi

echo "vnStat 服务：运行正常"

echo
echo "[6/6] 创建中文查询命令 vns..."

cat > /usr/local/bin/vns <<'VNS'
#!/bin/bash
set -u

/usr/local/bin/vps-port-stat show || echo "端口流量暂时无法读取"

IFACE=$(ip -4 route show default 2>/dev/null | awk 'NR==1 {print $5}')
[ -n "$IFACE" ] || IFACE=$(ip -6 route show default 2>/dev/null | awk 'NR==1 {print $5}')

if [ -z "$IFACE" ]; then
    echo "无法自动识别公网网卡"
    exit 1
fi

DATA=$(vnstat -i "$IFACE" --json 2>/dev/null)

if [ -z "$DATA" ]; then
    echo "无法读取 vnStat 数据"
    exit 1
fi

python3 - "$DATA" "$IFACE" <<'PY'
import sys, json, subprocess

try:
    data = json.loads(sys.argv[1])
    iface = sys.argv[2]
    interface = data["interfaces"][0]
    traffic = interface.get("traffic", {})
    days = traffic.get("day", [])
    months = traffic.get("month", [])

    def gib(n):
        return n / (1024 ** 3)

    def values(obj):
        rx = int(obj.get("rx", 0))
        tx = int(obj.get("tx", 0))
        return rx, tx, rx + tx

    print()
    print("========================================")
    print("          VPS 网卡流量统计")
    print("========================================")
    print(f"网卡：{iface}")
    print()

    if days:
        rx, tx, total = values(days[-1])
        print("今日流量")
        print("----------------------------------------")
        print(f"入向流量：{gib(rx):>10.2f} GiB")
        print(f"出向流量：{gib(tx):>10.2f} GiB")
        print(f"总流量：  {gib(total):>10.2f} GiB")

    if months:
        rx, tx, total = values(months[-1])
        print()
        print("本月流量")
        print("----------------------------------------")
        print(f"入向流量：{gib(rx):>10.2f} GiB")
        print(f"出向流量：{gib(tx):>10.2f} GiB")
        print(f"总流量：  {gib(total):>10.2f} GiB")

    print()
    print("流量说明")
    print("----------------------------------------")
    print("入向流量 = RX（VPS 接收的数据）")
    print("出向流量 = TX（VPS 发出的数据）")
    print("总流量   = 入向 + 出向")

    print()
    print("========================================")
    print("vnStat 原始统计")
    print("========================================")
    result = subprocess.run(["vnstat", "-i", iface], capture_output=True, text=True)
    print(result.stdout.rstrip())
    print("========================================")
    print()

except Exception as e:
    print("读取流量数据失败：", e)
    sys.exit(1)
PY

VNS

chmod +x /usr/local/bin/vns

echo
echo "========================================"
echo "             部署完成"
echo "========================================"
echo "监控网卡：$IFACE"
echo "vnStat 服务：$SERVICE"
echo "端口统计：$(tr '\n' ' ' < "$PORT_CONFIG")"
echo
echo "以后直接输入：vns"
echo "修改端口：vps-port-stat set 22/tcp 80/tcp 443/tcp"
echo "端口统计说明："
echo "  下行 RX = 收到且目的端口匹配"
echo "  上行 TX = 发出且源端口匹配"
echo "========================================"
echo

vns
