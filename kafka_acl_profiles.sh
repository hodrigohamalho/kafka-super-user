#!/usr/bin/env bash
set -euo pipefail

# kafka_acl_profiles.sh
# Perfis de ACL parametrizáveis para Kafka:
#   --mode admin       : "quase-admin" humano/CI (NÃO usa super.users)
#   --mode broker-zk   : broker em modo ZooKeeper (quando super.users é proibido)
#   --mode broker-kraft: broker em modo KRaft (quando super.users é proibido)
# ========== Defaults ==========
BOOTSTRAP="${BOOTSTRAP:-localhost:9093}"
PRINCIPAL_USER="${PRINCIPAL_USER:-poweruser}"         # nome sem o prefixo 'User:'
MODE="${MODE:-admin}"                                  # admin | broker-zk | broker-kraft
TOPIC_PATTERN="${TOPIC_PATTERN:-*}"                    # '*' (literal) ou prefixo (ex.: teamA-)
GROUP_PATTERN="${GROUP_PATTERN:-*}"                    # '*' ou prefixo
TXNID_PATTERN="${TXNID_PATTERN:-*}"                    # '*' ou prefixo
USER_ENTITY_PATTERN="${USER_ENTITY_PATTERN:-*}"        # quotas/SCRAM: '*' ou prefixo
KAFKA_BIN="${KAFKA_BIN:-/opt/kafka/bin}"              # diretório dos kafka-*.sh
COMMAND_CONFIG="${COMMAND_CONFIG:-}"                   # arquivo de props p/ CLI (SASL/TLS)
STRICT="false"                                        # para broker-* (mínimo prático)
DO_REMOVE="false"
DO_LIST="false"
DRY_RUN="false"

usage() {
  cat <<EOF
Uso: $(basename "$0") [opções]

Perfis:
  --mode admin        : usuário de operação/CI com poderes administrativos via ACL (sem super.users)
  --mode broker-zk    : principal do broker em ZooKeeper mode (quando não pode usar super.users)
  --mode broker-kraft : principal do broker em KRaft mode (quando não pode usar super.users)

Opções:
  -b <host:porta>     Bootstrap server (padrão: ${BOOTSTRAP})
  -u <usuario>        Principal sem 'User:' (ex.: ops-admin, broker-1) (padrão: ${PRINCIPAL_USER})
  -m <modo>           admin | broker-zk | broker-kraft (padrão: ${MODE})
  -t <padrão>         Padrão de tópicos (padrão: ${TOPIC_PATTERN})
  -g <padrão>         Padrão de consumer groups (padrão: ${GROUP_PATTERN})
  -x <padrão>         Padrão de transactional.id (padrão: ${TXNID_PATTERN})
  -U <padrão>         Padrão de usuários (entity users) p/ quotas/SCRAM (padrão: ${USER_ENTITY_PATTERN})
  -k <dir>            Diretório dos binários Kafka (padrão: ${KAFKA_BIN})
  -c <props>          Arquivo --command-config (auth SASL/TLS p/ CLI)
  --strict            Para broker-{zk|kraft}: aplica conjunto "mínimo prático" (default é amplo/seguro)
  -r                  Remover ACLs ao invés de criar
  -l                  Listar ACLs existentes e sair
  -n                  Dry-run (só imprime comandos)
  -h                  Ajuda

Exemplos:
  # Admin (quase-admin) local
  $(basename "$0") -m admin -b localhost:9093 -u ops-admin

  # Admin remoto com auth da CLI
  $(basename "$0") -m admin -b kafka-prod:9093 -u ops-admin -c client.properties

  # Broker em ZK (pacote amplo)
  $(basename "$0") -m broker-zk -b localhost:9093 -u broker-1

  # Broker em ZK (mínimo prático)
  $(basename "$0") -m broker-zk -b kafka-prod:9093 -u broker-1 --strict -c client.properties

  # Broker em KRaft (pacote amplo)
  $(basename "$0") -m broker-kraft -b kafka-dev:9093 -u broker-1
EOF
}

# Parse flags
OPTS=$(getopt -o b:u:m:t:g:x:U:k:c:rlnh --long strict -- "$@") || { usage; exit 1; }
eval set -- "$OPTS"
while true; do
  case "$1" in
    -b) BOOTSTRAP="$2"; shift 2;;
    -u) PRINCIPAL_USER="$2"; shift 2;;
    -m) MODE="$2"; shift 2;;
    -t) TOPIC_PATTERN="$2"; shift 2;;
    -g) GROUP_PATTERN="$2"; shift 2;;
    -x) TXNID_PATTERN="$2"; shift 2;;
    -U) USER_ENTITY_PATTERN="$2"; shift 2;;
    -k) KAFKA_BIN="$2"; shift 2;;
    -c) COMMAND_CONFIG="$2"; shift 2;;
    --strict) STRICT="true"; shift 1;;
    -r) DO_REMOVE="true"; shift 1;;
    -l) DO_LIST="true"; shift 1;;
    -n) DRY_RUN="true"; shift 1;;
    -h) usage; exit 0;;
    --) shift; break;;
    *) usage; exit 1;;
  esac
done

ACL_TOOL="${KAFKA_BIN%/}/kafka-acls.sh"
[[ -x "$ACL_TOOL" ]] || { echo "ERRO: kafka-acls.sh não encontrado em '$ACL_TOOL' (use -k)"; exit 1; }

PRINCIPAL="User:${PRINCIPAL_USER}"
ACTION_FLAG="--add"; $DO_REMOVE && ACTION_FLAG="--remove"
COMMON_FLAGS=(--bootstrap-server "$BOOTSTRAP")
[[ -n "$COMMAND_CONFIG" ]] && COMMON_FLAGS+=(--command-config "$COMMAND_CONFIG")

resource_pattern_type() {
  local p="$1"
  if [[ "$p" == "*" ]]; then echo literal; else echo prefixed; fi
}

run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    printf '[DRY-RUN] %q ' "$ACL_TOOL"; printf '%q ' "${COMMON_FLAGS[@]}"; printf '%q ' "$@"; printf '\n'
  else
    "$ACL_TOOL" "${COMMON_FLAGS[@]}" "$@"
  fi
}

if [[ "$DO_LIST" == "true" ]]; then
  run --list
  exit 0
fi

echo "==> Perfil: $MODE | Principal: $PRINCIPAL | Bootstrap: $BOOTSTRAP"
[[ -n "$COMMAND_CONFIG" ]] && echo "    CLI auth: $COMMAND_CONFIG"
echo

# -------------------- Profiles --------------------

apply_admin() {
  # 1) Cluster – administração geral
  run "$ACTION_FLAG" --allow-principal "$PRINCIPAL" \
    --operation Alter --operation Describe \
    --operation ClusterAction --operation IdempotentWrite \
    --cluster

  # 2) Cluster – Alter/Describe configs
  run "$ACTION_FLAG" --allow-principal "$PRINCIPAL" \
    --operation AlterConfigs --operation DescribeConfigs \
    --cluster

  # 3) Tópicos (todos/prefixo)
  run "$ACTION_FLAG" --allow-principal "$PRINCIPAL" \
    --operation Create --operation Delete --operation Alter \
    --operation Describe --operation DescribeConfigs --operation AlterConfigs \
    --topic "$TOPIC_PATTERN" --resource-pattern-type "$(resource_pattern_type "$TOPIC_PATTERN")"

  # 4) Consumer Groups
  run "$ACTION_FLAG" --allow-principal "$PRINCIPAL" \
    --operation Describe --operation Delete --operation Read \
    --group "$GROUP_PATTERN" --resource-pattern-type "$(resource_pattern_type "$GROUP_PATTERN")"

  # 5) Transactional Ids (se aplicável)
  run "$ACTION_FLAG" --allow-principal "$PRINCIPAL" \
    --operation Describe --operation Write \
    --transactional-id "$TXNID_PATTERN" --resource-pattern-type "$(resource_pattern_type "$TXNID_PATTERN")"

  # 6) Users (quotas/SCRAM)
  run "$ACTION_FLAG" --allow-principal "$PRINCIPAL" \
    --operation Alter --operation Describe \
    --user "$USER_ENTITY_PATTERN" --resource-pattern-type "$(resource_pattern_type "$USER_ENTITY_PATTERN")"
}

apply_broker_minimal() {
  # Cluster: controle
  run "$ACTION_FLAG" --allow-principal "$PRINCIPAL" \
    --operation Describe --operation ClusterAction --operation IdempotentWrite \
    --cluster

  # Tópicos de dados: replicação/metadata (Read/Describe)
  run "$ACTION_FLAG" --allow-principal "$PRINCIPAL" \
    --operation Read --operation Describe \
    --topic "$TOPIC_PATTERN" --resource-pattern-type "$(resource_pattern_type "$TOPIC_PATTERN")"

  # Tópicos internos críticos
  for t in "__consumer_offsets" "__transaction_state"; do
    run "$ACTION_FLAG" --allow-principal "$PRINCIPAL" \
      --operation Read --operation Write --operation Create \
      --topic "$t"
  done
}

apply_broker_wide() {
  # Cluster: controle
  run "$ACTION_FLAG" --allow-principal "$PRINCIPAL" \
    --operation Describe --operation ClusterAction --operation IdempotentWrite \
    --cluster

  # Tópicos de dados: pacote amplo (evita negações em reassign/alterações/partitions)
  run "$ACTION_FLAG" --allow-principal "$PRINCIPAL" \
    --operation Read --operation Write --operation Describe \
    --operation Alter --operation AlterConfigs --operation DescribeConfigs \
    --topic "$TOPIC_PATTERN" --resource-pattern-type "$(resource_pattern_type "$TOPIC_PATTERN")"

  # Tópicos internos críticos
  for t in "__consumer_offsets" "__transaction_state"; do
    run "$ACTION_FLAG" --allow-principal "$PRINCIPAL" \
      --operation Read --operation Write --operation Create \
      --topic "$t"
  done
}

case "$MODE" in
  admin)
    apply_admin
    ;;
  broker-zk)
    if [[ "$STRICT" == "true" ]]; then
      apply_broker_minimal
    else
      apply_broker_wide
    fi
    ;;
  broker-kraft)
    # Em termos de ACLs de dados/controle, KRaft e ZK são equivalentes do ponto de vista de clientes/brokers.
    if [[ "$STRICT" == "true" ]]; then
      apply_broker_minimal
    else
      apply_broker_wide
    fi
    ;;
  *)
    echo "ERRO: modo inválido: $MODE (use admin | broker-zk | broker-kraft)"; exit 1;;
esac

echo
echo "==> Concluído. Para listar ACLs:"
echo "    $ACL_TOOL ${COMMON_FLAGS[*]} --list"