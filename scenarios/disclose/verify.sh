#!/usr/bin/env bash
# Periodic-disclosure two-tier avoidable-waste scenario (v0.8.2+; follows the
# current binary and its report schema, perf-sentinel-report/v1.x).
#
# Locks the v0.8.2 headline feature: `disclose` aggregates the per-window
# `canonical_waste` (binary-pinned N+1 threshold 2, operator cannot configure)
# and `operational_waste` (operator's configured threshold) tiers from archived
# NDJSON, with the flat avoidable fields aliasing the canonical tier.
#
# Hermetic CLI scenario (same family as intent-validator / verify-hash-roundtrip):
# `docker run ...:${PERF_SENTINEL_VERSION} disclose` over committed fixtures, no
# cluster/daemon contact. The fixtures are real v0.8.2-daemon per-window archives
# (findings arrays trimmed for size; the tiers live in `disclosure_waste` +
# `green_summary`, not `findings`):
#   - reports-thr5.ndjson   operator threshold 5,  canonical 2
#   - reports-thr50.ndjson  operator threshold 50, canonical 2 (same workload;
#                           n+1 reclassified to redundant at the high threshold)
#
# 8 sub-tests run inside the perf-sentinel image under validation:
#
#   1. recognized schema + tiers: schema_version is perf-sentinel-report/v1.x,
#      canonical threshold == 2, operational threshold == 5, both tiers
#      energy/carbon > 0. (The tier structure is the contract; the schema string
#      is accepted across the v1.x family so a schema refresh doesn't false-fail.)
#   2. flat-field aliasing: estimated_optimization_potential_kgco2eq,
#      aggregate_waste_ratio, aggregate_efficiency_score alias the canonical tier.
#   3. official intent + verify-hash round-trip: `disclose --intent official`
#      passes the validator (exit 0) and `verify-hash` recomputes the
#      content_hash to OK (the disclose->verify round-trip fixed in v0.8.2 via
#      serde_json float_roundtrip. The gap verify-hash-roundtrip could not
#      close). A tampered copy must verify as FAIL.
#   4. anti-gaming invariant: over reports-thr50, canonical threshold stays 2
#      (UNCHANGED) while operational threshold is 50 and the canonical
#      waste_ratio strictly exceeds the operational one (the operator's high
#      threshold under-reports avoidable waste; the canonical headline is immune).
#   5. transport bracket: `transport_kgco2eq_low`/`_high` are published on an
#      archive every window of which declares the fixed coefficient, and
#      WITHHELD as soon as one window contributed transport without declaring
#      it, which is every window archived before 0.9.25.
#   6. canonical-disclosure migration: a mixed current/legacy period succeeds
#      with a counted warning. A 100% legacy official period remains refused.
#   7. attestation binding (0.28.0+): the in-toto subject is the canonical
#      content hash, so the attestation stays bound once the signature locator
#      is patched into report.json. Figures edited after signing and re-baked
#      with `hash-bake --allow-signed` fail the binding (UNTRUSTED, exit 1). An
#      attestation written by the published 0.27.0 binary, whose subject pinned
#      the pre-patch file bytes, is bound while the report is untouched and
#      unbindable once patched (PARTIAL, never TRUSTED).
#   8. archive reach (0.28.0+): official disclose refuses a period whose first
#      day precedes the oldest archived window (exit 2, no report), internal
#      warns. The official legs above use a period the fixtures do reach.
#
# Fixtures under fixtures/:
#   - reports-thr5.ndjson, reports-thr50.ndjson, org-config.toml
#     (org-config specpower_table_version tracks the pinned image's embedded CCF
#      vintage; bump it alongside PERF_SENTINEL_VERSION if the vintage changes.)

set -euo pipefail

SCENARIO="disclose"
REPORT="/tmp/scenario-${SCENARIO}-report.md"
TMP_DIR="/tmp/${SCENARIO}"
SCENARIO_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURES_DIR="${SCENARIO_DIR}/fixtures"

# The image under validation, resolved by scripts/resolve-image.sh:
# PERF_SENTINEL_IMAGE, then PERF_SENTINEL_VERSION, then the daemon manifest pin.
# It used to default to `latest`, which is the published release and therefore
# NOT the binary under validation during a pre-release round.
LAB_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../../scripts/resolve-image.sh
. "${LAB_ROOT}/scripts/resolve-image.sh"

mkdir -p "${TMP_DIR}"

color_blue()  { printf "\033[34m%s\033[0m\n" "$*"; }
color_green() { printf "\033[32m%s\033[0m\n" "$*"; }
color_red()   { printf "\033[31m%s\033[0m\n" "$*"; }
step() { color_blue "==> $*"; }
ok()   { color_green "    ok: $*"; }
fail() { color_red   "    fail: $*"; }
die()  { color_red   "    error: $*"; exit 1; }

PERIOD_ARGS=(--period-type calendar-quarter --from 2026-04-01 --to 2026-06-30)
# The fixtures' archive starts on 2026-06-05. From 0.28.0 an official
# disclosure refuses a period its archive does not reach back to (sub-test 8),
# so the official legs declare a custom period starting that day.
OFFICIAL_PERIOD_ARGS=(--period-type custom --from 2026-06-05 --to 2026-07-04)

step "0. Pre-flight"
command -v docker >/dev/null || die "docker not on PATH"
command -v python3 >/dev/null || die "python3 not on PATH"
for f in reports-thr5.ndjson reports-thr50.ndjson org-config.toml; do
  [ -f "${FIXTURES_DIR}/${f}" ] || die "fixture missing: ${f}"
done
docker image inspect "${IMAGE}" >/dev/null 2>&1 \
  || docker pull "${IMAGE}" >/dev/null 2>&1 \
  || die "cannot pull ${IMAGE}"
# Stage fixtures into TMP_DIR so docker mounts a single writable dir.
cp "${FIXTURES_DIR}/reports-thr5.ndjson"  "${TMP_DIR}/reports-thr5.ndjson"
cp "${FIXTURES_DIR}/reports-thr50.ndjson" "${TMP_DIR}/reports-thr50.ndjson"
cp "${FIXTURES_DIR}/org-config.toml"      "${TMP_DIR}/org-config.toml"
# Drop any output from a previous run so a stale file can never satisfy a
# later sub-test's `[ -f ... ]` guard if this run's disclose fails to write.
rm -f "${TMP_DIR}"/out-*.json
ok "fixtures + image OK (${IMAGE})"

# disclose is offline (no daemon contact); run as the host user so outputs are
# writable on the mounted dir.
in_image() {
  docker run --rm -u "$(id -u):$(id -g)" -v "${TMP_DIR}:/workdir" "${IMAGE}" "$@"
}

declare -a NAMES=() VERDICTS=() NOTES=()
record() { NAMES+=("$1"); VERDICTS+=("$2"); NOTES+=("$3"); }

# === Sub-test 1: recognized report schema + tiers (internal/internal over thr5) ===
step "1. recognized schema + two tiers (canonical==2, operational==5, tiers non-zero)"
if in_image disclose --intent internal --confidentiality internal "${PERIOD_ARGS[@]}" \
     --input /workdir/reports-thr5.ndjson --output /workdir/out-thr5.json \
     --org-config /workdir/org-config.toml >/dev/null 2>&1 \
   && note="$(python3 - "${TMP_DIR}/out-thr5.json" <<'PY'
import json, sys
a = json.load(open(sys.argv[1]))
ag = a["aggregate"]; cw = ag["canonical_waste"]; ow = ag["operational_waste"]
checks = {
    "recognized report schema": a["schema_version"].startswith("perf-sentinel-report/v1."),
    "canonical thr==2": cw["n_plus_one_threshold"] == 2,
    "operational thr==5": ow["n_plus_one_threshold"] == 5,
    "canonical energy>0": cw["energy_kwh"] > 0,
    "canonical carbon>0": cw["carbon_kgco2eq"] > 0,
    "operational energy>0": ow["energy_kwh"] > 0,
    "operational carbon>0": ow["carbon_kgco2eq"] > 0,
}
bad = [k for k, v in checks.items() if not v]
if bad:
    print("failed: " + ", ".join(bad)); sys.exit(1)
print("schema=%s canonical_thr=%d operational_thr=%d" % (
    a["schema_version"], cw["n_plus_one_threshold"], ow["n_plus_one_threshold"]))
PY
)"; then
  ok "${note}"; record "1. schema + tiers" PASS "${note}"
else
  fail "schema/tier assertion failed (${note:-disclose error})"
  record "1. schema + tiers" FAIL "${note:-disclose error}"
fi

# === Sub-test 2: flat-field aliasing of the canonical tier ===
step "2. flat avoidable fields alias canonical_waste"
note=""
if [ -f "${TMP_DIR}/out-thr5.json" ] \
   && note="$(python3 - "${TMP_DIR}/out-thr5.json" <<'PY'
import json, sys
ag = json.load(open(sys.argv[1]))["aggregate"]; cw = ag["canonical_waste"]
checks = {
    "estimated_optimization_potential_kgco2eq": ag["estimated_optimization_potential_kgco2eq"] == cw["carbon_kgco2eq"],
    "aggregate_waste_ratio": ag["aggregate_waste_ratio"] == cw["waste_ratio"],
    "aggregate_efficiency_score": ag["aggregate_efficiency_score"] == cw["efficiency_score"],
}
bad = [k for k, v in checks.items() if not v]
if bad:
    print("not aliased: " + ", ".join(bad)); sys.exit(1)
print("3/3 flat fields alias canonical_waste")
PY
)"; then
  ok "${note}"; record "2. flat-field aliasing" PASS "${note}"
else
  fail "aliasing assertion failed (${note:-no out-thr5.json})"
  record "2. flat-field aliasing" FAIL "${note:-no out-thr5.json}"
fi

step "3. official intent validates + verify-hash content_hash round-trips"
t3="FAIL"; t3note=""
if in_image disclose --intent official --confidentiality public "${OFFICIAL_PERIOD_ARGS[@]}" \
     --input /workdir/reports-thr5.ndjson --output /workdir/out-official.json \
     --org-config /workdir/org-config.toml >/dev/null 2>&1; then
  vh="$(in_image verify-hash --report /workdir/out-official.json --no-identity-check --format json 2>/dev/null || true)"
  ch_ok="$(printf '%s' "${vh}" | python3 -c "import sys,json; print(json.load(sys.stdin)['verifications']['content_hash']['status'])" 2>/dev/null || echo unknown)"
  # tamper: mutate a field on the host, verify-hash must report content_hash fail.
  # Mutate canonical_waste.carbon_kgco2eq (sub-test 1 already proves it exists),
  # so a schema rename cannot KeyError here; `|| true` keeps a tamper-write
  # failure from aborting the whole script under `set -e` (it degrades to a
  # FAIL verdict instead, via the ch_tampered check below).
  python3 - "${TMP_DIR}/out-official.json" "${TMP_DIR}/out-official-tampered.json" <<'PY' || true
import json, sys
r = json.load(open(sys.argv[1]))
r["aggregate"]["canonical_waste"]["carbon_kgco2eq"] += 1.0
json.dump(r, open(sys.argv[2], "w"), indent=2)
PY
  vh_t="$(in_image verify-hash --report /workdir/out-official-tampered.json --no-identity-check --format json 2>/dev/null || true)"
  ch_tampered="$(printf '%s' "${vh_t}" | python3 -c "import sys,json; print(json.load(sys.stdin)['verifications']['content_hash']['status'])" 2>/dev/null || echo unknown)"
  if [ "${ch_ok}" = "ok" ] && [ "${ch_tampered}" = "fail" ]; then
    t3="PASS"; t3note="content_hash ok on untampered, fail on tampered"
  else
    t3note="content_hash untampered=${ch_ok} (want ok), tampered=${ch_tampered} (want fail)"
  fi
else
  t3note="official disclose did not exit 0 (validator rejected)"
fi
if [ "${t3}" = "PASS" ]; then ok "${t3note}"; else fail "${t3note}"; fi
record "3. official + verify-hash" "${t3}" "${t3note}"

# === Sub-test 4: anti-gaming invariant (over thr50) ===
step "4. anti-gaming: canonical pinned at 2 while operational(50) under-reports"
note=""
if in_image disclose --intent internal --confidentiality internal "${PERIOD_ARGS[@]}" \
     --input /workdir/reports-thr50.ndjson --output /workdir/out-thr50.json \
     --org-config /workdir/org-config.toml >/dev/null 2>&1 \
   && note="$(python3 - "${TMP_DIR}/out-thr50.json" <<'PY'
import json, sys
ag = json.load(open(sys.argv[1]))["aggregate"]; cw = ag["canonical_waste"]; ow = ag["operational_waste"]
checks = {
    "canonical thr==2 (unchanged)": cw["n_plus_one_threshold"] == 2,
    "operational thr==50": ow["n_plus_one_threshold"] == 50,
    "canonical.waste_ratio > operational.waste_ratio": cw["waste_ratio"] > ow["waste_ratio"],
}
bad = [k for k, v in checks.items() if not v]
if bad:
    print("failed: " + ", ".join(bad)); sys.exit(1)
print("canonical thr=2 wr=%.4f > operational thr=50 wr=%.4f" % (cw["waste_ratio"], ow["waste_ratio"]))
PY
)"; then
  ok "${note}"; record "4. anti-gaming invariant" PASS "${note}"
else
  fail "anti-gaming assertion failed (${note:-disclose error})"
  record "4. anti-gaming invariant" FAIL "${note:-disclose error}"
fi

# === Sub-test 5: the transport bracket only frames the fixed coefficient ===
# 0.9.25 publishes `transport_kgco2eq` on every run, plus a sourced
# 0.001-0.059 kWh/GB bracket around it. That bracket frames the FIXED
# coefficient only, so it must be withheld whenever a window that contributed
# transport was scored under something else, including under a coefficient the
# reader cannot see, which is every window archived before 0.9.25.
#
# The first shipped guard could never fire: it looked for a coefficient entry in
# the aggregated coefficients, and no released version ever wrote one. An
# archive from 0.9.23 with a custom coefficient therefore published a bracket
# computed around 0.04 kWh/GB, under a signed content_hash. This leg is the
# regression test for that, and it is deliberately counter-intuitive: the
# mid value present with both bounds absent is the CORRECT outcome.
step "5. transport bracket: published on a pure archive, withheld on a mixed one"
cp "${FIXTURES_DIR}/transport-traces.json" "${TMP_DIR}/transport-traces.json"
cp "${FIXTURES_DIR}/green-transport.toml"  "${TMP_DIR}/green-transport.toml"
note=""
if in_image analyze --config /workdir/green-transport.toml \
     --input /workdir/transport-traces.json --format json \
     > "${TMP_DIR}/transport-window.json" 2>/dev/null \
   && python3 - "${TMP_DIR}" <<'PY'
import copy, json, pathlib, sys

tmp = pathlib.Path(sys.argv[1])
report = json.loads((tmp / "transport-window.json").read_text())
# Mid-quarter, so the window lands inside PERIOD_ARGS.
window = {"ts": "2026-05-15T10:00:00Z", "report": report}
(tmp / "transport-pure.ndjson").write_text(json.dumps(window) + "\n")

# A pre-0.9.25 window is exactly this one minus the declared coefficient: the
# field was born in that cycle, so an older archive carries no trace of what
# scaled its transport term.
old = copy.deepcopy(window)
cfg = old["report"]["green_summary"].get("scoring_config")
if cfg is None:
    raise SystemExit(
        "this binary does not stamp green_summary.scoring_config, "
        "so the pre-0.9.25 window cannot be derived"
    )
cfg.pop("network_energy_per_byte_kwh", None)
(tmp / "transport-mixed.ndjson").write_text(
    json.dumps(old) + "\n" + json.dumps(window) + "\n"
)
PY
then
  for variant in pure mixed; do
    in_image disclose --intent internal --confidentiality internal "${PERIOD_ARGS[@]}" \
      --input "/workdir/transport-${variant}.ndjson" --output "/workdir/out-transport-${variant}.json" \
      --org-config /workdir/org-config.toml >/dev/null 2>&1 || true
  done
  note="$(python3 - "${TMP_DIR}" <<'PY'
import json, pathlib, sys

tmp = pathlib.Path(sys.argv[1])
def breakdown(name):
    p = tmp / f"out-transport-{name}.json"
    if not p.is_file():
        return None
    return json.loads(p.read_text())["aggregate"].get("carbon_breakdown") or {}

pure, mixed = breakdown("pure"), breakdown("mixed")
if pure is None or mixed is None:
    print("disclose produced no report for one of the two variants"); sys.exit(1)
checks = {
    "pure: transport term present":  pure.get("transport_kgco2eq", 0) > 0,
    "pure: low bound published":     "transport_kgco2eq_low" in pure,
    "pure: high bound published":    "transport_kgco2eq_high" in pure,
    "mixed: transport term present": mixed.get("transport_kgco2eq", 0) > 0,
    "mixed: low bound WITHHELD":     "transport_kgco2eq_low" not in mixed,
    "mixed: high bound WITHHELD":    "transport_kgco2eq_high" not in mixed,
}
bad = [k for k, v in checks.items() if not v]
if bad:
    print("failed: " + ", ".join(bad)); sys.exit(1)
print("pure %.3e [%.3e, %.3e]; mixed %.3e with no bracket" % (
    pure["transport_kgco2eq"], pure["transport_kgco2eq_low"],
    pure["transport_kgco2eq_high"], mixed["transport_kgco2eq"]))
PY
)"
fi
if [ -n "${note}" ] && [[ "${note}" != failed:* ]] && [[ "${note}" != disclose* ]]; then
  ok "${note}"; record "5. transport bracket per window" PASS "${note}"
else
  fail "transport bracket assertion failed (${note:-analyze/disclose error})"
  record "5. transport bracket per window" FAIL "${note:-analyze/disclose error}"
fi

# === Sub-test 6: canonical disclosure migration boundary ===
step "6. mixed legacy/current period warns; all-legacy official period fails"
python3 - "${TMP_DIR}/reports-thr5.ndjson" "${TMP_DIR}" <<'PY'
import json, pathlib, sys

rows = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines() if line.strip()][:2]
legacy = json.loads(json.dumps(rows[0]))
legacy["report"].pop("disclosure_waste", None)
out = pathlib.Path(sys.argv[2])
(out / "canonical-mixed.ndjson").write_text("\n".join(map(json.dumps, [legacy, rows[1]])) + "\n")
old = []
for row in rows:
    row = json.loads(json.dumps(row))
    row["report"].pop("disclosure_waste", None)
    old.append(row)
(out / "canonical-old.ndjson").write_text("\n".join(map(json.dumps, old)) + "\n")
PY
rm -f "${TMP_DIR}/out-canonical-mixed.json" "${TMP_DIR}/out-canonical-old.json"
in_image disclose --intent official --confidentiality public "${OFFICIAL_PERIOD_ARGS[@]}" \
  --input /workdir/canonical-mixed.ndjson --output /workdir/out-canonical-mixed.json \
  --org-config /workdir/org-config.toml > "${TMP_DIR}/canonical-mixed.out" 2> "${TMP_DIR}/canonical-mixed.err" \
  && MIXED_RC=0 || MIXED_RC=$?
in_image disclose --intent official --confidentiality public "${OFFICIAL_PERIOD_ARGS[@]}" \
  --input /workdir/canonical-old.ndjson --output /workdir/out-canonical-old.json \
  --org-config /workdir/org-config.toml > "${TMP_DIR}/canonical-old.out" 2> "${TMP_DIR}/canonical-old.err" \
  && OLD_RC=0 || OLD_RC=$?
MIXED_WARNING_COUNT="$(grep -c '1 of 2 windows carry no canonical waste figure' "${TMP_DIR}/canonical-mixed.err" || true)"
OLD_BYTES=0
[ ! -f "${TMP_DIR}/out-canonical-old.json" ] || OLD_BYTES="$(wc -c < "${TMP_DIR}/out-canonical-old.json")"
if [ "${MIXED_RC}" = "0" ] && [ "${MIXED_WARNING_COUNT}" = "1" ] \
   && [ -s "${TMP_DIR}/out-canonical-mixed.json" ] \
   && [ "${OLD_RC}" != "0" ] && [ ! -s "${TMP_DIR}/out-canonical-old.json" ] \
   && grep -q 'canonical_waste' "${TMP_DIR}/canonical-old.err"; then
  note="mixed warning=1 of 2; all-legacy official exit=${OLD_RC} with no report"
  ok "${note}"; record "6. canonical migration boundary" PASS "${note}"
else
  note="mixed rc=${MIXED_RC}/warnings=${MIXED_WARNING_COUNT}; all-legacy rc=${OLD_RC}/bytes=${OLD_BYTES}"
  fail "${note}"; record "6. canonical migration boundary" FAIL "${note}"
fi

# === Sub-test 7: the signed attestation names the figures it vouches for ===
# Until 0.27.0 the in-toto subject was the SHA-256 of report.json's bytes at
# disclose time, the documented signing flow then patched integrity.signature
# into report.json, and verify-hash never compared the two, so a valid
# signature tied to nothing in the published figures. No bundle is signed here
# (no Sigstore identity in the lab): the binding check is pure Rust and runs
# whenever an attestation is passed, which is what these legs assert.
step "7. attestation binding: survives the locator patch, refuses re-baked figures, flags a 0.27.0 statement"

# What step 3 of the signing flow does to report.json.
patch_signature() {
  python3 - "$1" "$2" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
r["integrity"]["signature"] = {
    "format": "sigstore-cosign-intoto-v1",
    "bundle_url": "https://example.fr/bundle.sig",
    "signer_identity": "https://github.com/example/infra/.github/workflows/disclose.yml@refs/tags/2026-q2",
    "signer_issuer": "https://token.actions.githubusercontent.com",
    "rekor_url": "https://rekor.sigstore.dev",
    "rekor_log_index": 1,
    "signed_at": "2026-07-02T10:00:00Z",
}
r["report_metadata"]["integrity_level"] = "signed"
json.dump(r, open(sys.argv[2], "w"), indent=2)
PY
}

# status <verify-hash json file> <check>: ok, fail, skip, not_provided or the overall label.
status() {
  python3 - "$1" "$2" <<'PY' 2>/dev/null || echo unknown
import json, sys
v = json.load(open(sys.argv[1]))
print(v["overall"] if sys.argv[2] == "overall" else v["verifications"][sys.argv[2]]["status"])
PY
}

verify_with() {  # <report> <attestation> <out json>: exit code on stdout
  local rc
  in_image verify-hash --report "/workdir/$1" --attestation "/workdir/$2" \
    --no-identity-check --format json > "${TMP_DIR}/$3" 2>/dev/null && rc=0 || rc=$?
  echo "${rc}"
}

rm -f "${TMP_DIR}"/att-*.intoto.jsonl "${TMP_DIR}"/out-att*.json "${TMP_DIR}"/out-legacy*.json "${TMP_DIR}"/vh7-*.json

# 7a. bound, and still bound after the patch
t7a="FAIL"; t7anote="official disclose with --emit-attestation did not exit 0"
if in_image disclose --intent official --confidentiality public "${OFFICIAL_PERIOD_ARGS[@]}" \
     --input /workdir/reports-thr5.ndjson --output /workdir/out-att.json \
     --org-config /workdir/org-config.toml --emit-attestation /workdir/att-current.intoto.jsonl >/dev/null 2>&1; then
  shape="$(python3 - "${TMP_DIR}/out-att.json" "${TMP_DIR}/att-current.intoto.jsonl" <<'PY' || true
import json, sys
report = json.load(open(sys.argv[1]))
statement = json.loads(open(sys.argv[2]).read().strip())
subject = statement["subject"][0]["digest"]["sha256"]
want = report["integrity"]["content_hash"].removeprefix("sha256:")
binding = statement["predicate"].get("subject_binding")
print("ok" if subject == want and binding == "content_hash" else f"subject={subject[:12]} want={want[:12]} binding={binding}")
PY
)"
  patch_signature "${TMP_DIR}/out-att.json" "${TMP_DIR}/out-att-patched.json"
  rc="$(verify_with out-att-patched.json att-current.intoto.jsonl vh7-a.json)"
  ch="$(status "${TMP_DIR}/vh7-a.json" content_hash)"; ab="$(status "${TMP_DIR}/vh7-a.json" attestation_binding)"
  if [ "${shape}" = "ok" ] && [ "${ch}" = "ok" ] && [ "${ab}" = "ok" ] && [ "${rc}" = "2" ]; then
    t7a="PASS"; t7anote="subject == content_hash, subject_binding declared; patched report: content_hash ok, binding ok, exit 2 (no bundle)"
  else
    t7anote="shape=${shape}, patched content_hash=${ch}, binding=${ab}, exit=${rc} (want ok/ok/ok/2)"
  fi
fi
if [ "${t7a}" = "PASS" ]; then ok "${t7anote}"; else fail "${t7anote}"; fi
record "7a. binding survives the patch" "${t7a}" "${t7anote}"

# 7b. figures edited after signing, hash re-baked
t7b="FAIL"; t7bnote="no patched report from 7a"
if [ -f "${TMP_DIR}/out-att-patched.json" ]; then
  python3 - "${TMP_DIR}/out-att-patched.json" "${TMP_DIR}/out-att-edited.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
r["aggregate"]["total_carbon_kgco2eq"] /= 2
json.dump(r, open(sys.argv[2], "w"), indent=2)
PY
  if in_image hash-bake --report /workdir/out-att-edited.json --output /workdir/out-att-rebaked.json --allow-signed >/dev/null 2>&1; then
    rc="$(verify_with out-att-rebaked.json att-current.intoto.jsonl vh7-b.json)"
    ch="$(status "${TMP_DIR}/vh7-b.json" content_hash)"; ab="$(status "${TMP_DIR}/vh7-b.json" attestation_binding)"
    overall="$(status "${TMP_DIR}/vh7-b.json" overall)"
    if [ "${ch}" = "ok" ] && [ "${ab}" = "fail" ] && [ "${overall}" = "UNTRUSTED" ] && [ "${rc}" = "1" ]; then
      t7b="PASS"; t7bnote="re-baked hash ok, binding fail, UNTRUSTED, exit 1"
    else
      t7bnote="content_hash=${ch}, binding=${ab}, overall=${overall}, exit=${rc} (want ok/fail/UNTRUSTED/1)"
    fi
  else
    t7bnote="hash-bake --allow-signed did not exit 0"
  fi
fi
if [ "${t7b}" = "PASS" ]; then ok "${t7bnote}"; else fail "${t7bnote}"; fi
record "7b. re-baked figures refused" "${t7b}" "${t7bnote}"

# 7c. a statement from the published 0.27.0 binary. Pinned on purpose: it is
# the last release whose subject is the file bytes, the compatibility leg
# resolve-image.sh tells a scenario to name at its call site.
LEGACY_IMAGE="ghcr.io/institut-du-numerique-responsable/perf-sentinel:0.27.0"
t7c="FAIL"; t7cnote="cannot pull ${LEGACY_IMAGE}"
if docker image inspect "${LEGACY_IMAGE}" >/dev/null 2>&1 || docker pull "${LEGACY_IMAGE}" >/dev/null 2>&1; then
  t7cnote="0.27.0 disclose with --emit-attestation did not exit 0"
  if docker run --rm -u "$(id -u):$(id -g)" -v "${TMP_DIR}:/workdir" "${LEGACY_IMAGE}" \
       disclose --intent official --confidentiality public "${OFFICIAL_PERIOD_ARGS[@]}" \
       --input /workdir/reports-thr5.ndjson --output /workdir/out-legacy.json \
       --org-config /workdir/org-config.toml --emit-attestation /workdir/att-legacy.intoto.jsonl >/dev/null 2>&1; then
    old_shape="$(python3 -c "import json,sys; s=json.loads(open(sys.argv[1]).read().strip()); print('legacy' if 'subject_binding' not in s['predicate'] else 'new')" "${TMP_DIR}/att-legacy.intoto.jsonl" 2>/dev/null || echo unknown)"
    rc_u="$(verify_with out-legacy.json att-legacy.intoto.jsonl vh7-c-untouched.json)"
    ab_u="$(status "${TMP_DIR}/vh7-c-untouched.json" attestation_binding)"
    patch_signature "${TMP_DIR}/out-legacy.json" "${TMP_DIR}/out-legacy-patched.json"
    rc_p="$(verify_with out-legacy-patched.json att-legacy.intoto.jsonl vh7-c-patched.json)"
    ab_p="$(status "${TMP_DIR}/vh7-c-patched.json" attestation_binding)"
    overall_p="$(status "${TMP_DIR}/vh7-c-patched.json" overall)"
    if [ "${old_shape}" = "legacy" ] && [ "${ab_u}" = "ok" ] && [ "${ab_p}" = "skip" ] \
       && [ "${overall_p}" = "PARTIAL" ] && [ "${rc_p}" = "2" ]; then
      t7c="PASS"; t7cnote="0.27.0 statement: bound on untouched bytes (exit ${rc_u}), unbindable once patched, PARTIAL, exit 2"
    else
      t7cnote="shape=${old_shape}, untouched binding=${ab_u}, patched binding=${ab_p}, overall=${overall_p}, exit=${rc_p} (want legacy/ok/skip/PARTIAL/2)"
    fi
  fi
fi
if [ "${t7c}" = "PASS" ]; then ok "${t7cnote}"; else fail "${t7cnote}"; fi
record "7c. 0.27.0 statement flagged" "${t7c}" "${t7cnote}"

# === Sub-test 8: an official period the archive does not reach is refused ===
# Rotation prunes the archive by file count and the hash chain restarts with
# each file, so a busy daemon can lose a quarter's first weeks without a trace.
# From 0.28.0 official disclose refuses a period whose first day precedes the
# oldest archived window, and internal disclose warns. The fixtures start on
# 2026-06-05, well inside the declared quarter.
step "8. official refuses a quarter the archive does not reach back to"
rm -f "${TMP_DIR}/out-gap-official.json" "${TMP_DIR}/out-gap-internal.json"
in_image disclose --intent official --confidentiality public "${PERIOD_ARGS[@]}" \
  --input /workdir/reports-thr5.ndjson --output /workdir/out-gap-official.json \
  --org-config /workdir/org-config.toml > /dev/null 2> "${TMP_DIR}/gap-official.err" \
  && GAP_OFFICIAL_RC=0 || GAP_OFFICIAL_RC=$?
in_image disclose --intent internal --confidentiality internal "${PERIOD_ARGS[@]}" \
  --input /workdir/reports-thr5.ndjson --output /workdir/out-gap-internal.json \
  --org-config /workdir/org-config.toml > /dev/null 2> "${TMP_DIR}/gap-internal.err" \
  && GAP_INTERNAL_RC=0 || GAP_INTERNAL_RC=$?
GAP_MESSAGE="the archive starts on 2026-06-05, after the period's first day 2026-04-01"
if [ "${GAP_OFFICIAL_RC}" = "2" ] && [ ! -e "${TMP_DIR}/out-gap-official.json" ] \
   && grep -q "Error: ${GAP_MESSAGE}" "${TMP_DIR}/gap-official.err" \
   && [ "${GAP_INTERNAL_RC}" = "0" ] && [ -s "${TMP_DIR}/out-gap-internal.json" ] \
   && grep -q "Warning: ${GAP_MESSAGE}" "${TMP_DIR}/gap-internal.err"; then
  note="official exit 2 with no report, internal exit 0 with the warning"
  ok "${note}"; record "8. archive must reach the period start" PASS "${note}"
else
  note="official rc=${GAP_OFFICIAL_RC}, internal rc=${GAP_INTERNAL_RC}, see ${TMP_DIR}/gap-*.err"
  fail "${note}"; record "8. archive must reach the period start" FAIL "${note}"
fi

# === Aggregate verdict + report ===
overall="PASS"
for v in "${VERDICTS[@]}"; do [ "${v}" = "FAIL" ] && overall="FAIL"; done
{
  echo "# Scenario: ${SCENARIO}"
  echo
  echo "Image: ${IMAGE}"
  echo "Fixtures: scenarios/${SCENARIO}/fixtures/ (real v0.8.2-daemon archives, findings trimmed)"
  echo
  echo "| # | Name | Verdict | Note |"
  echo "| --- | --- | --- | --- |"
  for i in "${!NAMES[@]}"; do
    echo "| $((i+1)) | ${NAMES[$i]} | ${VERDICTS[$i]} | ${NOTES[$i]} |"
  done
  echo
  echo "## Verdict: ${overall}"
} > "${REPORT}"

if [ "${overall}" = "PASS" ]; then
  ok "PASS ${#VERDICTS[@]}/${#VERDICTS[@]}, see ${REPORT}"; exit 0
else
  fail "see ${REPORT}"; exit 1
fi
