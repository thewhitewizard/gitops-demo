#!/usr/bin/env bash
# Supprime le cluster du lab et son kubeconfig. Rien d'autre.
source "$(dirname "$0")/lib.sh"

if cluster_exists "$CLUSTER"; then
  echo "== Suppression du cluster '$CLUSTER' =="
  env -u KUBECONFIG k3d cluster delete "$CLUSTER"
else
  echo ">> Le cluster '$CLUSTER' n'existe pas."
fi

rm -f "$KUBECONFIG"
echo ">> Fait. Les entrées /etc/hosts, elles, restent en place."
