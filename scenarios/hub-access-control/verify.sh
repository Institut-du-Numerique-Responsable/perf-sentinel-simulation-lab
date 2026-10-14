#!/usr/bin/env bash
# Hub access control, end to end, on the NativeAOT build: who reaches what.
#
# The Hub's own tests drive access control through TestServer, with a fake
# daemon and no real Kestrel. Several things only show on the shipped image:
# the OAuth handler and the cookie handler under NativeAOT, the machine-token
# scheme over real Kestrel, the metrics port that refuses to start unbound,
# the daemon's read gate seen by a polling Hub, and the token file the real
# CLI writes, which the JetBrains plugin reads. This scenario crosses each of
# those boundaries once.
#
# An isolated PAIR, daemon and Hub, in one namespace, for the same reason as
# hub-source-reachability: the zero-trust policy admits a polling Hub only
# from its own namespace. The shared daemon and the shared Hub stay untouched
# and access-off. The daemon gates its reads (require_read_key) and groups on
# k8s.namespace.name; one tracegen Job in the namespace feeds it three service
# families under two tenants:
#   aca-a       tenant aca-a        the project "a" reads it
#   aca-b       tenant aca-b        no project reads it (shows in unmatched)
#   aca-shared  tenants aca-a and aca-b, same seed: one signature, two values
#               of the project key (shows in conflicts, and still reads)
#
# The identity provider is a fake one: about forty lines of stdlib Python in
# a sidecar of the Hub pod, on loopback, which the validator allows over http.
# curl plays the browser and skips the provider's page: it calls the Hub's
# callback with the code the fake provider accepts.
#
# Legs, in run order:
#   E. local account: the sign-in page, a wrong and a right password, and the
#      admin's /api/access (local_accounts, unmatched, conflicts)
#   A. the daemon gate as the Hub sees it: keyed reachable, keyless not
#   B. the grouping filter, blank variants included
#   C. machine tokens: expired, no grant, the plugin's query, read-only
#   D. MetricsPort: the split, and the exit when the port is not bound
#   F. terminal sign-in with the real CLI, and the plugin's token-file contract
#   G. provider sign-in: SubjectClaim, provider groups, RequiredGroups
#
# Prerequisites: make seed-daemon-local, make seed-hub-local (the Hub image
# must also be in local docker), make seed-tracegen, and a perf-sentinel
# binary with login/logout/hub (cargo build --release).

set -euo pipefail

SCENARIO="hub-access-control"
NS="${HUB_ACCESS_NS:-hub-access-control}"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"

HUB_PORT="${HUB_ACCESS_PORT:-8096}"
METRICS_PORT="${HUB_ACCESS_METRICS_PORT:-8097}"
POLL_SECS=5
HUB="http://127.0.0.1:${HUB_PORT}"
NONCE="acl"
export ACA_NONCE="${NONCE}"

PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-${HOME}/RustroverProjects/perf-sentinel}"
PERF_SENTINEL_LOCAL_BIN="${PERF_SENTINEL_LOCAL_BIN:-${PERF_SENTINEL_REPO_PATH}/target/release/perf-sentinel}"

# 0700: it holds session cookies, the CLI token file and the generated secrets.
rm -rf "${TMP_DIR}"; mkdir -m 700 "${TMP_DIR}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
fail() { color_red   "    fail: $*"; }
die()  { color_red   "    error: $*"; exit 1; }

PF_PID=""
LOGIN_PID=""
D2_NAME="${SCENARIO}-d2"
cleanup() {
  [ -n "${LOGIN_PID}" ] && kill "${LOGIN_PID}" 2>/dev/null || true
  [ -n "${PF_PID}" ] && kill "${PF_PID}" 2>/dev/null || true
  docker rm -f "${D2_NAME}" >/dev/null 2>&1 || true
  if [ "${KEEP_NAMESPACE:-no}" != "yes" ]; then
    kubectl delete namespace "${NS}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    # The report lives outside TMP_DIR; what is in it would stay valid as long as the Hub runs.
    rm -rf "${TMP_DIR}"
  fi
}
trap cleanup EXIT

declare -a NAMES=() VERDICTS=() NOTES=()
record() { NAMES+=("$1"); VERDICTS+=("$2"); NOTES+=("$3"); }
# $1 = name, $2 = actual, $3 = expected
expect() {
  if [ "$2" = "$3" ]; then ok "$1: $2"; record "$1" PASS "$2"
  else fail "$1: got '$2', expected '$3'"; record "$1" FAIL "got $2, expected $3"; fi
}
# $1 = name, $2 = note; the condition is the exit status of the command after it
expect_cmd() {
  local name="$1" note="$2"; shift 2
  if "$@" >/dev/null 2>&1; then ok "${name}: ${note}"; record "${name}" PASS "${note}"
  else fail "${name}: ${note}"; record "${name}" FAIL "${note}"; fi
}

# One request: body in $TMP_DIR/<name>.body, headers in <name>.hdr, the code on stdout.
http() {  # $1 = name, then curl arguments
  local name="$1"; shift
  curl -sS -o "${TMP_DIR}/${name}.body" -D "${TMP_DIR}/${name}.hdr" -w '%{http_code}' "$@" 2>/dev/null || true
}
# A response header's value, case ignored, without the trailing CR.
hdr() {  # $1 = name, $2 = header
  awk -v h="$(printf '%s' "$2" | tr 'A-Z' 'a-z')" 'BEGIN{FS=": "} tolower($1)==h {sub(/\r$/,""); sub(/^[^:]*: /,""); print; exit}' "${TMP_DIR}/$1.hdr"
}
# A Python expression over d, the JSON body of <name>; prints its value.
# fams(rows) is the sorted set of service families, aca-a / aca-b / aca-shared.
pyv() {  # $1 = name, $2 = expression
  python3 - "${TMP_DIR}/$1.body" "$2" <<'PY'
import json, os, sys
nonce = os.environ["ACA_NONCE"]
# A Hub row nests the daemon's finding; a conflict copy carries service and signature itself.
def fam(row): return str(row.get("finding", row).get("service", "")).split("-" + nonce)[0]
def sig(row): return row.get("finding", row).get("signature")
def fams(rows): return sorted({fam(r) for r in rows})
try:
    d = json.load(open(sys.argv[1]))
except Exception as exc:  # noqa: BLE001 - the verdict names it
    print(f"unparseable: {exc}")
    sys.exit(0)
try:
    r = eval(sys.argv[2])  # the expression is this script's own, never data from a response
except Exception as exc:  # noqa: BLE001
    print(f"error: {exc!r}")
    sys.exit(0)
print(r if isinstance(r, str) else json.dumps(r))
PY
}
# Every Set-Cookie pair of <name> whose cookie name starts with $2, non-empty, as a Cookie header.
cookies() {  # $1 = name, $2 = cookie name prefix
  python3 - "${TMP_DIR}/$1.hdr" "$2" <<'PY'
import sys
pairs = []
for line in open(sys.argv[1], encoding="latin-1"):
    if line.lower().startswith("set-cookie:"):
        pair = line.split(":", 1)[1].strip().split(";", 1)[0]
        name, _, value = pair.partition("=")
        if name.startswith(sys.argv[2]) and value:
            pairs.append(pair)
print("; ".join(pairs))
PY
}
cli() {  # the local CLI with a private config home and no inherited Hub settings
  env -u PERF_SENTINEL_HUB_TOKEN -u PERF_SENTINEL_HUB_URL XDG_CONFIG_HOME="${TMP_DIR}/xdg" \
    "${PERF_SENTINEL_LOCAL_BIN}" "$@"
}

# === 0. Pre-flight ===
step "0. Pre-flight"
for tool in kubectl docker python3 curl; do
  command -v "${tool}" >/dev/null || die "${tool} not on PATH"
done
HUB_IMAGE="$(kubectl -n observability get deploy/perf-sentinel-hub \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
[ -n "${HUB_IMAGE}" ] || die "no Hub in the cluster. Run: make seed-hub-local"
docker image inspect "${HUB_IMAGE}" >/dev/null 2>&1 \
  || die "${HUB_IMAGE} is not in local docker (hash-password and leg D2 run it). Run: make seed-hub-local"
DAEMON_IMAGE="$(kubectl -n observability get deploy/perf-sentinel-daemon \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
[ -n "${DAEMON_IMAGE}" ] || die "no daemon in the cluster to copy the image pin from. Run: make seed-daemon-local"
docker image inspect lab-tracegen:1 >/dev/null 2>&1 || die "no lab-tracegen:1 image. Run: make seed-tracegen"
[ -x "${PERF_SENTINEL_LOCAL_BIN}" ] \
  || die "no local binary at ${PERF_SENTINEL_LOCAL_BIN} (cargo build --release in ${PERF_SENTINEL_REPO_PATH})"
"${PERF_SENTINEL_LOCAL_BIN}" login --help >/dev/null 2>&1 \
  || die "${PERF_SENTINEL_LOCAL_BIN} has no login subcommand: rebuild it from perf-sentinel main (cargo build --release)"
for port in "${HUB_PORT}" "${METRICS_PORT}"; do
  curl -s -o /dev/null "http://127.0.0.1:${port}/" 2>/dev/null \
    && die "something already serves 127.0.0.1:${port}, leftover port-forward from a previous run?"
done
ok "isolated pair: hub ${HUB_IMAGE}, daemon ${DAEMON_IMAGE}; CLI $("${PERF_SENTINEL_LOCAL_BIN}" --version)"

rand_hex() { head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; }
READ_KEY="$(rand_hex 24)"
TOK_A="$(rand_hex 32)"
TOK_NONE="$(rand_hex 32)"
TOK_EXPIRED="$(rand_hex 32)"
OPS_PASSWORD="lab-$(rand_hex 12)"
OPS_HASH="$(printf '%s' "${OPS_PASSWORD}" | docker run -i --rm --network none "${HUB_IMAGE}" hash-password)" \
  || die "hash-password failed on ${HUB_IMAGE}"
case "${OPS_HASH}" in '$pbkdf2-sha256$'*) ;; *) die "hash-password printed '${OPS_HASH}'";; esac

# === 1. The namespace, the pair and the traffic ===
step "1. an isolated daemon (read gate on) and Hub (access on), polling every ${POLL_SECS}s"
# Always start from an empty namespace. A kept one (KEEP_NAMESPACE=yes) would
# take the new Secret without a rollout, so its pods would keep the old
# password and tokens; a terminating one (cleanup uses --wait=false) refuses
# creation. Delete waits out both.
kubectl delete namespace "${NS}" --ignore-not-found --wait=true --timeout=180s >/dev/null \
  || die "namespace ${NS} did not go away"
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "${NS}" create secret generic access-secrets \
  --from-literal=read-key="${READ_KEY}" \
  --from-literal=tok-a="${TOK_A}" \
  --from-literal=tok-none="${TOK_NONE}" \
  --from-literal=tok-expired="${TOK_EXPIRED}" \
  --from-literal=ops-hash="${OPS_HASH}" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

cat > "${TMP_DIR}/daemon.yaml" <<EOF
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: daemon-config
  namespace: ${NS}
data:
  config.toml: |
    [daemon]
    listen_address = "0.0.0.0"
    listen_port_http = 14318
    listen_port_grpc = 14317
    api_enabled = true
    trace_ttl_ms = 5000
    environment = "staging"
    # read_api_key comes from PERF_SENTINEL_READ_API_KEY: every GET but /health needs it.
    require_read_key = true

    [daemon.ack]
    enabled = false

    [detection]
    grouping_attributes = ["k8s.namespace.name"]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: daemon
  namespace: ${NS}
spec:
  replicas: 1
  selector: {matchLabels: {app: daemon}}
  template:
    metadata:
      labels: {app: daemon}
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        runAsGroup: 65534
        seccompProfile: {type: RuntimeDefault}
      containers:
        - name: perf-sentinel
          image: ${DAEMON_IMAGE}
          args: [watch, --config, /etc/perf-sentinel/config.toml]
          ports: [{name: http, containerPort: 14318}]
          env:
            - name: PERF_SENTINEL_READ_API_KEY
              valueFrom: {secretKeyRef: {name: access-secrets, key: read-key}}
          volumeMounts:
            - {name: config, mountPath: /etc/perf-sentinel, readOnly: true}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {drop: [ALL]}
          readinessProbe:
            httpGet: {path: /health, port: http}
            periodSeconds: 2
      volumes:
        - name: config
          configMap: {name: daemon-config}
---
apiVersion: v1
kind: Service
metadata:
  name: daemon
  namespace: ${NS}
spec:
  selector: {app: daemon}
  ports: [{name: http, port: 14318, targetPort: http}]
EOF

# Four sequential runs, one fixed nonce: services are <prefix>-${NONCE}-0000.
# Both aca-shared runs share a seed, so their signatures coincide.
cat > "${TMP_DIR}/tracegen.yaml" <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: tracegen
  namespace: ${NS}
spec:
  backoffLimit: 0
  template:
    metadata:
      labels: {app: tracegen}
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      containers:
        - name: tracegen
          image: lab-tracegen:1
          imagePullPolicy: Never
          command: [sh, -c]
          args:
            - |
              set -e
              run() {
                python3 /app/tracegen.py --protocol http-pb \
                  --endpoint http://daemon.${NS}.svc.cluster.local:14318 \
                  --duration 6 --tps 20 --batch-traces 10 --services 1 \
                  --service-prefix "\$1" --run-nonce ${NONCE} --seed "\$3" \
                  --mix n_plus_one:40,slow:20,redundant:20,chatty:10,clean:10 \
                  --resource-attribute "k8s.namespace.name=\$2"
              }
              run aca-a aca-a 11
              run aca-b aca-b 22
              run aca-shared aca-a 33
              run aca-shared aca-b 33
EOF

python3 - "${TMP_DIR}/hub.yaml" "${NS}" "${HUB_IMAGE}" "${POLL_SECS}" <<'PY'
import datetime, json, sys
out, ns, image, poll = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
iso = lambda t: t.isoformat().replace("+00:00", "Z")
daemon = f"http://daemon.{ns}.svc.cluster.local:14318"
provider = "http://127.0.0.1:9400"
settings = {"Hub": {
    "DatabasePath": "/data/hub.db",
    "PollInterval": f"00:00:{poll:02d}",
    "HttpTimeout": "00:00:02",
    "MetricsPort": 9464,
    "UpdateCheck": {"Enabled": False},
    # Same daemon twice: only the header differs. Secrets arrive through env.
    "Sources": [
        {"Id": "keyed", "Name": "keyed daemon", "Environment": "lab", "BaseUrl": daemon,
         "AuthHeaderName": "X-API-Key"},
        {"Id": "keyless", "Name": "keyless daemon", "Environment": "lab", "BaseUrl": daemon},
    ],
    "Auth": {
        "Enabled": True,
        "AuthorizationEndpoint": f"{provider}/authorize",
        "TokenEndpoint": f"{provider}/token",
        "UserInformationEndpoint": f"{provider}/userinfo",
        "ClientId": "lab", "ClientSecret": "lab",
        "RequiredGroups": ["/lab/users"],
        # Non-empty is what maps the device routes and admits local accounts.
        "TrustedProxyNetworks": ["127.0.0.1/32"],
    },
    "Access": {
        "Enabled": True,
        "Admins": ["local:ops"],
        "Groups": [{"Name": "devs", "Members": ["local:ops"]}, {"Name": "ci-a"}, {"Name": "ci-none"}],
        # No project for aca-b on purpose: it is what unmatched lists.
        "Projects": [{"Name": "a", "Patterns": [{"Attribute": "k8s.namespace.name=aca-a"}]}],
        "Grants": [{"Group": g, "Project": "a", "Role": "reader"}
                   for g in ("internal:devs", "internal:ci-a", "/teams/a")],
        "MachineTokens": [
            {"Name": "tok-a", "Group": "internal:ci-a", "ExpiresAt": iso(now + datetime.timedelta(days=30))},
            {"Name": "tok-none", "Group": "internal:ci-none", "ExpiresAt": iso(now + datetime.timedelta(days=30))},
            {"Name": "tok-expired", "Group": "internal:ci-a", "ExpiresAt": iso(now - datetime.timedelta(days=1))},
        ],
        "LocalAccounts": [{"Name": "ops"}],
    },
}}
fake = r'''
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs

# The code is the user's name, and the access token is the code.
USERS = {
    "alice": {"sub": "u-alice", "email": "alice@lab", "groups": ["/lab/users", "/teams/a", "/lab/unlisted"]},
    "bob": {"sub": "u-bob", "email": "bob@lab", "groups": ["/teams/a"]},
    "mallory": {"sub": "local:ops", "email": "mallory@lab", "groups": ["/lab/users", "/teams/a"]},
}


class Provider(BaseHTTPRequestHandler):
    def answer(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        form = parse_qs(self.rfile.read(int(self.headers.get("Content-Length", 0))).decode())
        code = form.get("code", [""])[0]
        if self.path != "/token" or code not in USERS:
            return self.answer(400, {"error": "invalid_grant"})
        self.answer(200, {"access_token": code, "token_type": "Bearer", "expires_in": 300})

    def do_GET(self):
        bearer = self.headers.get("Authorization", "").removeprefix("Bearer ")
        if self.path != "/userinfo" or bearer not in USERS:
            return self.answer(401, {"error": "invalid_token"})
        self.answer(200, USERS[bearer])


HTTPServer(("127.0.0.1", 9400), Provider).serve_forever()
'''
indent = lambda text, n: "\n".join(" " * n + line if line else "" for line in text.splitlines())
env = [("ASPNETCORE_ENVIRONMENT", None, "Production"),
       # Without the metrics port in the list the Hub exits at startup, event 2002 (leg D2).
       ("ASPNETCORE_HTTP_PORTS", None, "8080;9464"),
       ("Hub__Sources__0__AuthHeaderValue", "read-key", None),
       ("Hub__Access__MachineTokens__0__Token", "tok-a", None),
       ("Hub__Access__MachineTokens__1__Token", "tok-none", None),
       ("Hub__Access__MachineTokens__2__Token", "tok-expired", None),
       ("Hub__Access__LocalAccounts__0__PasswordHash", "ops-hash", None)]
env_yaml = "\n".join(
    f"            - name: {name}\n              value: \"{value}\"" if value is not None else
    f"            - name: {name}\n              valueFrom: {{secretKeyRef: {{name: access-secrets, key: {key}}}}}"
    for name, key, value in env)
open(out, "w").write(f"""---
apiVersion: v1
kind: ConfigMap
metadata:
  name: hub-config
  namespace: {ns}
data:
  appsettings.Production.json: |
{indent(json.dumps(settings, indent=2), 4)}
  fake.py: |
{indent(fake.strip(), 4)}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hub
  namespace: {ns}
spec:
  replicas: 1
  strategy: {{type: Recreate}}
  selector: {{matchLabels: {{app: hub}}}}
  template:
    metadata:
      labels: {{app: hub}}
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 1654
        runAsGroup: 1654
        fsGroup: 1654
        seccompProfile: {{type: RuntimeDefault}}
      containers:
        - name: hub
          image: {image}
          imagePullPolicy: Never
          ports: [{{name: http, containerPort: 8080}}, {{name: metrics, containerPort: 9464}}]
          env:
{env_yaml}
          volumeMounts:
            - {{name: config, mountPath: /app/appsettings.Production.json, subPath: appsettings.Production.json, readOnly: true}}
            - {{name: data, mountPath: /data}}
            - {{name: tmp, mountPath: /tmp}}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {{drop: [ALL]}}
          readinessProbe:
            httpGet: {{path: /health/ready, port: http}}
            periodSeconds: 2
        # The fake provider, on the pod's loopback: the Hub calls /token and /userinfo here.
        - name: provider
          image: lab-tracegen:1
          imagePullPolicy: Never
          command: [python3, /provider/fake.py]
          volumeMounts:
            - {{name: config, mountPath: /provider/fake.py, subPath: fake.py, readOnly: true}}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {{drop: [ALL]}}
      volumes:
        - name: config
          configMap: {{name: hub-config}}
        - name: data
          emptyDir: {{}}
        - name: tmp
          emptyDir: {{}}
---
apiVersion: v1
kind: Service
metadata:
  name: hub
  namespace: {ns}
spec:
  selector: {{app: hub}}
  ports: [{{name: http, port: 8080, targetPort: http}}, {{name: metrics, port: 9464, targetPort: metrics}}]
""")
PY

kubectl apply -f "${TMP_DIR}/daemon.yaml" >/dev/null
kubectl -n "${NS}" rollout status deploy/daemon --timeout=180s >/dev/null \
  || die "the isolated daemon did not become ready: $(kubectl -n "${NS}" logs deploy/daemon --tail=20 2>&1)"
kubectl apply -f "${TMP_DIR}/tracegen.yaml" >/dev/null
kubectl apply -f "${TMP_DIR}/hub.yaml" >/dev/null
kubectl -n "${NS}" rollout status deploy/hub --timeout=180s >/dev/null \
  || die "the isolated Hub did not become ready: $(kubectl -n "${NS}" logs deploy/hub -c hub --tail=20 2>&1)"
# disown, so killing it in cleanup does not print a job-control notice
# over the scenario verdict.
kubectl -n "${NS}" port-forward svc/hub "${HUB_PORT}:8080" "${METRICS_PORT}:9464" >"${TMP_DIR}/pf.log" 2>&1 &
PF_PID=$!
disown "${PF_PID}" 2>/dev/null || true
for _ in $(seq 1 40); do
  curl -sf "${HUB}/health/ready" >/dev/null 2>&1 && break
  sleep 0.5
done
curl -sf "${HUB}/health/ready" >/dev/null || die "the isolated Hub never answered /health/ready"
ok "isolated Hub ready, access on"
kubectl -n "${NS}" wait --for=condition=complete job/tracegen --timeout=180s >/dev/null 2>&1 \
  || die "the tracegen job did not complete: $(kubectl -n "${NS}" logs job/tracegen --tail=5 2>&1)"
ok "four tracegen runs sent"

# === E. Local account ===
step "E. local account: the sign-in page, then the admin's view"
CODE="$(http e-root "${HUB}/")"
LOCATION="$(hdr e-root location)"
case "${CODE} ${LOCATION}" in
  "302 "*"/auth/sign-in?return_url="*) ok "E: GET / without a session -> 302 ${LOCATION}"; record "E: page without session redirects to the sign-in page" PASS "302 ${LOCATION}";;
  *) fail "E: GET / -> ${CODE} ${LOCATION}"; record "E: page without session redirects to the sign-in page" FAIL "${CODE} ${LOCATION}";;
esac
expect "E: /api/findings without a session" "$(http e-anon "${HUB}/api/findings")" "401"
# What the code sends, not the API.md wording (which still says 'unsafe-inline').
CODE="$(http e-page "${HUB}/auth/sign-in?return_url=/")"
CSP="$(hdr e-page content-security-policy)"
expect_cmd "E: sign-in page CSP allows its style by hash" "${CODE}; ${CSP}" \
  python3 -c 'import sys; c=sys.argv[2]; sys.exit(0 if sys.argv[1]=="200" and "style-src '"'"'sha256-" in c and "unsafe-inline" not in c and "frame-ancestors '"'"'none'"'"'" in c else 1)' "${CODE}" "${CSP}"

sign_in_local() {  # $1 = name, $2 = password
  http "e-signin-$1" -X POST "${HUB}/auth/sign-in/local" -H "Sec-Fetch-Site: same-origin" \
    --data-urlencode "name=ops" --data-urlencode "password=$2" --data-urlencode "return_url=/"
}
CODE="$(sign_in_local wrong "not-the-password-at-all")"
WRONG_LINE="$(grep -c 'The name or the password is wrong.' "${TMP_DIR}/e-signin-wrong.body" || true)"
expect "E: wrong password" "${CODE} ${WRONG_LINE}" "403 1"
CODE="$(sign_in_local right "${OPS_PASSWORD}")"
ADMIN_COOKIE="$(cookies e-signin-right hub_session)"
expect_cmd "E: right password signs in" "${CODE}, hub_session $([ -n "${ADMIN_COOKIE}" ] && echo set || echo missing)" \
  test "${CODE}" = "302" -a -n "${ADMIN_COOKIE}"
[ -n "${ADMIN_COOKIE}" ] || die "no admin session, every leg below needs it"

admin() { http "$1" -H "Cookie: ${ADMIN_COOKIE}" "${HUB}$2"; }

# Wait for the corpus: all three families in, through the keyed source.
FAMS="[]"
for _ in $(seq 1 30); do
  admin wait-corpus "/api/findings?limit=1000" >/dev/null
  FAMS="$(pyv wait-corpus 'fams(d)')"
  [ "${FAMS}" = '["aca-a", "aca-b", "aca-shared"]' ] && break
  sleep "${POLL_SECS}"
done
[ "${FAMS}" = '["aca-a", "aca-b", "aca-shared"]' ] \
  || die "the Hub never listed all three families (got ${FAMS}); daemon log: $(kubectl -n "${NS}" logs deploy/daemon --tail=2 2>&1 | tail -c 400)"
ok "corpus in: ${FAMS}, $(pyv wait-corpus 'len(d)') findings"
# One more poll tick, so the aca-shared copy has been read under both groupings.
sleep "$((POLL_SECS * 2))"

expect "E: /api/access status" "$(admin e-access /api/access)" "200"
expect "E: caller, subject, admin" \
  "$(pyv e-access '[d["caller"], d["subject"], d["admin"]]')" '["session", "local:ops", true]'
expect "E: configuration.local_accounts" "$(pyv e-access 'd["configuration"]["local_accounts"]')" '["ops"]'
expect "E: unmatched lists the aca-b attribute" \
  "$(pyv e-access 'any(a["key"] == "k8s.namespace.name" and a["value"] == "aca-b" for a in d["unmatched"]["attributes"])')" "true"
expect "E: conflicts hold an aca-shared copy with both values" \
  "$(pyv e-access 'sorted({tuple(c["values"]) for c in d["conflicts"]["copies"] if fam(c) == "aca-shared"})')" '[["aca-a", "aca-b"]]'

# === A. The daemon gate, as the Hub sees it ===
step "A. the daemon's read gate, seen by the Hub's poll"
expect "A: /api/sources" "$(admin a-sources /api/sources)" "200"
expect "A: keyed reachable" "$(pyv a-sources '[s["reachable"] for s in d if s["id"] == "keyed"]')" "[true]"
# Any HTTP status from the daemon, its 401 here, is "http_error" (SourcePoller).
expect "A: keyless unreachable, refused by the gate" \
  "$(pyv a-sources '[[s["reachable"], s["last_error_code"]] for s in d if s["id"] == "keyless"]')" '[[false, "http_error"]]'
expect "A: every finding's sources[] names keyed only" \
  "$(pyv wait-corpus 'sorted({s["id"] for r in d for s in r["sources"]})')" '["keyed"]'

# === B. Grouping filter ===
step "B. the grouping filter, blank variants included"
for g in aca-a aca-b aca-zzz; do admin "b-${g}" "/api/findings?limit=1000&grouping=${g}" >/dev/null; done
expect "B: grouping=aca-a" "$(pyv b-aca-a 'fams(d)')" '["aca-a", "aca-shared"]'
expect "B: grouping=aca-b" "$(pyv b-aca-b 'fams(d)')" '["aca-b", "aca-shared"]'
expect "B: grouping=aca-zzz" "$(pyv b-aca-zzz 'd')" '[]'
# The baseline must itself hold all three families, or equal-to-it proves nothing.
CODE="$(admin b-all "/api/findings?limit=1000")"
expect "B: unfiltered listing" "${CODE} $(pyv b-all 'fams(d)')" '200 ["aca-a", "aca-b", "aca-shared"]'
ALL_SIGS="$(pyv b-all 'sorted(sig(r) for r in d)')"
i=0
for q in "grouping=" "grouping=%20" "grouping=+"; do
  i=$((i + 1))
  CODE="$(admin "b-blank-${i}" "/api/findings?limit=1000&${q}")"
  expect_cmd "B: ${q} equals the unfiltered listing" "${CODE}, $(pyv "b-blank-${i}" 'len(d)') rows" \
    test "${CODE} $(pyv "b-blank-${i}" 'sorted(sig(r) for r in d)')" = "200 ${ALL_SIGS}"
done

# === C. Machine tokens ===
step "C. machine tokens over AOT Kestrel"
bearer() { local name="$1" token="$2"; shift 2; http "${name}" -H "Authorization: Bearer ${token}" "$@"; }
CODE="$(bearer c-expired "${TOK_EXPIRED}" "${HUB}/api/findings")"
expect "C: expired token" "${CODE} $(hdr c-expired www-authenticate)" '401 Bearer error="invalid_token"'
CODE="$(bearer c-none "${TOK_NONE}" "${HUB}/api/findings")"
expect "C: token without a grant" "${CODE} $(pyv c-none 'd.get("detail")')" "403 No grant gives you findings.read on this Hub."
SVC_A="aca-a-${NONCE}-0000"
SVC_B="aca-b-${NONCE}-0000"
CODE="$(bearer c-plugin-a "${TOK_A}" "${HUB}/api/findings?service=${SVC_A}&limit=1000&include_acked=true")"
expect "C: plugin query on an aca-a service" "${CODE} $(pyv c-plugin-a 'len(d) > 0')" "200 true"
CODE="$(bearer c-plugin-b "${TOK_A}" "${HUB}/api/findings?service=${SVC_B}&limit=1000&include_acked=true")"
expect "C: plugin query on an aca-b service" "${CODE} $(pyv c-plugin-b 'd')" "200 []"
CODE="$(bearer c-all "${TOK_A}" "${HUB}/api/findings?limit=1000")"
expect "C: tok-a unfiltered reads aca-a and the conflicting aca-shared" "${CODE} $(pyv c-all 'fams(d)')" '200 ["aca-a", "aca-shared"]'
expect "C: API response frame-ancestors" "$(hdr c-all content-security-policy)" "frame-ancestors 'self'"
SIG_A="$(pyv c-plugin-a 'sig(d[0])')"
CODE="$(bearer c-ack "${TOK_A}" -X POST "${HUB}/api/sources/keyed/acks" -H "Content-Type: application/json" \
  --data "{\"signature\":\"${SIG_A}\",\"reason\":\"lab\"}")"
expect "C: machine token ack" "${CODE} $(pyv c-ack 'd.get("detail")')" "403 A machine token only reads."
CODE="$(bearer c-access "${TOK_A}" "${HUB}/api/access")"
expect "C: /api/access for tok-a" \
  "${CODE} $(pyv c-access '[d["caller"], d["admin"], len(d["reach"]) > 0 and all(r["permissions"] == ["findings.read"] for r in d["reach"])]')" \
  '200 ["machine_token", false, true]'

# === D. MetricsPort ===
step "D. MetricsPort: /metrics on its own port alone"
expect "D: /metrics on the main port" "$(http d-main-metrics "${HUB}/metrics")" "404"
CODE="$(http d-metrics "http://127.0.0.1:${METRICS_PORT}/metrics")"
expect "D: /metrics on the metrics port" "${CODE} $(grep -c '^# TYPE' "${TMP_DIR}/d-metrics.body" | awk '{print ($1 > 0)}')" "200 1"
expect "D: /health/ready on the metrics port" "$(http d-metrics-ready "http://127.0.0.1:${METRICS_PORT}/health/ready")" "404"
# D2: real Kestrel only, MetricsEndpoint returns early under TestServer.
docker rm -f "${D2_NAME}" >/dev/null 2>&1 || true
docker run -d --name "${D2_NAME}" --network none --tmpfs /data \
  -e ASPNETCORE_HTTP_PORTS=8080 -e Hub__MetricsPort=9464 -e Hub__DatabasePath=/data/hub.db \
  -e Hub__UpdateCheck__Enabled=false -e Hub__Sources__0__Id=x -e Hub__Sources__0__Name=x \
  -e Hub__Sources__0__Environment=lab -e Hub__Sources__0__BaseUrl=http://127.0.0.1:1 \
  "${HUB_IMAGE}" >/dev/null || die "docker run of ${HUB_IMAGE} failed"
D2_EXIT="running"
for _ in $(seq 1 60); do
  [ "$(docker inspect -f '{{.State.Running}}' "${D2_NAME}" 2>/dev/null)" = "false" ] \
    && { D2_EXIT="$(docker inspect -f '{{.State.ExitCode}}' "${D2_NAME}")"; break; }
  sleep 1
done
D2_EVENT="$(docker logs "${D2_NAME}" 2>&1 | grep -c 'MetricsEndpoint\[2002\]' || true)"
docker rm -f "${D2_NAME}" >/dev/null 2>&1 || true
expect "D2: unbound metrics port exits 1 with event 2002" "exit ${D2_EXIT}, event 2002 x${D2_EVENT}" "exit 1, event 2002 x1"

# === F. Terminal sign-in with the real CLI ===
step "F. perf-sentinel login, the token file, logout"
mkdir -p "${TMP_DIR}/xdg"
# Not through cli(): a backgrounded function is a subshell, and killing it would orphan login.
# env execs the binary, so $! is login itself.
env -u PERF_SENTINEL_HUB_TOKEN -u PERF_SENTINEL_HUB_URL XDG_CONFIG_HOME="${TMP_DIR}/xdg" \
  "${PERF_SENTINEL_LOCAL_BIN}" login --hub "${HUB}" >"${TMP_DIR}/login.out" 2>"${TMP_DIR}/login.err" &
LOGIN_PID=$!
USER_CODE=""
for _ in $(seq 1 40); do
  USER_CODE="$(sed -nE 's/.*enter the code ([A-Z]{4}-[A-Z]{4}).*/\1/p' "${TMP_DIR}/login.out" | head -1)"
  [ -n "${USER_CODE}" ] && break
  sleep 0.5
done
[ -n "${USER_CODE}" ] || die "login printed no code: $(cat "${TMP_DIR}/login.out" "${TMP_DIR}/login.err")"
ok "login waits on code ${USER_CODE}"
browser_post() {  # $1 = name, $2 = path, $3 = JSON body
  http "$1" -X POST "${HUB}$2" -H "Cookie: ${ADMIN_COOKIE}" -H "Content-Type: application/json" \
    -H "Sec-Fetch-Site: same-origin" --data "$3"
}
CODE="$(browser_post f-verify /api/device/verify "{\"user_code\":\"${USER_CODE}\"}")"
expect "F: verify the code" "${CODE} $(pyv f-verify 'd.get("same_network")')" "200 true"
# Built apart: a comma inside braces in a nested substitution is brace-expanded.
APPROVE_BODY="{\"user_code\":\"${USER_CODE}\",\"approve\":true}"
expect "F: approve the code" "$(browser_post f-approve /api/device/approve "${APPROVE_BODY}")" "204"
# The CLI polls every 5 seconds.
for _ in $(seq 1 60); do
  kill -0 "${LOGIN_PID}" 2>/dev/null || break
  sleep 0.5
done
if kill -0 "${LOGIN_PID}" 2>/dev/null; then
  LOGIN_EXIT="still running"
else
  LOGIN_EXIT=0
  wait "${LOGIN_PID}" || LOGIN_EXIT=$?
  LOGIN_PID=""
fi
expect "F: login exits 0, signed in" "${LOGIN_EXIT} $(grep -c "^Signed in to ${HUB} until" "${TMP_DIR}/login.out" || true)" "0 1"
TOKEN_FILE="${TMP_DIR}/xdg/perf-sentinel/hub-token.json"
FILE_CHECK="$(python3 - "${TOKEN_FILE}" "${HUB}" <<'PY'
import json, os, stat, sys
path, hub = sys.argv[1], sys.argv[2]
try:
    st, dst = os.stat(path), os.stat(os.path.dirname(path))
    data = json.load(open(path))
except Exception as exc:  # noqa: BLE001
    print(f"unreadable: {exc}")
    sys.exit(0)
print(json.dumps([oct(stat.S_IMODE(st.st_mode)), oct(stat.S_IMODE(dst.st_mode)), sorted(data),
                  data.get("hub_url") == hub, str(data.get("token", "")).startswith("pshub_")]))
PY
)"
expect "F: token file mode, dir mode, keys, hub_url, token prefix" "${FILE_CHECK}" \
  '["0o600", "0o700", ["expires_at_ms", "hub_url", "token"], true, true]'
TERMINAL_TOKEN="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["token"])' "${TOKEN_FILE}" 2>/dev/null || true)"
F_OUT="$(cli hub findings --format json --limit 1000 2>"${TMP_DIR}/f-findings.err")" && F_EXIT=0 || F_EXIT=$?
printf '%s' "${F_OUT}" > "${TMP_DIR}/f-findings.body"
expect "F: hub findings with the stored token" "${F_EXIT} $(pyv f-findings 'fams(d)')" '0 ["aca-a", "aca-shared"]'
CODE="$(bearer f-access "${TERMINAL_TOKEN}" "${HUB}/api/access")"
expect "F: /api/access with the terminal token" "${CODE} $(pyv f-access '[d["caller"], d["admin"]]')" '200 ["terminal_token", false]'
LOGOUT_OUT="$(cli logout 2>&1)" || true
expect_cmd "F: logout signs out and deletes the file" "${LOGOUT_OUT}" \
  sh -c "printf '%s' \"\$1\" | grep -q 'Signed out of' && [ ! -e \"\$2\" ]" _ "${LOGOUT_OUT}" "${TOKEN_FILE}"
expect "F: the revoked token" "$(bearer f-revoked "${TERMINAL_TOKEN}" "${HUB}/api/access")" "401"
F_MACHINE_EXIT=0
PERF_SENTINEL_HUB_TOKEN="${TOK_A}" XDG_CONFIG_HOME="${TMP_DIR}/xdg" "${PERF_SENTINEL_LOCAL_BIN}" \
  hub findings --hub "${HUB}" --format json >/dev/null 2>"${TMP_DIR}/f-machine.err" || F_MACHINE_EXIT=$?
expect "F: hub findings with a machine token" "${F_MACHINE_EXIT}" "0"
ACK_EXIT=0
ACK_ERR="$(PERF_SENTINEL_HUB_TOKEN="${TOK_A}" XDG_CONFIG_HOME="${TMP_DIR}/xdg" "${PERF_SENTINEL_LOCAL_BIN}" \
  hub ack --hub "${HUB}" --source-id keyed -s "${SIG_A}" -r lab 2>&1 >/dev/null)" || ACK_EXIT=$?
expect "F: hub ack with a machine token" "${ACK_EXIT} $(printf '%s' "${ACK_ERR}" | grep -c 'A machine token only reads.')" "1 1"

# === G. Provider sign-in ===
step "G. provider sign-in under AOT, against the fake provider"
# Returns the HTTP code of the callback; its headers land in g-cb-<user>.hdr.
provider_sign_in() {  # $1 = user
  local user="$1" location state correlation
  http "g-sso-${user}" "${HUB}/auth/sign-in/sso?return_url=/" >"${TMP_DIR}/g-sso-${user}.code"
  location="$(hdr "g-sso-${user}" location)"
  state="$(python3 -c 'import sys,urllib.parse as u; print(u.parse_qs(u.urlsplit(sys.argv[1]).query).get("state",[""])[0])' "${location}")"
  correlation="$(cookies "g-sso-${user}" .AspNetCore.Correlation)"
  printf '%s\n' "${location}" >"${TMP_DIR}/g-sso-${user}.location"
  http "g-cb-${user}" -G "${HUB}/auth/callback" -H "Cookie: ${correlation}" \
    --data-urlencode "code=${user}" --data-urlencode "state=${state}"
}
CODE="$(provider_sign_in alice)"
SSO_LOCATION="$(cat "${TMP_DIR}/g-sso-alice.location")"
expect_cmd "G: SSO challenge" "$(cat "${TMP_DIR}/g-sso-alice.code") ${SSO_LOCATION%%\?*}, correlation cookie $([ -n "$(cookies g-sso-alice .AspNetCore.Correlation)" ] && echo set || echo missing)" \
  sh -c 'case "$1" in "302 http://127.0.0.1:9400/authorize?"*state=*) [ -n "$2" ];; *) exit 1;; esac' _ \
  "$(cat "${TMP_DIR}/g-sso-alice.code") ${SSO_LOCATION}" "$(cookies g-sso-alice .AspNetCore.Correlation)"
ALICE_COOKIE="$(cookies g-cb-alice hub_session)"
expect "G: alice's callback" "${CODE} $([ -n "${ALICE_COOKIE}" ] && echo hub_session || echo no-session)" "302 hub_session"
CODE="$(http g-access-alice -H "Cookie: ${ALICE_COOKIE}" "${HUB}/api/access")"
expect "G: alice's subject and identity" "${CODE} $(pyv g-access-alice '[d["subject"], d["identity"], d["caller"]]')" \
  '200 ["u-alice", "alice@lab", "session"]'
expect "G: alice's groups" "$(pyv g-access-alice 'sorted([g["name"], g["origin"]] for g in d["groups"])')" '[["/teams/a", "provider"]]'
http g-findings-alice -H "Cookie: ${ALICE_COOKIE}" "${HUB}/api/findings?limit=1000" >/dev/null
expect "G: alice reads no aca-b" "$(pyv g-findings-alice 'fams(d)')" '["aca-a", "aca-shared"]'
BOB_CODE="$(provider_sign_in bob)"
MALLORY_CODE="$(provider_sign_in mallory)"
# The answer is one line for every refusal; the reason is only in the log (event 1900).
kubectl -n "${NS}" logs deploy/hub -c hub > "${TMP_DIR}/hub.log" 2>&1 || true
refused_for() { grep -A1 'HubAuthentication\[1900\]' "${TMP_DIR}/hub.log" | grep -c "$1" || true; }
expect "G: bob, outside RequiredGroups" \
  "${BOB_CODE} $(grep -c '^Sign-in refused\.' "${TMP_DIR}/g-cb-bob.body" || true) $(refused_for 'bob@lab is in none of Hub:Auth:RequiredGroups')" "403 1 1"
expect "G: mallory, subject local:ops" \
  "${MALLORY_CODE} $([ -z "$(cookies g-cb-mallory hub_session)" ] && echo no-session || echo session) $(refused_for 'mallory@lab: the subject or the identity starts with a reserved prefix')" \
  "403 no-session 1"

# === Report ===
{
  echo "# Scenario: ${SCENARIO}"
  echo
  echo "Hub image: \`${HUB_IMAGE}\`, daemon image: \`${DAEMON_IMAGE}\`, CLI: \`$("${PERF_SENTINEL_LOCAL_BIN}" --version)\`"
  echo
  echo "Settled on this run: keyless \`last_error_code\` = \`$(pyv a-sources '[s["last_error_code"] for s in d if s["id"] == "keyless"][0]')\`;"
  echo "OAuth callback over http with the correlation cookie sent explicitly, no X-Forwarded-Proto;"
  echo "device request client address = \`$(pyv f-verify 'd.get("client_address")')\`."
  echo
  echo "| Leg | Sub-test | Verdict | Note |"
  echo "| --- | --- | --- | --- |"
  for i in "${!NAMES[@]}"; do
    echo "| ${NAMES[$i]%%:*} | ${NAMES[$i]#*: } | ${VERDICTS[$i]} | ${NOTES[$i]//|/\\|} |"
  done
} > "${REPORT}"

step "Report written to ${REPORT}"
for leg in E A B C D F G; do
  verdict=PASS
  for i in "${!NAMES[@]}"; do
    case "${NAMES[$i]}" in "${leg}:"*|"${leg}2:"*) [ "${VERDICTS[$i]}" = "PASS" ] || verdict=FAIL;; esac
  done
  [ "${verdict}" = PASS ] && color_green "    leg ${leg}: PASS" || color_red "    leg ${leg}: FAIL"
done
for v in "${VERDICTS[@]}"; do
  [ "${v}" = "PASS" ] || { color_red "SCENARIO FAILED"; exit 1; }
done
color_green "SCENARIO PASSED"
