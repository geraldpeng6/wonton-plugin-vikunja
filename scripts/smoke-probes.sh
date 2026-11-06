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
# POST /api/v1/auth/openid/wonton/callback 换令牌 → 用 Bearer 调应用自己的“当前用户”接口。
# 本地登录和注册在清单里关掉了，顺带断言这两项没开。
identity_check() {
  local info auth_url redirect enc_redirect state final code body token me
  info="$(web_get /api/v1/info)" || { echo "取 /api/v1/info 失败：$info"; return 1; }
  auth_url="$(jq -r '.auth.openid_connect.providers[0].auth_url' <<<"$info")"
  [[ -n "$auth_url" && "$auth_url" != null ]] || { echo "没有 OIDC provider：$info"; return 1; }
  jq -e '.auth.local.enabled == false and .auth.local.registration_enabled == false' <<<"$info" >/dev/null ||
    { echo "本地登录或注册还开着：$(jq -c .auth.local <<<"$info")"; return 1; }
  redirect="$SMOKE_WEB_URL/auth/openid/wonton"
  enc_redirect="$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$redirect")"
  state="$(head -c8 /dev/urandom | od -An -tx1 | tr -d ' \n')"   # Hydra 要求 state ≥ 8 字符
  final="$(curl -sS --noproxy '*' -o /dev/null -L -b "$SMOKE_JAR" -c "$SMOKE_JAR" -H 'Accept: text/html' \
    -w '%{url_effective}' \
    "$auth_url?client_id=$SMOKE_PLUGIN_ID&redirect_uri=$enc_redirect&response_type=code&scope=openid+profile+email&state=$state")" ||
    { echo "authorize 链失败"; return 1; }
  code="$(python3 -c 'import sys,urllib.parse;print((urllib.parse.parse_qs(urllib.parse.urlparse(sys.argv[1]).query).get("code") or [""])[0])' "$final")"
  [[ -n "$code" ]] || { echo "回调里没有 code：$final"; return 1; }
  body="$(jq -nc --arg c "$code" --arg r "$redirect" '{code:$c,redirect_url:$r}')"
  token="$(curl -sS --noproxy '*' -b "$SMOKE_JAR" -H 'Content-Type: application/json' -d "$body" \
    "$SMOKE_WEB_URL/api/v1/auth/openid/wonton/callback" | jq -r '.token // empty')" ||
    { echo "callback 换令牌失败：$token"; return 1; }
  [[ -n "$token" ]] || { echo "callback 没有返回令牌"; return 1; }
  me="$(web_get /api/v1/user -H "Authorization: Bearer $token")" || { echo "/api/v1/user 失败：$me"; return 1; }
  jq -e --arg u "$SMOKE_OWNER" '.username == $u' <<<"$me" >/dev/null ||
    { echo "当前用户不是用户 $SMOKE_OWNER：$me"; return 1; }
}
