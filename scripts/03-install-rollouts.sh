#!/usr/bin/env bash
# Installe le contrôleur Argo Rollouts et le plugin kubectl associé.
source "$(dirname "$0")/lib.sh"

need helm
guard

echo "== Installation d'Argo Rollouts (chart $ROLLOUTS_CHART_VERSION) =="
helm upgrade --install argo-rollouts argo-rollouts \
  --repo https://argoproj.github.io/argo-helm \
  --version "$ROLLOUTS_CHART_VERSION" \
  --namespace argo-rollouts --create-namespace \
  --wait --timeout 5m

# Le plugin kubectl n'est pas indispensable au fonctionnement, mais c'est lui qui
# affiche la progression d'un canary et qui permet de le promouvoir.
if ! kubectl argo rollouts version >/dev/null 2>&1; then
  echo "== Installation du plugin 'kubectl argo rollouts' dans ~/.local/bin =="
  mkdir -p "$HOME/.local/bin"
  curl -sSL -o "$HOME/.local/bin/kubectl-argo-rollouts" \
    https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-linux-amd64
  chmod +x "$HOME/.local/bin/kubectl-argo-rollouts"
fi

kubectl argo rollouts version
echo ">> Si la commande n'est pas trouvée hors de ce script, ajoute ~/.local/bin à ton PATH."
