# arc-agent-commerce

Five small Solidity contracts for running a business with AI agents on [Arc](https://arc.network), in USDC, with
limits a human sets and the agents can't talk their way past. Fork them, import them, or deploy the whole kit in
one script.

They run in production at **[Syncly](https://hiresyncly.site)**: an AI team that does $1 jobs for small businesses
in Nigeria (websites, promo videos, ad campaigns, reports) while an AI CFO runs the money. Real customers pay into
`JobEscrow`, most of them in naira through `NairaDesk`, and the agents' tool spending comes out of `SynclyVault`.
Every payment is on the [live traction record](https://hiresyncly.site/api/traction.md).

| Contract | What it gives you | Arc mainnet (verified, exact match) |
|---|---|---|
| [`JobEscrow`](src/JobEscrow.sol) | Pay only for work you accept: the customer is the evaluator, rejection refunds the price **plus a bond** | [`0xde2c…EDBd`](https://explorer.arc.io/address/0xde2ca0c975a1f5789f9b79fe578d43ccf417edbd?tab=contract) |
| [`SynclyVault`](src/SynclyVault.sol) | A treasury an AI CFO can run but not drain: buckets, a weekly agent budget, per-move caps, co-sign above them | [`0x589e…9f2b`](https://explorer.arc.io/address/0x589e8ec9134777acecb83a9abdf018942ddc9f2b?tab=contract) |
| [`NairaDesk`](src/NairaDesk.sol) | A USDC float that funds escrow for customers who paid in local currency, with no wallet | [`0x2773…a577`](https://explorer.arc.io/address/0x2773c0e9801c267d7ffa230e9caae62b9858a577?tab=contract) |
| [`InvoiceBook`](src/InvoiceBook.sol) | Invoices paid exactly once, to the payee fixed when booked, tied to a document hash | [`0x7b05…8F93`](https://explorer.arc.io/address/0x7b0530865040dc44a9cc90270396d7c5bcac8f93?tab=contract) |
| [`PayVault`](src/PayVault.sol) | Supplier autopay inside the owner's rules: approved payees, per-payment and weekly caps | [`0x2d9f…3641`](https://explorer.arc.io/address/0x2d9f8eb4bb30f89a92c5acbee68223ee572f3641?tab=contract) |

No dependencies: plain Solidity 0.8.26, 52 tests, MIT licensed.

## How they fit

```
 customer wallet ──fund──┐                                  ┌── accept ──▶ price → SynclyVault (OPERATING)
                         ▼                                  │
 bank transfer ─▶ NairaDesk ──fund──▶ JobEscrow ── submit ──┼── reject ──▶ price + bond → customer
 (off-chain, confirmed)               ▲ open (locks bond)   └── silence ─▶ released after the window
                                      │
                         server key (OPERATOR): opens and delivers, can never accept

 SynclyVault: OPERATING · TOOLS · BOND · RESERVE · PROMO
   AI CFO key ──▶ move between buckets, set agent allowances, top agents up (Circle Gateway)
   human OWNER ─▶ sets the policy, co-signs anything bigger, can withdraw

 InvoiceBook: book(payee, amount, docHash) ──▶ pay() once, straight from payer to the booked payee
 PayVault:    owner deposits + approves payees and caps ──▶ agent autopay()s booked invoices inside them
```

## The contracts

### JobEscrow: pay only for accepted work

A plain escrow lets the seller (or an AI judge) decide the work is done. Here only the **customer** can accept, and
the seller backs every quote with a bond it loses if the customer rejects or the deadline passes.

- `open(id, customer, amount, bond, specHash, fundBy, deliverBy)`: the operator quotes a job. The bond is locked in
  the vault's `BOND` bucket at once, so every open quote is covered. `specHash` fixes what was promised.
- `fund(id)`: anyone pays exactly `amount` (the customer, or a desk paying on their behalf).
- `submit(id, deliverableHash)`: the operator delivers; the acceptance window (48 h by default) starts.
- `accept(id)`: customer only. The price goes to the vault as revenue and the bond is released.
- `requestRevision(id)`: one revision, inside the window.
- `reject(id)`: the customer gets the full price back **and** the bond.
- `autoRelease(id)`: silence means yes, after the window.
- `refundLate(id)`: anyone can trigger it once the deadline passes: price plus bond to the customer.

### SynclyVault: an AI-run treasury with human limits

All USDC sits in five buckets: `OPERATING`, `TOOLS`, `BOND`, `RESERVE` and `PROMO`.

- The **CFO key** can `move` between buckets, `setAllowance` for each agent per epoch, and `topUp` agents' Circle
  Gateway balances. It has no function that sends money anywhere else.
- The **owner** sets `setPolicy(reserveFloor, maxMove, epochToolBudget, promoCap)`. The vault refuses any move over
  `maxMove` (it becomes a proposal the owner `coSign`s) and any week of allowances over `epochToolBudget`.
- `BOND` always covers outstanding bonds: the CFO can't move bond money a customer may be owed.
- `openEpoch(commit)` and `closeEpoch(recordHash)` seal the CFO's weekly plan and record on-chain before money
  moves, so the plan can be checked against what happened.

### NairaDesk: local-currency customers, on-chain guarantees

Most small businesses in Africa have no crypto wallet, and Arc has no on-ramp there. A customer pays in naira
through a local processor; once the payment is confirmed off-chain, the agent key calls `fund(job, ref)`.

- It can fund **only** a `JobEscrow` job whose customer is the desk itself, **once per payment reference**, under a
  per-payment and a daily cap.
- Because the desk is the escrow's customer, the agent relays the customer's `accept`, `requestRevision` or
  `reject`. A refund and the bond come back to the desk; the local currency is refunded off-chain.
- The float can go nowhere but into JobEscrow. Only the owner can `withdraw` it or change the caps.

### InvoiceBook: the payee can't change after booking

Built against the four failure modes in Canteen's [Agents and Ledgers](https://thecanteenapp.com/analysis/2026/09/12/agents-and-ledgers.html):

- **Wrong payee:** `book(id, payee, amount, due, docHash)` fixes the payee. A changed pay link can't redirect money.
- **Double pay:** `pay(id)` works once.
- **Phantom invoice:** every payment points to a document hash fixed before the money moved.
- **Rounding:** whole USDC units (6 decimals), paid exactly; the optional fee (at most 1%) is floored in the
  payee's favour.

Money goes straight from payer to payee in the same call; the contract never holds it.

### PayVault: autopay an agent can run but not abuse

A business deposits USDC and calls `open(biz, perPayCap, weekCap, payees)`. The agent key can then `autopay` a
booked InvoiceBook invoice from that balance, but only to an approved payee, under both caps, and only once.
Anything outside the rules can only be `propose`d; the owner `approve`s it from their wallet, and can `withdraw`
at any time.

## Quick start

```bash
curl -L https://foundry.paradigm.xyz | bash && foundryup
git clone https://github.com/neromtoobad/arc-agent-commerce && cd arc-agent-commerce
forge build
forge test        # 52 tests
```

Deploy the whole kit (see the variables at the top of the script):

```bash
export RPC_URL=https://rpc.mainnet.arc.io PRIVATE_KEY=0x... OWNER=0x... CFO=0x... OPERATOR=0x... AGENT=0x... FEE_TO=0x...
./script/deploy.sh
```

Or one contract at a time:

```bash
forge create src/InvoiceBook.sol:InvoiceBook --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast \
  --constructor-args 0x3600000000000000000000000000000000000000 $OWNER $FEE_TO 50 $BOOKER
forge verify-contract --chain-id 5042 --verifier sourcify <address> src/InvoiceBook.sol:InvoiceBook
```

USDC on Arc is `0x3600000000000000000000000000000000000000` (6 decimals through this ERC-20 interface). Note that a
wallet's "send USDC" usually sends Arc's native gas balance, which these contracts don't accept: send through the
ERC-20 contract.

## Calling them from TypeScript (viem)

```ts
import { createPublicClient, createWalletClient, custom, http, parseAbi, keccak256, toHex } from 'viem';

const USDC = '0x3600000000000000000000000000000000000000';
const ESCROW = '0xde2ca0c975a1f5789f9b79fe578d43ccf417edbd';
const erc20 = parseAbi(['function approve(address spender, uint256 amount) returns (bool)']);
const escrow = parseAbi([
  'function fund(bytes32 id)', 'function accept(bytes32 id)', 'function requestRevision(bytes32 id)', 'function reject(bytes32 id)',
  'function jobs(bytes32) view returns (address customer, uint96 amount, uint96 bond, uint64 fundBy, uint64 deliverBy, uint64 acceptBy, bool revised, uint8 state, bytes32 specHash, bytes32 deliverableHash)',
]);

// the customer pays a quoted job, then decides on the delivery
const id = keccak256(toHex('order-123'));
const job = await publicClient.readContract({ address: ESCROW, abi: escrow, functionName: 'jobs', args: [id] });
await wallet.writeContract({ address: USDC, abi: erc20, functionName: 'approve', args: [ESCROW, job[1]] });
await wallet.writeContract({ address: ESCROW, abi: escrow, functionName: 'fund', args: [id] });
// ...after `submit`:
await wallet.writeContract({ address: ESCROW, abi: escrow, functionName: 'accept', args: [id] }); // or 'reject' / 'requestRevision'
```

```ts
// a fiat payment was confirmed off-chain: the agent funds the job from the desk's float, once per payment
const desk = parseAbi(['function fund(bytes32 job, bytes32 ref)']);
await agentWallet.writeContract({ address: DESK, abi: desk, functionName: 'fund', args: [jobId, keccak256(toHex(processorPaymentId))] });

// book an invoice (payee and amount fixed), then pay it exactly once
const book = parseAbi(['function book(bytes32 id, address payee, uint256 amount, uint64 due, bytes32 docHash)', 'function pay(bytes32 id)']);
await booker.writeContract({ address: BOOK, abi: book, functionName: 'book', args: [invId, supplier, 25_000_000n, due, keccak256(pdfBytes)] });
await payer.writeContract({ address: BOOK, abi: book, functionName: 'pay', args: [invId] }); // after approving USDC to BOOK
```

## Roles at a glance

| Role | Can | Can't |
|---|---|---|
| Customer | fund, accept, ask for one revision, reject (price + bond back) | be overruled by the seller |
| Operator (server key) | open quotes, deliver | accept, or touch funded money |
| AI CFO (vault key) | move between buckets, set allowances, top up agents, all inside the policy | send money outside the vault, exceed the weekly budget or `maxMove`, touch bond cover |
| Agent (desk / autopay key) | fund desk jobs once per payment, autopay approved invoices under caps | send the float or bill money anywhere else |
| Owner (a human) | set the rules, co-sign, withdraw, change keys | nothing is hidden from them |

## Status

These contracts hold real customer money on Arc mainnet and have a full test suite, but they have **not been
audited**. Read them (about 950 lines in total), test your deployment, and set the caps low.

Questions or improvements: open an issue or a pull request.

## License

[MIT](LICENSE)
