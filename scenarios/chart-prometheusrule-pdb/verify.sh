#!/usr/bin/env bash
# Chart Phase A: PrometheusRule + PodDisruptionBudget (perf-sentinel 0.8.13+,
# chart 0.2.63). Both features are opt-in (values default to disabled).
# Chart 0.2.63 dropped the findings-store near-cap alert, so the stored_findings
# / max_retained_findings metrics are no longer referenced by the rule set.
#
# This scenario renders the upstream Helm chart (charts/perf-sentinel/ in the
# perf-sentinel product repo -- the lab does NOT vendor it, the daemon ships via
# manifests/perf-sentinel-daemon.yaml) and validates the two new opt-in
# resources without needing a published image. It mirrors the product CI's
# `flags-on` leg (helm template + kubeconform -strict -ignore-missing-schemas)
# and adds the promtool rule-expression check that CI does not run.
#
# Sub-tests:
#   1. render flags-on | kubeconform -strict -ignore-missing-schemas -> 0 invalid.
#   2. promtool check rules on the PrometheusRule spec.groups -> SUCCESS.
#   3. every alert expr references a real daemon metric (11 names, chart 0.2.63).
#   4. PDB edge case: minAvailable=0 renders `minAvailable: 0` (NOT maxUnavailable);
#      default (no minAvailable) renders `maxUnavailable: 1`; apiVersion policy/v1.
#   5. if the cluster has the Prometheus-Operator CRD, `helm install` (no --wait,
#      the daemon image need not exist) -> PrometheusRule + PDB admitted by the
#      API server; otherwise SKIP (render+kubeconform+promtool suffice, as in CI).
#
# Chart path override: PERF_SENTINEL_CHART, else
# ${PERF_SENTINEL_REPO_PATH:-$HOME/RustroverProjects/perf-sentinel}/charts/perf-sentinel.

set -euo pipefail

SCENARIO="chart-prometheusrule-pdb"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
PERF_SENTINEL_REPO_PATH="${PERF_SENTINEL_REPO_PATH:-$HOME/RustroverProjects/perf-sentinel}"
CHART="${PERF_SENTINEL_CHART:-${PERF_SENTINEL_REPO_PATH}/charts/perf-sentinel}"

mkdir -p "${TMP_DIR}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
fail() { color_red   "    fail: $*"; }
die()  { color_red   "    error: $*"; exit 1; }

declare -a NAMES=() VERDICTS=() NOTES=()
record() { NAMES+=("$1"); VERDICTS+=("$2"); NOTES+=("$3"); }

# The shipped alerts, and the doctrine behind the split. The chart alerts on
# data the daemon lost and cannot recover, plus the freshness of every energy
# scraper it can be configured with. Saturation, service cardinality and
# correlator eviction are deliberately NOT alerts: `values.yaml` says they are
# dashboard panels, "because each one fires on a state the daemon reaches
# while working normally" (docs/METRICS.md), and chart 0.17.0 removed them in
# `fix(chart): alert only on data the daemon lost irrecoverably`.
REQUIRED_METRICS=(
  perf_sentinel_otlp_rejected_total
  perf_sentinel_analysis_shed_traces_total
  perf_sentinel_archive_windows_dropped_total
  perf_sentinel_ingest_memory_pressure
  perf_sentinel_scaphandre_last_scrape_age_seconds
  perf_sentinel_kepler_last_scrape_age_seconds
  perf_sentinel_redfish_last_scrape_age_seconds
  perf_sentinel_cloud_energy_last_scrape_age_seconds
  perf_sentinel_alumet_last_scrape_age_seconds
  # The host CPU probes of [green.database_static] and [green.broker_static]
  # (chart 0.32.0, PerfSentinelHostCpuProbeStale).
  perf_sentinel_database_cpu_last_scrape_age_seconds
  perf_sentinel_broker_cpu_last_scrape_age_seconds
)

# The other half of the same rule, asserted rather than assumed. Dropping the
# five from the list above would leave a scenario that passes whether or not
# the doctrine holds; these must stay OUT of the rules, and an alert added on
# one of them has to fail here rather than reach an operator's pager.
FORBIDDEN_METRICS=(
  perf_sentinel_active_traces
  perf_sentinel_analysis_queue_depth
  perf_sentinel_analysis_queue_capacity
  perf_sentinel_correlator_pairs_evicted_total
  perf_sentinel_service_io_ops_overflow_total
)

step "0. Pre-flight"
command -v helm    >/dev/null || die "helm not on PATH"
command -v python3 >/dev/null || die "python3 not on PATH"
[ -f "${CHART}/Chart.yaml" ] || die "chart not found at ${CHART} (set PERF_SENTINEL_CHART or PERF_SENTINEL_REPO_PATH)"
CHART_VER="$(awk '/^version:/{print $2}' "${CHART}/Chart.yaml")"
APP_VER="$(awk '/^appVersion:/{gsub(/"/,"",$2);print $2}' "${CHART}/Chart.yaml")"
ok "chart ${CHART} (version ${CHART_VER}, appVersion ${APP_VER})"

FLAGS=(--set prometheusRule.enabled=true --set prometheusRule.energyScrapers=true --set podDisruptionBudget.enabled=true)

step "1. helm template flags-on | kubeconform -strict -ignore-missing-schemas"
helm template t "${CHART}" "${FLAGS[@]}" > "${TMP_DIR}/all.yaml" 2>"${TMP_DIR}/helm-err.txt" \
  || die "helm template failed: $(cat "${TMP_DIR}/helm-err.txt")"
if command -v kubeconform >/dev/null; then
  if kubeconform -strict -summary -ignore-missing-schemas "${TMP_DIR}/all.yaml" > "${TMP_DIR}/kc.txt" 2>&1 \
     && ! grep -qE 'Invalid: [1-9]|Errors: [1-9]' "${TMP_DIR}/kc.txt"; then
    ok "kubeconform: $(grep Summary "${TMP_DIR}/kc.txt")"
    record "kubeconform" "PASS" "$(grep Summary "${TMP_DIR}/kc.txt")"
  else
    fail "kubeconform reported invalid/errors"; cat "${TMP_DIR}/kc.txt"
    record "kubeconform" "FAIL" "$(grep Summary "${TMP_DIR}/kc.txt" || echo 'see log')"
  fi
else
  fail "kubeconform absent"; record "kubeconform" "SKIP" "kubeconform not installed"
fi

step "2. promtool check rules (PrometheusRule spec.groups)"
helm template t "${CHART}" --set prometheusRule.enabled=true --set prometheusRule.energyScrapers=true \
  --show-only templates/prometheusrule.yaml > "${TMP_DIR}/pr.yaml" 2>/dev/null || true
# Each guard is an elif condition, so a failure records a clean SKIP/FAIL instead
# of aborting the whole script under `set -e` (e.g. PyYAML absent on a bare CI
# runner, or an empty render from a chart/template rename).
if ! command -v promtool >/dev/null; then
  fail "promtool absent"; record "promtool" "SKIP" "promtool not installed"
elif ! python3 -c 'import yaml' >/dev/null 2>&1; then
  fail "PyYAML absent"; record "promtool" "SKIP" "python3 yaml module not installed"
elif [ ! -s "${TMP_DIR}/pr.yaml" ]; then
  fail "helm --show-only produced no PrometheusRule"; record "promtool" "FAIL" "empty render"
elif ! python3 -c "
import yaml
doc=yaml.safe_load(open('${TMP_DIR}/pr.yaml'))
yaml.safe_dump(doc['spec'], open('${TMP_DIR}/rules.yaml','w'), default_flow_style=False, sort_keys=False)
" 2>"${TMP_DIR}/pyerr.txt"; then
  fail "spec extraction failed: $(cat "${TMP_DIR}/pyerr.txt")"; record "promtool" "FAIL" "spec extraction error"
elif promtool check rules "${TMP_DIR}/rules.yaml" > "${TMP_DIR}/promtool.txt" 2>&1; then
  PT_OK="$(grep -i success "${TMP_DIR}/promtool.txt" | head -1)"
  ok "promtool: ${PT_OK}"; record "promtool" "PASS" "${PT_OK}"
else
  fail "promtool check rules failed"; cat "${TMP_DIR}/promtool.txt"; record "promtool" "FAIL" "see log"
fi

# === 3. every required metric appears in the rendered rules ===
step "3. the rules alert on lost data and scraper freshness, and on nothing else"
miss=0
for m in "${REQUIRED_METRICS[@]}"; do
  if grep -q "$m" "${TMP_DIR}/pr.yaml"; then ok "$m"; else fail "MISSING $m"; miss=$((miss+1)); fi
done
for m in "${FORBIDDEN_METRICS[@]}"; do
  if grep -q "$m" "${TMP_DIR}/pr.yaml"; then
    fail "ALERTS ON $m, which values.yaml calls a dashboard panel, not an alert"
    miss=$((miss+1))
  else
    ok "not alerted on: $m"
  fi
done
if [ "$miss" -eq 0 ]; then
  record "metrics" "PASS" "${#REQUIRED_METRICS[@]} alerted, ${#FORBIDDEN_METRICS[@]} deliberately not"
else record "metrics" "FAIL" "$miss metric(s) on the wrong side of the alert/panel split"; fi

step "4. PodDisruptionBudget edge cases"
PDB0="$(helm template t "${CHART}" --set podDisruptionBudget.enabled=true --set podDisruptionBudget.minAvailable=0 --show-only templates/poddisruptionbudget.yaml 2>/dev/null)"
PDBD="$(helm template t "${CHART}" --set podDisruptionBudget.enabled=true --show-only templates/poddisruptionbudget.yaml 2>/dev/null)"
pdb_ok=1
echo "$PDB0" | grep -qE '^[[:space:]]*minAvailable: 0[[:space:]]*$' || { fail "minAvailable=0 did not render 'minAvailable: 0'"; pdb_ok=0; }
echo "$PDB0" | grep -qE 'maxUnavailable' && { fail "minAvailable=0 also rendered maxUnavailable (0 treated as falsy)"; pdb_ok=0; }
echo "$PDBD" | grep -qE '^[[:space:]]*maxUnavailable: 1[[:space:]]*$' || { fail "default did not render 'maxUnavailable: 1'"; pdb_ok=0; }
echo "$PDB0" | grep -qE 'apiVersion: policy/v1' || { fail "PDB apiVersion not policy/v1"; pdb_ok=0; }
if [ "$pdb_ok" -eq 1 ]; then ok "minAvailable:0 honored, default maxUnavailable:1, policy/v1"; record "pdb-edge" "PASS" "minAvailable:0 + default maxUnavailable:1 + policy/v1"
else record "pdb-edge" "FAIL" "see log"; fi

# === 5. StatefulSet ServiceMonitor selects only the main Service ===
step "5. StatefulSet headless Service is excluded from the ServiceMonitor"
helm template t "${CHART}" --set workload.kind=StatefulSet --set serviceMonitor.enabled=true \
  >"${TMP_DIR}/stateful-servicemonitor.yaml" 2>"${TMP_DIR}/stateful-servicemonitor.err" \
  || die "StatefulSet + ServiceMonitor render failed: $(cat "${TMP_DIR}/stateful-servicemonitor.err")"
if python3 - "${TMP_DIR}/stateful-servicemonitor.yaml" <<'PY'
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1], encoding="utf-8")) if d]
services = [d for d in docs if d.get("kind") == "Service"]
assert len(services) == 2, [d["metadata"]["name"] for d in services]
headless = [d for d in services if d.get("spec", {}).get("clusterIP") == "None"]
main = [d for d in services if d.get("spec", {}).get("clusterIP") != "None"]
assert len(headless) == len(main) == 1
assert headless[0]["metadata"]["labels"]["app.kubernetes.io/component"] == "headless"
assert "app.kubernetes.io/component" not in main[0]["metadata"].get("labels", {})
monitors = [d for d in docs if d.get("kind") == "ServiceMonitor"]
assert len(monitors) == 1
expressions = monitors[0]["spec"]["selector"].get("matchExpressions", [])
assert {"key": "app.kubernetes.io/component", "operator": "NotIn", "values": ["headless"]} in expressions
PY
then
  ok "headless label + NotIn selector render together; main Service remains eligible"
  record "stateful-servicemonitor" "PASS" "headless labelled/excluded, main Service unlabelled"
else
  fail "StatefulSet ServiceMonitor would duplicate or lose scrape targets"
  record "stateful-servicemonitor" "FAIL" "rendered selector contract failed"
fi

# === 6. optional in-cluster admission (only if Prometheus-Operator CRD present) ===
step "6. in-cluster admission (optional)"
if kubectl get crd prometheusrules.monitoring.coreos.com >/dev/null 2>&1; then
  NS="phasea-$$"
  cleanup() { helm uninstall t -n "$NS" >/dev/null 2>&1 || true; kubectl delete ns "$NS" --wait=false >/dev/null 2>&1 || true; }
  trap cleanup EXIT
  kubectl create ns "$NS" >/dev/null 2>&1 || true
  # No --wait: the chart's appVersion image need not exist. We only assert admission of the
  # two opt-in objects, not that the daemon pod becomes Ready.
  if helm install t "${CHART}" -n "$NS" "${FLAGS[@]}" >/dev/null 2>"${TMP_DIR}/install-err.txt"; then
    sleep 3
    pr_ok=$(kubectl get prometheusrule -n "$NS" -o name 2>/dev/null | wc -l | tr -d ' ')
    pdb_ok2=$(kubectl get pdb -n "$NS" -o name 2>/dev/null | wc -l | tr -d ' ')
    if [ "$pr_ok" -ge 1 ] && [ "$pdb_ok2" -ge 1 ]; then
      ok "PrometheusRule + PDB admitted in ns/$NS"
      record "install-admission" "PASS" "PrometheusRule + PDB admitted"
    else
      fail "admission incomplete (pr=$pr_ok pdb=$pdb_ok2)"; record "install-admission" "FAIL" "pr=$pr_ok pdb=$pdb_ok2"
    fi
  else
    fail "helm install failed: $(cat "${TMP_DIR}/install-err.txt")"; record "install-admission" "FAIL" "helm install error"
  fi
else
  ok "no Prometheus-Operator CRD -> render+kubeconform+promtool suffice (as CI)"
  record "install-admission" "SKIP" "no monitoring.coreos.com/v1 CRD"
fi

step "Summary"
pass=0; failc=0; skip=0
{ echo "# ${SCENARIO}"; echo; } > "${REPORT}"
for i in "${!NAMES[@]}"; do
  printf "  %-20s %-5s %s\n" "${NAMES[$i]}" "${VERDICTS[$i]}" "${NOTES[$i]}"
  printf -- "- **%s**: %s — %s\n" "${NAMES[$i]}" "${VERDICTS[$i]}" "${NOTES[$i]}" >> "${REPORT}"
  case "${VERDICTS[$i]}" in PASS) pass=$((pass+1));; FAIL) failc=$((failc+1));; SKIP) skip=$((skip+1));; esac
done
echo "  --- ${pass} PASS / ${failc} FAIL / ${skip} SKIP ---"
[ "$failc" -eq 0 ] || exit 1
