# perf-sentinel simulation lab Makefile.
# Run `make help` to list targets.

CLUSTER_NAME := perf-sentinel-lab
DAEMON_URL   := http://localhost:14318
GRAFANA_URL  := http://localhost:3000
PERF_SENTINEL_REPO_PATH ?= $(HOME)/RustroverProjects/perf-sentinel
PERF_SENTINEL_LOCAL_BIN ?= $(PERF_SENTINEL_REPO_PATH)/target/release/perf-sentinel

.DEFAULT_GOAL := help

.PHONY: help up down reset recover validate smoke status logs grafana inspect psql ps clean-images \
        seed-services teardown-services inject-all validate-findings \
        seed-quarkus-svc seed-mutiny-svc seed-helidon-mp-svc seed-helidon-se-svc seed-ktor-svc seed-dotnet-svc seed-go-svc seed-nest-svc seed-django-svc seed-fastapi-svc seed-diesel-svc seed-seaorm-svc seed-rails-svc seed-laravel-svc seed-symfony-svc \
        seed-electricity-maps verify-electricity-maps capture-greenops-screenshot redeploy-services \
        up-gitlab down-gitlab seed-gitlab-project verify-gitlab-perf-sentinel \
        up-cni reset-cni install-cni apply-network-policies remove-network-policies \
        hubble-ui verify-network-policies \
        verify-hybrid-daemon-batch verify-batch-tempo-scrape verify-batch-victoria-scrape \
		verify-daemon-otlp-direct \
        verify-multiformat-input verify-calibrate-mode verify-sidecar-pattern \
        verify-correlation-finding verify-grouping-identity verify-pg-stat verify-grafana-dashboard \
        verify-ci-shift-left verify-output-formats-coverage verify-disclose verify-disclose-temporal \
        verify-verify-hash-roundtrip verify-intent-validator verify-daemon-analysis-shedding \
        verify-template-gitlab-ci verify-template-jenkinsfile verify-template-github-actions \
        verify-multi-agent-load verify-long-running-drift \
        verify-failure-mode-daemon-restart verify-failure-mode-backend-down \
        verify-failure-mode-network-partition verify-cold-start-edge-cases \
        verify-daemon-sigterm-drain verify-daemon-ack-workflow \
        seed-scaphandre-mock verify-scaphandre-mock-validation \
        seed-kepler-mock seed-redfish-mock verify-measured-energy-chain \
        seed-kepler-exporter \
        seed-tracegen seed-daemon-local \
        verify-limit-batch-volume verify-limit-trace-shapes verify-limit-service-cardinality \
        verify-limit-saturation-curve verify-limit-multi-source verify-limit-prod-window-soak \
        verify-sql-backtick-redaction verify-non-sql-datastore-drop verify-non-sql-datastore-metering \
        verify-ruby-activerecord-suggestion verify-datadog-bridge \
        verify-batch-otlp-file verify-mysql-stat \
        verify-astronomy-shop capture-astronomy-shop \
        verify-sampling-degradation verify-semconv-drift \
        verify-prod-topology-replay fetch-prod-topology \
        verify-rpc-carrier-parity \
        verify-chaos-replay capture-chaos-replay \
        verify-alumet-conformance \
        verify-alumet-db-waste \
        verify-appsec-hardening \
        verify-endpoint-resolution verify-consumer-endpoint \
        verify-broker-messaging-waste \
        verify-chart-disclose-persistence \
        verify-java-ci-capture \
        verify-java-ci-file-export \
        verify-micrometer-http-client \
        verify-hibernate-alias-suggestion verify-ack-store-fsgroup-root verify-outbound-proxy-private-ca \
        verify-ci-e2e-jenkins verify-ci-e2e-github verify-ci-e2e-gitlab \
        verify-archive-integrity-chain verify-archive-window-drops verify-config-fragments \
        verify-incident-window-capture verify-incident-namespace-scope \
        verify-incident-alerting-chain \
        verify-disclose-archive-family-baseline verify-diff-mutated-findings \
        seed-hub-local verify-hub-ingestion verify-hub-incidents-mirror \
        verify-hub-source-reachability \
        verify-hub-derived-status verify-hub-lineage-mutation \
        verify-hub-retention-purge verify-hub-plugin-contract \
        verify-hub-access-control \
        verify-otlp-compression-matrix verify-ack-lifecycle-warning \
        verify-export-snapshot-scope verify-grouping-metrics-split \
        verify-findings-page-filters \
        verify-correlation-event-time verify-slow-window-cross-batch \
        verify-all-scenarios

help: ## List available targets
	@awk 'BEGIN {FS = ":.*##"; printf "Targets:\n"} /^[a-zA-Z0-9_-]+:.*?##/ { printf "  %-32s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

up: ## Bootstrap the cluster (redirects to up-cni since the CNI migration)
	@echo "Note: 'make up' is deprecated since the Cilium CNI migration."
	@echo "      The k3d config disables Flannel and the default network"
	@echo "      policy controller, so plain bootstrap.sh produces NotReady"
	@echo "      nodes. Redirecting to 'make up-cni' which installs Cilium"
	@echo "      first, then runs bootstrap.sh, then applies the zero-trust"
	@echo "      NetworkPolicy."
	@echo
	@$(MAKE) up-cni

down: ## Tear down the cluster
	./scripts/teardown.sh

reset: down up ## Teardown then bootstrap

recover: ## Bounce Cilium worker agents and not-Ready shop pods after k3d cluster start
	@echo "==> bouncing Cilium agents on worker nodes (DNS recovery after k3d cluster start)"
	@victims=$$(for node in $$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[*].metadata.name}'); do \
	  kubectl get pod -n kube-system -l k8s-app=cilium --field-selector=spec.nodeName=$$node -o jsonpath='{.items[0].metadata.name} ' 2>/dev/null; \
	done); \
	if [ -n "$$(echo $$victims | tr -d ' ')" ]; then echo "  delete:$$victims"; kubectl delete pod -n kube-system $$victims --grace-period=5; fi
	@kubectl rollout status ds/cilium -n kube-system --timeout=120s
	@echo "==> bouncing not-Ready shop pods (escape CrashLoopBackOff faster)"
	@stale=$$(kubectl get pod -n shop --no-headers 2>/dev/null | awk '$$3 != "Running" || $$2 != "1/1" {print $$1}'); \
	if [ -n "$$stale" ]; then echo "  delete: $$stale" | tr '\n' ' '; echo; echo "$$stale" | xargs kubectl delete pod -n shop --grace-period=5; else echo "  no stale shop pods"; fi
	@kubectl wait --for=condition=Ready pod --all -n shop --timeout=180s
	@echo "==> recovery complete"

validate: ## Validate manifests, helm values, dashboards, scripts (no cluster)
	@echo "==> yaml parse on manifests and values"
	@python3 -c "import yaml,sys; [list(yaml.safe_load_all(open(f))) for f in sys.argv[1:]]" \
	  manifests/namespaces.yaml \
	  manifests/postgres.yaml \
	  manifests/postgres-init-schemas.yaml \
	  manifests/messaging-rabbitmq.yaml \
	  manifests/tempo.yaml \
	  manifests/victoria-traces.yaml \
	  manifests/perf-sentinel-daemon.yaml \
	  manifests/perf-sentinel-hub.yaml \
	  manifests/scaphandre-mock.yaml \
	  cluster/k3d-config.yaml \
	  helm/values/kube-prometheus-stack.yaml \
	  helm/values/otel-collector.yaml
	@echo "==> messaging manifest keeps its image variants and port wiring"
	@python3 -c 'import yaml; docs=list(yaml.safe_load_all(open("manifests/messaging-rabbitmq.yaml"))); deployments={d["metadata"]["name"]: d for d in docs if d and d.get("kind") == "Deployment"}; services={d["metadata"]["name"]: d for d in docs if d and d.get("kind") == "Service"}; rmq=deployments["rabbitmq"]["spec"]["template"]["spec"]["containers"][0]["image"]; tox=deployments["toxiproxy"]["spec"]["template"]["spec"]["containers"][0]["image"]; assert rmq.startswith("rabbitmq:") and rmq.endswith("-management-alpine"), "rabbitmq image must stay a rabbitmq:*-management-alpine tag, Renovate owns the version: "+rmq; assert tox.startswith("ghcr.io/shopify/toxiproxy:"), "toxiproxy image must stay a ghcr.io/shopify/toxiproxy tag, Renovate owns the version: "+tox; assert 5672 in {p["port"] for p in services["rabbitmq"]["spec"]["ports"]}, "rabbitmq Service lost the AMQP port 5672"; assert 25672 in {p["port"] for p in services["toxiproxy"]["spec"]["ports"]}, "toxiproxy Service lost the proxied AMQP port 25672"'
	@echo "==> committed manifests keep the published pins (no seed-*-local.sh leak)"
	@python3 -c 'import re; srcs={"daemon":open("manifests/perf-sentinel-daemon.yaml").read(),"hub":open("manifests/perf-sentinel-hub.yaml").read()}; bad=[k+": image is not a ghcr.io/institut-du-numerique-responsable pin" for k,s in srcs.items() if not re.search(r"image: ghcr\.io/institut-du-numerique-responsable/perf-sentinel(-hub)?[@:]",s)]+[k+": imagePullPolicy Never" for k,s in srcs.items() if "imagePullPolicy: Never" in s]+["daemon: [daemon.hub_export] enabled = true, the Secret only exists after seed-hub-local.sh" for _ in [0] if re.search(r"\[daemon\.hub_export\]\s*\n\s*enabled = true",srcs["daemon"])]; assert not bad, "local seed-*-local.sh working-tree edits leaked into the committed manifests: "+"; ".join(bad)'
	@echo "==> helm template kube-prometheus-stack"
	@helm template lab-kps prometheus-community/kube-prometheus-stack \
	  --version "$$(awk -F'"' '/^KPS_CHART_VERSION=/{print $$2}' scripts/bootstrap.sh)" \
	  -f helm/values/kube-prometheus-stack.yaml >/dev/null
	@echo "==> helm template otel-collector"
	@helm template lab-otel open-telemetry/opentelemetry-collector \
	  --version "$$(awk -F'"' '/^OTEL_CHART_VERSION=/{print $$2}' scripts/bootstrap.sh)" \
	  -f helm/values/otel-collector.yaml >/dev/null
	@echo "==> json parse on dashboards"
	@python3 -m json.tool < manifests/grafana-dashboards/perf-sentinel-overview.json >/dev/null
	@python3 -m json.tool < manifests/grafana-dashboards/kubernetes-cluster.json >/dev/null
	@python3 -m json.tool < manifests/grafana-dashboards/perf-sentinel-findings.json >/dev/null
	@echo "==> shell syntax check"
	@bash -n scripts/bootstrap.sh
	@bash -n scripts/teardown.sh
	@bash -n scripts/wait-for-ready.sh
	@bash -n scripts/port-forward.sh
	@bash -n scripts/seed-electricity-maps.sh
	@bash -n scripts/seed-services.sh
	@bash -n scripts/k3d-image.sh
	@bash -n scripts/verify-electricity-maps.sh
	@bash -n scripts/capture-greenops-screenshot.sh
	@bash -n scripts/redeploy-services.sh
	@bash -n scripts/test-validate-findings-freshness.sh
	@bash -n scripts/test-k3d-image.sh
	@bash -n scripts/run-multistack-scenario.sh
	@bash -n scripts/verify-messaging-negative-contract.sh
	@bash -n scripts/test-verify-messaging-negative-contract.sh
	@bash -n scripts/seed-ktor-svc.sh
	@./scripts/test-validate-findings-freshness.sh
	@./scripts/test-k3d-image.sh
	@bash scripts/test-verify-messaging-negative-contract.sh
	@bash -n scripts/capture-trace-fixture.sh
	@bash -n scripts/up-gitlab.sh
	@bash -n scripts/down-gitlab.sh
	@bash -n scripts/seed-gitlab-project.sh
	@bash -n scripts/verify-gitlab-perf-sentinel.sh
	@bash -n scripts/install-cni.sh
	@bash -n scripts/up-cni.sh
	@bash -n scripts/hubble-ui.sh
	@bash -n scenarios/batch-victoria-scrape/verify.sh
	@bash -n scenarios/hub-ingestion/verify.sh
	@bash -n scenarios/hub-incidents-mirror/verify.sh
	@bash -n scenarios/hub-source-reachability/verify.sh
	@bash -n scenarios/hub-derived-status/verify.sh
	@bash -n scenarios/hub-lineage-mutation/verify.sh
	@bash -n scenarios/hub-retention-purge/verify.sh
	@bash -n scenarios/hub-plugin-contract/verify.sh
	@bash -n scenarios/hub-access-control/verify.sh
	@bash -n scripts/verify-network-policies.sh
	@bash -n scripts/record-validation.sh
	@bash -n release-gate/check-lab-validation.sh
	@bash -n scenarios/intent-validator/verify.sh
	@bash -n scenarios/disclose/verify.sh
	@bash -n scenarios/disclose-temporal/verify.sh
	@bash -n scenarios/hybrid-daemon-batch/verify.sh
	@bash -n scenarios/batch-tempo-scrape/verify.sh
	@bash -n scenarios/daemon-otlp-direct/verify.sh
	@bash -n scenarios/multiformat-input/verify.sh
	@bash -n scenarios/calibrate-mode/verify.sh
	@bash -n scenarios/sidecar-pattern/verify.sh
	@bash -n scenarios/correlation-finding/verify.sh
	@bash -n scenarios/grouping-identity/verify.sh
	@bash -n scenarios/incident-window-capture/verify.sh
	@bash -n scenarios/incident-namespace-scope/verify.sh
	@bash -n scenarios/incident-alerting-chain/verify.sh
	@bash -n scenarios/grouping-metrics-split/verify.sh
	@bash -n scenarios/findings-page-filters/verify.sh
	@bash -n scenarios/correlation-event-time/verify.sh
	@bash -n scenarios/slow-window-cross-batch/verify.sh
	@python3 -m py_compile tools/tracegen/emit_at.py
	@bash -n scenarios/ci-e2e-common/browser-check.sh
	@bash -n scenarios/pg-stat/verify.sh
	@bash -n scenarios/grafana-dashboard/verify.sh
	@bash -n scenarios/consumer-endpoint/verify.sh
	@bash -n scenarios/multi-agent-load/verify.sh
	@bash -n scenarios/long-running-drift/verify.sh
	@bash -n scenarios/failure-mode-daemon-restart/verify.sh
	@bash -n scenarios/failure-mode-backend-down/verify.sh
	@bash -n scenarios/failure-mode-network-partition/verify.sh
	@bash -n scenarios/cold-start-edge-cases/verify.sh
	@bash -n scenarios/daemon-sigterm-drain/verify.sh
	@bash -n scenarios/daemon-ack-workflow/verify.sh
	@bash -n scenarios/scaphandre-mock-validation/verify.sh
	@bash -n scenarios/measured-energy-chain/verify.sh
	@bash -n scenarios/ci-shift-left/verify.sh
	@bash -n scenarios/output-formats-coverage/verify.sh
	@bash -n scenarios/verify-hash-roundtrip/verify.sh
	@bash -n scenarios/sql-backtick-redaction/verify.sh
	@bash -n scenarios/non-sql-datastore-drop/verify.sh
	@bash -n scenarios/non-sql-datastore-metering/verify.sh
	@bash -n scenarios/ruby-activerecord-suggestion/verify.sh
	@bash -n scenarios/batch-otlp-file/verify.sh
	@bash -n scenarios/mysql-stat/verify.sh
	@bash -n scenarios/astronomy-shop/verify.sh
	@bash -n scenarios/astronomy-shop/capture.sh
	@bash -n scenarios/sampling-degradation/verify.sh
	@bash -n scenarios/semconv-drift/verify.sh
	@bash -n scenarios/prod-topology-replay/verify.sh
	@bash -n scenarios/prod-topology-replay/fetch.sh
	@bash -n scenarios/rpc-carrier-parity/verify.sh
	@bash -n scenarios/chaos-replay/verify.sh
	@bash -n scenarios/chaos-replay/capture.sh
	@bash -n scenarios/alumet-conformance/verify.sh
	@bash -n scenarios/alumet-db-waste/verify.sh
	@bash -n scenarios/appsec-hardening/verify.sh
	@bash -n scenarios/endpoint-resolution/verify.sh
	@bash -n scenarios/broker-messaging-waste/verify.sh
	@bash -n scenarios/java-ci-capture/verify.sh
	@bash -n scenarios/java-ci-file-export/verify.sh
	@bash -n scenarios/micrometer-http-client/verify.sh
	@bash -n scenarios/hibernate-alias-suggestion/verify.sh
	@bash -n scenarios/ack-store-fsgroup-root/verify.sh
	@bash -n scenarios/outbound-proxy-private-ca/verify.sh
	@bash -n scenarios/ci-e2e-common/render-check.sh
	@bash -n scenarios/ci-e2e-jenkins/verify.sh
	@bash -n scenarios/ci-e2e-github/verify.sh
	@bash -n scenarios/ci-e2e-gitlab/verify.sh
	@bash -n scenarios/archive-integrity-chain/verify.sh
	@bash -n scenarios/config-fragments/verify.sh
	@bash -n scenarios/chart-disclose-persistence/verify.sh
	@bash -n scenarios/template-gitlab-ci/verify.sh
	@bash -n scenarios/template-jenkinsfile/verify.sh
	@bash -n scenarios/template-github-actions/verify.sh
	@bash -n scenarios/daemon-analysis-shedding/verify.sh
	@bash -n scenarios/limit-batch-volume/verify.sh
	@bash -n scenarios/limit-trace-shapes/verify.sh
	@bash -n scenarios/limit-service-cardinality/verify.sh
	@bash -n scenarios/limit-saturation-curve/verify.sh
	@bash -n scenarios/limit-multi-source/verify.sh
	@bash -n scenarios/limit-prod-window-soak/verify.sh
	@bash -n scenarios/otlp-compression-matrix/verify.sh
	@bash -n scenarios/ack-lifecycle-warning/verify.sh
	@bash -n scenarios/export-snapshot-scope/verify.sh
	@bash -n scenarios/chart-prometheusrule-pdb/verify.sh
	@bash -n scenarios/datadog-bridge/verify.sh
	@bash -n scenarios/esrs-e1-crosswalk/verify.sh
	@bash -n scenarios/query-monitor-api/verify.sh
	@bash -n scenarios/rgesn-crosswalk/verify.sh
	@bash -n scenarios/sci-functional-unit/verify.sh
	@bash -n scenarios/verify-hash-fail-closed/verify.sh
	@bash -n scenarios/archive-window-drops/verify.sh
	@bash -n scenarios/diff-mutated-findings/verify.sh
	@bash -n scenarios/disclose-archive-family-baseline/verify.sh
	@bash -n scripts/seed-tracegen.sh
	@bash -n scripts/seed-daemon-local.sh
	@echo "==> yaml parse on resilience scenario manifests"
	@python3 -c "import yaml,sys; [list(yaml.safe_load_all(open(f))) for f in sys.argv[1:]]" \
	  scenarios/multi-agent-load/manifests.yaml \
	  scenarios/long-running-drift/manifests.yaml \
	  scenarios/failure-mode-network-partition/manifests.yaml
	@python3 -c 'import yaml; docs=list(yaml.safe_load_all(open("scenarios/multi-agent-load/manifests.yaml"))); args=next(doc["spec"]["template"]["spec"]["containers"][0]["args"] for doc in docs if doc and doc.get("kind") == "Job"); required={"--telemetry-attributes=rpc.system=\"grpc\"", "--telemetry-attributes=rpc.service=\"load-test\"", "--telemetry-attributes=rpc.method=\"Call\""}; missing=required-set(args); assert not missing, "multi-agent-load lacks analyzable RPC attributes: " + repr(sorted(missing))'
	@echo "==> yaml parse on grafana-dashboard manifests"
	@python3 -c "import yaml,sys; [list(yaml.safe_load_all(open(f))) for f in sys.argv[1:]]" \
	  scenarios/grafana-dashboard/postgres-exporter.yaml \
	  scenarios/grafana-dashboard/alertrules.yaml
	@echo "==> json parse on grafana-dashboard extended dashboard"
	@python3 -m json.tool < scenarios/grafana-dashboard/dashboard-extended.json >/dev/null
	@echo "==> yaml parse on gitlab-ce values"
	@python3 -c "import yaml,sys; list(yaml.safe_load_all(open(sys.argv[1])))" \
	  helm/values/gitlab-ce.yaml
	@echo "==> yaml parse on network-policies"
	@python3 -c "import yaml,sys; list(yaml.safe_load_all(open(sys.argv[1])))" \
	  manifests/network-policies.yaml
	@echo "validation ok"

smoke: ## Run end-to-end smoke test against the running lab (CI-friendly)
	./scripts/smoke-test.sh

seed-services: ## Build + import + helm install the 3 Java services into shop
	./scripts/seed-services.sh

teardown-services: ## Remove the 3 Java services (cluster stays up)
	./scripts/teardown-services.sh

seed-quarkus-svc: ## Build + import + helm install the Quarkus multistack pilot
	./scripts/seed-quarkus-svc.sh

seed-mutiny-svc: ## Build + import + helm install the Quarkus+Mutiny reactive multistack member
	./scripts/seed-mutiny-svc.sh

seed-helidon-mp-svc: ## Build + import + helm install the Helidon MP 4.4 multistack member
	./scripts/seed-helidon-mp-svc.sh

seed-helidon-se-svc: ## Build + import + helm install the Helidon SE 4.4 multistack member
	./scripts/seed-helidon-se-svc.sh

seed-ktor-svc: ## Build + import + helm install the Kotlin 2.4 + Ktor 3.5 multistack member
	./scripts/seed-ktor-svc.sh

seed-dotnet-svc: ## Build + import + helm install the .NET 10 LTS multistack member
	./scripts/seed-dotnet-svc.sh

seed-go-svc: ## Build + import + helm install the Go 1.26 multistack member
	./scripts/seed-go-svc.sh

seed-nest-svc: ## Build + import + helm install the NestJS 11 + Prisma multistack member
	./scripts/seed-nest-svc.sh

seed-django-svc: ## Build + import + helm install the Django 5.2 LTS multistack member
	./scripts/seed-django-svc.sh

seed-fastapi-svc: ## Build + import + helm install the FastAPI + SQLAlchemy async multistack member
	./scripts/seed-fastapi-svc.sh

seed-diesel-svc: ## Build + import + helm install the Rust + Diesel 2.x multistack member
	./scripts/seed-diesel-svc.sh

seed-seaorm-svc: ## Build + import + helm install the Rust + SeaORM 1.1 async multistack member
	./scripts/seed-seaorm-svc.sh

seed-rails-svc: ## Build + import + helm install the Rails 8 + Active Record (Ruby 4.0) multistack member
	./scripts/seed-rails-svc.sh

seed-laravel-svc: ## Build + import + helm install the Laravel 11 + Eloquent (PHP 8.5, native OTel) multistack member
	./scripts/seed-laravel-svc.sh

seed-symfony-svc: ## Build + import + helm install the Symfony 7 + Doctrine (PHP 8.5, native OTel) multistack member
	./scripts/seed-symfony-svc.sh

inject-all: ## Run the Spring baseline's 12 k6 scenarios and assert findings (alias of validate-findings)
	./scripts/inject-all.sh

validate-findings: ## Run the Spring baseline's 12 k6 scenarios and write tmp/validation-report.md
	./scripts/validate-findings.sh

status: ## Curl-only status of cluster + perf-sentinel daemon endpoints
	@echo "==> Pods overview"
	@kubectl get pods -A 2>/dev/null || echo "kubectl not connected to cluster"
	@echo
	@echo "==> Daemon /api/status"
	@curl -fsS $(DAEMON_URL)/api/status | python3 -m json.tool || echo "daemon not reachable"
	@echo
	@echo "==> Daemon /api/findings (count)"
	@curl -fsS $(DAEMON_URL)/api/findings | python3 -c "import sys, json; d=json.load(sys.stdin); print('findings:', len(d) if isinstance(d, list) else d)" || true
	@echo
	@echo "==> Daemon /api/correlations (count)"
	@curl -fsS $(DAEMON_URL)/api/correlations | python3 -c "import sys, json; d=json.load(sys.stdin); print('correlations:', len(d) if isinstance(d, list) else d)" || true

logs: ## Tail logs of the observability namespace
	kubectl -n observability logs -l app.kubernetes.io/part-of=perf-sentinel-lab --all-containers --tail=200 -f || \
	kubectl -n observability logs --all-containers --tail=200 -f deployment/perf-sentinel-daemon

grafana: ## Open Grafana in the default browser
	@echo "Grafana: $(GRAFANA_URL)  (admin / admin)"
	@open $(GRAFANA_URL) 2>/dev/null || xdg-open $(GRAFANA_URL) 2>/dev/null || true

inspect: ## Launch the perf-sentinel TUI against the local daemon
	@if [ -x "$(PERF_SENTINEL_LOCAL_BIN)" ]; then \
		echo "==> using $(PERF_SENTINEL_LOCAL_BIN)"; \
		"$(PERF_SENTINEL_LOCAL_BIN)" query inspect --daemon-url $(DAEMON_URL); \
	elif command -v perf-sentinel >/dev/null 2>&1; then \
		echo "==> using perf-sentinel from PATH"; \
		perf-sentinel query inspect --daemon-url $(DAEMON_URL); \
	else \
		echo "TUI requires the perf-sentinel binary."; \
		echo "Install via cargo install (--path \$$PERF_SENTINEL_REPO_PATH/crates/sentinel-cli)"; \
		echo "or build from source: cd \$$PERF_SENTINEL_REPO_PATH && cargo build --release -p sentinel-cli"; \
		echo "or override PERF_SENTINEL_REPO_PATH if your perf-sentinel checkout is elsewhere."; \
		exit 1; \
	fi

psql: ## Open a psql shell against the lab database (uses .postgres-password)
	@if [ ! -f .postgres-password ]; then \
		echo "missing .postgres-password. Run 'make up' first."; \
		exit 1; \
	fi
	kubectl run -n db psql-shell --rm -it --restart=Never \
	  --image=postgres@sha256:54451ecb8ab38c24c3ec123f2fd501303a3a1856a5c66e98cecf2460d5e1e9d7 \
	  --env="PGPASSWORD=$$(cat .postgres-password)" \
	  -- psql -h postgres -U lab -d lab

ps: ## docker ps for k3d containers of the lab cluster
	docker ps --filter "label=k3d.cluster=$(CLUSTER_NAME)"

clean-images: ## Remove dangling docker images
	docker image prune -f

seed-electricity-maps: ## Provision the Electricity Maps token Secret from .electricity-maps-token
	./scripts/seed-electricity-maps.sh

verify-electricity-maps: ## Confirm the daemon picked up the Electricity Maps token
	./scripts/verify-electricity-maps.sh

seed-scaphandre-mock: ## Apply the Scaphandre mock manifest (RAPL stand-in for the daemon scrape path)
	@kubectl apply -f manifests/scaphandre-mock.yaml
	@kubectl rollout status deployment/scaphandre-mock -n observability --timeout=120s

seed-kepler-mock: ## Apply the Kepler mock manifest (stand-in for the daemon scrape path)
	@kubectl apply -f manifests/kepler-mock.yaml
	@kubectl rollout status deployment/kepler-mock -n observability --timeout=120s

seed-redfish-mock: ## Apply the Redfish mock manifest (BMC stand-in for the daemon scrape path)
	@kubectl apply -f manifests/redfish-mock.yaml
	@kubectl rollout status deployment/redfish-mock -n observability --timeout=120s

seed-kepler-exporter: ## Apply the upstream Kepler exporter (opt-in harness for post-release validation)
	@kubectl apply -f manifests/kepler-exporter.yaml
	@kubectl -n kepler rollout status daemonset/kepler --timeout=240s

capture-greenops-screenshot: ## Capture the daemon report banner to artifacts/greenops-bandeau.png
	./scripts/capture-greenops-screenshot.sh

redeploy-services: ## Re-apply Helm values for the 3 Java services
	./scripts/redeploy-services.sh

up-gitlab: ## Deploy GitLab CE in namespace gitlab-ce (~10 min)
	./scripts/up-gitlab.sh

down-gitlab: ## Tear down GitLab CE
	./scripts/down-gitlab.sh

seed-gitlab-project: ## Bootstrap perf-sentinel-template-test project
	./scripts/seed-gitlab-project.sh

verify-gitlab-perf-sentinel: ## Validate the GitLab CI template end-to-end
	./scripts/verify-gitlab-perf-sentinel.sh

up-cni: ## Bootstrap with Cilium (or Calico) instead of Flannel
	./scripts/up-cni.sh

reset-cni: down up-cni ## Teardown then bootstrap with CNI

install-cni: ## Install Cilium (default) or Calico on a fresh cluster
	./scripts/install-cni.sh

apply-network-policies: ## Apply zero-trust NetworkPolicy
	kubectl apply -f manifests/network-policies.yaml

remove-network-policies: ## Remove NetworkPolicy (debug iteration)
	kubectl delete -f manifests/network-policies.yaml --ignore-not-found

hubble-ui: ## Enable Hubble UI on the active Cilium release
	./scripts/hubble-ui.sh

verify-network-policies: ## Probe the policy contract end-to-end
	./scripts/verify-network-policies.sh

verify-hybrid-daemon-batch: ## daemon Report -> HTML dashboard via report --input
	./scenarios/hybrid-daemon-batch/verify.sh

verify-batch-tempo-scrape: ## batch over Tempo via perf-sentinel tempo subcommand
	./scenarios/batch-tempo-scrape/verify.sh

verify-batch-victoria-scrape: ## batch over Victoria Traces via the jaeger-query subcommand
	./scenarios/batch-victoria-scrape/verify.sh

verify-daemon-otlp-direct: ## services push OTLP straight to a dedicated daemon (no collector)
	./scenarios/daemon-otlp-direct/verify.sh

verify-multiformat-input: ## batch ingests Native + Jaeger + Zipkin coherently
	./scenarios/multiformat-input/verify.sh

verify-calibrate-mode: ## calibrate energy coefficients from baseline traces + power CSV
	./scenarios/calibrate-mode/verify.sh

verify-sidecar-pattern: ## perf-sentinel daemon as a per-service pod sidecar
	./scenarios/sidecar-pattern/verify.sh

verify-correlation-finding: ## cross-trace correlation finding via /api/correlations
	./scenarios/correlation-finding/verify.sh

verify-grouping-identity: ## 0.11 grouping identity across ingest, detection, diff, API, HTML and CSV
	./scenarios/grouping-identity/verify.sh

verify-grouping-metrics-split: ## 0.19.0 grouping label on the five metric families: the split, the sum invariant, the (service, grouping) pair caps and the per_grouping_labels knob (local binary, no cluster)
	./scenarios/grouping-metrics-split/verify.sh

verify-findings-page-filters: ## 0.21.0 GET /api/findings reading contract: the grouping and offset filters, an empty value as no filter, the rewritten fold and the bounded serialized_calls suggestion, each against the published release (local binary + Docker, no cluster)
	./scenarios/findings-page-filters/verify.sh

verify-correlation-event-time: ## 0.23.0 correlator pairs findings on their own timestamps: exact median lag, earlier event as source whatever the arrival order, both sides' traces open in Explain, window_minutes validated, against the published release (local binary + Docker, no cluster)
	./scenarios/correlation-event-time/verify.sh

verify-slow-window-cross-batch: ## 0.23.0 daemon slow window: a template slow in three episodes across batches reports once, on a trace Explain opens, disabled at 0, absent from the published release (local binary + Docker, no cluster)
	./scenarios/slow-window-cross-batch/verify.sh

verify-diff-mutated-findings: ## 0.15 template-mutation pairing in diff: pairs, stays out of SARIF, carries its severity escalation, never guesses (no cluster)
	./scenarios/diff-mutated-findings/verify.sh

verify-pg-stat: ## perf-sentinel report --pg-stat live integration
	./scenarios/pg-stat/verify.sh

verify-grafana-dashboard: ## Grafana dashboard import, audit, alerts, postgres-exporter integration
	./scenarios/grafana-dashboard/verify.sh

verify-query-monitor-api: ## query monitor data plane: /api/config (no secrets), /api/status, /api/energy, the 6 gauges
	./scenarios/query-monitor-api/verify.sh

verify-ci-shift-left: ## CI shift-left workflow (clean / regression / acked) post-0.5.17
	./scenarios/ci-shift-left/verify.sh

verify-output-formats-coverage: ## Output formats, diff mode, signature presence, ack cap loader
	./scenarios/output-formats-coverage/verify.sh

verify-verify-hash-roundtrip: ## verify-hash CLI contract (exit codes 1/3/4 + identity-required default)
	./scenarios/verify-hash-roundtrip/verify.sh

verify-sql-backtick-redaction: ## 0.9.2 normalize: MySQL backtick ids preserved + PostgreSQL bracket/array literals masked (no leak), 0.25.5 MySQL/MariaDB double-quoted values masked
	./scenarios/sql-backtick-redaction/verify.sh

verify-non-sql-datastore-drop: ## 0.9.2 ingest: redis/elasticsearch dropped on db.system across batch Jaeger/Zipkin + OTLP daemon
	./scenarios/non-sql-datastore-drop/verify.sh

verify-non-sql-datastore-metering: ## 0.9.2 metering: non_sql_datastore counter + zero-retention warning excludes non_sql (not_io still counts)
	./scenarios/non-sql-datastore-metering/verify.sh

verify-ruby-activerecord-suggestion: ## 0.9.2 detect: Ruby/ActiveRecord suggested_fix (ruby_active_record via OTLP scope, ruby_generic via .rb)
	./scenarios/ruby-activerecord-suggestion/verify.sh

verify-datadog-bridge: ## 0.9.3 ingest: dd-trace/Datadog bridge end to end (db.system.name + canonicalization across OTLP/Jaeger/Zipkin; F3 auto vs strict; optional live datadogreceiver)
	./scenarios/datadog-bridge/verify.sh

verify-batch-otlp-file: ## 0.9.5 ingest: OTLP/JSON batch from the Collector file exporter (dd-trace -> datadogreceiver -> NDJSON -> analyze; truncation, negatives, Jaeger/OTLP sniff non-regression)
	./scenarios/batch-otlp-file/verify.sh

verify-mysql-stat: ## 0.9.5 stats: mysql-stat on a real MySQL LTS (9.7) performance_schema (4 rankings, --traces cross-ref, NULL/ANSI robustness, report --mysql-stat tab)
	./scenarios/mysql-stat/verify.sh

verify-astronomy-shop: ## Foreign instrumentation + FP budget: replay committed OTel Astronomy Shop slices (recall on degraded, findings <= fp_budget on clean, report; no cluster, no Docker)
	./scenarios/astronomy-shop/verify.sh

capture-astronomy-shop: ## One-off: run the OTel demo (docker compose, ~8 GiB), dump OTLP NDJSON clean+degraded, curate committed slices, stamp the manifest
	./scenarios/astronomy-shop/capture.sh

verify-sampling-degradation: ## Sampling robustness: FNV-1a trace-sampled (50/10/1%) + span-loss variants of the astronomy slices (monotone totals, no class invention, FP budget holds; no cluster, no Docker)
	./scenarios/sampling-degradation/verify.sh

verify-semconv-drift: ## Semconv drift: old-only/new-only/dup attribute-key rewrites of the degraded astronomy slice yield identical findings (db.statement<->db.query.text etc.; no cluster, no Docker)
	./scenarios/semconv-drift/verify.sh

verify-prod-topology-replay: ## Real production topology: replay a committed Alibaba v2022 call-graph slice (deterministic ingest + topological detector recall; no cluster, no Docker)
	./scenarios/prod-topology-replay/verify.sh

fetch-prod-topology: ## One-off: download 3 min of Alibaba v2022 call graphs (~223 MB), convert a consistent slice to OTLP NDJSON, stamp the manifest
	./scenarios/prod-topology-replay/fetch.sh

verify-rpc-carrier-parity: ## OTel RPC semconv ingest: the Alibaba slice rewritten onto real rpc.* keys matches the synthetic-carrier baseline; SERVER-kind twins rejected (no cluster, no Docker)
	./scenarios/rpc-carrier-parity/verify.sh

verify-chaos-replay: ## Chaos telemetry: replay a committed slice of the OTel demo under failure flags + kill/pause chaos (clean degradation, deterministic census; no cluster, no Docker)
	./scenarios/chaos-replay/verify.sh

capture-chaos-replay: ## One-off: drive the OTel demo (docker compose, ~8 GiB) through the chaos window, curate the slice, stamp the manifest
	./scenarios/chaos-replay/capture.sh

verify-intent-validator: ## disclose-time validators (75% gate + org-config required fields)
	./scenarios/intent-validator/verify.sh

verify-disclose: ## periodic disclosure two-tier waste (current schema, verify-hash round-trip, anti-gaming)
	./scenarios/disclose/verify.sh

verify-disclose-temporal: ## periodic disclosure continuity (temporal_coverage, coverage_basis, dense/sparse)
	./scenarios/disclose-temporal/verify.sh

verify-disclose-archive-family-baseline: ## 0.15 drop baseline keyed per archive family: two hosts stay independent, a rotation keeps its delta (no cluster)
	./scenarios/disclose-archive-family-baseline/verify.sh

verify-sci-functional-unit: ## 0.8.13 G1: SCI per-functional-unit intensity (batch analyze + daemon /api/export/report)
	./scenarios/sci-functional-unit/verify.sh

verify-rgesn-crosswalk: ## 0.8.13 G2: RGESN 2024 crosswalk on disclosed anti_patterns (slow_* omitted)
	./scenarios/rgesn-crosswalk/verify.sh

verify-esrs-e1-crosswalk: ## 0.8.13 R1: ESRS E1 crosswalk + schema v1.3 + hash integrity + v1.2 retro-compat
	./scenarios/esrs-e1-crosswalk/verify.sh

verify-verify-hash-fail-closed: ## 0.8.13 R2: verify-hash fail-closed on a signed report without identity flags
	./scenarios/verify-hash-fail-closed/verify.sh

verify-chart-prometheusrule-pdb: ## 0.8.13 Phase A: chart PrometheusRule + PodDisruptionBudget (render + kubeconform + promtool)
	./scenarios/chart-prometheusrule-pdb/verify.sh

verify-chart-disclose-persistence: ## Real helm install (StatefulSet+persistence): archive survives a pod restart, feeds disclose
	./scenarios/chart-disclose-persistence/verify.sh

verify-template-gitlab-ci: ## Validate upstream gitlab-ci.yml template via GitLab CE in-cluster
	./scenarios/template-gitlab-ci/verify.sh

verify-template-jenkinsfile: ## Validate upstream jenkinsfile.groovy via jenkinsfile-runner
	./scenarios/template-jenkinsfile/verify.sh

verify-template-github-actions: ## Validate upstream github-actions.yml via nektos/act --list
	./scenarios/template-github-actions/verify.sh

verify-multi-agent-load: ## telemetrygen Job parallel charges the prod daemon
	./scenarios/multi-agent-load/verify.sh

verify-long-running-drift: ## drift accelere 2h (LONG_RUN=1 for 24h leak hunting)
	./scenarios/long-running-drift/verify.sh

verify-failure-mode-daemon-restart: ## kubectl rollout restart while traffic flows
	./scenarios/failure-mode-daemon-restart/verify.sh

verify-daemon-sigterm-drain: ## 0.8.5 graceful SIGTERM drains the in-flight window (needs SIGTERM_DRAIN_IMAGE)
	./scenarios/daemon-sigterm-drain/verify.sh

verify-daemon-analysis-shedding: ## 0.8.6 decoupled analysis worker sheds whole batches (metered) under overload
	./scenarios/daemon-analysis-shedding/verify.sh

seed-tracegen: ## Build + import the tracegen load-generator image (I/O-semantic synthetic traces)
	./scripts/seed-tracegen.sh

seed-daemon-local: ## Build a daemon image from a local perf-sentinel checkout and pin the manifest to it (pre-release validation)
	./scripts/seed-daemon-local.sh

seed-hub-local: ## Build a PerfSentinelHub image from a local checkout, import it and pin the manifest (pre-release validation)
	./scripts/seed-hub-local.sh

verify-hub-ingestion: ## daemon -> Hub over the shared pair: envelopes stay plugin-compatible, a malformed import is counted not fatal
	./scenarios/hub-ingestion/verify.sh

verify-hub-incidents-mirror: ## daemon -> Hub incident chain over the shared pair: the frozen findings copied whole, the closed filters that refuse a typo, a refused read key that spares the findings, and a copy that outlives the ring
	./scenarios/hub-incidents-mirror/verify.sh

verify-hub-source-reachability: ## push vs poll on unreachable_since, on an isolated pair partitioned by NetworkPolicy
	./scenarios/hub-source-reachability/verify.sh

verify-hub-derived-status: ## active -> likely_resolved -> not_observed, with the two negative cases that must stay not_observed
	./scenarios/hub-derived-status/verify.sh

verify-hub-lineage-mutation: ## a real SQL template mutation keeps its origin: Hub lineage plus the CLI diff pairing
	./scenarios/hub-lineage-mutation/verify.sh

verify-hub-retention-purge: ## the boot purge drops a stale predecessor, its successor keeps the origin, backup stays servable
	./scenarios/hub-retention-purge/verify.sh

verify-hub-plugin-contract: ## capture the payload the IDE plugin parses, straight from a running Hub
	./scenarios/hub-plugin-contract/verify.sh

verify-hub-access-control: ## Hub access control on the AOT image: local and provider sign-in, machine and terminal tokens, the daemon read gate, grouping and the metrics port, on an isolated pair
	./scenarios/hub-access-control/verify.sh

verify-limit-batch-volume: ## Large-input batch CLI (50k+ traces x 3 formats, no cluster)
	./scenarios/limit-batch-volume/verify.sh

verify-limit-trace-shapes: ## Adversarial trace shapes (1500-span traces, 400-deep chains, 1200-wide fanout, dup ids, 70KB SQL)
	./scenarios/limit-trace-shapes/verify.sh

verify-limit-service-cardinality: seed-tracegen ## 1500+ services vs the 1024 metering cap (overflow counter, /metrics envelope)
	./scenarios/limit-service-cardinality/verify.sh

verify-limit-saturation-curve: seed-tracegen ## Ramp tps until shed; emits the saturation table (max clean throughput at 256Mi/500m)
	./scenarios/limit-saturation-curve/verify.sh

verify-limit-multi-source: seed-tracegen ## OTLP gRPC + HTTP + NDJSON socket + tempo batch reader, concurrently
	./scenarios/limit-multi-source/verify.sh

verify-limit-prod-window-soak: seed-tracegen ## Production window config (ttl 30s) under sustained mixed load
	./scenarios/limit-prod-window-soak/verify.sh

verify-failure-mode-backend-down: ## OTel collector / Tempo / Postgres scaled to 0 in turn
	./scenarios/failure-mode-backend-down/verify.sh

verify-failure-mode-network-partition: ## NetworkPolicy ingress isolation of the daemon
	./scenarios/failure-mode-network-partition/verify.sh

verify-cold-start-edge-cases: ## 4 sub-tests of cold-start corner cases
	./scenarios/cold-start-edge-cases/verify.sh

verify-daemon-ack-workflow: ## ack API end-to-end with PVC persistence and 0.5.21 counter asserts
	@echo "==> seed findings (scenario needs >=2 distinct sigs in the store)"
	@./scripts/validate-findings.sh > /tmp/daemon-ack-workflow-seed.log 2>&1 || true
	./scenarios/daemon-ack-workflow/verify.sh

verify-scaphandre-mock-validation: ## Scaphandre scrape path end-to-end against the Python stdlib mock
	./scenarios/scaphandre-mock-validation/verify.sh

verify-measured-energy-chain: ## Kepler and Redfish scraper integration against the Python stdlib mocks
	./scenarios/measured-energy-chain/verify.sh

verify-alumet-conformance: ## 0.9.12 green: Alumet 6th measured backend vs the real agent (wire conformance, summed-label math, desync x5, precedence over Scaphandre, warn latches; local binary, Docker optional)
	./scenarios/alumet-conformance/verify.sh

verify-alumet-db-waste: ## 0.9.13 green: Alumet DB-cgroup energy x SQL waste ratio (database_waste arithmetic + exclusion + disclose absence, sticky/staleness, carry-over under shedding, config validation, monitor line; local binary, no cluster)
	./scenarios/alumet-db-waste/verify.sh

verify-appsec-hardening: ## 0.9.15 AppSec: source_endpoint redaction, ack API key + env override, real export quality gate, verify-hash attestation PARTIAL cap, non-loopback bind advisory, require_read_key gate + query --api-key-file (local binary > 0.26.2, no cluster)
	./scenarios/appsec-hardening/verify.sh

verify-endpoint-resolution: ## 0.9.22 source.endpoint: ancestor walk to the inbound route, CLIENT skip, outermost code frame, one spelling per origin (local binary, no cluster)
	./scenarios/endpoint-resolution/verify.sh

verify-consumer-endpoint: ## 0.22.2 source.endpoint on a message CONSUMER root: notification-service consumes perfsim.order-service, the finding names "rabbitmq order-service" (daemon + k6)
	./scenarios/consumer-endpoint/verify.sh

verify-broker-messaging-waste: ## messaging ingestion + broker energy: the two-source arbitration against a real scraper (cut/restore/wrong-label/cold-boot), disclosure v1.5, config refusals, destination spellings, producer link (local binary, no cluster)
	./scenarios/broker-messaging-waste/verify.sh

verify-java-ci-capture: ## Upstream Java CI recipe end to end: Maven Failsafe + perf-sentinel capture -> analyze, plus the capture exit-code contract (local binary, no cluster)
	./scenarios/java-ci-capture/verify.sh

verify-java-ci-file-export: ## Java agent (SDK 1.66 otlp_file) writes the trace file itself in a forked Failsafe JVM, no capture -> analyze (local binary, no cluster)
	./scenarios/java-ci-file-export/verify.sh

verify-micrometer-http-client: ## 0.25.2 ingest: Spring Boot 4 traced through Micrometer Observation, method and status tags read over OTLP, Zipkin, Jaeger and the daemon, 0.25.5 jaeger-query on Jaeger 2.20 and 2.21 (local binary + Docker, no cluster)
	./scenarios/micrometer-http-client/verify.sh

verify-hibernate-alias-suggestion: ## 0.25.3 detect: java_jpa from Hibernate aliases on lazy loads no Hibernate span wraps, java_generic through Micrometer, under the agent, the bare agent and the daemon (local binary, no cluster)
	./scenarios/hibernate-alias-suggestion/verify.sh

verify-ack-store-fsgroup-root: ## 0.25.3 daemon: no warning at start when the ack store sits at an fsGroup volume root it cannot chmod, each advisory printed once, 0.25.5 advisory wording (docker image, no cluster)
	./scenarios/ack-store-fsgroup-root/verify.sh

verify-outbound-proxy-private-ca: ## 0.25.5 HTTPS_PROXY/ALL_PROXY/NO_PROXY/SSL_CERT_FILE through a CONNECT proxy to a private-CA origin, plus the daemon TLS listener (local binary + docker, no cluster)
	./scenarios/outbound-proxy-private-ca/verify.sh

verify-ci-e2e-jenkins: ## Upstream Java CI recipe inside a real Jenkins controller, through to whether the published dashboard renders under Jenkins' CSP (docker, no cluster)
	./scenarios/ci-e2e-jenkins/verify.sh

verify-ci-e2e-github: ## Upstream Java CI recipe through a real GitHub Actions workflow (act) to the rendered dashboard (docker + act, no cluster)
	./scenarios/ci-e2e-github/verify.sh

verify-ci-e2e-gitlab: ## Upstream Java CI recipe through a real GitLab pipeline to the dashboard served by GitLab Pages (needs make up-gitlab)
	./scenarios/ci-e2e-gitlab/verify.sh

verify-archive-integrity-chain: ## 0.9.25 hash chain over the daemon window archive: intact, edited, pre-chaining, hash-stripped, SIGKILL and torn-tail (local binary, no cluster)
	./scenarios/archive-integrity-chain/verify.sh

verify-config-fragments: ## 0.9.25 .perf-sentinel.d/ loader (merge order, rejected names, exit 75 on both config paths) plus the three deprecated [green] keys (local binary, no cluster)
	./scenarios/config-fragments/verify.sh

verify-archive-window-drops: ## 0.15.0 dropped archive windows: the four pre-warmed reasons on a healthy archive, channel_full on a saturated one (local binary, no cluster)
	./scenarios/archive-window-drops/verify.sh

verify-incident-window-capture: ## 0.20.0 incident intake: the window frozen at reception, the settle merge, idempotent reposts, counted refusals, the NDJSON archive, until_ms, the last-span gauge and the 0.24.0 id parameter (local binary, no cluster)
	./scenarios/incident-window-capture/verify.sh

verify-incident-namespace-scope: ## 0.25.0 namespace screen on the incident freeze: each tenant keeps its own rows at reception and in the settle, the attribute read in any position, findings=false, the archive and the startup warning (local binary, no cluster)
	./scenarios/incident-namespace-scope/verify.sh

verify-incident-alerting-chain: seed-tracegen ## 0.22.0 alerting half of POST /api/incidents: the shipped rules applied unedited, the group_left fix against a replicated kube-state-metrics, the namespace-matcher trap both ways, and a real Alertmanager delivering with a bearer credential against a 0.21.0 twin
	./scenarios/incident-alerting-chain/verify.sh

verify-ack-lifecycle-warning: ## 0.9.28 CI acknowledgment life cycle: unmatched warning, the fixed/not-run split, and the pre-computed-report guard (local binary, no cluster)
	./scenarios/ack-lifecycle-warning/verify.sh

verify-export-snapshot-scope: ## 0.13.1 export snapshot scope: the configurable max_export_findings cap, the snapshot_scope disclosure, and an oversized body named rather than flattened (local binary, no cluster)
	./scenarios/export-snapshot-scope/verify.sh

verify-otlp-compression-matrix: ## 0.9.28 OTLP transport x encoding matrix (gRPC/HTTP x gzip/deflate/none/zstd) with an A/B against the pre-fix image (Docker, no cluster; one cluster leg SKIPs without one)
	./scenarios/otlp-compression-matrix/verify.sh

verify-all-scenarios: seed-tracegen ## Run all 95 scenarios sequentially (see docs/SCENARIOS.md)
	@# Order matters:
	@# - grafana-dashboard before pg-stat so pg-stat detects postgres-exporter
	@#   and exercises Path 2 (--pg-stat-prometheus).
	@# - ci-shift-left before output-formats-coverage because the latter
	@#   reuses /tmp/ci-shift-left/regression-report.json artefacts.
	@# - verify-hash-roundtrip is CLI-only (no cluster contact); placed
	@#   next to the other CLI-heavy scenarios for grouping clarity.
	@# - templates run before the resilience scenarios because they may
	@#   SKIP runtime steps when the GitLab/Jenkins/act environment is
	@#   not fully available.
	@# - resilience scenarios run last: they restart the daemon, scale
	@#   shared backends to 0, and apply temporary NetworkPolicies.
	@#   Running them after the rest avoids polluting earlier scenarios.
	@# - daemon-sigterm-drain swaps the daemon image to the image under test
	@#   (SIGTERM_DRAIN_IMAGE, default = the manifest's current pin, i.e. the
	@#   version under validation) and restores the manifest image on cleanup;
	@#   on a pre-0.8.5 image it FAILs the positive control by design.
	@# - sql-backtick-redaction / non-sql-datastore-* / ruby-activerecord-suggestion
	@#   are self-contained 0.9.2 checks (local release binary + throwaway loopback
	@#   daemon, no cluster); grouped with the CLI-heavy batch scenarios.
	@# - batch-otlp-file / mysql-stat are the 0.9.5 gates: both need the local
	@#   release binary + Docker; batch-otlp-file's native-OTel leg overlays the
	@#   cluster collector with a file exporter and reverts it on exit, so it is
	@#   grouped with the other collector-touching scenarios before the daemon
	@#   resilience block.
	@# - otlp-compression-matrix runs right after batch-otlp-file: both overlay the
	@#   shared cluster collector and revert it on exit, so they stay adjacent and
	@#   ahead of everything that reads findings through the nominal HTTP path.
	@# - datadog-bridge is the self-contained 0.9.3 check (local binary + throwaway
	@#   daemon + batch analyze/explain; an optional live datadogreceiver leg SKIPs
	@#   cleanly when Docker is unavailable).
	@# - astronomy-shop replays committed Astronomy Shop fixtures (local binary
	@#   only, no Docker, no cluster); grouped with the CLI-heavy batch scenarios.
	@# - sampling-degradation and semconv-drift replay deterministic transforms
	@#   of the astronomy fixtures (local binary only), so they run right after
	@#   astronomy-shop; prod-topology-replay replays its own committed Alibaba
	@#   slice (local binary only) and is grouped with them, followed by
	@#   rpc-carrier-parity which rewrites that same slice onto rpc.* keys.
	@# - chaos-replay replays its committed chaos slice of the OTel demo
	@#   (local binary only, no Docker) and closes the replay group.
	@# - appsec-hardening is the self-contained 0.9.15 check (local binary +
	@#   throwaway loopback daemon, no cluster); grouped with the other
	@#   local-binary batch scenarios after the alumet pair.
	@# - chart-disclose-persistence installs its own daemon via a real
	@#   `helm install` into a scratch namespace/release (StatefulSet +
	@#   persistence), fully isolated from the shared observability daemon;
	@#   grouped with chart-prometheusrule-pdb, the only other scenario that
	@#   touches the real chart.
	@# - hub-incidents-mirror runs in the resilience block rather than beside
	@#   the other hub-* gates: its last leg restarts the shared daemon and
	@#   leaves an empty findings ring behind, so it sits after the hub
	@#   scenarios that read that ring and just before cold-start-edge-cases,
	@#   which starts from a cold daemon anyway.
	@# - hub-access-control runs right after the other hub-* gates: it stands up
	@#   its own daemon and Hub in an isolated namespace and touches neither the
	@#   shared daemon nor the shared Hub.
	@for s in limit-batch-volume endpoint-resolution java-ci-capture java-ci-file-export micrometer-http-client hibernate-alias-suggestion ack-store-fsgroup-root outbound-proxy-private-ca ci-e2e-jenkins ci-e2e-github ci-e2e-gitlab archive-integrity-chain archive-window-drops config-fragments incident-window-capture incident-namespace-scope incident-alerting-chain grouping-identity grouping-metrics-split findings-page-filters correlation-event-time slow-window-cross-batch diff-mutated-findings ack-lifecycle-warning export-snapshot-scope broker-messaging-waste sql-backtick-redaction non-sql-datastore-drop non-sql-datastore-metering ruby-activerecord-suggestion datadog-bridge batch-otlp-file otlp-compression-matrix mysql-stat astronomy-shop sampling-degradation semconv-drift prod-topology-replay rpc-carrier-parity chaos-replay alumet-conformance alumet-db-waste appsec-hardening hybrid-daemon-batch batch-tempo-scrape batch-victoria-scrape daemon-otlp-direct hub-ingestion hub-derived-status hub-lineage-mutation hub-retention-purge hub-plugin-contract hub-access-control multiformat-input calibrate-mode sidecar-pattern correlation-finding consumer-endpoint grafana-dashboard query-monitor-api pg-stat ci-shift-left output-formats-coverage verify-hash-roundtrip intent-validator disclose disclose-temporal disclose-archive-family-baseline sci-functional-unit rgesn-crosswalk esrs-e1-crosswalk verify-hash-fail-closed chart-prometheusrule-pdb chart-disclose-persistence template-gitlab-ci template-jenkinsfile template-github-actions multi-agent-load long-running-drift failure-mode-daemon-restart daemon-sigterm-drain daemon-analysis-shedding failure-mode-backend-down failure-mode-network-partition hub-source-reachability hub-incidents-mirror cold-start-edge-cases daemon-ack-workflow scaphandre-mock-validation measured-energy-chain limit-trace-shapes limit-multi-source limit-service-cardinality limit-saturation-curve limit-prod-window-soak; do \
	  echo "==> verify-$$s"; \
	  $(MAKE) verify-$$s || echo "$$s FAILED"; \
	done
