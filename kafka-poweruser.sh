#!/usr/bin/env bash
set -euo pipefail

# Cria ou remove um conjunto de ACLs "quase-admin" sem usar super.users.
# Requer authorizer habilitado no broker: StandardAuthorizer (ou equivalente).

# =========================
# Defaults (pode sobrescrever via flags)
# =========================
BOOTSTRAP="${BOOTSTRAP:-localhost:9093}"
PRINCIPAL_USER="${PRINCIPAL_USER:-poweruser}"          # nome do principal Kafka (ex.: User:poweruser)
TOPIC_PATTERN="${TOPIC_PATTERN:-*}"                    # tópicos alvo (use '*' ou prefixos)
GROUP_PATTERN="${GROUP_PATTERN:-*}"                    # consumer groups alvo
TXNID_PATTERN="${TXNID_PATTERN:-*}"                    # transactional.id alvo
USER_ENTITY_PATTERN="${USER_ENTITY_PATTERN:-*}"        # para quotas/SCRAM (entity-type users)
KAFKA_BIN="${KAFKA_BIN:-/opt/kafka/bin}"               # diretório dos scripts kafka-*.sh
COMMAND_CONFIG="${COMMAND_CONFIG:-}"                   # arquivo de propriedades opcional p/ auth (ex.: client.properties)

# Modo de operação
DO_REMOVE="false"      # --remove ao invés de --add
DO_LIST="false"        # apenas listar ACLs do principal
DRY_RUN="false"        # só imprime os comandos (não executa)

usage() {
  cat <<EOF
Uso: $(basename "$0") [opções]

Opções:
  -b <host:porta>     Bootstrap server (padrão: ${BOOTSTRAP})
  -u <usuario>        Principal (sem o 'User:'), ex.: 'poweruser' (padrão: ${PRINCIPAL_USER})
  -t <padrão>         Padrão de tópicos (padrão: ${TOPIC_PATTERN})
  -g <padrão>         Padrão de consumer groups (padrão: ${GROUP_PATTERN})
  -x <padrão>         Padrão de transactional.id (padrão: ${TXNID_PATTERN})
  -U <padrão>         Padrão de usuários p/ quotas/SCRAM (entity users) (padrão: ${USER_ENTITY_PATTERN})
  -k <dir>            Diretório dos binários Kafka (padrão: ${KAFKA_BIN})
  -c <props>          Arquivo --command-config (auth SASL/TLS p/ CLI)
  -r                  Remover ACLs (ao invés de criar)
  -l                  Listar ACLs do principal e sair
  -n                  Dry-run (somente imprime os comandos)
  -h                  Ajuda

Exemplos:
  # Local: criar ACLs para User:poweruser
  $(basename "$0") -b localhost:9093 -u poweruser

  # Remoto com auth via arquivo de propriedades (SASL/OAUTH ou SCRAM)
  $(basename "$0") -b kafka-prod.internal:9093 -u svc-admin -c client.properties

  # Remover ACLs previamente criadas
  $(basename "$0") -b kafka-prod.internal:9093 -u svc-admin -r -c client.properties

  # Restringindo escopo a prefixos de tópicos e grupos
  $(basename "$0") -b localhost:9093 -u poweruser -t 'teamA-prod-' -g 'teamA-'
EOF
}

while getopts ":b:u:t:g:x:U:k:c:rlnh" opt; do
  case ${opt} in
    b) BOOTSTRAP="$OPTARG" ;;
    u) PRINCIPAL_USER="$OPTARG" ;;
    t) TOPIC_PATTERN="$OPTARG" ;;
    g) GROUP_PATTERN="$OPTARG" ;;
    x) TXNID_PATTERN="$OPTARG" ;;
    U) USER_ENTITY_PATTERN="$OPTARG" ;;
    k) KAFKA_BIN="$OPTARG" ;;
    c) COMMAND_CONFIG="$OPTARG" ;;
    r) DO_REMOVE="true" ;;
    l) DO_LIST="true" ;;
    n) DRY_RUN="true" ;;
    h) usage; exit 0 ;;
    \?) echo "Opção inválida: -$OPTARG" >&2; usage; exit 1 ;;
    :) echo "Opção -$OPTARG requer um valor." >&2; usage; exit 1 ;;
  done
done

ACL_TOOL="${KAFKA_BIN%/}/kafka-acls.sh"

if [[ ! -x "$ACL_TOOL" ]]; then
  echo "ERRO: não encontrei kafka-acls.sh em '$ACL_TOOL' (use -k para ajustar)" >&2
  exit 1
fi

PRINCIPAL="User:${PRINCIPAL_USER}"
ACTION_FLAG="--add"
$DO_REMOVE && ACTION_FLAG="--remove"

COMMON_FLAGS=(--bootstrap-server "$BOOTSTRAP")
[[ -n "$COMMAND_CONFIG" ]] && COMMON_FLAGS+=(--command-config "$COMMAND_CONFIG")

run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    printf '[DRY-RUN] %q ' "$ACL_TOOL"
    printf '%q ' "${COMMON_FLAGS[@]}"
    printf '%q ' "$@"
    printf '\n'
  else
    "$ACL_TOOL" "${COMMON_FLAGS[@]}" "$@"
  fi
}

if [[ "$DO_LIST" == "true" ]]; then
  run --list
  exit 0
fi

echo "==> Aplicando ACLs ($ACTION_FLAG) para principal: ${PRINCIPAL}"
echo "    Bootstrap: ${BOOTSTRAP}"
[[ -n "$COMMAND_CONFIG" ]] && echo "    Command-config: ${COMMAND_CONFIG}"
echo

# -------------------------
# 1) Cluster – administração geral
# -------------------------
run "$ACTION_FLAG" --allow-principal "$PRINCIPAL" \
  --operation Alter --operation Describe \
  --operation ClusterAction --operation IdempotentWrite \
  --cluster

# -------------------------
# 2) Cluster – Alter/Describe configs
# -------------------------
run "$ACTION_FLAG" --allow-principal "$PRINCIPAL" \
  --operation AlterConfigs --operation DescribeConfigs \
  --cluster

# -------------------------
# 3) Tópicos (todos ou prefixo)
# -------------------------
run "$ACTION_FLAG" --allow-principal "$PRINCIPAL" \
  --operation Create --operation Delete --operation Alter \
  --operation Describe --operation DescribeConfigs --operation AlterConfigs \
  --topic "$TOPIC_PATTERN" --resource-pattern-type $( [[ "$TOPIC_PATTERN" == "*" ]] && echo literal || echo prefixed )

# Observação: se TOPIC_PATTERN='*' usamos literal; se for 'prefixo-' usamos prefixed.

# -------------------------
# 4) Consumer Groups (todos ou prefixo)
# -------------------------
run "$ACTION_FLAG" --allow-principal "$PRINCIPAL" \
  --operation Describe --operation Delete --operation Read \
  --group "$GROUP_PATTERN" --resource-pattern-type $( [[ "$GROUP_PATTERN" == "*" ]] && echo literal || echo prefixed )

# -------------------------
# 5) Transactional Ids (opcional)
# -------------------------
run "$ACTION_FLAG" --allow-principal "$PRINCIPAL" \
  --operation Describe --operation Write \
  --transactional-id "$TXNID_PATTERN" --resource-pattern-type $( [[ "$TXNID_PATTERN" == "*" ]] && echo literal || echo prefixed )

# -------------------------
# 6) Users (quotas e SCRAM) – entity-type users
# -------------------------
run "$ACTION_FLAG" --allow-principal "$PRINCIPAL" \
  --operation Alter --operation Describe \
  --user "$USER_ENTITY_PATTERN" --resource-pattern-type $( [[ "$USER_ENTITY_PATTERN" == "*" ]] && echo literal || echo prefixed )

echo
echo "==> Concluído."
echo "    Para listar ACLs atuais:"
echo "       $ACL_TOOL ${COMMON_FLAGS[*]} --list"