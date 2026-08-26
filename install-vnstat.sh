#!/bin/bash
set -u

echo "========================================"
echo "       vnStat 中文流量监控一键部署"
echo "========================================"

if [ "$(id -u)" -ne 0 ]; then
    echo "错误：请使用 root 用户运行"
    exit 1
fi

[ -f /etc/os-release ] || { echo "错误：无法识别系统"; exit 1; }
. /etc/os-release
echo "系统：${PRETTY_NAME:-Unknown}"

echo
echo "[1/5] 安装/检查 vnStat..."

if command -v vnstat >/dev/null 2>&1; then
    echo "vnStat 已安装"
else
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update || exit 1
        apt-get install -y vnstat python3 || exit 1
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y vnstat python3 || exit 1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y vnstat python3 || exit 1
    elif command -v apk >/dev/null 2>&1; then
        apk add vnstat python3 || exit 1
    else
        echo "错误：找不到支持的包管理器"
        exit 1
    fi
fi

command -v python3 >/dev/null 2>&1 || {
    echo "错误：python3 不可用"
    exit 1
}

echo
echo "[2/5] 自动识别公网网卡..."

IFACE=$(ip -4 route show default 2>/dev/null | awk 'NR==1 {print $5}')

if [ -z "$IFACE" ]; then
    IFACE=$(ip -6 route show default 2>/dev/null | awk 'NR==1 {print $5}')
fi

if [ -z "$IFACE" ]; then
    IFACE=$(ip route get 1.1.1.1 2>/dev/null |
        awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
fi

if [ -z "$IFACE" ]; then
    IFACE=$(ip -br link 2>/dev/null |
        awk '$1 != "lo" && $2 ~ /UP/ {print $1}' | head -n1)
fi

if [ -z "$IFACE" ] || [ "$IFACE" = "lo" ] ||
   ! ip link show "$IFACE" >/dev/null 2>&1; then
    echo "错误：无法自动识别公网网卡"
    ip -br link
    exit 1
fi

echo "检测到网卡：$IFACE"

echo
echo "[3/5] 配置 vnStat..."

if ! vnstat --iflist 2>/dev/null | grep -qw "$IFACE"; then
    vnstat --add -i "$IFACE" 2>/dev/null || true
fi

SERVICE=""
if systemctl list-unit-files 2>/dev/null | grep -q '^vnstat.service'; then
    SERVICE="vnstat"
elif systemctl list-unit-files 2>/dev/null | grep -q '^vnstatd.service'; then
    SERVICE="vnstatd"
fi

[ -n "$SERVICE" ] || {
    echo "错误：找不到 vnStat systemd 服务"
    exit 1
}

echo
echo "[4/5] 启动 vnStat..."

systemctl enable "$SERVICE" || exit 1
systemctl restart "$SERVICE" || exit 1
sleep 3

if ! systemctl is-active --quiet "$SERVICE"; then
    systemctl status "$SERVICE" --no-pager
    exit 1
fi

echo "vnStat 服务：运行正常"

echo
echo "[5/5] 创建中文查询命令 vns..."

cat > /usr/local/bin/vns <<'VNS'
#!/bin/bash

set -u

IFACE=$(ip -4 route show default 2>/dev/null | awk 'NR==1 {print $5}')

if [ -z "$IFACE" ]; then
    IFACE=$(ip -6 route show default 2>/dev/null | awk 'NR==1 {print $5}')
fi

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
    print("          VPS 网络流量统计")
    print("========================================")
    print(f"网卡：{iface}")
    print()

    if days:
        rx, tx, total = values(days[-1])
        print("今日流量")
        print("----------------------------------------")
        print(f"下载：{gib(rx):>10.2f} GiB")
        print(f"上传：{gib(tx):>10.2f} GiB")
        print(f"总流量：{gib(total):>8.2f} GiB")

    if months:
        rx, tx, total = values(months[-1])
        print()
        print("本月流量")
        print("----------------------------------------")
        print(f"下载：{gib(rx):>10.2f} GiB")
        print(f"上传：{gib(tx):>10.2f} GiB")
        print(f"总流量：{gib(total):>8.2f} GiB")

    print()
    print("========================================")
    print("vnStat 原始统计")
    print("========================================")
    result = subprocess.run(
        ["vnstat", "-i", iface],
        capture_output=True,
        text=True
    )
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
echo
echo "以后直接输入：vns"
echo "========================================"
echo

vns
