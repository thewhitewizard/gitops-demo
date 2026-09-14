#!/usr/bin/env bash
# Installe Headlamp, une IHM web pour explorer le cluster, sur
# http://dashboard.k3d.lab (port 80, via Traefik).
source "$(dirname "$0")/lib.sh"

need helm
guard

echo "== Installation de Headlamp (chart $HEADLAMP_CHART_VERSION) =="
helm upgrade --install headlamp headlamp \
  --repo https://kubernetes-sigs.github.io/headlamp/ \
  --version "$HEADLAMP_CHART_VERSION" \
  --namespace headlamp --create-namespace \
  --wait --timeout 5m

echo "== Identité de consultation (lecture seule) =="
kubectl apply -f "$REPO/dashboard/rbac.yaml"

echo "== Exposition sur http://$DASHBOARD_HOST =="
kubectl apply -f "$REPO/dashboard/ingress.yaml"

# Headlamp demande un token de ServiceAccount à la connexion. On en génère un
# pour l'identité en lecture seule définie dans dashboard/rbac.yaml.
# Le token est éphémère : il n'est stocké nulle part, il suffit de relancer ce
# script (ou la commande ci-dessous) pour en obtenir un nouveau.
token="$(kubectl -n headlamp create token headlamp-viewer --duration=24h)"

echo
echo "== Headlamp prêt =="
echo "   URL   : http://$DASHBOARD_HOST"
echo "   Coller ce token dans l'écran de connexion (valable 24 h) :"
echo
echo "$token"
echo
echo "   Pour en régénérer un :"
echo "   kubectl -n headlamp create token headlamp-viewer --duration=24h"
