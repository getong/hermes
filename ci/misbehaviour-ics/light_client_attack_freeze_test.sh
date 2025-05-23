#!/bin/bash
# shellcheck disable=2086

set -eu

DEBUG=${DEBUG:-false}

if [ "$DEBUG" = true ]; then
    set -x
fi

diag() {
  echo ">>
>> $*
>>" 1>&2
}

waiting() {
    secs=$1
    shift
    msg="$*"
    while [ $secs -gt 0 ]
    do
        echo -ne "|| Waiting $msg (${secs}s)\033[0K\r"
        sleep 1
        : $((secs--))
    done
    echo "|| Waiting $msg (done)"
}


# User balance of stake tokens 
USER_COINS="100000000000stake"
# Amount of stake tokens staked
STAKE="100000000stake"
# Amount of stake tokens staked
STAKE2="4000000stake"
# Node IP address
NODE_IP="127.0.0.1"

# Home directory
HOME_DIR=$HOME

# Hermes debug
if [ "$DEBUG" = true ]; then
    HERMES_DEBUG="--debug=rpc"
else
    HERMES_DEBUG=""
fi

# Hermes config
HERMES_CONFIG="$HOME_DIR/hermes.toml"
HERMES_CONFIG_FORK="$HOME_DIR/hermes-fork.toml"
# Hermes binary
HERMES_BIN="cargo run -q --bin hermes -- $HERMES_DEBUG --config $HERMES_CONFIG"
HERMES_BIN_FORK="cargo run -q --bin hermes -- $HERMES_DEBUG --config $HERMES_CONFIG_FORK"

# Validator moniker
MONIKER="coordinator"
MONIKER_SUB="sub"

# Validator directory
PROV_NODE_DIR=${HOME_DIR}/provider-${MONIKER}
PROV_NODE_SUB_DIR=${HOME_DIR}/provider-${MONIKER_SUB}
CONS_NODE_DIR=${HOME_DIR}/consumer-${MONIKER}
CONS_NODE_SUB_DIR=${HOME_DIR}/consumer-${MONIKER_SUB}
CONS_FORK_NODE_DIR=${HOME_DIR}/consumer-fork-${MONIKER}

# Coordinator key
PROV_KEY=${MONIKER}-key
PROV_KEY_SUB=${MONIKER_SUB}-key


# Clean start
pkill -f interchain-security-pd &> /dev/null || true
pkill -f interchain-security-cd &> /dev/null || true
pkill -f hermes &> /dev/null || true

mkdir -p "${HOME_DIR}"
rm -rf "${PROV_NODE_DIR}"
rm -rf "${PROV_NODE_SUB_DIR}"
rm -rf "${CONS_NODE_DIR}"
rm -rf "${CONS_NODE_SUB_DIR}"
rm -rf "${CONS_FORK_NODE_DIR}"

# Build genesis file and node directory structure
interchain-security-pd init $MONIKER --chain-id provider --home ${PROV_NODE_DIR}
jq ".app_state.gov.params.voting_period = \"5s\"  \
| .app_state.gov.params.expedited_voting_period = \"4s\" \
| .app_state.staking.params.unbonding_time = \"86400s\"  \
| .app_state.provider.params.blocks_per_epoch = \"5\"" \
   ${PROV_NODE_DIR}/config/genesis.json > \
   ${PROV_NODE_DIR}/edited_genesis.json && mv ${PROV_NODE_DIR}/edited_genesis.json ${PROV_NODE_DIR}/config/genesis.json

# Create account keypair
interchain-security-pd keys add $PROV_KEY --home ${PROV_NODE_DIR} --keyring-backend test --output json > ${PROV_NODE_DIR}/${PROV_KEY}.json 2>&1

# Add stake to user
PROV_ACCOUNT_ADDR=$(jq -r '.address' ${PROV_NODE_DIR}/${PROV_KEY}.json)
interchain-security-pd genesis add-genesis-account "$PROV_ACCOUNT_ADDR" $USER_COINS --home ${PROV_NODE_DIR} --keyring-backend test

# Stake 1/1000 user's coins
interchain-security-pd genesis gentx $PROV_KEY $STAKE --chain-id provider --home ${PROV_NODE_DIR} --keyring-backend test --moniker $MONIKER

## config second node

rm -rf ${PROV_NODE_SUB_DIR}

# Build genesis file and node directory structure
interchain-security-pd init $MONIKER_SUB --chain-id provider --home ${PROV_NODE_SUB_DIR}

# Create account keypair
interchain-security-pd keys add $PROV_KEY_SUB --home ${PROV_NODE_SUB_DIR} --keyring-backend test --output json > ${PROV_NODE_SUB_DIR}/${PROV_KEY_SUB}.json 2>&1

cp ${PROV_NODE_DIR}/config/genesis.json  ${PROV_NODE_SUB_DIR}/config/genesis.json

# Add stake to user
PROV_ACCOUNT_ADDR=$(jq -r '.address' ${PROV_NODE_SUB_DIR}/${PROV_KEY_SUB}.json)
interchain-security-pd genesis add-genesis-account "$PROV_ACCOUNT_ADDR" $USER_COINS --home ${PROV_NODE_SUB_DIR} --keyring-backend test

cp -r ${PROV_NODE_DIR}/config/gentx/ ${PROV_NODE_SUB_DIR}/config/gentx/

# # Stake 1/1000 user's coins
interchain-security-pd genesis gentx $PROV_KEY_SUB $STAKE2 --chain-id provider --home ${PROV_NODE_SUB_DIR} --keyring-backend test --moniker $MONIKER_SUB

interchain-security-pd genesis collect-gentxs --home ${PROV_NODE_SUB_DIR} --gentx-dir ${PROV_NODE_SUB_DIR}/config/gentx/

cp ${PROV_NODE_SUB_DIR}/config/genesis.json  ${PROV_NODE_DIR}/config/genesis.json


# Start nodes

sed -i -r "/node =/ s/= .*/= \"tcp:\/\/${NODE_IP}:26658\"/" ${PROV_NODE_DIR}/config/client.toml
sed -i -r 's/timeout_commit = "5s"/timeout_commit = "3s"/g' ${PROV_NODE_DIR}/config/config.toml
sed -i -r 's/timeout_propose = "3s"/timeout_propose = "1s"/g' ${PROV_NODE_DIR}/config/config.toml
sed -i -r 's/block_sync = true/block_sync = false/g' ${PROV_NODE_DIR}/config/config.toml

# Start gaia
interchain-security-pd start \
    --home ${PROV_NODE_DIR} \
    --rpc.laddr tcp://${NODE_IP}:26658 \
    --grpc.address ${NODE_IP}:9091 \
    --address tcp://${NODE_IP}:26655 \
    --p2p.laddr tcp://${NODE_IP}:26656 \
    --grpc-web.enable=false &> ${PROV_NODE_DIR}/logs &

waiting 10 "for provider node to start"

sed -i -r "/node =/ s/= .*/= \"tcp:\/\/${NODE_IP}:26628\"/" ${PROV_NODE_SUB_DIR}/config/client.toml
sed -i -r 's/timeout_commit = "5s"/timeout_commit = "3s"/g' ${PROV_NODE_SUB_DIR}/config/config.toml
sed -i -r 's/timeout_propose = "3s"/timeout_propose = "1s"/g' ${PROV_NODE_SUB_DIR}/config/config.toml
sed -i -r 's/block_sync = true/block_sync = false/g' ${PROV_NODE_SUB_DIR}/config/config.toml

# Start gaia
interchain-security-pd start \
    --home ${PROV_NODE_SUB_DIR} \
    --rpc.laddr tcp://${NODE_IP}:26628 \
    --grpc.address ${NODE_IP}:9021 \
    --address tcp://${NODE_IP}:26625 \
    --p2p.laddr tcp://${NODE_IP}:26626 \
    --grpc-web.enable=false &> ${PROV_NODE_SUB_DIR}/logs &

waiting 10 "for provider sub-node to start"

# Build consumer chain proposal file
tee ${PROV_NODE_DIR}/create-consumer-msg.json<<EOF
{
	"chain_id" : "consumer",
	"metadata": {
        "name": "consumer-1-metadata-name",
        "description":"consumer-1-metadata-description",
        "metadata": "consumer-1-metadata-metadata"
    },
    "initialization_parameters": {
        "initial_height": {
            "revision_number": 0,
            "revision_height": 1
        },
        "genesis_hash": "Z2VuX2hhc2g=",
        "binary_hash": "YmluX2hhc2g=",
        "spawn_time": "2024-08-29T12:26:16.529913Z",
        "unbonding_period": 1728000000000000,
        "ccv_timeout_period": 2419200000000000,
        "transfer_timeout_period": 1800000000000,
        "consumer_redistribution_fraction": "0.75",
        "blocks_per_distribution_transmission": 1000,
        "historical_entries": 10000,
        "distribution_transmission_channel": ""
    },
    "power_shaping_parameters": {
        "top_N": 0,
        "validators_power_cap": 0,
        "validator_set_cap": 0,
        "allowlist": [],
        "denylist": [],
        "min_stake": 0,
        "allow_inactive_vals": false
    }
}
EOF

TX_RES=$(interchain-security-pd tx provider create-consumer \
    ${PROV_NODE_DIR}/create-consumer-msg.json \
    --chain-id provider \
    --from $PROV_KEY \
    --keyring-backend test \
    --home $PROV_NODE_DIR \
    --node tcp://${NODE_IP}:26658 \
    -o json -y)

sleep 5

TX_RES=$(interchain-security-pd q tx --type=hash $(echo $TX_RES | jq -r '.txhash') \
    --home ${PROV_NODE_DIR} \
    --node tcp://${NODE_IP}:26658 \
    -o json)


echo $TX_RES | jq .code

if [ "$(echo $TX_RES | jq -r .code )" != "0" ]; then
  echo consumer creation failed with code: $(echo $TX_RES | jq .code )
  exit 1
fi


EVENTS=$(echo $TX_RES | jq -c '.events[]')
found=false
CONSUMER_ID=""
while IFS= read -r event; do
    type=$(echo "$event" | jq -r '.type')
    echo $type
    if [ "$type" = "create_consumer" ]; then
        attrs=$(echo $event | jq -c '.attributes[]')
        while IFS= read -r attr; do
            key=$(echo "$attr" | jq -r '.key')
            if [ "$key" = "consumer_id" ]; then
                CONSUMER_ID=$(echo "$attr" | jq -r '.value')
                found=true
                break 2
            fi
       done <<< "$attrs"
    fi
done <<< "$EVENTS"

if [ "$found" = false ]; then
    echo "consumer creation event not found"
    exit 1
fi

echo "consumer created: $CONSUMER_ID"


AUTHORITY=cosmos10d07y265gmmuvt4z0w9aw880jnsr700j6zn9kn
PROV_ACCOUNT_ADDR=$(jq -r '.address' ${PROV_NODE_DIR}/${PROV_KEY}.json)

## Grant the consumer ownership to the Gov module
tee ${PROV_NODE_DIR}/update-consumer-msg.json<<EOF
{
	"consumer_id" : "$CONSUMER_ID",
    "owner_address": "$PROV_ACCOUNT_ADDR",
    "new_owner_address": "$AUTHORITY",
	"metadata": $(jq -r '.metadata' ${PROV_NODE_DIR}/create-consumer-msg.json)
}
EOF

TX_RES=$(interchain-security-pd tx provider update-consumer \
    ${PROV_NODE_DIR}/update-consumer-msg.json \
    --chain-id provider \
    --from $PROV_KEY \
    --keyring-backend test \
    --home $PROV_NODE_DIR \
    --node tcp://${NODE_IP}:26658 \
    -o json -y)

sleep 5

## Update consumer to TopN by submitting a gov proposal
tee ${PROV_NODE_DIR}/consumer_prop.json<<EOF
{
    "messages": [
        {
            "@type": "/interchain_security.ccv.provider.v1.MsgUpdateConsumer",
            "consumer_id": "${CONSUMER_ID}",
            "owner": "$AUTHORITY",
            "metadata": $(jq -r '.metadata' ${PROV_NODE_DIR}/create-consumer-msg.json),
            "initialization_parameters": {
                "initial_height": {
                    "revision_number": 0,
                    "revision_height": 1
                },
                "genesis_hash": "2D5C2110941DA54BE07CBB9FACD7E4A2E3253E79BE7BE3E5A1A7BDA518BAA4BE",
                "binary_hash": "2D5C2110941DA54BE07CBB9FACD7E4A2E3253E79BE7BE3E5A1A7BDA518BAA4BE",
                "spawn_time": "2023-03-11T09:02:14.718477-08:00",
                "ccv_timeout_period": "2419200s",
                "unbonding_period": "2419200s",
                "transfer_timeout_period": "3600s",
                "consumer_redistribution_fraction": "0.75",
                "blocks_per_distribution_transmission": 1500,
                "historical_entries": 1000,
                "distribution_transmission_channel": ""
            },
            "power_shaping_parameters": {
                "top_N": 100,
                "validators_power_cap": 0,
                "validator_set_cap": 50,
                "allowlist": [],
                "denylist": [],
                "min_stake": 1000,
                "allow_inactive_vals": true
            }
        }
    ],
    "metadata": "ipfs://CID",
    "deposit": "10000000stake",
    "title": "\"update consumer 0 to top N\"",
    "summary": "\"update consumer 0 to top N\"",
    "expedited": false
}
EOF

PROP_ID=1

interchain-security-pd tx gov submit-proposal ${PROV_NODE_DIR}/consumer_prop.json \
    --chain-id provider \
    --from $PROV_KEY \
    --keyring-backend test \
    --home $PROV_NODE_DIR \
    --node tcp://${NODE_IP}:26658 \
    -o json -y

waiting 3 "for proposal to be submitted"

# Vote yes to proposal
interchain-security-pd tx gov vote 1 yes --from $PROV_KEY --chain-id provider --home ${PROV_NODE_DIR} -y --keyring-backend test

# CONSUMER CHAIN ##

### Assert that the proposal for the consumer chain passed
PROPOSAL_STATUS_PASSED="PROPOSAL_STATUS_PASSED"
MAX_TRIES=10
TRIES=0

cat ${PROV_NODE_DIR}/config/genesis.json | grep "period"

while [ $TRIES -lt $MAX_TRIES ]; do
    output=$(interchain-security-pd query gov proposal 1 --home ${PROV_NODE_DIR} --node tcp://${NODE_IP}:26658 --output json)

    proposal_status=$(echo "$output" | grep -o '"status": "[^"]*' | awk -F ': "' '{print $2}')
    if [ "$proposal_status" = "$PROPOSAL_STATUS_PASSED" ]; then
        echo "Proposal status is now $proposal_status. Exiting loop."
        break
    else
        echo "Proposal status is $proposal_status. Continuing to check..."
    fi
    TRIES=$((TRIES + 1))

    sleep 2
done

if [ $TRIES -eq $MAX_TRIES ]; then
    echo "[ERROR] Failed due to an issue with the consumer proposal"
    echo "This is likely due to a misconfiguration in the test script."
    exit 0
fi

sleep 6

# Build genesis file and node directory structure
interchain-security-cd init $MONIKER --chain-id consumer  --home  ${CONS_NODE_DIR}

# Create user account keypair
interchain-security-cd keys add $PROV_KEY --home  ${CONS_NODE_DIR} --keyring-backend test --output json > ${CONS_NODE_DIR}/${PROV_KEY}.json 2>&1

# Add stake to user account
CONS_ACCOUNT_ADDR=$(jq -r '.address' ${CONS_NODE_DIR}/${PROV_KEY}.json)
interchain-security-cd genesis add-genesis-account "$CONS_ACCOUNT_ADDR" 1000000000stake --home ${CONS_NODE_DIR}

# Add consumer genesis states to genesis file
interchain-security-pd query provider consumer-genesis $CONSUMER_ID --home ${PROV_NODE_DIR} -o json > consumer_gen.json
jq -s '.[0].app_state.ccvconsumer = .[1] | .[0]' ${CONS_NODE_DIR}/config/genesis.json consumer_gen.json > ${CONS_NODE_DIR}/edited_genesis.json \
&& mv ${CONS_NODE_DIR}/edited_genesis.json ${CONS_NODE_DIR}/config/genesis.json
rm consumer_gen.json

# Create validator states
echo '{"height": "0","round": 0,"step": 0}' > ${CONS_NODE_DIR}/data/priv_validator_state.json

# Copy validator key files
cp ${PROV_NODE_DIR}/config/priv_validator_key.json ${CONS_NODE_DIR}/config/priv_validator_key.json
cp ${PROV_NODE_DIR}/config/node_key.json ${CONS_NODE_DIR}/config/node_key.json

# Set default client port
sed -i -r "/node =/ s/= .*/= \"tcp:\/\/${NODE_IP}:26648\"/" ${CONS_NODE_DIR}/config/client.toml
sed -i -r 's/block_sync = true/block_sync = false/g' ${CONS_NODE_DIR}/config/config.toml


# Start gaia
interchain-security-cd start --home ${CONS_NODE_DIR} \
        --rpc.laddr tcp://${NODE_IP}:26648 \
        --grpc.address ${NODE_IP}:9081 \
        --address tcp://${NODE_IP}:26645 \
        --p2p.laddr tcp://${NODE_IP}:26646 \
        --grpc-web.enable=false \
        &> ${CONS_NODE_DIR}/logs &

waiting 20 "for consumer node to start"

tee ${HERMES_CONFIG}<<EOF
[global]
log_level = "debug"

[mode]

[mode.clients]
enabled = true
refresh = true
misbehaviour = true

[mode.connections]
enabled = false

[mode.channels]
enabled = false

[mode.packets]
enabled = true

[[chains]]
id = "consumer"
type = "CosmosSdk"
ccv_consumer_chain = true
account_prefix = "cosmos"
clock_drift = "5s"
gas_multiplier = 1.1
grpc_addr = "tcp://${NODE_IP}:9081"
key_name = "relayer"
max_gas = 2000000
rpc_addr = "http://${NODE_IP}:26648"
rpc_timeout = "10s"
store_prefix = "ibc"
trusting_period = "2days"
event_source = { mode = 'pull', interval = '500ms', max_retries = 4 }

[chains.gas_price]
       denom = "stake"
       price = 0.00

[chains.trust_threshold]
       denominator = "3"
       numerator = "1"

[[chains]]
id = "provider"
type = "CosmosSdk"
account_prefix = "cosmos"
clock_drift = "5s"
gas_multiplier = 1.1
grpc_addr = "tcp://${NODE_IP}:9091"
key_name = "relayer"
max_gas = 2000000
rpc_addr = "http://${NODE_IP}:26658"
rpc_timeout = "10s"
store_prefix = "ibc"
trusting_period = "2days"
event_source = { mode = 'pull', interval = '500ms', max_retries = 4 }

[chains.gas_price]
       denom = "stake"
       price = 0.00

[chains.trust_threshold]
       denominator = "3"
       numerator = "1"
EOF

# Delete all previous keys in relayer
$HERMES_BIN keys delete --chain consumer --all
$HERMES_BIN keys delete --chain provider --all

# Restore keys to hermes relayer
$HERMES_BIN keys add --key-file  ${CONS_NODE_DIR}/${PROV_KEY}.json --chain consumer
$HERMES_BIN keys add --key-file  ${PROV_NODE_DIR}/${PROV_KEY}.json --chain provider

waiting 5 "for a block"

# CCV connection 
$HERMES_BIN create connection \
    --a-chain consumer \
    --a-client 07-tendermint-0 \
    --b-client 07-tendermint-0

# Dummy client and connection for the test
$HERMES_BIN create client \
    --host-chain provider \
    --reference-chain consumer \
    --trusting-period 57600s

$HERMES_BIN create client \
    --host-chain consumer \
    --reference-chain provider \
    --trusting-period 57600s

$HERMES_BIN create connection \
    --a-chain consumer \
    --a-client 07-tendermint-1 \
    --b-client 07-tendermint-1

# CCV channel
$HERMES_BIN create channel \
    --a-chain consumer \
    --a-port consumer \
    --b-port provider \
    --order ordered \
    --channel-version 1 \
    --a-connection connection-0

waiting 5 "for a block"

# Find trusted state before fork
$HERMES_BIN --json query client consensus --chain provider --client 07-tendermint-0
TRUSTED_HEIGHT="$($HERMES_BIN --json query client consensus --chain provider --client 07-tendermint-0 | tail -n 1 | jq '.result[2].revision_height')"
diag "Trusted height: $TRUSTED_HEIGHT"

interchain-security-pd q tendermint-validator-set --home ${PROV_NODE_DIR}
interchain-security-cd q tendermint-validator-set --home ${CONS_NODE_DIR}

waiting 5 "for a block"

##### Fork consumer

tee ${HERMES_CONFIG_FORK}<<EOF
[global]
log_level = "debug"

[mode]

[mode.clients]
enabled = true
refresh = true
misbehaviour = true

[mode.connections]
enabled = false

[mode.channels]
enabled = false

[mode.packets]
enabled = true

[[chains]]
id = "consumer"
type = "CosmosSdk"
ccv_consumer_chain = true
account_prefix = "cosmos"
clock_drift = "5s"
gas_multiplier = 1.1
grpc_addr = "tcp://${NODE_IP}:9071"
key_name = "relayer"
max_gas = 2000000
rpc_addr = "http://${NODE_IP}:26638"
rpc_timeout = "10s"
store_prefix = "ibc"
trusting_period = "2days"
event_source = { mode = 'pull', interval = '500ms', max_retries = 4 }

[chains.gas_price]
       denom = "stake"
       price = 0.00

[chains.trust_threshold]
       denominator = "3"
       numerator = "1"

[[chains]]
id = "provider"
type = "CosmosSdk"
account_prefix = "cosmos"
clock_drift = "5s"
gas_multiplier = 1.1
grpc_addr = "tcp://${NODE_IP}:9091"
key_name = "relayer"
max_gas = 2000000
rpc_addr = "http://${NODE_IP}:26658"
rpc_timeout = "10s"
store_prefix = "ibc"
trusting_period = "2days"
event_source = { mode = 'pull', interval = '500ms', max_retries = 4 }

[chains.gas_price]
       denom = "stake"
       price = 0.00

[chains.trust_threshold]
       denominator = "3"
       numerator = "1"
EOF

waiting 10 "for a couple blocks"

read -r height hash < <(
	curl -s "localhost:26648"/commit \
		| jq -r '(.result//.).signed_header.header.height + " " + (.result//.).signed_header.commit.block_id.hash')
diag "Fork => Height: ${height}, Hash: ${hash}"

cp -r ${CONS_NODE_DIR} ${CONS_FORK_NODE_DIR}
# Set default client port
sed -i -r "/node =/ s/= .*/= \"tcp:\/\/${NODE_IP}:26638\"/" ${CONS_FORK_NODE_DIR}/config/client.toml
sed -i -r 's/block_sync = true/block_sync = false/g' ${CONS_FORK_NODE_DIR}/config/config.toml


# Start gaia
interchain-security-cd start --home  ${CONS_FORK_NODE_DIR} \
        --rpc.laddr tcp://${NODE_IP}:26638 \
        --grpc.address ${NODE_IP}:9071 \
        --address tcp://${NODE_IP}:26635 \
        --p2p.laddr tcp://${NODE_IP}:26636 \
        --grpc-web.enable=false \
        &> ${CONS_FORK_NODE_DIR}/logs &

waiting 5 "for forked consumer node to start"

diag "Start Hermes relayer multi-chain mode"

$HERMES_BIN start &> ${HOME_DIR}/hermes-start-logs.txt &

# If we sleep 5 here and below, we end up on the forked block later
waiting 10 "for Hermes relayer to start"

diag "Running Hermes relayer evidence command"

# Run hermes in evidence mode
$HERMES_BIN evidence --chain consumer &> ${HOME_DIR}/hermes-evidence-logs.txt &

# If we sleep 5 here and above, we end up on the forked block later
waiting 10 "for Hermes evidence monitor to start"

diag "Updating client on forked chain using trusted height $TRUSTED_HEIGHT"
$HERMES_BIN_FORK update client --client 07-tendermint-0 --host-chain provider --trusted-height "$TRUSTED_HEIGHT"

waiting 20 "for Hermes to detect and submit evidence"

# Check the client state on provider and verify it is frozen
FROZEN_HEIGHT=$($HERMES_BIN --json query client state --chain provider --client 07-tendermint-0 | tail -n 1 | jq '.result.frozen_height.revision_height')

diag "Frozen height: $FROZEN_HEIGHT"

if [ "$FROZEN_HEIGHT" != "null" ]; then
    diag "Client is frozen, as expected."
else
    diag "Client is not frozen, aborting."
    ${HOME_DIR}/hermes-evidence-logs.txt
    exit 1
fi

if grep -q "found light client attack evidence" ${HOME_DIR}/hermes-evidence-logs.txt; then
    diag "Evidence found, proceeding."
else
    diag "Evidence not found, aborting."
    cat ${HOME_DIR}/hermes-evidence-logs.txt
    exit 1
fi

waiting 20 "for Hermes to submit evidence and freeze client"

if grep -q "successfully submitted light client attack evidence" ${HOME_DIR}/hermes-evidence-logs.txt; then
    diag "Evidence successfully submitted, success!"
else
    if grep -q "provider is frozen" ${HOME_DIR}/hermes-evidence-logs.txt; then
        diag "Client on provider is already frozen, as expected. Success!"
        exit 0
    elif grep -q "client is frozen and does not have a consensus state at height" ${HOME_DIR}/hermes-evidence-logs.txt; then
        diag "Client already frozen and does not have a consensus state at common height, cannot do anything."
        exit 0
    else
        diag "Evidence not submitted, failed."
        echo ""

        diag "Hermes evidence logs:"
        cat ${HOME_DIR}/hermes-evidence-logs.txt

        exit 1
    fi
fi
