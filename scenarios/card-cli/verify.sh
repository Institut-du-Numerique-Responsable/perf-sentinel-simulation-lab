#!/usr/bin/env bash
# card-cli: the 0.39.0 share-card commands, keygen, render and verify-card,
# against the contract of docs/SHARE-CARD.md (C2 commands, C3 payloads).
#
# Local release binary, no cluster, no Docker. The --online legs run against
# a throwaway private CA, a python TLS origin that answers both the
# DNS-over-HTTPS JSON query and /.well-known/perf-sentinel-key, and a python
# CONNECT proxy that tunnels every name to it: the binary reads HTTPS_PROXY
# and SSL_CERT_FILE, so the host never resolves card-lab.test.
#
#   K1 keygen prints {fingerprint, public_key}, the fingerprint is ps1: and
#      22 base64url characters, the base64url of the first 16 bytes of the
#      SHA-256 of the public key, and <fingerprint>.pk8 is mode 0600.
#   K2 render writes the story, curve and collective fixtures in png, pdf,
#      svg and jxl: exit 0, {"result":"rendered","files":["card.<f>"]} with
#      the key's fingerprint and a perf-sentinel.dev/verifier#c= URL.
#   K3 the same input and key give the same bytes, in every format.
#   K4 verify-card offline on each of the 12 originals: exit 0, integrity
#      ok, content intact, level 1, no_key_list, and the signed figures of
#      the input.
#   K5 --keys with a local list naming the key: level 2, key_published.
#   K6 a retouched PNG (one IDAT byte, CRC fixed): exit 1 and the exact
#      content_modified line of the docs.
#   K7 card.json breaking C3: a period that is not a calendar month is
#      refused (period_not_calendar, exit 1), a float is malformed_input
#      (exit 3), and nothing is written.
#   K8 --online: DNS record alone (well-known 404) and both sources give
#      level 2; a revoked= record gives key_revoked, exit 1; a DoH failure
#      gives binding_check_failed when the well-known file is 404 and
#      binding_partial when it lists the key, both level 1, exit 4; a
#      retouched file makes no network request.
#
# On 0.38.0 the card and verify-card subcommands do not exist and K1 fails.
set -euo pipefail

SCENARIO="card-cli"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
rm -f "${REPORT}"  # die() prints it, never show a previous run's verdict
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${SCENARIO}.XXXXXX")"

PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
PERF_SENTINEL_LOCAL_BIN="${PERF_SENTINEL_LOCAL_BIN:-${PERF_SENTINEL_REPO_PATH}/target/release/perf-sentinel}"
FIXTURES="${CC_FIXTURES:-${PERF_SENTINEL_REPO_PATH}/tests/fixtures/card}"
ORIGIN_PORT="${CC_ORIGIN_PORT:-14956}"
PROXY_PORT="${CC_PROXY_PORT:-14957}"
DOMAIN="card-lab.test"
DOH_URL="https://doh.${DOMAIN}/dns-query"
ANGLES="story curve collective"
FORMATS="png pdf svg jxl"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
die()  { color_red   "    error: $*"; cat "${REPORT}" 2>/dev/null || true; exit 1; }

NET_PID=""
cleanup() {
  [ -n "${NET_PID}" ] && kill "${NET_PID}" 2>/dev/null
  rm -rf "${TMP_DIR}"
  return 0
}
trap cleanup EXIT

# No proxy or trust store from the operator's shell leaks into a leg.
CLEAN_ENV=(env -u HTTPS_PROXY -u https_proxy -u ALL_PROXY -u all_proxy -u HTTP_PROXY
  -u http_proxy -u NO_PROXY -u no_proxy -u SSL_CERT_FILE -u SSL_CERT_DIR)
bin() { "${CLEAN_ENV[@]}" "${PERF_SENTINEL_LOCAL_BIN}" "$@"; }

# Runs the binary, keeps stdout (the JSON line) in OUT and the exit in RC.
run() {
  set +e
  OUT="$(bin "$@" 2>"${TMP_DIR}/stderr.txt")"
  RC=$?
  set -e
}

# Asserts that the JSON line in $1 holds every key=value of the JSON object $2.
expect() {  # $1 = id, $2 = expected subset as JSON
  python3 - "${OUT}" "$2" <<'PY' || die "$1 line ${OUT:-<empty>} (stderr: $(tail -2 "${TMP_DIR}/stderr.txt"))"
import json, sys
try:
    got = json.loads(sys.argv[1])
except ValueError:
    sys.exit("not one JSON line")
want = json.loads(sys.argv[2])
bad = {k: got.get(k, "<absent>") for k, v in want.items() if got.get(k, "<absent>") != v}
if bad:
    sys.exit("differs on %s, want %s" % (bad, {k: want[k] for k in bad}))
PY
}

step "Prerequisites"
[ -x "${PERF_SENTINEL_LOCAL_BIN}" ] \
  || die "no local binary at ${PERF_SENTINEL_LOCAL_BIN} (cargo build --release -p perf-sentinel first)"
for f in story curve collective; do
  [ -f "${FIXTURES}/${f}.json" ] || die "no fixture ${FIXTURES}/${f}.json (set PERF_SENTINEL_REPO_PATH or CC_FIXTURES)"
done
for c in openssl python3 cmp; do command -v "${c}" >/dev/null || die "${c} is required"; done
BIN_VERSION="$(bin --version | awk '{print $2}')"
ok "under test: ${PERF_SENTINEL_LOCAL_BIN} ${BIN_VERSION}"

step "K1 keygen writes a 0600 key named after a ps1: fingerprint"
mkdir -p "${TMP_DIR}/keys"
run card keygen --out-dir "${TMP_DIR}/keys"
[ "${RC}" = "0" ] || die "K1 keygen exit ${RC}: ${OUT} $(tail -2 "${TMP_DIR}/stderr.txt")"
K1="$(python3 - "${OUT}" "${TMP_DIR}/keys" <<'PY'
import base64, hashlib, json, os, re, stat, sys
line, keydir = json.loads(sys.argv[1]), sys.argv[2]
if sorted(line) != ["fingerprint", "public_key"]:
    sys.exit("keys %s, want fingerprint and public_key" % sorted(line))
fp, pk = line["fingerprint"], line["public_key"]
if not re.fullmatch(r"ps1:[A-Za-z0-9_-]{22}", fp):
    sys.exit("fingerprint %r is not ps1: and 22 base64url characters" % fp)
raw = base64.urlsafe_b64decode(pk + "=" * (-len(pk) % 4))
if len(raw) != 32 or "=" in pk:
    sys.exit("public_key %r is not 32 bytes in unpadded base64url" % pk)
want = "ps1:" + base64.urlsafe_b64encode(hashlib.sha256(raw).digest()[:16]).decode().rstrip("=")
if fp != want:
    sys.exit("fingerprint %s, the SHA-256 of the public key gives %s" % (fp, want))
files = os.listdir(keydir)
if files != [fp + ".pk8"]:
    sys.exit("key directory holds %s, want %s.pk8" % (files, fp))
mode = stat.S_IMODE(os.stat(os.path.join(keydir, files[0])).st_mode)
if mode != 0o600:
    sys.exit("key file mode %o, want 600" % mode)
print(fp, pk)
PY
)" || die "K1 ${K1:-check failed}"
read -r FP PUBKEY <<< "${K1}"
KEY="${TMP_DIR}/keys/${FP}.pk8"
ok "${FP}, ${FP}.pk8 mode 600"

step "K2 render the three fixtures in four formats"
for a in ${ANGLES}; do
  for f in ${FORMATS}; do
    d="${TMP_DIR}/out/${a}-${f}"
    mkdir -p "${d}"
    run card render --input "${FIXTURES}/${a}.json" --signing-key "${KEY}" --out-dir "${d}" --format "${f}"
    [ "${RC}" = "0" ] || die "K2 ${a} ${f} exit ${RC}: ${OUT} $(tail -2 "${TMP_DIR}/stderr.txt")"
    expect "K2 ${a} ${f}" "{\"result\":\"rendered\",\"files\":[\"card.${f}\"],\"fingerprint\":\"${FP}\"}"
    python3 -c "import json,sys; sys.exit(0 if json.loads(sys.argv[1])['compact_url'].startswith('https://perf-sentinel.dev/verifier#c=') else 1)" "${OUT}" \
      || die "K2 ${a} ${f} compact_url is not a perf-sentinel.dev/verifier#c= URL: ${OUT}"
    [ "$(ls "${d}")" = "card.${f}" ] || die "K2 ${a} ${f} wrote $(ls "${d}" | tr '\n' ' '), want card.${f} alone"
  done
done
ok "12 cards rendered, $(du -sk "${TMP_DIR}/out" | awk '{print $1}') KiB in all"

step "K3 the same input and key give the same bytes"
for f in ${FORMATS}; do
  d="${TMP_DIR}/again-${f}"
  mkdir -p "${d}"
  run card render --input "${FIXTURES}/story.json" --signing-key "${KEY}" --out-dir "${d}" --format "${f}"
  [ "${RC}" = "0" ] || die "K3 second ${f} render exit ${RC}"
  cmp -s "${d}/card.${f}" "${TMP_DIR}/out/story-${f}/card.${f}" || die "K3 two renders of the story in ${f} differ"
done
ok "story re-rendered byte for byte in ${FORMATS}"

step "K4 verify-card offline reads every original intact, with the input's figures"
for a in ${ANGLES}; do
  for f in ${FORMATS}; do
    run verify-card "${TMP_DIR}/out/${a}-${f}/card.${f}"
    [ "${RC}" = "0" ] || die "K4 ${a} ${f} exit ${RC}: ${OUT}"
    python3 - "${OUT}" "${FIXTURES}/${a}.json" <<'PY' || die "K4 ${a} ${f}: ${OUT}"
import json, sys
got, card = json.loads(sys.argv[1]), json.load(open(sys.argv[2]))
want = {"integrity": "ok", "content": "intact", "level": 1, "domain": card["org"]["domain"],
        "key": "unknown", "reason": "no_key_list"}
bad = {k: got.get(k) for k in want if got.get(k) != want[k]}
if bad:
    sys.exit("differs on %s, want %s" % (bad, {k: want[k] for k in bad}))
fig, src = got["figures"], card["figures"]
exp = {"angle": card["angle"], "period": card["period"]}
if "before_fix_period" in card:
    exp["before_fix_period"] = card["before_fix_period"]
# The compact payload's figures, named as in the SHARE-CARD.md table.
if card["angle"] == "story":
    for k in ("cited_ops", "cited_ms", "before_fix_ops", "threshold_ops", "threshold_ms"):
        if k in src:
            exp[k] = src[k]
elif card["angle"] == "curve":
    exp["last_waste_permille"] = src["waste_permille"][-1]
    exp["previous_waste_permille"] = src["waste_permille"][-2]
else:
    exp["confirmed_fixes_count"] = src["confirmed_fixes_count"]
    exp["services_count"] = src["services_count"]
if fig != exp:
    sys.exit("figures %s, want %s" % (json.dumps(fig, sort_keys=True), json.dumps(exp, sort_keys=True)))
PY
  done
done
ok "12 originals: integrity ok, content intact, level 1 no_key_list, figures as signed"

step "K5 --keys with a local list naming the key gives level 2"
printf '{"keys":[{"fingerprint":"%s","public_key":"%s","from":"2026-09-01","to":null,"revoked":null}]}\n' \
  "${FP}" "${PUBKEY}" > "${TMP_DIR}/published.json"
run verify-card "${TMP_DIR}/out/story-png/card.png" --keys "${TMP_DIR}/published.json"
[ "${RC}" = "0" ] || die "K5 exit ${RC}: ${OUT}"
expect K5 '{"integrity":"ok","content":"intact","level":2,"domain":"acme.fr","key":"current","reason":"key_published"}'
ok "level 2, current, key_published"

step "K6 a PNG with one IDAT byte changed reads content_modified"
python3 - "${TMP_DIR}/out/story-png/card.png" "${TMP_DIR}/retouched.png" <<'PY' || die "K6 could not retouch the PNG"
import struct, sys, zlib
data = bytearray(open(sys.argv[1], "rb").read())
pos = 8
while pos < len(data):
    length, kind = struct.unpack(">I4s", data[pos:pos + 8])
    if kind == b"IDAT":
        at = pos + 8 + length // 2  # one byte inside the compressed pixels
        data[at] ^= 0x01
        crc = zlib.crc32(data[pos + 4:pos + 8 + length]) & 0xFFFFFFFF
        data[pos + 8 + length:pos + 12 + length] = struct.pack(">I", crc)
        break
    pos += 12 + length
else:
    sys.exit("no IDAT")
open(sys.argv[2], "wb").write(data)
PY
cmp -s "${TMP_DIR}/retouched.png" "${TMP_DIR}/out/story-png/card.png" && die "K6 the retouched PNG equals the original"
run verify-card "${TMP_DIR}/retouched.png"
[ "${RC}" = "1" ] || die "K6 exit ${RC}, want 1: ${OUT}"
K6_WANT='{"integrity":"ok","content":"modified","level":1,"domain":null,"key":"unknown","reason":"content_modified","figures":null}'
expect K6 "${K6_WANT}"
ok "exit 1, ${OUT}"

step "K7 a card.json breaking C3 is refused and writes nothing"
python3 - "${FIXTURES}/story.json" "${TMP_DIR}" <<'PY'
import json, sys
card = json.load(open(sys.argv[1]))
off = json.loads(json.dumps(card))
off["period"]["from"] = "2026-09-02"  # not the first day of the month
json.dump(off, open(sys.argv[2] + "/not-calendar.json", "w"))
flt = json.loads(json.dumps(card))
flt["figures"]["cited_ops"] = 41.5  # integers only
json.dump(flt, open(sys.argv[2] + "/float.json", "w"))
PY
mkdir -p "${TMP_DIR}/refused"
run card render --input "${TMP_DIR}/not-calendar.json" --signing-key "${KEY}" --out-dir "${TMP_DIR}/refused" --format png
[ "${RC}" = "1" ] || die "K7 period_not_calendar exit ${RC}, want 1: ${OUT}"
expect "K7 period_not_calendar" '{"result":"refused","reason":"period_not_calendar"}'
K7A="${OUT}"
run card render --input "${TMP_DIR}/float.json" --signing-key "${KEY}" --out-dir "${TMP_DIR}/refused" --format png
[ "${RC}" = "3" ] || die "K7 malformed_input exit ${RC}, want 3: ${OUT}"
expect "K7 malformed_input" '{"result":"input_error","reason":"malformed_input"}'
K7B="${OUT}"
[ -z "$(ls -A "${TMP_DIR}/refused")" ] || die "K7 a refused render wrote $(ls -A "${TMP_DIR}/refused" | tr '\n' ' ')"
ok "period_not_calendar exit 1, malformed_input exit 3, nothing written"

step "K8 --online through a fake DoH and well-known origin"
mkdir -p "${TMP_DIR}/tls"
cat > "${TMP_DIR}/tls/openssl.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
[dn]
CN = perf-sentinel lab card-cli throwaway
[ca_ext]
basicConstraints = critical, CA:TRUE
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
[srv_ext]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:${DOMAIN}, DNS:doh.${DOMAIN}
authorityKeyIdentifier = keyid
EOF
(
  cd "${TMP_DIR}/tls"
  openssl req -x509 -new -nodes -newkey rsa:2048 -days 1 -keyout ca.key -out ca.pem \
    -config openssl.cnf -extensions ca_ext 2>/dev/null
  openssl req -new -nodes -newkey rsa:2048 -keyout server.key -out server.csr -config openssl.cnf 2>/dev/null
  openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 1 \
    -extfile openssl.cnf -extensions srv_ext -out server.pem 2>/dev/null
) || die "K8 openssl failed"

# A TLS origin answering the DoH JSON query and the well-known file as
# mode.json says, and a CONNECT proxy sending every tunnel to it. Each
# request and tunnel is one line of net.log.
cat > "${TMP_DIR}/lab_net.py" <<'PY'
import json, socket, ssl, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs

tls_port, proxy_port, cert, key, mode_path, log_path = sys.argv[1:7]
tls_port, proxy_port = int(tls_port), int(proxy_port)
lock = threading.Lock()

def log(rec):
    with lock, open(log_path, "a") as f:
        f.write(json.dumps(rec) + "\n")

class Origin(BaseHTTPRequestHandler):
    def do_GET(self):
        mode = json.load(open(mode_path))
        url = urlsplit(self.path)
        log({"host": self.headers.get("Host"), "path": url.path, "query": url.query,
             "accept": self.headers.get("Accept")})
        if url.path == "/dns-query":
            doh = mode["doh"]
            if doh.get("status", 200) != 200:
                return self.reply(doh["status"], b"{}")
            name = parse_qs(url.query).get("name", [""])[0]
            # NXDOMAIN (Status 3) when no record is published.
            body = {"Status": 0 if doh.get("txt") else 3,
                    "Question": [{"name": name, "type": 16}],
                    "Answer": [{"name": name, "type": 16, "TTL": 60, "data": json.dumps(t)}
                               for t in doh.get("txt", [])]}
            return self.reply(200, json.dumps(body).encode(), "application/dns-json")
        if url.path == "/.well-known/perf-sentinel-key":
            wk = mode["well_known"]
            if wk.get("status", 200) != 200:
                return self.reply(wk["status"], b"not found")
            return self.reply(200, json.dumps(wk["body"]).encode())
        self.reply(404, b"not found")
    def reply(self, status, body, ctype="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args):
        pass

origin = ThreadingHTTPServer(("127.0.0.1", tls_port), Origin)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(cert, key)
origin.socket = ctx.wrap_socket(origin.socket, server_side=True)
threading.Thread(target=origin.serve_forever, daemon=True).start()

def pipe(a, b):
    try:
        while (data := a.recv(65536)):
            b.sendall(data)
    except OSError:
        pass
    finally:
        for s in (a, b):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

def tunnel(client):
    head = b""
    while b"\r\n\r\n" not in head:
        chunk = client.recv(4096)
        if not chunk:
            return client.close()
        head += chunk
    line = head.split(b"\r\n", 1)[0].decode("latin-1")
    method, target = (line.split(" ") + ["", ""])[:2]
    log({"connect": target} if method == "CONNECT" else {"proxy_refused": line})
    if method != "CONNECT":
        client.sendall(b"HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\n\r\n")
        return client.close()
    upstream = socket.create_connection(("127.0.0.1", tls_port))
    client.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
    threading.Thread(target=pipe, args=(upstream, client), daemon=True).start()
    pipe(client, upstream)

proxy = socket.create_server(("127.0.0.1", proxy_port))
while True:
    conn, _ = proxy.accept()
    threading.Thread(target=tunnel, args=(conn,), daemon=True).start()
PY
NET_LOG="${TMP_DIR}/net.log"
MODE="${TMP_DIR}/mode.json"
: > "${NET_LOG}"
echo '{"doh":{},"well_known":{"status":404}}' > "${MODE}"
python3 "${TMP_DIR}/lab_net.py" "${ORIGIN_PORT}" "${PROXY_PORT}" \
  "${TMP_DIR}/tls/server.pem" "${TMP_DIR}/tls/server.key" "${MODE}" "${NET_LOG}" 2>"${TMP_DIR}/net.err" &
NET_PID=$!
disown "${NET_PID}" 2>/dev/null || true
for _ in $(seq 1 20); do
  python3 -c "import socket,sys; socket.create_connection(('127.0.0.1', int(sys.argv[1])), 1)" "${PROXY_PORT}" 2>/dev/null && break
  sleep 0.25
done
kill -0 "${NET_PID}" 2>/dev/null || die "K8 fake origin did not start: $(cat "${TMP_DIR}/net.err")"

# The domain must pass the card's own rule (two labels or more, the last not
# all digits), so localhost and 127.0.0.1 cannot stand in: card-lab.test does.
python3 - "${FIXTURES}/story.json" "${TMP_DIR}/online.json" "${DOMAIN}" <<'PY'
import json, sys
card = json.load(open(sys.argv[1]))
card["org"]["domain"] = sys.argv[3]
json.dump(card, open(sys.argv[2], "w"))
PY
mkdir -p "${TMP_DIR}/online"
run card render --input "${TMP_DIR}/online.json" --signing-key "${KEY}" --out-dir "${TMP_DIR}/online" --format png
[ "${RC}" = "0" ] || die "K8 render of the ${DOMAIN} card exit ${RC}: ${OUT}"
ONLINE_CARD="${TMP_DIR}/online/card.png"

online() {  # $1 = file
  set +e
  OUT="$("${CLEAN_ENV[@]}" HTTPS_PROXY="http://127.0.0.1:${PROXY_PORT}" SSL_CERT_FILE="${TMP_DIR}/tls/ca.pem" \
    "${PERF_SENTINEL_LOCAL_BIN}" verify-card "$1" --online --doh "${DOH_URL}" 2>"${TMP_DIR}/stderr.txt")"
  RC=$?
  set -e
}
set_mode() {  # $1 = JSON
  printf '%s\n' "$1" > "${MODE}"
}
TXT_OK="v=ps1; k=${FP}; from=2026-09-01"
WK_OK="{\"status\":200,\"body\":{\"keys\":[{\"fingerprint\":\"${FP}\",\"public_key\":\"${PUBKEY}\",\"from\":\"2026-09-01\",\"to\":null,\"revoked\":null}]}}"

# K8a: the DNS record alone, the well-known file 404 (an answer, not a failure).
set_mode "{\"doh\":{\"txt\":[\"${TXT_OK}\"]},\"well_known\":{\"status\":404}}"
BEFORE="$(wc -l < "${NET_LOG}")"
online "${ONLINE_CARD}"
[ "${RC}" = "0" ] || die "K8a exit ${RC}, want 0: ${OUT} $(tail -2 "${TMP_DIR}/stderr.txt")"
expect K8a "{\"integrity\":\"ok\",\"content\":\"intact\",\"level\":2,\"domain\":\"${DOMAIN}\",\"key\":\"current\",\"reason\":\"key_published\"}"
python3 - "${NET_LOG}" "${BEFORE}" "${DOMAIN}" <<'PY' || die "K8a requests"
import json, sys
recs = [json.loads(l) for l in open(sys.argv[1]).read().splitlines()[int(sys.argv[2]):]]
dom = sys.argv[3]
doh = [r for r in recs if r.get("path") == "/dns-query"]
wk = [r for r in recs if r.get("path") == "/.well-known/perf-sentinel-key"]
if len(doh) != 1 or doh[0]["query"] != "name=_perf-sentinel.%s&type=TXT" % dom or doh[0]["accept"] != "application/dns-json":
    sys.exit("DoH requests %s, want one name=_perf-sentinel.%s&type=TXT with Accept application/dns-json" % (doh, dom))
if len(wk) != 1 or wk[0]["host"] != dom:
    sys.exit("well-known requests %s, want one on Host %s" % (wk, dom))
PY
ok "DNS only (well-known 404): level 2, key_published; one DoH query for _perf-sentinel.${DOMAIN} TXT, one well-known GET"

# K8b: both sources list the key.
set_mode "{\"doh\":{\"txt\":[\"${TXT_OK}\"]},\"well_known\":${WK_OK}}"
online "${ONLINE_CARD}"
[ "${RC}" = "0" ] || die "K8b exit ${RC}, want 0: ${OUT}"
expect K8b "{\"level\":2,\"key\":\"current\",\"reason\":\"key_published\"}"
ok "DNS and well-known: level 2, key_published"

# K8c: the DNS record revokes the key.
set_mode "{\"doh\":{\"txt\":[\"${TXT_OK}; revoked=2026-10-01\"]},\"well_known\":{\"status\":404}}"
online "${ONLINE_CARD}"
[ "${RC}" = "1" ] || die "K8c exit ${RC}, want 1: ${OUT}"
expect K8c "{\"integrity\":\"ok\",\"content\":\"intact\",\"level\":1,\"key\":\"revoked\",\"reason\":\"key_revoked\"}"
ok "revoked= record: exit 1, level 1, key_revoked"

# K8d: DoH answers 500, the well-known file is 404.
set_mode '{"doh":{"status":500},"well_known":{"status":404}}'
online "${ONLINE_CARD}"
[ "${RC}" = "4" ] || die "K8d exit ${RC}, want 4: ${OUT}"
expect K8d '{"level":1,"reason":"binding_check_failed"}'
ok "DoH 500 + well-known 404: exit 4, level 1, binding_check_failed"

# K8e: DoH answers 500, the well-known file lists the key.
set_mode "{\"doh\":{\"status\":500},\"well_known\":${WK_OK}}"
online "${ONLINE_CARD}"
[ "${RC}" = "4" ] || die "K8e exit ${RC}, want 4: ${OUT}"
expect K8e '{"level":1,"reason":"binding_partial"}'
ok "DoH 500 + well-known lists the key: exit 4, level 1, binding_partial"

# K8f: a retouched file stops before the key, so no request leaves.
set_mode "{\"doh\":{\"txt\":[\"${TXT_OK}\"]},\"well_known\":${WK_OK}}"
BEFORE="$(wc -l < "${NET_LOG}")"
online "${TMP_DIR}/retouched.png"
[ "${RC}" = "1" ] || die "K8f exit ${RC}, want 1: ${OUT}"
expect K8f "${K6_WANT}"
AFTER="$(wc -l < "${NET_LOG}")"
[ "${AFTER}" = "${BEFORE}" ] || die "K8f a content_modified file sent $((AFTER - BEFORE)) request(s) under --online"
ok "retouched file under --online: content_modified, no request"

{
  echo "# Scenario: ${SCENARIO}"
  echo ""
  echo "- Binary: ${PERF_SENTINEL_LOCAL_BIN} (${BIN_VERSION})"
  echo ""
  echo "| id | check | result |"
  echo "|---|---|---|"
  echo "| K1 | keygen | ${FP}, ${FP}.pk8 mode 600, fingerprint = SHA-256 of the public key |"
  echo "| K2 | render story, curve, collective x png, pdf, svg, jxl | 12 files, one per run |"
  echo "| K3 | same input and key | same bytes in ${FORMATS} |"
  echo "| K4 | verify-card offline on the 12 originals | integrity ok, content intact, level 1, no_key_list, figures as input |"
  echo "| K5 | --keys naming the key | level 2, key_published |"
  echo "| K6 | one IDAT byte changed, CRC fixed | exit 1, content_modified |"
  echo "| K7 | C3 broken | \`${K7A}\` exit 1, \`${K7B}\` exit 3, nothing written |"
  echo "| K8 | --online via a fake DoH and well-known | DNS only and both: level 2; revoked: key_revoked exit 1; DoH 500: binding_check_failed / binding_partial exit 4; retouched: no request |"
  echo ""
  echo "Verdict: **PASS**"
} > "${REPORT}"
color_green "PASS, report at ${REPORT}"
