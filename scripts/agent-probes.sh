# shellcheck shell=bash
# Agent 插件的冒烟助手：扮演用户的手机经隧道发加密消息、等 Bot 回答，验确认卡片、打断、重启、名单外不应答。
# probes.sh 读入它；插件在 smoke-probes.sh 的 extra_check 里按自己有的能力组合这些函数，每个函数记一到几行
# 附加检查的子项（extra_item），返回值不表示成败。例：
#
#   EXTRA_TIMEOUT=2400
#   extra_check() {
#     agent_check_chat '请用一句话回答：冒烟。记住暗号：青杏。'
#     agent_check_model
#     agent_check_mcp_bus
#     agent_check_restart agent bridge
#     agent_check_resume 青杏
#     agent_check_outsider
#   }
#
# 扮演手机的两个验收工具是核心仓库 deploy/dev/core/Dockerfile 的 tunnel-client、echo-bot 两个构建目标，由调用方
# 给镜像：WONTON_SMOKE_TUNNEL_CLIENT_IMAGE、WONTON_SMOKE_ECHO_BOT_IMAGE。没给时要手机的子项记 N/A 并写原因。
# WONTON_SMOKE_CURL_IMAGE 只用来经手机的隧道代理取 Matrix 登录令牌。
# 要模型回答的子项（模型能回话、经聊天调工具、确认卡片、打断、续聊）要先接模型上游（WONTON_DEV_MODEL_*），没接时记 N/A。
# 只要 Bot 回了话就算数的（加密私聊、名单外不应答）不要模型：没有模型时 Bot 回的报错也是一条加密回复。

: "${WONTON_SMOKE_CURL_IMAGE:=curlimages/curl:8.23.0}"
AGENT_PHONE_STATE=""

# 用户的手机：tunnel-client 进核心的网络命名空间，和核心配对后在 127.0.0.1:18008 开带凭据的代理；
# echo-bot probe 经它连 Matrix。只起一次，后面的子项共用。起不来时记一行 FAIL 加密私聊（配对坏了是真问题），
# 没给镜像时什么都不记；返回 1，调用方按 AGENT_PHONE_STATE 记自己的 N/A。
agent_phone() {
  [[ -z "$AGENT_PHONE_STATE" ]] || { [[ "$AGENT_PHONE_STATE" == ok ]]; return; }
  if [[ -z "${WONTON_SMOKE_TUNNEL_CLIENT_IMAGE:-}" || -z "${WONTON_SMOKE_ECHO_BOT_IMAGE:-}" ]]; then
    AGENT_PHONE_STATE="na:没给验收工具镜像（WONTON_SMOKE_TUNNEL_CLIENT_IMAGE、WONTON_SMOKE_ECHO_BOT_IMAGE），没有扮演用户手机的客户端"
    return 1
  fi
  if agent_phone_up; then
    AGENT_PHONE_STATE=ok
    return 0
  fi
  AGENT_PHONE_STATE="fail:$AGENT_WHY"
  extra_item FAIL 加密私聊 "$AGENT_WHY"
  return 1
}

agent_phone_up() {
  local server pairing record hostport
  hostport="${SMOKE_BASE#*://}"
  hostport="${hostport%%/*}"
  AGENT_HOST="${hostport%:*}"
  AGENT_PORT="${hostport##*:}"
  AGENT_PHONE="wonton-$SMOKE_INSTANCE--smoke-phone"
  docker rm -f "$AGENT_PHONE" >/dev/null 2>&1 || true
  server="$(smoke_api GET /_wonton/api/tunnel | jq -r '.endpoint_id // empty')"
  [[ -n "$server" ]] || { AGENT_WHY="拿不到核心的隧道端点"; return 1; }
  # 带上实例标签：冒烟结束时随实例一起删。隧道的直连端口是网页端口的下一个。
  docker run -d --name "$AGENT_PHONE" --label "wonton.instance=$SMOKE_INSTANCE" \
    --network "container:$SMOKE_CORE" --entrypoint sh "$WONTON_SMOKE_TUNNEL_CLIENT_IMAGE" -c \
    "tunnel-client --key /tmp/phone.key id && exec tunnel-client --key /tmp/phone.key proxy --auth --domain $AGENT_HOST --server $server --addr 127.0.0.1:$((AGENT_PORT + 1)) --listen 127.0.0.1:18008" \
    >/dev/null || { AGENT_WHY="手机的隧道客户端起不来（$WONTON_SMOKE_TUNNEL_CLIENT_IMAGE）"; return 1; }
  for _ in $(seq 1 30); do
    docker logs "$AGENT_PHONE" 2>&1 | grep -q '^本地代理' && break
    sleep 1
  done
  AGENT_CREDENTIAL="$(docker logs "$AGENT_PHONE" 2>&1 | sed -n 's/^会话凭据：//p' | tail -1)"
  [[ -n "$AGENT_CREDENTIAL" ]] || { AGENT_WHY="手机的隧道代理 30 秒没就绪：$(docker logs "$AGENT_PHONE" 2>&1 | tail -3 | tr '\n' ' ')"; return 1; }
  # 配对码带上回环直连地址（和 proxy 的 --addr 同一个端口）：不带就只能走中继，偶尔要半分钟以上。
  pairing="$(docker exec "$SMOKE_CORE" wonton-core pair "127.0.0.1:$((AGENT_PORT + 1))" 2>&1 | grep '^wonton://pair?' | tail -1)"
  [[ -n "$pairing" ]] || { AGENT_WHY="wonton-core pair 没给出配对链接"; return 1; }
  docker exec "$AGENT_PHONE" tunnel-client --key /tmp/phone.key pair "$pairing" --name 'smoke phone' ||
    { AGENT_WHY="手机配对被核心拒绝"; return 1; }
  record="$(docker exec "$SMOKE_CORE" cat "$SMOKE_DATA_DIR/core/plugins/bots/$SMOKE_PLUGIN_ID.json")" ||
    { AGENT_WHY="核心里没有这个插件的 Bot 记录"; return 1; }
  AGENT_ROOM="$(jq -r '.bots.default.home_room // empty' <<<"$record")"
  AGENT_BOT="$(jq -r '.bots.default.user_id // empty' <<<"$record")"
  [[ -n "$AGENT_ROOM" && -n "$AGENT_BOT" ]] || { AGENT_WHY="Bot 记录里没有主房间或用户 ID"; return 1; }
}

# 用户的一台新设备发消息、等 Bot 回答：参数原样交给 echo-bot probe（--text、--reply、--wait、--settle、--mention…），
# 标准输出是 probe 的输出（含 Bot 的回答）。每次新设备，登录令牌只用这一次。
agent_say() {
  local token
  token="$(docker run --rm --network "container:$AGENT_PHONE" "$WONTON_SMOKE_CURL_IMAGE" -sS --noproxy '' \
    --max-time 60 -x http://127.0.0.1:18008 -U "$AGENT_CREDENTIAL" -H "Authorization: Bearer $SMOKE_TOKEN" \
    -X POST "http://$AGENT_HOST:$AGENT_PORT/_wonton/matrix/login-token" | jq -r '.token // empty')"
  [[ -n "$token" ]] || { echo "拿不到用户的 Matrix 登录令牌"; return 1; }
  timeout "${AGENT_SAY_TIMEOUT:-360}" docker run --rm --network "container:$AGENT_PHONE" \
    "$WONTON_SMOKE_ECHO_BOT_IMAGE" probe --homeserver "http://matrix.$AGENT_HOST:$AGENT_PORT" \
    --proxy "http://$AGENT_CREDENTIAL@127.0.0.1:18008" --login-token "$token" \
    --room "$AGENT_ROOM" --bot "$AGENT_BOT" "$@"
}

# 子项的前置：<子项> [model]。手机或模型不在时记这一项 N/A（写原因）并返回 1。
agent_need() {
  local item="$1"
  if ! agent_phone; then
    case "$AGENT_PHONE_STATE" in
      na:*) extra_item N/A "$item" "${AGENT_PHONE_STATE#na:}" ;;
      *) extra_item N/A "$item" "手机没连上，没测（${AGENT_PHONE_STATE#fail:}）" ;;
    esac
    return 1
  fi
  if [[ "${2:-}" == model && -z "${WONTON_DEV_MODEL_BASE_URL:-}" ]]; then
    extra_item N/A "$item" "没接模型上游（WONTON_DEV_MODEL_*），Bot 答不了需要模型的问题"
    return 1
  fi
}

agent_tmp() { mktemp "${SMOKE_STATE%/*}/agent.XXXXXX"; }

# 一行摘要：日志里留全文，结果行里只放末尾一段。
agent_tail() { tail -c "${2:-200}" <<<"$1" | tr '\n' ' '; }

agent_check_chat() { # [文字]：首次安装后加密私聊收发
  local out
  agent_need 加密私聊 || return 0
  if out="$(agent_say --reply any --settle 15 --wait 240 --text "${1:-请用一句话回答：冒烟。}" 2>&1)"; then
    extra_item PASS 加密私聊 "用户的新设备发加密消息，收到 Bot 的加密回复"
  else
    extra_item FAIL 加密私聊 "没收到 Bot 的加密回复：$(agent_tail "$out")"
  fi
  printf '%s\n' "$out"
}

# 真问到模型：回答里不能是网关或 Agent 的报错（模型不存在、上游出错）。
agent_check_model() {
  local out rc=0
  agent_need 模型能回话 model || return 0
  out="$(agent_say --reply any --wait 240 --text '请只回答：模型验收通过。' 2>&1)" || rc=$?
  printf '%s\n' "$out"
  if ((rc == 0)) && ! grep -Eiq 'model was not found|couldn.t finish|could not finish|provider-error|⚠️' <<<"$out"; then
    extra_item PASS 模型能回话 "经模型网关回答了（上游模型 ${WONTON_DEV_MODEL:-}）"
  else
    extra_item FAIL 模型能回话 "接了模型上游，回答失败：$(agent_tail "$out")"
  fi
}

# MCP 总线本身：tools/list 有核心的 wonton__list_plugins，真调一次（只读）。不要手机。
agent_check_mcp_bus() {
  local out
  if ! out="$(mcp list 2>&1)"; then
    extra_item FAIL MCP工具 "总线 tools/list 失败：$(agent_tail "$out")"
  elif ! jq -e 'any(.[]; .name == "wonton__list_plugins")' <<<"$out" >/dev/null 2>&1; then
    extra_item FAIL MCP工具 "总线 tools/list 里没有 wonton__list_plugins"
  elif ! out="$(mcp call wonton__list_plugins '{}' 2>&1)"; then
    extra_item FAIL MCP工具 "调 wonton__list_plugins 失败：$(agent_tail "$out")"
  else
    extra_item PASS MCP工具 "总线 tools/list 有 wonton__list_plugins，只读调用成功"
  fi
}

# Agent 自己经总线调工具：让它列已装的插件，回答里要有核心预装的模型网关。
agent_check_mcp_chat() {
  local out rc=0
  agent_need MCP工具 model || return 0
  out="$(agent_say --reply any --settle 10 --wait 240 \
    --text '用 wonton__list_plugins 列出已装的插件，一个一行，不要解释。' 2>&1)" || rc=$?
  printf '%s\n' "$out"
  if ((rc == 0)) && grep -q 'ai.usemagpie.magpie' <<<"$out"; then
    extra_item PASS MCP工具 "Agent 在聊天里调了 wonton__list_plugins，回答里有预装的模型网关"
  else
    extra_item FAIL MCP工具 "Agent 没在聊天里调成 wonton__list_plugins：$(agent_tail "$out")"
  fi
}

# 等一张标题里含 <文字> 的确认卡片，按 <approve|reject> 回答；卡片没出现返回 1。选项带 choice_id 的
# （ACP 的权限卡）要把那个选项自己的 answer 和 choice_id 一起发回去。
agent_card_answer() {
  local want="$1" needle="$2" list id body
  for _ in $(seq 1 120); do
    list="$(smoke_api GET /_wonton/api/confirmations 2>/dev/null)" || list='{}'
    id="$(jq -r --arg n "$needle" '[.confirmations[]? | select(.title | contains($n)) | .id][0] // empty' <<<"$list")"
    if [[ -n "$id" ]]; then
      body="$(jq -c --arg id "$id" --arg a "$want" '[.confirmations[] | select(.id == $id) | .choices[]?
        | select(((.answer // .kind) // "") | startswith($a))][0] // {} | {answer: (.answer // $a)}
        + (if .choice_id then {choice_id} else {} end)' <<<"$list")"
      echo "卡片 $id：回答 $body"
      smoke_api POST "/_wonton/confirmations/$id" -H 'Content-Type: application/json' -d "$body"
      return
    fi
    sleep 1
  done
  return 1
}

# 确认卡片：让 Agent 用 shell 跑命令，卡片同意一次（输出回到聊天）、拒绝一次（命令没跑，Agent 如实说）。
agent_check_card() {
  local file bg
  agent_need 确认卡片 model || return 0
  file="$(agent_tmp)"
  agent_say --reply any --wait 240 --text '用 shell 跑一条命令：echo card-ok，然后只说命令输出。' >"$file" 2>&1 &
  bg=$!
  if agent_card_answer approve 'echo card-ok'; then
    wait "$bg"
    if grep -q 'card-ok' "$file"; then
      extra_item PASS 确认卡片 "跑命令前出了确认卡片，同意后命令的输出回到聊天"
    else
      extra_item FAIL 确认卡片 "同意了卡片，聊天里没等到命令输出：$(agent_tail "$(cat "$file")")"
    fi
  else
    kill "$bg" 2>/dev/null; wait "$bg"
    extra_item FAIL 确认卡片 "让 Agent 跑命令，等不到确认卡片：$(agent_tail "$(cat "$file")")"
  fi
  cat "$file"
  agent_say --reply any --wait 240 --text '再用 shell 跑一条命令：echo card-no，然后只说结果。' >"$file" 2>&1 &
  bg=$!
  if agent_card_answer reject 'echo card-no'; then
    wait "$bg"
    if grep -qxE ' *card-no *' "$file" || ! grep -Eiq '拒绝|没(有)?执行|未执行|denied|rejected|cancel' "$file"; then
      extra_item FAIL 确认卡片 "拒绝了卡片，回答看不出命令没跑：$(agent_tail "$(cat "$file")")"
    else
      extra_item PASS 确认卡片 "拒绝卡片后命令没跑，Agent 如实说了"
    fi
  else
    kill "$bg" 2>/dev/null; wait "$bg"
    extra_item FAIL 确认卡片 "第二次跑命令等不到确认卡片：$(agent_tail "$(cat "$file")")"
  fi
  cat "$file"
  rm -f "$file"
}

# 打断：先交一个要跑很久的活，再从另一台设备发 /wonton interrupt，新的一轮要能回答。
agent_check_interrupt() {
  local file bg out rc=0
  agent_need 打断 model || return 0
  file="$(agent_tmp)"
  agent_say --reply any --wait 240 --text '先用 shell 跑 sleep 45，跑完只回答一句：数完了。' >"$file" 2>&1 &
  bg=$!
  sleep 8
  out="$(agent_say --reply any --wait 180 --settle 20 --text '/wonton interrupt 只回答一句：打断好了。' 2>&1)" || rc=$?
  wait "$bg"
  cat "$file"
  rm -f "$file"
  printf '%s\n' "$out"
  if ((rc == 0)) && grep -q '打断好了' <<<"$out"; then
    extra_item PASS 打断 "/wonton interrupt 停下手上的活，新的一轮回答了"
  else
    extra_item FAIL 打断 "打断后没等到新一轮的回答：$(agent_tail "$out")"
  fi
}

agent_wait_healthy() { # <容器>：最多等 3 分钟
  for _ in $(seq 1 90); do
    [[ "$(docker inspect "$1" --format '{{.State.Health.Status}}' 2>/dev/null)" == healthy ]] && return 0
    sleep 2
  done
  return 1
}

# 重启插件的这些服务（数据卷留着），等它们重新 healthy。<服务…> 是清单里的服务名。
agent_check_restart() {
  local svc container containers=() bad=""
  for svc in "$@"; do
    container="$(running_container "wonton-$SMOKE_INSTANCE--$SMOKE_SLUG--$svc")" ||
      { extra_item FAIL 重启后还能聊 "找不到服务 $svc 在跑的容器"; return 0; }
    containers+=("$container")
  done
  docker restart "${containers[@]}" >/dev/null ||
    { extra_item FAIL 重启后还能聊 "docker restart 失败：${containers[*]}"; return 0; }
  for container in "${containers[@]}"; do
    agent_wait_healthy "$container" || bad="$bad $container"
  done
  if [[ -n "$bad" ]]; then
    extra_item FAIL 重启后还能聊 "重启后 3 分钟没回到 healthy：$bad"
  else
    extra_item PASS 重启后还能聊 "$* 重启后重新 healthy"
  fi
}

# 续聊：问第一条消息里留的暗号，重启以后同一个会话还带得住上下文。
agent_check_resume() { # <暗号>
  local out rc=0
  agent_need 续聊 model || return 0
  out="$(agent_say --reply any --wait 240 --text '我们第一次说话时留的暗号是什么？只回答暗号。' 2>&1)" || rc=$?
  printf '%s\n' "$out"
  if ((rc == 0)) && grep -qF "$1" <<<"$out"; then
    extra_item PASS 续聊 "同一个会话记得第一条消息里的暗号"
  else
    extra_item FAIL 续聊 "问不回暗号 $1：$(agent_tail "$out")"
  fi
}

# Matrix 客户端接口：<令牌> <方法> <路径> [JSON 正文]，在核心容器里发（同 probes_matrix），正文只用 ASCII。
agent_matrix() {
  MATRIX_TOKEN="$1" probes_matrix "${@:2}"
}

# 名单外不应答：Bot 只听名单里的人。名单外的临时用户在主房间里发一条，30 秒内 Bot 不许回；踢掉他以后用户在
# 同一个房间发一条，Bot 必须回：说明 Bot 在收这个房间的消息，前一条是看到了不答，不是没在跑。
# 临时用户用 Matrix 服务器的注册共享密钥建；邀请、踢人、读消息用用户本人的身份（管理接口代登录，用完退出），
# 不碰 Bot 的令牌。
agent_check_outsider() {
  local admin owner owner_token secret nonce pass name mac reg outsider outsider_token room_url since seen out rc=0 expect
  agent_need 名单外不应答 || return 0
  admin="$(docker exec "$SMOKE_CORE" cat "$SMOKE_DATA_DIR/core/matrix-admin-token")" ||
    { extra_item FAIL 名单外不应答 "读不到核心的 Matrix 管理令牌"; return 0; }
  owner="@$SMOKE_OWNER:${AGENT_BOT#*:}"
  owner_token="$(agent_matrix "$admin" POST "/_synapse/admin/v1/users/$(jq -rn --arg u "$owner" '$u | @uri')/login" '{}' |
    jq -r '.access_token // empty')"
  [[ -n "$owner_token" ]] || { extra_item FAIL 名单外不应答 "代登录用户 $owner 失败"; return 0; }
  # shellcheck disable=SC2016 # 单引号里是核心容器里的变量
  secret="$(docker exec "$SMOKE_CORE" sh -c 'cat "$WONTON_MATRIX_REGISTRATION_SECRET_FILE"')" ||
    { extra_item FAIL 名单外不应答 "读不到 Matrix 服务器的注册共享密钥"; return 0; }
  # 注册接口不认令牌，带上管理令牌只是不发空的 Authorization 头。
  nonce="$(agent_matrix "$admin" GET /_synapse/admin/v1/register | jq -r '.nonce // empty')"
  pass="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
  name="smoke-outsider-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
  # 共享密钥注册的签名：HMAC-SHA1(nonce \0 用户名 \0 密码 \0 admin)。用服务器管理员注册：Bot 的名单不看对方是不是管理员，临时用户随冒烟实例一起删。
  mac="$(python3 -c 'import hmac,hashlib,sys; print(hmac.new(sys.argv[1].encode(), "\0".join(sys.argv[2:]).encode(), hashlib.sha1).hexdigest())' \
    "$secret" "$nonce" "$name" "$pass" admin)"
  reg="$(agent_matrix "$admin" POST /_synapse/admin/v1/register "$(jq -cn --arg n "$nonce" --arg u "$name" --arg p "$pass" \
    --arg m "$mac" '{nonce: $n, username: $u, password: $p, admin: true, mac: $m}')")"
  outsider="$(jq -r '.user_id // empty' <<<"$reg" 2>/dev/null)"
  outsider_token="$(jq -r '.access_token // empty' <<<"$reg" 2>/dev/null)"
  [[ -n "$outsider" && -n "$outsider_token" ]] ||
    { extra_item FAIL 名单外不应答 "注册名单外的临时用户失败：$(agent_tail "$reg")"; return 0; }
  room_url="$(jq -rn --arg r "$AGENT_ROOM" '$r | @uri')"
  agent_matrix "$owner_token" POST "/_matrix/client/v3/rooms/$room_url/invite" \
    "$(jq -cn --arg u "$outsider" '{user_id: $u}')" >/dev/null
  agent_matrix "$outsider_token" POST "/_matrix/client/v3/rooms/$room_url/join" '{}' | jq -e '.room_id' >/dev/null ||
    { extra_item FAIL 名单外不应答 "名单外的人进不了主房间（用户邀请他失败？）"; return 0; }
  since="$(($(date +%s) * 1000))"
  agent_matrix "$outsider_token" PUT "/_matrix/client/v3/rooms/$room_url/send/m.room.message/smoke-outsider-$since" \
    "$(jq -cn --arg b "$AGENT_BOT" '{msgtype: "m.text", body: "outsider smoke: please reply", "m.mentions": {user_ids: [$b]}}')" |
    jq -e '.event_id' >/dev/null || { extra_item FAIL 名单外不应答 "名单外的人发不出消息"; return 0; }
  sleep 30
  seen="$(agent_matrix "$owner_token" GET "/_matrix/client/v3/rooms/$room_url/messages?dir=b&limit=100" |
    jq --arg b "$AGENT_BOT" --argjson t "$since" '[.chunk[]? | select(.sender == $b and (.origin_server_ts // 0) >= $t
      and (.type == "m.room.message" or .type == "m.room.encrypted"))] | length')"
  # 踢掉以后房间回到两个人，Bot 按私聊处理（有的 Agent 在三人房间里整个不回）。
  agent_matrix "$owner_token" POST "/_matrix/client/v3/rooms/$room_url/kick" \
    "$(jq -cn --arg u "$outsider" '{user_id: $u}')" >/dev/null
  agent_matrix "$outsider_token" POST /_matrix/client/v3/logout '{}' >/dev/null
  agent_matrix "$owner_token" POST /_matrix/client/v3/logout '{}' >/dev/null
  if [[ "$seen" != 0 ]]; then
    extra_item FAIL 名单外不应答 "名单外的人（$outsider）发消息后 Bot 回了 ${seen:-?} 条"
    return 0
  fi
  sleep 10
  expect="名单内通过"
  [[ -n "${WONTON_DEV_MODEL_BASE_URL:-}" ]] || expect=""
  out="$(agent_say --reply any --settle 15 --wait 240 --mention "$AGENT_BOT" \
    --text '同一个房间里的对照：请只回答 名单内通过' 2>&1)" || rc=$?
  printf '%s\n' "$out"
  if ((rc == 0)) && grep -qF "$expect" <<<"$out"; then
    extra_item PASS 名单外不应答 "名单外的人发消息 30 秒没有回答，用户随后在同一房间得到回答"
  else
    extra_item FAIL 名单外不应答 "名单外的人没得到回答，但用户随后在同一房间也没得到回答：$(agent_tail "$out")"
  fi
}
