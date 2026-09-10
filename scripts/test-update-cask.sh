#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TEMP_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/headless-cask-test.XXXXXX")"
trap 'rm -rf "$TEMP_DIRECTORY"' EXIT

cat > "$TEMP_DIRECTORY/curl" <<'MOCK'
#!/bin/bash
set -euo pipefail

printf '%s\n' "$*" >> "$MOCK_CURL_ARGUMENTS"
if [[ "$*" == *"/releases/latest"* ]]; then
  printf '{"tag_name":"v1.2.3"}\n'
  exit 0
fi

output=""
while [[ "$#" -gt 0 ]]; do
  if [[ "$1" == "--output" ]]; then
    output="$2"
    shift 2
    continue
  fi
  shift
done
[[ -z "$output" ]] || : > "$output"
printf '%s' "$MOCK_HTTP_STATUS"
exit 22
MOCK
chmod +x "$TEMP_DIRECTORY/curl"

run_case() {
  local expected_exit="$1"
  local http_status="$2"
  local output="$TEMP_DIRECTORY/output-$http_status"
  local result

  set +e
  PATH="$TEMP_DIRECTORY:$PATH" \
    GITHUB_TOKEN="test-token" \
    MOCK_CURL_ARGUMENTS="$TEMP_DIRECTORY/curl-arguments-$http_status" \
    MOCK_HTTP_STATUS="$http_status" \
    "$ROOT/scripts/update-cask.sh" > "$output" 2>&1
  result=$?
  set -e

  [[ "$result" -eq "$expected_exit" ]] || {
    echo "Expected HTTP $http_status to exit $expected_exit, got $result" >&2
    cat "$output" >&2
    exit 1
  }
  grep -q 'Authorization: Bearer test-token' "$TEMP_DIRECTORY/curl-arguments-$http_status"
}

run_case 78 404
grep -q 'predates the signed distribution contract' "$TEMP_DIRECTORY/output-404"

run_case 22 403
grep -q 'failed to fetch the checksum manifest (HTTP 403)' "$TEMP_DIRECTORY/output-403"
if grep -q 'predates the signed distribution contract' "$TEMP_DIRECTORY/output-403"; then
  echo "Transient HTTP failures must not be treated as legacy releases" >&2
  exit 1
fi

echo "Cask updater HTTP handling tests passed"
