#!/bin/sh
# ocserv connect hook - called when a user connects
# Environment: $USERNAME, $IP_REAL, $IP_REMOTE (client VPN IP), $IP_LOCAL (server gateway), $DEVICE, $HOSTNAME

# ── 通知后端连接事件 ──

# 动态读取 Web 端口（由 ocserv-manager 启动时写入）
PORT=$(cat /etc/ocserv-panel/web_port 2>/dev/null)
PORT=${PORT:-8088}
# 内部接口鉴权令牌（由 ocserv-manager 启动时生成）
TOKEN=$(cat /etc/ocserv-panel/internal_token 2>/dev/null)
API="http://127.0.0.1:${PORT}/api/internal/connect"

# 令牌或用户名缺失时直接放弃上报：无令牌必被后端拒绝（白白重试），无用户名的事件也无意义
[ -z "$TOKEN" ] && exit 0
[ -z "$USERNAME" ] && exit 0

# 用 jq 构造 JSON，所有字段自动转义，不怕特殊字符
# 注意：IP_REMOTE 是分配给客户端的 VPN IP，IP_LOCAL 是服务端网关 IP
payload=$(jq -n \
    --arg u  "${USERNAME}" \
    --arg r  "${IP_REAL}" \
    --arg l  "${IP_REMOTE}" \
    --arg d  "${DEVICE}" \
    --arg h  "${HOSTNAME}" \
    '{username:$u, ip_real:$r, ip_local:$l, device:$d, hostname:$h}')

# --retry 在连接被拒绝/超时等瞬时错误时重试，避免后端重启窗口内丢失连接事件
curl -s --max-time 5 --retry 3 --retry-delay 1 --retry-connrefused -X POST "$API" \
    -H "Content-Type: application/json" \
    -H "X-Internal-Token: ${TOKEN}" \
    -d "$payload" > /dev/null 2>&1 &

exit 0