# Brings the whole environment up from scratch. Idempotent: safe to re-run.
# Expects OrderFlow and PayLedger cloned next to this repo (override with -OrderFlow / -PayLedger).
param(
    [string]$OrderFlow = "$PSScriptRoot/../../OrderFlow",
    [string]$PayLedger = "$PSScriptRoot/../../PayLedger",
    [switch]$SkipBuild
)
$root = Split-Path $PSScriptRoot -Parent

# Native tools write progress to stderr, so fail on exit codes instead of $ErrorActionPreference.
function Run { & $args[0] $args[1..($args.Count - 1)]; if ($LASTEXITCODE) { throw "Failed: $args" } }

k3d cluster get platform *> $null
if ($LASTEXITCODE) {
    Run k3d cluster create --config "$root/k3d.yaml" --wait
} else {
    Run k3d cluster start platform --wait  # no-op when already running
}
Run kubectl config use-context k3d-platform
Run kubectl wait --for=condition=Ready node --all --timeout=120s

if (-not $SkipBuild) {
    $images = @(
        @{ tag = 'orderflow-api:dev';                 ctx = $OrderFlow; file = 'src/OrderFlow.Api/Dockerfile';           target = 'final' }
        @{ tag = 'orderflow-api-migrations:dev';      ctx = $OrderFlow; file = 'src/OrderFlow.Api/Dockerfile';           target = 'migrations' }
        @{ tag = 'orderflow-consumer:dev';            ctx = $OrderFlow; file = 'src/OrderFlow.Consumer/Dockerfile';      target = 'final' }
        @{ tag = 'orderflow-consumer-migrations:dev'; ctx = $OrderFlow; file = 'src/OrderFlow.Consumer/Dockerfile';      target = 'migrations' }
        @{ tag = 'orderflow-warehouse-stub:dev';      ctx = $OrderFlow; file = 'src/OrderFlow.WarehouseStub/Dockerfile'; target = 'final' }
        @{ tag = 'payledger:dev';                     ctx = $PayLedger; file = 'Dockerfile';                             target = '' }
    )
    foreach ($i in $images) {
        $target = if ($i.target) { @('--target', $i.target) } else { @() }
        Run docker build -q -t $i.tag -f "$($i.ctx)/$($i.file)" @target $i.ctx
    }
    $tags = $images | ForEach-Object tag
    Run k3d image import -c platform @tags
}

Run helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
Run helm repo add grafana https://grafana.github.io/helm-charts --force-update
$m = "$root/monitoring"
Run helm upgrade --install kps prometheus-community/kube-prometheus-stack --version 92.16.1 -n monitoring --create-namespace -f "$m/kube-prometheus-stack.yaml" --wait --timeout 10m
Run helm upgrade --install tempo grafana/tempo --version 1.24.4 -n monitoring -f "$m/tempo.yaml" --wait
Run helm upgrade --install kafka-exporter prometheus-community/prometheus-kafka-exporter --version 4.1.1 -n monitoring -f "$m/kafka-exporter.yaml"

Run helm upgrade --install infra "$root/charts/infra" -n platform --create-namespace --wait --timeout 5m
# Restart pods so freshly imported :dev images are picked up.
Run helm upgrade --install apps "$root/charts/apps" -n platform --wait --timeout 5m --set-string "podRestart=$(Get-Date -Format o)"

Write-Host "`nOrderFlow API: http://orderflow.localhost:8088/scalar   PayLedger: http://payledger.localhost:8088/swagger-ui.html   Grafana: http://grafana.localhost:8088"
