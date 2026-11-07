# scripts/smoke.sh 的一项一项探测，跟着插件走。没写的项会 FAIL 并给出写法，不会默认放行。
# shellcheck shell=bash
#
# 页面：web_assert 从标准输入读页面，命中的确是应用的真实页面时返回 0。
# 身份：identity_check 用应用自己的“当前用户”接口断言认出的是用户管理员。没有用户体系时写 IDENTITY_NA=1，
#       并在 SMOKE_NOTE 里写原因。dweb / web_get 是带用户会话的请求助手，可继续走应用自己的登录链。
# 工具：MCP_TOOL 写一个只读工具名（可带插件前缀），MCP_ARGS 是 JSON 参数；mcp_assert 从标准输入读调用结果。
#       要断言多个工具时改成写 mcp_check；调用前要备数据时写 before_mcp。
# 数据：data_write 用随机标记建一个项目、把标记原样写进 $SMOKE_STATE（标记文件，data_write 覆盖写），
#       data_check 读回标记去应用里找；
#       升级和重装都会换 OIDC 客户端密钥，所以每次都现取新令牌，不复用旧的。
#       本插件的 API 一律用裸 curl 直连（vikunja_base 给出的域名）：套件的 web_get 会把请求拼到
#       SMOKE_WEB_URL（带 webui.path 的入口）后面，对 webui.path 不是 / 的插件会拼出错误地址。
# 装之前要准备（如先配出口代理）：写 before_install。

web_assert() { grep -qi 'vikunja'; }   # 应用真实页面

# SMOKE_WEB_URL 带着清单 webui.path（/login?redirectToProvider=wonton），API 调用要用剥掉路径的域名。
vikunja_base() {
  [[ -n "${SMOKE_WEB_URL:-}" ]] || probes_web_url || { echo "拿不到插件网页地址"; return 1; }
  python3 -c 'import urllib.parse, sys; p = urllib.parse.urlsplit(sys.argv[1]); print(f"{p.scheme}://{p.netloc}")' "$SMOKE_WEB_URL"
}

# 走完浏览器式 OIDC（Hydra authorize 用核心会话自动登录）→ 回调拿 code → 应用自己的
# POST /api/v1/auth/openid/wonton/callback 换应用令牌，打到标准输出。
# 冒烟的数据钩子跑在第一次会话建立之前，进来先走一遍插件网页登录把核心会话放进 $SMOKE_JAR。
vikunja_token() {
  local base info auth_url redirect enc_redirect state final code body
  base="$(vikunja_base)" || return 1
  if [[ ! -s "${SMOKE_JAR:-}" ]]; then
    probes_dev web --jar "${SMOKE_JAR:-}" --fresh >/dev/null 2>&1 || { echo "建立核心会话失败"; return 1; }
  fi
  info="$(curl -sS --noproxy '*' -b "${SMOKE_JAR:-}" "$base/api/v1/info")" ||
    { echo "取 /api/v1/info 失败"; return 1; }
  auth_url="$(jq -r '.auth.openid_connect.providers[0].auth_url // empty' <<<"$info" 2>/dev/null)"
  [[ -n "$auth_url" ]] || { echo "info 里没有 OIDC provider：$(head -c 200 <<<"$info")"; return 1; }
  redirect="$base/auth/openid/wonton"
  enc_redirect="$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$redirect")"
  state="$(head -c8 /dev/urandom | od -An -tx1 | tr -d ' \n')"   # Hydra 要求 state ≥ 8 字符
  final="$(curl -sS --noproxy '*' -o /dev/null -L -b "${SMOKE_JAR:-}" -c "${SMOKE_JAR:-}" -H 'Accept: text/html' \
    -w '%{url_effective}' \
    "$auth_url?client_id=$SMOKE_PLUGIN_ID&redirect_uri=$enc_redirect&response_type=code&scope=openid+profile+email&state=$state")" ||
    { echo "authorize 链失败"; return 1; }
  code="$(python3 -c 'import sys,urllib.parse;print((urllib.parse.parse_qs(urllib.parse.urlparse(sys.argv[1]).query).get("code") or [""])[0])' "$final")"
  [[ -n "$code" ]] || { echo "回调里没有 code：$final"; return 1; }
  body="$(jq -nc --arg c "$code" --arg r "$redirect" '{code:$c,redirect_url:$r}')" || return 1
  body="$(curl -sS --noproxy '*' -b "${SMOKE_JAR:-}" -H 'Content-Type: application/json' -d "$body" \
    "$base/api/v1/auth/openid/wonton/callback")" || { echo "callback 请求失败"; return 1; }
  jq -r '.token // empty' <<<"$body" 2>/dev/null
}

# 本地登录和注册在清单里关掉了，顺带断言这两项没开。
identity_check() {
  local token me info
  token="$(vikunja_token)"
  [[ -n "$token" ]] || { echo "callback 没有换到应用令牌"; return 1; }
  info="$(curl -sS --noproxy '*' -b "${SMOKE_JAR:-}" "$(vikunja_base)/api/v1/info")" || { echo "取 /api/v1/info 失败"; return 1; }
  jq -e '.auth.local.enabled == false and .auth.local.registration_enabled == false' <<<"$info" >/dev/null 2>&1 ||
    { echo "本地登录或注册还开着：$(head -c 200 <<<"$info")"; return 1; }
  me="$(curl -sS --noproxy '*' -b "${SMOKE_JAR:-}" -H "Authorization: Bearer $token" "$(vikunja_base)/api/v1/user")" ||
    { echo "/api/v1/user 请求失败"; return 1; }
  jq -e --arg u "${SMOKE_OWNER:-}" '.username == $u' <<<"$me" >/dev/null 2>&1 ||
    { echo "当前用户不是用户 ${SMOKE_OWNER:-}：$(head -c 200 <<<"$me")"; return 1; }
}

data_write() {
  local base marker token resp
  base="$(vikunja_base)" || return 1
  marker="$(head -c8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  token="$(vikunja_token)"
  [[ -n "$token" ]] || { echo "callback 没有换到应用令牌，建不了项目"; return 1; }
  resp="$(curl -sS --noproxy '*' -b "${SMOKE_JAR:-}" -X PUT -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
    -d "{\"title\":\"smoke-data-$marker\"}" "$base/api/v1/projects")" || { echo "建项目请求失败"; return 1; }
  jq -e --arg t "smoke-data-$marker" '.title == $t' <<<"$resp" >/dev/null 2>&1 ||
    { echo "项目没建成：$(head -c 200 <<<"$resp")"; return 1; }
  printf '%s' "$marker" >"${SMOKE_STATE:?}"
}

data_check() {
  local base marker token resp
  base="$(vikunja_base)" || return 1
  marker="$(cat "${SMOKE_STATE:-}" 2>/dev/null)"
  [[ -n "$marker" ]] || { echo "SMOKE_STATE 标记文件是空的（data_write 没跑过？）"; return 1; }
  token="$(vikunja_token)"
  [[ -n "$token" ]] || { echo "callback 没有换到应用令牌"; return 1; }
  resp="$(curl -sS --noproxy '*' -b "${SMOKE_JAR:-}" -H "Authorization: Bearer $token" "$base/api/v1/projects")" ||
    { echo "列项目请求失败"; return 1; }
  jq -e --arg t "smoke-data-$marker" '.[] | select(.title == $t)' <<<"$resp" >/dev/null 2>&1 ||
    { echo "没找到项目 smoke-data-$marker，看到的项目：$(jq -r 'if type=="array" then ([.[].title] | join(", ")) else . end' <<<"$resp" 2>/dev/null | head -c 200)"; return 1; }
}
