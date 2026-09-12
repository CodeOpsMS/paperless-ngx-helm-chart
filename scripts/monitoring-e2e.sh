#!/usr/bin/env bash
# Sourced by paperless-e2e.sh; all resources live in its newly owned namespace.

create_metrics_probe() {
  local name=$1 access=$2
  jq -n --arg name "$name" --arg access "$access" --arg namespace "$NAMESPACE" '
    {apiVersion:"v1",kind:"Pod",metadata:{name:$name,namespace:$namespace,
      labels:{"paperless-e2e-metrics":$access}},spec:{automountServiceAccountToken:false,
      restartPolicy:"Never",securityContext:{runAsNonRoot:true,runAsUser:1000,
        seccompProfile:{type:"RuntimeDefault"}},containers:[{name:"probe",
        image:"busybox:1.38.0@sha256:dc2d74b28e4cf8984fa52af1f39bc7c3d9c73760b41a74d629f5d11b1ab28616",
        command:["sh","-c","sleep 1800"],securityContext:{allowPrivilegeEscalation:false,
          capabilities:{drop:["ALL"]}},resources:{requests:{cpu:"10m",memory:"16Mi"},
          limits:{cpu:"100m",memory:"32Mi"}}}]}}
  ' | kube apply -f -
  kube wait -n "$NAMESPACE" "pod/$name" --for=condition=Ready --timeout=3m
}

verify_metrics_network_path() {
  local pod_ip=$1 host service
  host=$pod_ip
  if [[ "$pod_ip" == *:* ]]; then host="[$pod_ip]"; fi
  service=$(app_service)
  create_metrics_probe paperless-metrics-allowed allowed
  for endpoint in "http://${service}:9100/metrics" "http://${host}:5555/metrics"; do
    kube exec -n "$NAMESPACE" paperless-metrics-allowed -- sh -ceu \
      'wget -q -T 10 -O /tmp/metrics "$1"; grep -q "flower_" /tmp/metrics' sh "$endpoint"
  done
  if [[ "$REQUIRE_NETWORK_POLICY_ENFORCEMENT" == true ]]; then
    create_metrics_probe paperless-metrics-denied denied
    for endpoint in "http://${service}:9100/metrics" "http://${host}:5555/metrics"; do
      kube exec -n "$NAMESPACE" paperless-metrics-denied -- sh -ceu \
        'if wget -q -T 5 -O /dev/null "$1"; then echo "NetworkPolicy did not deny metrics"; exit 1; fi' sh "$endpoint"
    done
    echo "Metrics NetworkPolicy allowed and denied paths verified"
  fi
  echo "Flower metrics verified through Service and Pod IP from a separate pod"
}

verify_prometheus_integration() {
  local attempt service port targets rules samples
  service=$(app_service)
  port=$((LOCAL_PORT + 1))
  kube get crd servicemonitors.monitoring.coreos.com prometheuses.monitoring.coreos.com \
    prometheusrules.monitoring.coreos.com >/dev/null
  jq -n --arg ns "$NAMESPACE" --arg run "$RUN_ID" '
    {apiVersion:"v1",kind:"List",items:[
      {apiVersion:"v1",kind:"ServiceAccount",metadata:{name:"paperless-metrics",namespace:$ns}},
      {apiVersion:"rbac.authorization.k8s.io/v1",kind:"Role",metadata:{name:"paperless-metrics",namespace:$ns},rules:[
        {apiGroups:[""],resources:["services","endpoints","pods"],verbs:["get","list","watch"]},
        {apiGroups:["discovery.k8s.io"],resources:["endpointslices"],verbs:["get","list","watch"]}]},
      {apiVersion:"rbac.authorization.k8s.io/v1",kind:"RoleBinding",metadata:{name:"paperless-metrics",namespace:$ns},
        roleRef:{apiGroup:"rbac.authorization.k8s.io",kind:"Role",name:"paperless-metrics"},
        subjects:[{kind:"ServiceAccount",name:"paperless-metrics",namespace:$ns}]},
      {apiVersion:"monitoring.coreos.com/v1",kind:"Prometheus",metadata:{name:"paperless-metrics",namespace:$ns},spec:{
        version:"v3.14.0",image:"quay.io/prometheus/prometheus:v3.14.0@sha256:5ce7540c3c00ef4ab0c9d2c995c6a5b9c421f44b4a115d97a2c7af3b1c21cbb0",
        replicas:1,serviceAccountName:"paperless-metrics",
        podMetadata:{labels:{"paperless-e2e-metrics":"allowed"}},
        serviceMonitorSelector:{matchLabels:{"paperless-e2e-monitor":$run}},
        ruleSelector:{matchLabels:{"paperless-e2e-monitor":$run}},
        evaluationInterval:"5s",scrapeInterval:"5s",retention:"1h",
        resources:{requests:{cpu:"50m",memory:"128Mi"},limits:{cpu:"500m",memory:"512Mi"}}}},
      {apiVersion:"v1",kind:"Service",metadata:{name:"paperless-metrics",namespace:$ns},
        spec:{selector:{prometheus:"paperless-metrics"},ports:[{name:"web",port:9090,targetPort:9090}]}}
    ]}
  ' >"$WORK_DIR/prometheus.json"
  # The real API/CRDs validate the chart-created ServiceMonitor and PrometheusRule;
  # the operator must reconcile both into an actually scraping Prometheus pod.
  kube apply --dry-run=server -f "$WORK_DIR/prometheus.json" >/dev/null
  kube apply -f "$WORK_DIR/prometheus.json"
  for attempt in $(seq 1 60); do
    if kube get statefulset prometheus-paperless-metrics -n "$NAMESPACE" >/dev/null 2>&1; then break; fi
    sleep 5
  done
  kube rollout status statefulset/prometheus-paperless-metrics -n "$NAMESPACE" --timeout=5m
  kube port-forward -n "$NAMESPACE" service/paperless-metrics "${port}:9090" \
    >"$WORK_DIR/prometheus-forward.log" 2>&1 &
  # Read by the caller cleanup trap after sourcing this helper.
  # shellcheck disable=SC2034
  PROMETHEUS_FORWARD_PID=$!
  for attempt in $(seq 1 120); do
    targets=$(curl -fsS --max-time 10 "http://127.0.0.1:${port}/api/v1/targets?state=active" 2>/dev/null) || targets='{}'
    rules=$(curl -fsS --max-time 10 "http://127.0.0.1:${port}/api/v1/rules?type=alert" 2>/dev/null) || rules='{}'
    samples=$(curl -fsS --max-time 10 --get "http://127.0.0.1:${port}/api/v1/query" \
      --data-urlencode "query={__name__=~\"flower_.+\",namespace=\"${NAMESPACE}\",service=\"${service}\"}" 2>/dev/null) || samples='{}'
    if jq -e --arg ns "$NAMESPACE" --arg service "$service" '
      .status == "success" and any(.data.activeTargets[]?;
        .labels.namespace == $ns and .labels.service == $service and .health == "up"
        and (.scrapeUrl | endswith(":5555/metrics")))' <<<"$targets" >/dev/null \
      && jq -e '.status == "success" and any(.data.groups[]?.rules[]?;
        .name == "PaperlessE2EAlwaysFiring" and .state == "firing" and .health == "ok")' <<<"$rules" >/dev/null \
      && jq -e '.status == "success" and (.data.result | length) > 0' <<<"$samples" >/dev/null; then
      echo "Operator, ServiceMonitor, real Flower scrape/samples and PrometheusRule evaluation verified"
      return 0
    fi
    sleep 5
  done
  echo "Prometheus did not scrape Flower or evaluate the chart rule after ${attempt} attempts" >&2
  return 1
}
