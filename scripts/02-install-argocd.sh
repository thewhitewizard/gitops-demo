#!/usr/bin/env bash
# Installe ArgoCD et l'expose sur http://argocd.k3d.lab (port 80, via Traefik).
source "$(dirname "$0")/lib.sh"

need helm
guard

echo "== Installation d'ArgoCD (chart $ARGOCD_CHART_VERSION) =="
helm upgrade --install argocd argo-cd \
  --repo https://argoproj.github.io/argo-helm \
  --version "$ARGOCD_CHART_VERSION" \
  --namespace argocd --create-namespace \
  --set dex.enabled=false \
  --set notifications.enabled=false \
  --set 'server.extraArgs={--insecure}' \
  --set server.ingress.enabled=true \
  --set "server.ingress.hostname=$ARGOCD_HOST" \
  --set server.ingress.ingressClassName=traefik \
  --set 'configs.cm.timeout\.reconciliation=30s' \
  --wait --timeout 10m

# --insecure : ArgoCD sert en HTTP derrière Traefik. Sans ça il redirige vers
#   HTTPS, que Traefik renvoie vers lui en HTTP : boucle de redirection.
# timeout.reconciliation : ArgoCD scrute git toutes les 3 minutes par défaut,
#   ce qui est intenable devant un public. 30s rend la démo fluide.

echo
echo "== ArgoCD prêt =="
echo "   URL      : http://$ARGOCD_HOST"
echo "   user     : admin"
echo -n "   password : "
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
echo
