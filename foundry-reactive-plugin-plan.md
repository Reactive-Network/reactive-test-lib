# Foundry Reactive Testing Library — Implementation Plan

## Overview

A standalone, `forge install`-able Solidity library that lets third-party developers test Reactive Network contracts locally within Foundry's `forge test` framework — no testnet deployment required.

**Repository name:** `reactive-foundry-test` (or `forge-reactive-test`)

---

## Architecture

The library simulates the Reactive Network lifecycle entirely in Solidity using Foundry cheatcodes. It replaces the three runtime components that normally only exist on Reactive Network / ReactVM:

| Real Component | Local Simulation |
|---|---|
| System Contract (subscriptions + payments) | `MockSystemContract` |
| ReactVM (event delivery + `react()` invocation) | `ReactiveSimulator` (test harness) |
| Callback Proxy (cross-chain callback execution) | `MockCallbackProxy` |

### Data Flow (local simulation)

```
1. Test emits event on origin contract (normal Solidity call)
2. ReactiveSimulator captures event via vm.getRecordedLogs()
3. ReactiveSimulator matches event against MockSystemContract subscriptions
4. For each match: constructs LogRecord, calls rc.react(logRecord)
5. react() emits Callback events
6. ReactiveSimulator captures Callback events
7. ReactiveSimulator overwrites first 160 bits of payload with deployer address (RVM ID)
8. ReactiveSimulator executes payload on destination contract via MockCallbackProxy
```

---

## Library Structure

```
src/
├── mock/
│   ├── MockSystemContract.sol      # ISystemContract implementation with subscription registry
│   ├── MockCallbackProxy.sol       # Callback executor simulating cross-chain delivery
│   └── MockPayable.sol             # Minimal IPayable stub (debt always 0, accepts ETH)
├── simulator/
│   ├── ReactiveSimulator.sol       # Core test harness — the "ReactVM in a test"
│   └── CronSimulator.sol           # Cron event emitter for time-based testing
├── base/
│   ├── ReactiveTest.sol            # Base test contract (extends forge-std/Test.sol)
│   └── ReactiveFixtures.sol        # Common setup patterns and factory helpers
├── interfaces/
│   └── IReactiveTest.sol           # Internal interfaces for the test library
└── constants/
    └── ReactiveConstants.sol       # Chain IDs, cron topics, REACTIVE_IGNORE, SERVICE_ADDR
test/
├── BasicDemo.t.sol                 # Tests mirroring the Basic Demo
├── CronDemo.t.sol                  # Tests mirroring the Cron Demo
├── CallbackAuth.t.sol              # RVM ID overwrite / auth tests
└── SubscriptionFiltering.t.sol     # Wildcard and topic matching tests
```

---

## Component Details

### 1. `MockSystemContract` — Subscription Registry

**Implements:** `ISystemContract` (= `IPayable` + `ISubscriptionService`)

```solidity
// Core state
struct Subscription {
    uint256 chainId;       // 0 = wildcard
    address contractAddr;  // address(0) = wildcard
    uint256 topic0;        // REACTIVE_IGNORE = wildcard
    uint256 topic1;
    uint256 topic2;
    uint256 topic3;
    address subscriber;    // the RC that called subscribe()
}

Subscription[] public subscriptions;
```

**Key behaviors:**
- `subscribe(chainId, addr, t0, t1, t2, t3)` — appends to `subscriptions[]`, records `msg.sender` as subscriber
- `unsubscribe(...)` — finds and removes matching subscription
- `getMatchingSubscribers(chainId, addr, t0, t1, t2, t3)` — returns all RCs whose subscriptions match a given event (used by the simulator)
- Matching logic: a subscription field matches if it equals the event field OR is a wildcard (`0` for chainId, `address(0)` for contract, `REACTIVE_IGNORE` for topics)
- Payment functions are no-ops (always return 0 debt, accept ETH)

**Deployed at:** `SERVICE_ADDR` (`0x0000000000000000000000000000000000fffFfF`) using `vm.etch` to place code at the well-known address so that `AbstractReactive` constructors work unmodified.

### 2. `MockCallbackProxy` — Callback Executor

**Purpose:** Receives callback payloads from the simulator and executes them on destination contracts, mimicking the real Callback Proxy.

```solidity
contract MockCallbackProxy {
    // Called by ReactiveSimulator after capturing Callback events
    function executeCallback(
        address target,
        bytes memory payload,
        uint64 gasLimit,
        address rvmId        // deployer address to inject
    ) external returns (bool success, bytes memory result);
}
```

**Key behaviors:**
- Overwrites the first 160 bits (20 bytes) of the payload's first argument with `rvmId` (replicating the real network's RVM ID injection)
- Calls `target` with modified payload using specified `gasLimit`
- Records callback execution results for test assertions

### 3. `ReactiveSimulator` — Core Harness

**Purpose:** Orchestrates the full reactive lifecycle within a single `forge test` transaction.

```solidity
library ReactiveSimulator {
    /// Simulate the full event → react() → callback cycle
    function simulateReaction(
        Vm vm,
        address origin,         // origin contract to call
        bytes memory callData,  // call that emits the triggering event
        uint256 originChainId,  // chain ID to stamp on LogRecords
        MockSystemContract sys,
        MockCallbackProxy proxy,
        address rvmId           // deployer/RVM identity
    ) internal returns (CallbackResult[] memory);

    /// Lower-level: deliver a specific LogRecord to matching subscribers
    function deliverEvent(
        MockSystemContract sys,
        IReactive.LogRecord memory log,
        MockCallbackProxy proxy,
        address rvmId
    ) internal returns (CallbackResult[] memory);

    /// Manually construct and deliver a LogRecord (for edge cases)
    function deliverRawEvent(
        IReactive target,
        IReactive.LogRecord memory log
    ) internal;
}
```

**`simulateReaction` flow:**
1. `vm.recordLogs()` — start recording
2. Execute `origin.call(callData)` — trigger the event
3. `vm.getRecordedLogs()` — capture all emitted logs
4. For each log entry, query `sys.getMatchingSubscribers()`
5. Build `LogRecord` from the Foundry log struct (map topics, set `chain_id = originChainId`)
6. Call `rc.react(logRecord)` on each matched subscriber — with `vm.prank(SERVICE_ADDR)` so `vmOnly` modifier passes
7. Capture any `Callback` events emitted during `react()`
8. For each `Callback`: call `proxy.executeCallback(target, payload, gasLimit, rvmId)`
9. Return results for assertions

**Important detail — `vmOnly` bypass:**
`AbstractReactive.vmOnly` checks `require(vm, ...)` where `vm` is set by `detectVm()`. The simulator must ensure the RC thinks it's inside ReactVM. Two approaches:
- **Option A (preferred):** Deploy the RC *after* etching `MockSystemContract` to `SERVICE_ADDR`. Since `detectVm()` checks for code at the system address, the RC's constructor will set `vm = true` automatically.
- **Option B (fallback):** Use `vm.store()` to set the `vm` storage slot to `true` after deployment.

### 4. `CronSimulator` — Time-Based Event Triggers

```solidity
library CronSimulator {
    /// Emit a cron event and deliver it to all subscribers of that cron topic
    function triggerCron(
        Vm vm,
        CronType cronType,     // Cron1, Cron10, Cron100, Cron1000, Cron10000
        MockSystemContract sys,
        MockCallbackProxy proxy,
        address rvmId
    ) internal returns (CallbackResult[] memory);

    /// Advance block number and trigger cron (convenience)
    function advanceAndTriggerCron(
        Vm vm,
        uint256 blocks,
        CronType cronType,
        MockSystemContract sys,
        MockCallbackProxy proxy,
        address rvmId
    ) internal returns (CallbackResult[] memory);
}
```

**Cron topic constants** (from Reactive docs):
| Type | Topic 0 |
|------|---------|
| Cron1 | `0xf02d6ea5c...` |
| Cron10 | `0x04463f7c...` |
| Cron100 | `0xb49937fb...` |
| Cron1000 | `0xe20b3129...` |
| Cron10000 | `0xd214e1d8...` |

The cron simulator constructs a `LogRecord` with `chain_id = REACTIVE_CHAIN_ID`, the system contract as `_contract`, the cron topic as `topic_0`, and `block.number` encoded in `data`. Then delivers it via `ReactiveSimulator.deliverEvent()`.

### 5. `ReactiveTest` — Base Test Contract

The developer-facing base contract that wires everything together.

```solidity
import "forge-std/Test.sol";

abstract contract ReactiveTest is Test {
    MockSystemContract  internal sys;
    MockCallbackProxy   internal proxy;
    address             internal rvmId;

    function setUp() public virtual {
        // 1. Deploy MockSystemContract
        sys = new MockSystemContract();

        // 2. Etch its code to SERVICE_ADDR so AbstractReactive constructors detect VM
        vm.etch(SERVICE_ADDR, address(sys).code);
        sys = MockSystemContract(payable(SERVICE_ADDR));

        // 3. Deploy MockCallbackProxy
        proxy = new MockCallbackProxy();

        // 4. Set rvmId to the test contract address (simulates deployer)
        rvmId = address(this);
    }

    // ---- Convenience wrappers ----

    /// Deploy a reactive contract with correct environment
    function deployReactive(bytes memory creationCode)
        internal returns (address rc);

    /// Trigger an event and run the full reactive cycle
    function triggerAndReact(
        address origin,
        bytes memory callData,
        uint256 originChainId
    ) internal returns (CallbackResult[] memory);

    /// Trigger a cron event
    function triggerCron(CronType cronType)
        internal returns (CallbackResult[] memory);

    // ---- Assertion helpers ----

    function assertCallbackEmitted(
        CallbackResult[] memory results,
        address expectedTarget
    ) internal;

    function assertCallbackCount(
        CallbackResult[] memory results,
        uint256 expected
    ) internal;

    function assertNoCallbacks(
        CallbackResult[] memory results
    ) internal;

    function assertCallbackSuccess(
        CallbackResult[] memory results,
        uint256 index
    ) internal;
}
```

---

## Example Test (Basic Demo)

Shows how a developer would test the Basic Demo contracts using this library:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-reactive-test/ReactiveTest.sol";
import "../src/demos/basic/BasicDemoL1Contract.sol";
import "../src/demos/basic/BasicDemoReactiveContract.sol";
import "../src/demos/basic/BasicDemoL1Callback.sol";

contract BasicDemoTest is ReactiveTest {
    BasicDemoL1Contract origin;
    BasicDemoReactiveContract rc;
    BasicDemoL1Callback cb;

    uint256 constant ORIGIN_CHAIN = 11155111;  // Sepolia
    uint256 constant DEST_CHAIN = 11155111;

    function setUp() public override {
        super.setUp();

        // Deploy origin contract
        origin = new BasicDemoL1Contract();

        // Deploy callback contract — pass proxy address as callback_sender
        cb = new BasicDemoL1Callback(address(proxy));

        // Deploy reactive contract — constructor calls subscribe() on MockSystemContract
        rc = new BasicDemoReactiveContract(
            address(sys),
            ORIGIN_CHAIN,
            DEST_CHAIN,
            address(origin),
            uint256(keccak256("Received(address,address,uint256)")), // topic_0
            address(cb)
        );
    }

    function testCallbackTriggeredAboveThreshold() public {
        // Send 0.002 ETH to origin — emits Received event with value > 0.001 ether
        CallbackResult[] memory results = triggerAndReact(
            address(origin),
            abi.encodeWithSignature("receive()"),  // or use low-level value send
            ORIGIN_CHAIN
        );

        // Callback should have fired
        assertCallbackCount(results, 1);
        assertCallbackSuccess(results, 0);
        assertCallbackEmitted(results, address(cb));
    }

    function testNoCallbackBelowThreshold() public {
        // Send 0.0005 ETH — below 0.001 threshold
        CallbackResult[] memory results = triggerAndReact{value: 0.0005 ether}(
            address(origin),
            "",
            ORIGIN_CHAIN
        );

        assertNoCallbacks(results);
    }
}
```

## Example Test (Cron Demo)

```solidity
contract CronDemoTest is ReactiveTest {
    BasicCronContract rc;
    address callbackTarget;

    function setUp() public override {
        super.setUp();
        callbackTarget = makeAddr("cronCallback");
        rc = new BasicCronContract(
            address(sys),
            CRON_TOPIC_1,  // Cron1 topic
            address(callbackTarget)
        );
    }

    function testCronTriggersCallback() public {
        // Advance 10 blocks and trigger cron
        CallbackResult[] memory results = triggerCron(CronType.Cron1);

        assertCallbackCount(results, 1);
        assertEq(rc.getLastCronBlock(), block.number);
    }

    function testCronPauseResume() public {
        rc.pause();
        CallbackResult[] memory results = triggerCron(CronType.Cron1);
        assertNoCallbacks(results);

        rc.resume();
        results = triggerCron(CronType.Cron1);
        assertCallbackCount(results, 1);
    }
}
```

---

## Implementation Phases

### Phase 1 — Core Mock Contracts
**Goal:** Get `MockSystemContract` and `MockCallbackProxy` working so reactive contracts can deploy in test.

1. Implement `MockSystemContract` with subscribe/unsubscribe and subscription storage
2. Implement payment stubs (no-op `pay()`, `coverDebt()`, zero `debt()`)
3. Implement `MockCallbackProxy` with RVM ID payload injection
4. Write unit tests for subscription matching logic (wildcards, REACTIVE_IGNORE)
5. Verify `AbstractReactive` constructors work when `MockSystemContract` is etched to `SERVICE_ADDR`

### Phase 2 — Reactive Simulator
**Goal:** Automate the event → react() → callback pipeline.

1. Implement `ReactiveSimulator.simulateReaction()` using `vm.recordLogs()` / `vm.getRecordedLogs()`
2. Implement LogRecord construction from Foundry's `Vm.Log` struct
3. Implement `vm.prank(SERVICE_ADDR)` for `react()` calls (if needed for auth)
4. Implement Callback event capture and execution via `MockCallbackProxy`
5. Test with Basic Demo contracts end-to-end

### Phase 3 — Cron Simulator
**Goal:** Support time-based reactive contracts.

1. Define cron topic constants and `CronType` enum
2. Implement `CronSimulator.triggerCron()` — constructs synthetic LogRecord with cron topic
3. Implement `advanceAndTriggerCron()` with `vm.roll()` / `vm.warp()`
4. Test with Cron Demo contract

### Phase 4 — ReactiveTest Base + Developer UX
**Goal:** Clean developer-facing API.

1. Implement `ReactiveTest` base contract with setUp wiring
2. Add convenience methods (`triggerAndReact`, `triggerCron`, `deployReactive`)
3. Add assertion helpers (`assertCallbackEmitted`, `assertCallbackCount`, etc.)
4. Add `ReactiveFixtures` with common setup patterns
5. Write comprehensive example tests mirroring all demo contracts

### Phase 5 — Documentation + Packaging
**Goal:** Ship as installable library.

1. Write README with quick-start, API reference, and examples
2. Add `foundry.toml` and `remappings.txt`
3. Tag release, verify `forge install` works
4. Add CI (GitHub Actions) running the example tests

---

## Key Technical Decisions

### How `vmOnly` works in tests
`AbstractReactive.detectVm()` checks for code at `SERVICE_ADDR`. By etching `MockSystemContract` to that address *before* deploying the RC, the constructor sets `vm = true` automatically. No storage hacks needed.

### How `authorizedSenderOnly` works on callbacks
`AbstractCallback` authorizes `_callback_sender` in its constructor. In tests, pass `address(proxy)` as the callback sender. The proxy then calls the callback function, satisfying the modifier.

### How `rvmIdOnly` works on callbacks
`AbstractCallback` stores `msg.sender` (the deployer) as `rvm_id`. The first argument of every callback payload is overwritten with the deployer's address by the real network. Our `MockCallbackProxy` replicates this, so `rvmIdOnly(sender)` passes.

### Single-chain simulation
Everything runs on one Anvil/EVM instance. Chain IDs are logical — they're just numbers in the `LogRecord.chain_id` field and `Callback.chain_id` event parameter. The simulator stamps the developer-specified chain ID on LogRecords.

### Compatibility with reactive-lib
The library imports nothing from reactive-lib at runtime. Developers import reactive-lib for their own contracts. Our library only needs to be ABI-compatible with the interfaces (LogRecord struct, Callback event, ISystemContract).

---

## Dependencies

- `forge-std` (Foundry's standard library) — for `Test.sol`, `Vm` cheatcodes
- No dependency on `reactive-lib` itself (ABI-compatible reimplementation of interfaces)

## Compatibility Target

- Solidity >=0.8.20
- Foundry (any recent version with `vm.recordLogs()` / `vm.getRecordedLogs()` support)
- Compatible with `reactive-lib` v0.2.0+
