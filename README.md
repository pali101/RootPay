# RootPay: Merkle-Indexed Micropayment Channels

RootPay is a general-purpose, high-frequency micropayment protocol designed to eliminate the bottlenecks of traditional state channels. By combining Merkle trees with client-side multiplexing, it enables massive concurrency and zero-gas micro-transactions with predictable O(log n) on-chain settlement.

## The Vision

In today's digital economy, users and autonomous agents are often locked into rigid, over-provisioned subscriptions dictated by corporate models rather than actual usage. RootPay gives control back to the user.

Whether you are querying an AI inference API for a few milliseconds, downloading fragmented datasets across parallel streams from a decentralized storage network, or paying for a few minutes of WiFi, RootPay lets you pay at granular resolution. Track usage at the byte or millisecond level and pay only for exactly what you consume, with ultimate flexibility and trust between you and the service provider, without the overhead of traditional payment rails.

## The Problem

Standard micropayment schemes fail to scale for high-frequency, parallelized use cases:

* **Signature-Based Channels:** Require cryptographic signature verification (e.g., `ecrecover`) for every payment. At thousands of transactions per second (TPS), this creates massive off-chain compute overhead for the merchant.
* **Linear Hashchains:** Solve off-chain compute by using fast hash pre-images, but force strict sequential payments (breaking concurrency) and suffer from O(n) gas costs during on-chain settlement.

## The Core Idea

RootPay replaces linear hashchains with **Merkle-Indexed State Channels**.

Instead of a sequential chain of hashes, the payer pre-commits to a Merkle tree root on-chain. The tree has N leaves (where N must be a power of 2), and each leaf encodes a hidden secret at a fixed index:

```
Leaf(i) = hash(i || secret_i)
```

Each leaf carries an **implicit fixed value** of `channelAmount / N`. The leaf index itself acts as the value counter: a merchant who has verified up to index `i` is entitled to `(i + 1) * channelAmount / N` tokens. No value needs to be encoded in the leaf preimage; the index is sufficient.

By mandating power-of-2 tree sizes, the protocol simplifies Merkle construction and guarantees a mathematically fixed O(log n) on-chain settlement cost regardless of the number of micro-transactions.

## How It Works

### Phase 1: On-Chain Setup

1. The Client generates a Merkle tree with N leaves (N must be a power of 2, e.g., 1024) off-chain. Each leaf corresponds to a secret at a fixed index: `Leaf(i) = hash(i || secret_i)`.
2. The Client locks funds in the RootPay smart contract, committing the **Merkle Root** as the channel's trust anchor.

### Phase 2: Off-Chain Multiplexed Payments

1. **Client-Side Multiplexing:** The Client runs a local payment daemon. When multiple parallel processes (e.g., 10 concurrent file downloads) need to pay the Merchant, they request tokens from this local daemon.
2. **Sequential Dispensing:** The daemon increments a global index, handing out the corresponding leaf secret (`secret_i`) and its Merkle proof to the requesting processes.
3. **Merchant Aggregation:** To minimize off-chain compute overhead, the Merchant does not verify a proof for every individual request. Instead, the Merchant runs a daemon that periodically requests the proof for the new current index (i.e., the highest leaf index consumed since the last check). The verification window is configurable based on trust level:
   - **Low trust / new client:** Short windows (e.g., 30 seconds), frequent proof checks.
   - **Established client:** Longer windows (e.g., 1 minute or more).
   - **Maximum granularity:** Per-second checks are possible but approach the overhead of traditional hashchains and are generally discouraged.

### Phase 3: On-Chain Settlement

1. To close the channel, the Merchant submits the **highest verified leaf** (`leafIndex`, `secret_i`) and its corresponding Merkle proof to the smart contract.
2. The contract verifies the O(log n) Merkle proof against the pre-committed root.
3. The Merchant receives `(leafIndex + 1) * channelAmount / N` tokens. Any remaining balance is refunded to the payer. Integer division remainder (dust) is returned to the payer.

### Dispute Resolution and Channel Expiry

Payment channels include two configurable timeouts set at creation:

* **`merchantWithdrawAfterBlocks`:** The block number after which the Merchant is permitted to redeem the channel. The Merchant cannot settle before this block is reached.
* **`payerWithdrawAfterBlocks`:** The block number after which the payer may reclaim the full remaining deposit via `reclaimChannel`. This must be set sufficiently after `merchantWithdrawAfterBlocks` to give the Merchant adequate time to settle. Importantly, `payerWithdrawAfterBlocks` acts as the Merchant's implicit deadline: if the Merchant does not submit a valid proof before the payer reclaims, the full balance returns to the payer.

If neither party acts, the payer can always reclaim their locked funds after the expiry window. This ensures no funds are locked permanently.

### Known Limitations (v1)

* **Fixed tree size:** The payer commits to N leaves at channel creation. If all N leaves are exhausted mid-session, a new channel must be opened. For long-running sessions, choose N appropriately upfront.
* **Integer division dust:** Payout is computed as `(leafIndex + 1) * channelAmount / N`. Remainder dust from integer division is returned to the payer rather than the merchant.
* **N must be a power of 2:** This constraint simplifies Merkle tree construction and proof verification. Arbitrary N is not supported in v1.

## The Contract

The key insight behind RootPay is replacing resource-heavy PKI operations and sequence-blocking linear hashchains with a Merkle-indexed tree structure. This facilitates decentralized, concurrent payments with mathematically predictable, low-gas on-chain settlement.

**Core Features:**

* **Channel Creation:** Users create a payment channel by locking tokens/Ether and committing a Merkle Root as the trust anchor. Supports EIP-2612 permit for gasless approval.
* **Token Validation:** Uses O(log n) Merkle proofs for secure, trustless token verification both off-chain (merchant daemon) and on-chain (settlement).
* **Channel Redemption:** Merchants redeem accumulated tokens by submitting the single highest verified leaf index, its secret, and its Merkle proof. The contract pays the proportional amount to the merchant and refunds the remainder to the payer.
* **Channel Reclaim:** Payers can reclaim their full deposit after `payerWithdrawAfterBlocks` if the merchant has not settled.

## Supercharging x402 (Off-Chain Execution)

The standard [x402 protocol](https://x402.org/) proposes an elegant HTTP-native payment flow, but currently expects an on-chain transaction for every `HTTP 402 Payment Required` challenge. This is fundamentally incompatible with low-latency applications due to network latency and gas fees.

RootPay acts as the high-speed, off-chain execution layer for x402:

1. **The Handshake:** The provider responds with an `HTTP 402`, specifying its RootPay contract address and required token amount.
2. **The Off-Chain Payload:** Instead of signing and broadcasting a slow on-chain transaction, the client constructs the `Authorization: L402` (or x402) header containing the RootPay leaf index, secret, and Merkle proof.
3. **The Result:** The provider verifies the O(log n) proof locally in milliseconds and serves the request. The blockchain is touched only once at the end of the session to settle the aggregated sum.

## Who Is This For?

* **Decentralized Infrastructure (DePIN):** Bandwidth metering, Filecoin CDN retrieval markets, and decentralized compute networks where streaming payments must be non-blocking.
* **High-Volume API Monetization:** Pay-per-call APIs (e.g., AI inference endpoints, RPC nodes) that require thousands of requests per second.
* **Agent-to-Agent Economies:** Autonomous AI agents executing high-frequency micro-transactions with other agents without managing complex, stateful channels.

## Why RootPay?

* **Massive Concurrency:** Client-side multiplexing allows thousands of parallel streams over a single on-chain channel.
* **Ultra-Low Merchant Overhead:** Off-chain aggregation means merchants verify O(log n) proofs periodically, rather than computing signatures or hashes for every micro-transaction.
* **Predictable, Low-Gas Settlement:** On-chain settlement is always a single O(log n) Merkle proof verification, completely eliminating the O(n) loop bottleneck of traditional hashchains.
* **Configurable Trust Tiers:** Merchants tune verification frequency to match their trust model, from per-second granularity down to minute-long aggregation windows.

## Demo

A live demo application is available at [pali101/rootpay-demo](https://github.com/pali101/rootpay-demo). It is included in this repository as a Git submodule under `demo/`.

To clone with the demo included:

```bash
git clone --recurse-submodules https://github.com/pali101/RootPay
```

Or, if you have already cloned the repo:

```bash
git submodule update --init --recursive
```