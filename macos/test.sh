#!/bin/bash
# Builds the app, runs its self-test, then one-shot readings against a local mock of the usage endpoint
# (fake sign-in, no network, no Keychain).
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
green=$'\e[32m'; red=$'\e[31m'; off=$'\e[0m'
bin="$here/build/Claude Usage.app/Contents/MacOS/ClaudeUsage"
tmp="$(mktemp -d)"; trap 'kill $mock 2>/dev/null; wait $mock 2>/dev/null; rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" = 0 ]; then echo "${green}✅ $1${off}"; else echo "${red}❌ $1${off}"; fail=1; fi; }

# A failed build stops here: the checks below would otherwise run an older binary.
if "$here/build.sh" >"$tmp/build.log" 2>&1; then check "build" 0; else check "build" 1; tail -20 "$tmp/build.log"; exit 1; fi
"$bin" --self-test >"$tmp/self.log"; check "self-test ($(tail -1 "$tmp/self.log"))" $?
grep '❌' "$tmp/self.log"

# One version for the whole product: the app's must be the newest CHANGELOG.md entry (tools/package.ps1 checks the same).
want=$(grep -m1 -E '^## \[?[0-9]+\.[0-9]+\.[0-9]+' "$here/../CHANGELOG.md" | sed -E 's/^## \[?([0-9]+\.[0-9]+\.[0-9]+).*/\1/')
have=$("$bin" --version)
[ -n "$want" ] && [ "$have" = "$want" ]; check "version $have matches CHANGELOG.md ($want)" $?

# Out-of-range numbers in a reply must never crash parsing or drawing the menu (#61).
n=0; crashed=0
for body in \
  '{"seven_day":{"utilization":1e30,"resets_at":"2030-11-19T02:59:41Z"}}' \
  '{"seven_day":{"utilization":-1e30,"resets_at":"2030-11-19T02:59:41Z"}}' \
  '{"seven_day":{"utilization":105,"resets_at":"2030-11-19T02:59:41Z"}}' \
  '{"seven_day":{"utilization":40,"resets_at":1e20}}' \
  '{"seven_day":{"utilization":40,"resets_at":1e30}}' \
  '{"seven_day":{"utilization":40,"resets_at":"9999-12-31T23:59:59Z"}}' \
  '{"seven_day":{"utilization":40,"resets_at":253402300799000}}' \
  '{"seven_day":{"utilization":40,"resets_at":253402300800000}}' \
  '{"five_hour":{"utilization":40,"resets_at":1e30},"seven_day":{"utilization":10,"resets_at":"2030-11-19T02:59:41Z"}}' \
  '{"seven_day":{"utilization":40,"resets_at":"2030-11-19T02:59:41Z"},"extra_usage":{"is_enabled":true,"utilization":1e30,"used_credits":1e30,"monthly_limit":1e30}}' \
  '{"seven_day":{"utilization":40,"resets_at":"2030-11-19T02:59:41Z"},"seven_day_opus":{"utilization":1e30,"resets_at":1e30}}'; do
  n=$((n + 1)); printf '%s' "$body" >"$tmp/edge$n.json"
  "$bin" --parse "$tmp/edge$n.json" >/dev/null 2>&1 || { rc=$?; crashed=1; echo "   --parse exit $rc on $body"; }
  "$bin" --render-preview "$tmp/edge$n.png" --from "$tmp/edge$n.json" >/dev/null 2>&1 || { rc=$?; crashed=1; echo "   --render-preview exit $rc on $body"; }
done
[ $crashed = 0 ]; check "$n replies with out-of-range numbers parsed and drawn" $?

port=$(( 20000 + RANDOM % 20000 ))
python3 -I "$here/tests/mock_usage.py" "$port" "$tmp/headers.log" & mock=$!
for _ in $(seq 50); do nc -z 127.0.0.1 "$port" 2>/dev/null && break; sleep 0.1; done
echo '{"claudeAiOauth":{"accessToken":"test-token-1234567890","expiresAt":4102444800000,"subscriptionType":"max"}}' >"$tmp/creds.json"
once() { "$bin" --once --url "http://127.0.0.1:$port/$1" --credentials-file "$tmp/creds.json"; }

out=$(once ok); code=$?
[ $code = 0 ] && echo "$out" | grep -q '"used" : 61' && echo "$out" | grep -q '"name" : "Opus"'; check "live shape parsed (weekly 61% used, Opus scoped)" $?
grep -q '^/ok Bearer test-token-1234567890 oauth-2025-04-20$' "$tmp/headers.log"; check "Bearer token and anthropic-beta header sent" $?
echo "$out" | grep -q 'test-token'; [ $? != 0 ]; check "token never printed" $?
out=$(once 401); echo "$out" | grep -q 'Sign-in needed'; check "401 -> sign-in needed" $?
out=$(once 429); echo "$out" | grep -q 'rate limiting'; check "429 -> rate limited" $?
[ "$(grep -c '^/429' "$tmp/headers.log")" = 1 ]; check "429 is not retried at once" $?
out=$(once html); echo "$out" | grep -q 'unexpected response'; check "HTML body -> unexpected response" $?
out=$(once redirect); echo "$out" | grep -q 'redirected'; check "redirect refused" $?
[ "$(grep -c '^/elsewhere' "$tmp/headers.log")" = 0 ]; check "redirect not followed" $?
"$bin" --once --url "https://example.com/" --credentials-file "$tmp/creds.json" >/dev/null 2>&1; [ $? = 2 ]; check "test URL limited to 127.0.0.1" $?

[ $fail = 0 ] && echo "${green}✅ all macOS checks passed${off}" || echo "${red}❌ some macOS checks failed${off}"
exit $fail
