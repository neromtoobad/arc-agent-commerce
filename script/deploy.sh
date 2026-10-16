#!/usr/bin/env bash
# Deploy the whole kit to Arc (testnet or mainnet), in the order the contracts depend on each other, then hand the
# vault to its human owner. Needs Foundry (forge, cast) and python3.
#
#   export RPC_URL=https://rpc.mainnet.arc.io      # or your Arc testnet RPC
#   export PRIVATE_KEY=0x...                       # the deployer; owns the vault until the last step
#   export OWNER=0x...    # the human owner ("the Boss"): approves anything outside the rules, can withdraw
#   export CFO=0x...      # the AI CFO's signer: moves money between buckets and funds agents, inside the policy
#   export OPERATOR=0x... # your server's key: opens and delivers escrow jobs (it can never accept them)
#   export AGENT=0x...    # the key that relays fiat payments (NairaDesk) and runs autopay (PayVault)
#   export FEE_TO=0x...   # where InvoiceBook's fee goes (the vault is a good choice; set after deploy if so)
#   ./script/deploy.sh
set -euo pipefail
USDC=${USDC:-0x3600000000000000000000000000000000000000}       # USDC on Arc (6 decimals through this interface)
GATEWAY=${GATEWAY:-0x77777777Dcc4d5A8B6E418Fd04D8997ef11000eE} # Circle Gateway wallet on Arc mainnet
FEE_BPS=${FEE_BPS:-50}                                         # InvoiceBook fee, in basis points (max 100)
NAIRA_PER_PAY=${NAIRA_PER_PAY:-10000000}                        # NairaDesk: most per fiat payment, 10 USDC
NAIRA_PER_DAY=${NAIRA_PER_DAY:-50000000}                        # NairaDesk: most per day, 50 USDC
DEPLOYER=$(cast wallet address --private-key "$PRIVATE_KEY")
create() { forge create "$1" --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --broadcast --json --constructor-args "${@:2}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["deployedTo"])'; }
send() { cast send "$@" --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" >/dev/null; }

VAULT=$(create src/SynclyVault.sol:SynclyVault "$USDC" "$GATEWAY" "$DEPLOYER" "$CFO");   echo "SynclyVault  $VAULT"
ESCROW=$(create src/JobEscrow.sol:JobEscrow "$USDC" "$VAULT" "$OPERATOR" "$OWNER");      echo "JobEscrow    $ESCROW"
send "$VAULT" "setEscrow(address)" "$ESCROW"
# reserve floor 1, largest move the CFO makes alone 7, weekly agent tool budget 10, weekly promo cap 2 (USDC)
send "$VAULT" "setPolicy(uint256,uint256,uint256,uint256)" 1000000 7000000 10000000 2000000
DESK=$(create src/NairaDesk.sol:NairaDesk "$USDC" "$ESCROW" "$AGENT" "$OWNER" "$NAIRA_PER_PAY" "$NAIRA_PER_DAY"); echo "NairaDesk    $DESK"
BOOK=$(create src/InvoiceBook.sol:InvoiceBook "$USDC" "$OWNER" "$FEE_TO" "$FEE_BPS" "$AGENT"); echo "InvoiceBook  $BOOK"
PAY=$(create src/PayVault.sol:PayVault "$USDC" "$BOOK" "$AGENT" "$OWNER");              echo "PayVault     $PAY"
# hire agents with: cast send $VAULT "hire(address)" <agent> (while the deployer still owns it), then:
send "$VAULT" "setOwner(address)" "$OWNER"
echo "Vault handed to $OWNER. Verify with: forge verify-contract --chain-id <5042|5042002> --verifier sourcify <address> src/<File>.sol:<Name>"
