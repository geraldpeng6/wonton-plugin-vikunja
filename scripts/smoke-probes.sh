# scripts/smoke.sh 的一项一项探测，跟着插件走。没写的项会 FAIL 并给出写法，不会默认放行。
# shellcheck shell=bash disable=SC2034
#
# 页面：web_assert 从标准输入读页面，命中的确是应用的真实页面时返回 0。
# 身份：identity_check 用应用自己的"当前用户"接口断言认出的是用户管理员。没有用户体系时写 IDENTITY_NA=1，
#       并在 SMOKE_NOTE 里写原因。dweb / web_get 是带用户会话的请求助手，可继续走应用自己的登录链。
# 工具：MCP_TOOL 写一个只读工具名（可带插件前缀），MCP_ARGS 是 JSON 参数；mcp_assert 从标准输入读调用结果。
#       要断言多个工具时改成写 mcp_check；调用前要备数据时写 before_mcp。
# 装之前要准备（如先配出口代理）：写 before_install。

_vk_origin() { # web_url 可能带路径和查询（如 /login?redirectToProvider=…），拼 API 前取 origin
  local u="${SMOKE_WEB_URL%%\?*}" rest="${SMOKE_WEB_URL#*://}"
  printf '%s://%s' "${u%%://*}" "${rest%%/*}"
}

web_assert() { grep -qi 'vikunja'; }   # 应用真实页面

# 走完浏览器式 OIDC（Hydra authorize 用核心会话自动登录）→ 回调拿 code → 应用自己的
# POST /api/v1/auth/openid/wonton/callback 换令牌，令牌打到标准输出（诊断走标准错误）。
# 只用冒烟契约里的 SMOKE_JAR/SMOKE_WEB_URL/SMOKE_BASE/SMOKE_TOKEN 和助手 web_get；client_id 是
# 本插件清单自己的 id，provider 键 wonton 也来自清单。本地登录和注册在清单里关掉了，顺带断言这两项没开。
vk_token() {
  local jar base_core token info auth_url redirect enc_redirect state final code body token_out
  jar="${SMOKE_JAR:-}"
  base_core="${SMOKE_BASE:-}"
  token="${SMOKE_TOKEN:-}"
  [[ -n "$jar" && -n "$base_core" && -n "$token" && -n "${SMOKE_WEB_URL:-}" ]] ||
    { echo "缺冒烟变量：需要 SMOKE_JAR/SMOKE_BASE/SMOKE_TOKEN/SMOKE_WEB_URL" >&2; return 1; }
  # 核心会话和应用会话都补进 jar：主流程的 web_login 可能在更晚阶段才跑。-b 保留已有 cookie
  # （只写 -c 会把 jar 里别的域的会话抹掉）。
  curl -sS --noproxy '*' -o /dev/null -b "$jar" -c "$jar" --data-urlencode "token=$token" "$base_core/_wonton/login" ||
    { echo "主人令牌登录不了核心" >&2; return 1; }
  curl -sS --noproxy '*' -o /dev/null -L -b "$jar" -c "$jar" -H 'Accept: text/html' "$SMOKE_WEB_URL" ||
    { echo "走不通应用网页的登录跳转" >&2; return 1; }
  # 2.8.0 起部分路由在 /api/v2（登录页提示原文就是 v2），/info 先试 v2 再回落 v1；都带现场。
  info="$(curl -sS --noproxy '*' -o /tmp/vk-info -w '%{http_code}' -b "$jar" "$(_vk_origin)/api/v2/info")" &&
    jq -e '.auth != null' </tmp/vk-info >/dev/null 2>&1 ||
    info="$(curl -sS --noproxy '*' -o /tmp/vk-info -w '%{http_code}' --fail-with-body -b "$jar" "$(_vk_origin)/api/v1/info")" ||
    { echo "取 /api/v2/info（含 /api/v1 回落）失败：HTTP $info $(head -c 200 </tmp/vk-info 2>/dev/null)" >&2; return 1; }
  info="$(cat /tmp/vk-info)"
  auth_url="$(jq -r '.auth.openid_connect.providers[0].auth_url' <<<"$info")"
  [[ -n "$auth_url" && "$auth_url" != null ]] || { echo "没有 OIDC provider：$info" >&2; return 1; }
  jq -e '.auth.local.enabled == false and .auth.local.registration_enabled == false' <<<"$info" >/dev/null ||
    { echo "本地登录或注册还开着：$(jq -c .auth.local <<<"$info")" >&2; return 1; }
  redirect="$(_vk_origin)/auth/openid/wonton"
  enc_redirect="$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$redirect")"
  state="$(head -c8 /dev/urandom | od -An -tx1 | tr -d ' \n')"   # Hydra 要求 state ≥ 8 字符
  final="$(curl -sS --noproxy '*' -o /dev/null -L -b "$jar" -c "$jar" -H 'Accept: text/html' \
    -w '%{url_effective}' \
    "$auth_url?client_id=io.vikunja.vikunja&redirect_uri=$enc_redirect&response_type=code&scope=openid+profile+email&state=$state")" ||
    { echo "authorize 链失败" >&2; return 1; }
  code="$(python3 -c 'import sys,urllib.parse;print((urllib.parse.parse_qs(urllib.parse.urlparse(sys.argv[1]).query).get("code") or [""])[0])' "$final")"
  [[ -n "$code" ]] || { echo "回调里没有 code：$final" >&2; return 1; }
  body="$(jq -nc --arg c "$code" --arg r "$redirect" '{code:$c,redirect_url:$r}')"
  token_out="$(curl -sS --noproxy '*' -b "$jar" -H 'Content-Type: application/json' -d "$body" \
    "$(_vk_origin)/api/v1/auth/openid/wonton/callback" | jq -r '.token // empty')" ||
    { echo "callback 换令牌失败：$token_out" >&2; return 1; }
  [[ -n "$token_out" ]] || { echo "callback 没有返回令牌" >&2; return 1; }
  printf '%s' "$token_out"
}

identity_check() {
  local token me
  token="$(vk_token)" || return 1
  # 2.8.0 起用户端点也在 /api/v2（同 info），先 v2 再回落 v1；套件 web_get 直接拼 web_url
  # （带 /login?redirectToProvider=… 路径）会落进页面兜底，这里按 origin 直调。
  me="$(curl -sS --noproxy '*' --fail-with-body -b "${SMOKE_JAR:-}" -H "Authorization: Bearer $token" "$(_vk_origin)/api/v2/user")" &&
    jq -e '.username != null' <<<"$me" >/dev/null 2>&1 ||
    me="$(curl -sS --noproxy '*' --fail-with-body -b "${SMOKE_JAR:-}" -H "Authorization: Bearer $token" "$(_vk_origin)/api/v1/user")" ||
    { echo "/api/v2/user（含 /api/v1 回落）失败：$me"; return 1; }
  jq -e --arg u "$SMOKE_OWNER" '.username == $u' <<<"$me" >/dev/null ||
    { echo "当前用户不是用户 $SMOKE_OWNER：$me"; return 1; }
}

# 保数据：经应用自己的 API（OIDC 换令牌后 Bearer 调用）建一个标题带随机标记的项目和一个任务，
# 标记写进 $SMOKE_STATE；升级/重装后按 id 读回来核对标题。只依赖契约变量（SMOKE_JAR/SMOKE_WEB_URL/
# SMOKE_BASE/SMOKE_TOKEN/SMOKE_STATE）。接口形状按 v2.8.0 的 swagger：
# PUT /api/v1/projects、PUT /api/v1/projects/{id}/tasks。
marker_file() { # SMOKE_STATE 在套件里是状态目录（e2e 传的是标记文件本身），标记放对应路径
  if [[ -d "$SMOKE_STATE" ]]; then printf '%s' "$SMOKE_STATE/vikunja-marker"; else printf '%s' "${SMOKE_STATE}.marker"; fi
}

data_write() {
  local token marker project project_id task task_id
  [[ -n "${SMOKE_JAR:-}" && -n "${SMOKE_WEB_URL:-}" ]] ||
    { echo "缺冒烟变量：需要 SMOKE_JAR/SMOKE_WEB_URL" >&2; return 1; }
  token="$(vk_token)" || { echo "拿不到应用令牌，写不了数据" >&2; return 1; }
  marker="保数据-$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
  project="$(curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" -X PUT \
    -H "Authorization: Bearer $token" -H 'Content-Type: application/json' -d "{\"title\":\"$marker\"}" \
    "$(_vk_origin)/api/v1/projects")" || { echo "建项目失败：$project"; return 1; }
  project_id="$(jq -r '.id // empty' <<<"$project")"
  [[ -n "$project_id" ]] || { echo "建项目没回 id：$project"; return 1; }
  task="$(curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" -X PUT \
    -H "Authorization: Bearer $token" -H 'Content-Type: application/json' -d "{\"title\":\"$marker\"}" \
    "$(_vk_origin)/api/v1/projects/$project_id/tasks")" || { echo "建任务失败：$task"; return 1; }
  task_id="$(jq -r '.id // empty' <<<"$task")"
  [[ -n "$task_id" ]] || { echo "建任务没回 id：$task"; return 1; }
  jq -nc --arg m "$marker" --arg p "$project_id" --arg t "$task_id" \
    '{marker:$m,project_id:$p,task_id:$t}' >"$(marker_file)"
}

data_check() {
  local token marker project_id task_id seen
  marker="$(jq -r .marker "$(marker_file)")"
  project_id="$(jq -r .project_id "$(marker_file)")"
  task_id="$(jq -r .task_id "$(marker_file)")"
  token="$(vk_token)" || { echo "拿不到应用令牌，查不了数据" >&2; return 1; }
  seen="$(curl -sS --noproxy '*' -b "$SMOKE_JAR" -H "Authorization: Bearer $token" \
    "$(_vk_origin)/api/v1/projects/$project_id")" ||
    { echo "项目 $project_id 读不到（数据丢了？）：$seen"; return 1; }
  [[ "$(jq -r '.title // empty' <<<"$seen")" == "$marker" ]] ||
    { echo "项目对不上：期待标题 $marker（id $project_id），看到 $(jq -c '{id,title}' <<<"$seen" 2>/dev/null || head -c 200 <<<"$seen")"; return 1; }
  seen="$(curl -sS --noproxy '*' -b "$SMOKE_JAR" -H "Authorization: Bearer $token" \
    "$(_vk_origin)/api/v1/tasks/$task_id")" ||
    { echo "任务 $task_id 读不到（数据丢了？）：$seen"; return 1; }
  [[ "$(jq -r '.title // empty' <<<"$seen")" == "$marker" ]] ||
    { echo "任务对不上：期待标题 $marker（id $task_id），看到 $(jq -c '{id,title}' <<<"$seen" 2>/dev/null || head -c 200 <<<"$seen")"; return 1; }
}

# ---------- 邮件（notify）：真发一封提醒信，核对核心投进私聊（extra_check 由 e2e 冒烟跑） ----------

core_container() { # 核心容器：实例名拼（e2e 起的栈核心容器名固定这个形状）
  printf '%s' "wonton-${SMOKE_INSTANCE:?}--core"
}

mailpit_messages() { # 经核心的网络栈读 Mailpit 收件箱 API（SMTP 25/HTTP 8025 都不发布到宿主）。
  # API 要 Basic 认证（core:<密钥>，密钥在核心数据目录，核心的 mailbox 组件生成）。
  local pwd
  pwd="$(docker exec "$(core_container)" sh -c 'cat "$WONTON_DATA_DIR/core/mailpit/api-password"')" ||
    { echo "读不到 Mailpit API 密钥"; return 1; }
  docker run --rm --network "container:$(core_container)" curlimages/curl:8.23.0 --noproxy '*' -s \
    -u "core:$pwd" "http://mailpit.wonton.internal:8025/api/v1/messages?limit=50"
}

_ours_in_mailpit() { # <owner 邮箱>：Vikunja 发的、还没被核心取走的信（From 是注入的发件地址）
  mailpit_messages | jq -r --arg f "io.vikunja.vikunja@plugins.wonton.internal" --arg t "$1" '
    [.messages[] | select((.From.Address == $f) and ([.To[].Address] | index($t)))] | length'
}

extra_check() { # 邮件专项：建一个 90 秒后提醒的任务，等提醒信出现、再等核心投进私聊后取走
  local token marker project_id task reminder out
  [[ -n "${SMOKE_JAR:-}" && -n "${SMOKE_WEB_URL:-}" && -n "${SMOKE_OWNER:-}" ]] ||
    { echo "缺冒烟变量：需要 SMOKE_JAR/SMOKE_WEB_URL/SMOKE_OWNER" >&2; return 1; }
  token="$(vk_token)" || { echo "拿不到应用令牌" >&2; return 1; }
  # 收件人是主人的内部邮箱（<用户名>@wonton.internal，规范固定的形状；冒烟工具按形状拼，应用不发它
  # 之外的收件人）。Vikunja 的收件人只能来自 OIDC 的 email 声明，没有发外部地址的功能可触发。
  local owner_email="$SMOKE_OWNER@wonton.internal"

  marker="提醒-$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
  project="$(curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" -X PUT \
    -H "Authorization: Bearer $token" -H 'Content-Type: application/json' -d "{\"title\":\"$marker\"}" \
    "$(_vk_origin)/api/v1/projects")" || { echo "建项目失败：$project"; return 1; }
  project_id="$(jq -r '.id // empty' <<<"$project")"
  [[ -n "$project_id" ]] || { echo "建项目没回 id：$project"; return 1; }
  # 提醒时间 = 现在 + 90 秒（提醒的 cron 每分钟跑一次，查「本分钟到期」的提醒）
  reminder="$(python3 -c 'import datetime;print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(seconds=90)).isoformat())')"
  task="$(curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" -X PUT \
    -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
    -d "{\"title\":\"$marker\",\"reminders\":[{\"reminder\":\"$reminder\"}]}" \
    "$(_vk_origin)/api/v1/projects/$project_id/tasks")" || { echo "建任务失败：$task"; return 1; }
  task_id="$(jq -r '.id // empty' <<<"$task")"
  [[ -n "$task_id" ]] || { echo "建任务没回 id：$task"; return 1; }
  echo "建了任务 $task_id，提醒 $reminder（收件人 $owner_email）"

  # 等信出现：提醒 cron 到点后由 mailer 发出（默认的主题来自通知标题翻译，按 From+To 认）。
  # 出现后再等核心投进私聊并从 Mailpit 删掉（投递成功才删）：数量回到 0 就是投走了。
  local seen=0 i
  for i in {1..60}; do
    sleep 5
    out="$(_ours_in_mailpit "$owner_email")" || { echo "$out"; return 1; }
    if [[ "$out" != 0 ]]; then seen=1; break; fi
  done
  [[ "$seen" == 1 ]] || { echo "等了 5 分钟没看到提醒信进 Mailpit（提醒没触发或 mailer 没发）"; return 1; }
  echo "提醒信进了 Mailpit"
  for i in {1..24}; do
    sleep 5
    out="$(_ours_in_mailpit "$owner_email")" || { echo "$out"; return 1; }
    [[ "$out" == 0 ]] && break
    [[ "$i" == 24 ]] && { echo "等了 2 分钟信还在 Mailpit，核心没取走（投递失败？）"; return 1; }
  done
  echo "提醒信已被核心投进主人的 Wonton 私聊（Mailpit 里删了）"
}
