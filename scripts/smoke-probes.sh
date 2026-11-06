# scripts/smoke.sh 的一项一项探测，跟着插件走。没写的项会 FAIL 并给出写法，不会默认放行。
# shellcheck shell=bash
#
# 页面：web_assert 从标准输入读页面，命中的确是应用的真实页面时返回 0。
# 身份：identity_check 用应用自己的“当前用户”接口断言认出的是用户管理员。没有用户体系时写 IDENTITY_NA=1，
#       并在 SMOKE_NOTE 里写原因。dweb / web_get 是带用户会话的请求助手，可继续走应用自己的登录链。
# 工具：MCP_TOOL 写一个只读工具名（可带插件前缀），MCP_ARGS 是 JSON 参数；mcp_assert 从标准输入读调用结果。
#       要断言多个工具时改成写 mcp_check；调用前要备数据时写 before_mcp。
# 装之前要准备（如先配出口代理）：写 before_install。

web_assert() { grep -qi 'vikunja'; }   # 应用真实页面

# 走完浏览器式 OIDC（Hydra authorize 用核心会话自动登录）→ 回调拿 code → 应用自己的
# POST /api/v1/auth/openid/wonton/callback 换令牌，令牌打到标准输出（诊断走标准错误）。
# 变量同时兼容 e2e 冒烟（E2E_*）和仓库自带的 dev.sh smoke（SMOKE_*）两套命名。
# 本地登录和注册在清单里关掉了，顺带断言这两项没开。
vk_id() { # 插件 id：冒烟主流程没导出时（e2e 的 data_write 在装 tag 阶段跑）从检出的清单读
  local id="${E2E_NAME_ID:-}${SMOKE_PLUGIN_ID:-}"
  if [[ -n "$id" ]]; then printf '%s' "$id"; return 0; fi
  local dir="${E2E_DIR:-}${SMOKE_DIR:-}"
  [[ -n "$dir" && -f "$dir/docker-compose.yml" ]] || { echo "拿不到插件 id（主流程变量和检出目录都没有）" >&2; return 1; }
  docker compose -f "$dir/docker-compose.yml" config --no-interpolate --format json | jq -r '."x-wonton".id'
}

vk_web_base() { # 应用网页源点：主流程给了就用；data_write 阶段还没有时，经核心 API 查插件列表
  local url plugins id
  url="${E2E_WEB_URL:-}${SMOKE_WEB_URL:-}"
  if [[ -z "$url" ]]; then
    id="$(vk_id)" || return 1
    plugins="$(e2e_api GET /_wonton/api/plugins)" || { echo "查不到插件列表" >&2; return 1; }
    url="$(jq -rn --arg json "$plugins" --arg id "$id" \
      '$json | fromjson | .plugins[] | select(.id==$id) | .web_url // ""')"
    [[ -n "$url" ]] || { echo "插件列表里没有 $id 的网页地址" >&2; return 1; }
  fi
  sed -E 's#^(https?://[^/]+).*#\1#' <<<"$url"   # 新核心的地址带入口路径，应用 API 在源点下
}

vk_token() {
  local jar base_core base_web token client info auth_url redirect enc_redirect state final code body token_out
  jar="${E2E_JAR:-}${SMOKE_JAR:-}"
  base_core="${E2E_BASE:-}${SMOKE_BASE:-}"
  token="${E2E_TOKEN:-}${SMOKE_TOKEN:-}"
  base_web="$(vk_web_base)" || return 1
  # 核心会话和应用会话都补进 jar：e2e 的 web_login 在网页节才跑，data_write 阶段 jar 可能还没有
  # 应用会话。-b 保留已有 cookie（只写 -c 会把 jar 里别的域的会话抹掉）。
  curl -sS --noproxy '*' -o /dev/null -b "$jar" -c "$jar" --data-urlencode "token=$token" "$base_core/_wonton/login" ||
    { echo "主人令牌登录不了核心" >&2; return 1; }
  curl -sS --noproxy '*' -o /dev/null -L -b "$jar" -c "$jar" -H 'Accept: text/html' "$base_web/" ||
    { echo "走不通应用网页的登录跳转" >&2; return 1; }
  info="$(curl -sS --noproxy '*' --fail-with-body -b "$jar" "$base_web/api/v1/info")" ||
    { echo "取 /api/v1/info 失败" >&2; return 1; }
  auth_url="$(jq -r '.auth.openid_connect.providers[0].auth_url' <<<"$info")"
  [[ -n "$auth_url" && "$auth_url" != null ]] || { echo "没有 OIDC provider：$info" >&2; return 1; }
  jq -e '.auth.local.enabled == false and .auth.local.registration_enabled == false' <<<"$info" >/dev/null ||
    { echo "本地登录或注册还开着：$(jq -c .auth.local <<<"$info")" >&2; return 1; }
  client="$(vk_id)" || return 1
  redirect="$base_web/auth/openid/wonton"
  enc_redirect="$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$redirect")"
  state="$(head -c8 /dev/urandom | od -An -tx1 | tr -d ' \n')"   # Hydra 要求 state ≥ 8 字符
  final="$(curl -sS --noproxy '*' -o /dev/null -L -b "$jar" -c "$jar" -H 'Accept: text/html' \
    -w '%{url_effective}' \
    "$auth_url?client_id=$client&redirect_uri=$enc_redirect&response_type=code&scope=openid+profile+email&state=$state")" ||
    { echo "authorize 链失败" >&2; return 1; }
  code="$(python3 -c 'import sys,urllib.parse;print((urllib.parse.parse_qs(urllib.parse.urlparse(sys.argv[1]).query).get("code") or [""])[0])' "$final")"
  [[ -n "$code" ]] || { echo "回调里没有 code：$final" >&2; return 1; }
  body="$(jq -nc --arg c "$code" --arg r "$redirect" '{code:$c,redirect_url:$r}')"
  token_out="$(curl -sS --noproxy '*' -b "$jar" -H 'Content-Type: application/json' -d "$body" \
    "$base_web/api/v1/auth/openid/wonton/callback" | jq -r '.token // empty')" ||
    { echo "callback 换令牌失败：$token_out" >&2; return 1; }
  [[ -n "$token_out" ]] || { echo "callback 没有返回令牌" >&2; return 1; }
  printf '%s' "$token_out"
}

identity_check() {
  local token me base_web
  base_web="$(vk_web_base)" || return 1
  token="$(vk_token)" || return 1
  me="$(curl -sS --noproxy '*' --fail-with-body -b "${E2E_JAR:-}${SMOKE_JAR:-}" \
    -H "Authorization: Bearer $token" "$base_web/api/v1/user")" || { echo "/api/v1/user 失败：$me"; return 1; }
  jq -e --arg u "${E2E_OWNER:-}${SMOKE_OWNER:-}" '.username == $u' <<<"$me" >/dev/null ||
    { echo "当前用户不是用户 ${E2E_OWNER:-}${SMOKE_OWNER:-}：$me"; return 1; }
}

# 保数据：经应用自己的 API（OIDC 换令牌后 Bearer 调用）建一个标题带随机标记的项目和一个任务，
# 标记写进 $SMOKE_STATE；升级/重装后按 id 读回来核对标题。data_write 在装 main 最新 tag 的阶段跑
# （早于主流程的 web_login 和 E2E_WEB_URL），所以会话和源点由 vk_token/vk_web_base 自取。
# 接口形状按 v2.8.0 的 swagger：PUT /api/v1/projects、PUT /api/v1/projects/{id}/tasks。
data_write() {
  local jar base_web token marker project project_id task task_id
  jar="${E2E_JAR:-}${SMOKE_JAR:-}"
  base_web="$(vk_web_base)" || return 1
  token="$(vk_token)" || { echo "拿不到应用令牌，写不了数据" >&2; return 1; }
  marker="保数据-$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
  project="$(curl -sS --noproxy '*' --fail-with-body -b "$jar" -X PUT \
    -H "Authorization: Bearer $token" -H 'Content-Type: application/json' -d "{\"title\":\"$marker\"}" \
    "$base_web/api/v1/projects")" || { echo "建项目失败：$project"; return 1; }
  project_id="$(jq -r '.id // empty' <<<"$project")"
  [[ -n "$project_id" ]] || { echo "建项目没回 id：$project"; return 1; }
  task="$(curl -sS --noproxy '*' --fail-with-body -b "$jar" -X PUT \
    -H "Authorization: Bearer $token" -H 'Content-Type: application/json' -d "{\"title\":\"$marker\"}" \
    "$base_web/api/v1/projects/$project_id/tasks")" || { echo "建任务失败：$task"; return 1; }
  task_id="$(jq -r '.id // empty' <<<"$task")"
  [[ -n "$task_id" ]] || { echo "建任务没回 id：$task"; return 1; }
  jq -nc --arg m "$marker" --arg p "$project_id" --arg t "$task_id" \
    '{marker:$m,project_id:$p,task_id:$t}' >"$SMOKE_STATE"
}

data_check() {
  local base_web token marker project_id task_id seen
  base_web="$(vk_web_base)" || return 1
  marker="$(jq -r .marker "$SMOKE_STATE")"
  project_id="$(jq -r .project_id "$SMOKE_STATE")"
  task_id="$(jq -r .task_id "$SMOKE_STATE")"
  token="$(vk_token)" || { echo "拿不到应用令牌，查不了数据" >&2; return 1; }
  seen="$(curl -sS --noproxy '*' -b "${E2E_JAR:-}${SMOKE_JAR:-}" -H "Authorization: Bearer $token" \
    "$base_web/api/v1/projects/$project_id")" ||
    { echo "项目 $project_id 读不到（数据丢了？）：$seen"; return 1; }
  [[ "$(jq -r '.title // empty' <<<"$seen")" == "$marker" ]] ||
    { echo "项目对不上：期待标题 $marker（id $project_id），看到 $(jq -c '{id,title}' <<<"$seen" 2>/dev/null || head -c 200 <<<"$seen")"; return 1; }
  seen="$(curl -sS --noproxy '*' -b "${E2E_JAR:-}${SMOKE_JAR:-}" -H "Authorization: Bearer $token" \
    "$base_web/api/v1/tasks/$task_id")" ||
    { echo "任务 $task_id 读不到（数据丢了？）：$seen"; return 1; }
  [[ "$(jq -r '.title // empty' <<<"$seen")" == "$marker" ]] ||
    { echo "任务对不上：期待标题 $marker（id $task_id），看到 $(jq -c '{id,title}' <<<"$seen" 2>/dev/null || head -c 200 <<<"$seen")"; return 1; }
}
