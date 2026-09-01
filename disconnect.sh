#!/bin/sh
# ocserv disconnect hook - called when a user disconnects
# Environment: $USERNAME, $IP_REAL, $IP_REMOTE, $DEVICE, $STATS_BYTES_IN, $STATS_BYTES_OUT, $STATS_DURATION

# 动态读取 Web 端口（由 ocserv-manager 启动时写入）
PORT=$(cat /etc/ocserv-panel/web_port 2>/dev/null)
PORT=${PORT:-8088}
# 内部接口鉴权令牌（由 ocserv-manager 启动时生成）
TOKEN=$(cat /etc/ocserv-panel/internal_token 2>/dev/null)
API="http://127.0.0.1:${PORT}/api/internal/disconnect"

# 令牌或用户名缺失时直接放弃上报：无令牌必被后端拒绝（白白重试），无用户名的事件也无意义
[ -z "$TOKEN" ] && exit 0
[ -z "$USERNAME" ] && exit 0

# 对数值型变量做纯数字校验，非数字则回退为 0，防止 jq 构造 JSON 失败
_is_int() { echo "${1:-0}" | grep -qE '^[0-9]+$' && echo "${1}" || echo "0"; }

BI=$(_is_int  "${STATS_BYTES_IN}")
BO=$(_is_int  "${STATS_BYTES_OUT}")
DUR=$(_is_int "${STATS_DURATION}")

payload=$(jq -n \
    --arg     u   "${USERNAME}" \
    --arg     r   "${IP_REAL}" \
    --arg     d   "${DEVICE}" \
    --argjson bi  "${BI}" \
    --argjson bo  "${BO}" \
    --argjson dur "${DUR}" \
    '{username:$u, ip_real:$r, device:$d, bytes_in:$bi, bytes_out:$bo, duration:$dur}')

# --retry 在连接被拒绝/超时等瞬时错误时重试，避免后端重启窗口内丢失断开事件
curl -s --max-time 5 --retry 3 --retry-delay 1 --retry-connrefused -X POST "$API" \
    -H "Content-Type: application/json" \
    -H "X-Internal-Token: ${TOKEN}" \
    -d "$payload" > /dev/null 2>&1 &

exit 0