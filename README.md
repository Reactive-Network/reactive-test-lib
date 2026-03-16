# Reactive Foundry Test

A Solidity testing library for [Reactive Network](https://reactive.network) contracts. Test your reactive contracts locally with `forge test` — no testnet deployment required.

This library simulates the full Reactive Network lifecycle (event subscriptions, `react()` invocations, cross-chain callbacks, same-chain self-callbacks, cron triggers, and multi-step reactive protocols) entirely within Foundry's testing framework.

## Installation

```bash
forge install Reactive-Network/reactive-test-lib
```

Add the remapping to your `remappings.txt` or `foundry.toml`:

```
reactive-test-lib/=lib/reactive-test-lib/src/
```

### Requirements

- Solidity >= 0.8.20
- Foundry (any recent version with `vm.recordLogs()` / `vm.getRecordedLogs()`)
- Compatible with `reactive-lib` v0.2.0+

## Quick Start

### 1. Inherit from `ReactiveTest`

```solidity
import "reactive-test-lib/base/ReactiveTest.sol";
import {CallbackResult} from "reactive-test-lib/interfaces/IReactiveInterfaces.sol";

contract MyTest is ReactiveTest {
    function setUp() public override {
        super.setUp();
        // Deploy your contracts here...
    }
}
```

Calling `super.setUp()` automatically:
- Deploys `MockSystemContract` and etches it to `SERVICE_ADDR` (`0x...fffFfF`)
- Deploys `MockCallbackProxy` for cross-chain callback execution
- Sets `rvmId` to `address(this)` (the simulated deployer identity)
- Sets `reactiveChainId` to `REACTIVE_CHAIN_ID` (`0x512512`)

Your reactive contracts can then call `subscribe()` / `unsubscribe()` in their constructors as they would on a real deployment.

### 2. Deploy Your Contracts

```solidity
function setUp() public override {
    super.setUp();

    // Origin contract (L1) — emits events that trigger reactions
    origin = new MyL1Contract();

    // Callback contract — pass address(proxy) as the callback sender
    callback = new MyCallbackContract(address(proxy));

    // Reactive contract — constructor calls subscribe() on the mock system contract
    reactive = new MyReactiveContract(
        address(sys),        // system contract address
        ORIGIN_CHAIN_ID,     // chain to watch
        DEST_CHAIN_ID,       // callback destination chain
        address(origin),     // contract to watch
        TOPIC_0,             // event signature hash
        address(callback)    // callback target
    );

    // Optional: register contracts for auto chain ID detection
    registerChain(address(origin), ORIGIN_CHAIN_ID);
    registerChain(address(callback), DEST_CHAIN_ID);
    registerChain(address(reactive), reactiveChainId);
}
```

### 3. Simulate the Reactive Lifecycle

```solidity
function testCallbackFires() public {
    // Single-step: trigger an event and run one reactive cycle
    CallbackResult[] memory results = triggerAndReact(
        address(origin),
        abi.encodeWithSignature("doSomething()"),
        ORIGIN_CHAIN_ID
    );

    assertCallbackCount(results, 1);
    assertCallbackSuccess(results, 0);
    assertCallbackEmitted(results, address(callback));
}

function testMultiStepProtocol() public {
    // Full-cycle: keep processing events until quiescence
    CallbackResult[] memory results = triggerFullCycle(
        address(origin),
        abi.encodeWithSignature("doSomething()"),
        ORIGIN_CHAIN_ID,
        20  // max iterations (safety limit)
    );

    // All callbacks across all reactive hops are collected
    assertGt(results.length, 1);
}
```

## What It Simulates

The library replaces the three Reactive Network runtime components:

| Real Component | Local Simulation | Purpose |
|---|---|---|
| System Contract | `MockSystemContract` | Subscription registry and matching |
| ReactVM | `ReactiveSimulator` | Event delivery and `react()` invocation |
| Callback Proxy | `MockCallbackProxy` | Cross-chain callback execution |

### Data Flow (single-step)

```
1. Test calls origin contract            (normal Solidity call)
2. Simulator captures emitted events     (vm.getRecordedLogs())
3. Simulator matches events to subscriptions
4. For each match: builds LogRecord, calls rc.react(logRecord)
5. Simulator captures Callback events from react()
6. Simulator injects RVM ID into callback payload
7. Cross-chain callbacks → executed via MockCallbackProxy
   Same-chain callbacks  → executed via vm.prank(SERVICE_ADDR)
```

### Data Flow (full-cycle)

```
1-7. Same as single-step
8. Events emitted during callback execution are captured
9. Each event is tagged with the callback's destination chain ID
10. Events are fed back to step 3 for the next iteration
11. Repeats until no callbacks are produced or maxIterations is reached
```

## API Reference

### `ReactiveTest` (Base Contract)

Inherit this in your test files. Provides:

#### State

| Member | Type | Description |
|---|---|---|
| `sys` | `MockSystemContract` | System contract at `SERVICE_ADDR` |
| `proxy` | `MockCallbackProxy` | Callback proxy for executing cross-chain callbacks |
| `rvmId` | `address` | Simulated deployer/RVM identity (default: `address(this)`) |
| `reactiveChainId` | `uint256` | Reactive chain ID for self-callback detection (default: `0x512512`) |

#### Chain Registry

Register contracts with their logical chain IDs for auto chain ID detection. This eliminates the need to pass `originChainId` manually on every trigger call.

```solidity
// Register a contract as belonging to a specific chain
registerChain(address(myContract), SEPOLIA);

// Look up chain ID (returns fallback if not registered)
uint256 chainId = resolveChainId(address(myContract), fallbackId);
```

#### Single-Step Trigger Methods

Run one reactive cycle: origin event → `react()` → callbacks.

```solidity
// With explicit chain ID
function triggerAndReact(address origin, bytes memory callData, uint256 originChainId)
    internal returns (CallbackResult[] memory);

function triggerAndReactWithValue(address origin, bytes memory callData, uint256 value, uint256 originChainId)
    internal returns (CallbackResult[] memory);

// With auto chain ID detection (requires registerChain)
function triggerAndReact(address origin, bytes memory callData)
    internal returns (CallbackResult[] memory);

function triggerAndReactWithValue(address origin, bytes memory callData, uint256 value)
    internal returns (CallbackResult[] memory);
```

#### Full-Cycle Trigger Methods

Run the complete multi-step reactive cycle until no more callbacks are produced. Callback execution produces new events, which are matched against subscriptions, triggering further `react()` calls — repeating until quiescence or `maxIterations`.

```solidity
// With explicit chain ID
function triggerFullCycle(address origin, bytes memory callData, uint256 originChainId, uint256 maxIterations)
    internal returns (CallbackResult[] memory);

function triggerFullCycleWithValue(address origin, bytes memory callData, uint256 value, uint256 originChainId, uint256 maxIterations)
    internal returns (CallbackResult[] memory);

// With auto chain ID detection (requires registerChain)
function triggerFullCycle(address origin, bytes memory callData, uint256 maxIterations)
    internal returns (CallbackResult[] memory);

function triggerFullCycleWithValue(address origin, bytes memory callData, uint256 value, uint256 maxIterations)
    internal returns (CallbackResult[] memory);
```

#### Cron Methods

```solidity
function triggerCron(CronType cronType) internal returns (CallbackResult[] memory);
function advanceAndTriggerCron(uint256 blocks, CronType cronType) internal returns (CallbackResult[] memory);
```

#### Assertion Helpers

```solidity
assertCallbackCount(results, expectedCount)    // Exact callback count
assertNoCallbacks(results)                     // Zero callbacks
assertCallbackEmitted(results, targetAddress)  // Callback targets specific address
assertCallbackSuccess(results, index)          // Callback at index succeeded
assertCallbackFailure(results, index)          // Callback at index reverted
```

#### VM Mode Helper

If your reactive contract uses the `vmOnly` modifier (from `AbstractReactive`), call this after deployment:

```solidity
enableVmMode(address(myReactiveContract));
```

This sets the `vm` storage flag to `true`. Needed because etching code to `SERVICE_ADDR` causes `detectVm()` to set `vm = false`.

### `CallbackResult` Struct

Each callback execution returns:

```solidity
struct CallbackResult {
    uint256 chainId;      // Destination chain ID
    address target;       // Callback target contract
    uint64  gasLimit;     // Gas limit specified by react()
    bytes   payload;      // Original callback payload
    bool    success;      // Whether the callback call succeeded
    bytes   returnData;   // Return/revert data from the callback
}
```

### `CronType` Enum

```solidity
enum CronType {
    Cron1,      // Every block
    Cron10,     // Every 10 blocks
    Cron100,    // Every 100 blocks
    Cron1000,   // Every 1,000 blocks
    Cron10000   // Every 10,000 blocks
}
```

## Examples

### Event-Driven Reactive Contract

```solidity
contract BasicReactiveTest is ReactiveTest {
    MyOrigin origin;
    MyReactive rc;
    MyCallback cb;

    uint256 constant SEPOLIA = 11155111;

    function setUp() public override {
        super.setUp();

        origin = new MyOrigin();
        cb = new MyCallback(address(proxy));
        rc = new MyReactive(address(sys), SEPOLIA, address(origin), address(cb));

        registerChain(address(origin), SEPOLIA);
    }

    function testReactionTriggered() public {
        // Auto chain ID detection — no need to pass SEPOLIA
        CallbackResult[] memory results = triggerAndReact(
            address(origin),
            abi.encodeWithSignature("emitEvent()")
        );

        assertCallbackCount(results, 1);
        assertCallbackSuccess(results, 0);
    }

    function testNoReactionForUnrelatedEvent() public {
        address unrelated = makeAddr("unrelated");
        vm.etch(unrelated, address(origin).code);

        CallbackResult[] memory results = triggerAndReact(
            unrelated,
            abi.encodeWithSignature("emitEvent()"),
            SEPOLIA
        );

        assertNoCallbacks(results); // subscription doesn't match
    }

    function testRvmIdInjection() public {
        triggerAndReact(
            address(origin),
            abi.encodeWithSignature("emitEvent()")
        );

        // First argument of the callback payload is overwritten with rvmId
        assertEq(cb.lastRvmId(), rvmId);
    }
}
```

### Cron-Driven Reactive Contract

```solidity
import {CronType} from "reactive-test-lib/interfaces/IReactiveInterfaces.sol";
import {ReactiveConstants} from "reactive-test-lib/constants/ReactiveConstants.sol";

contract CronTest is ReactiveTest {
    MyCronReactive rc;

    function setUp() public override {
        super.setUp();
        rc = new MyCronReactive(address(sys), ReactiveConstants.CRON_TOPIC_1);
    }

    function testCronTriggersCallback() public {
        CallbackResult[] memory results = triggerCron(CronType.Cron1);
        assertCallbackCount(results, 1);
    }

    function testAdvanceBlocksAndTrigger() public {
        uint256 startBlock = block.number;

        CallbackResult[] memory results = advanceAndTriggerCron(100, CronType.Cron1);

        assertCallbackCount(results, 1);
        assertEq(block.number, startBlock + 100);
    }
}
```

### Multi-Step Reactive Protocol (e.g. Bridge)

For protocols that require multiple reactive cycles — like a bridge with confirmation rounds — use `triggerFullCycle`. Events emitted during callback execution are automatically captured, matched against subscriptions, and fed back through `react()`.

```solidity
contract BridgeTest is ReactiveTest {
    Bridge bridge;
    ReactiveBridge reactiveBridge;

    uint256 constant SEPOLIA = 11155111;

    function setUp() public override {
        super.setUp();

        bridge = new Bridge(address(proxy), /* ... */);
        reactiveBridge = new ReactiveBridge(
            reactiveChainId, SEPOLIA, address(bridge), /* ... */
        );
        enableVmMode(address(reactiveBridge));

        // Register for auto chain ID detection
        registerChain(address(bridge), SEPOLIA);
        registerChain(address(reactiveBridge), reactiveChainId);
    }

    function testFullBridgeFlow() public {
        // Full-cycle runs the entire multi-hop protocol:
        //   bridge() → SendMessage → react() → Callback to Bridge
        //   → ConfirmationRequest → react() → Callback to Bridge
        //   → Confirmation → react() → ... until delivered
        CallbackResult[] memory results = triggerFullCycleWithValue(
            address(reactiveBridge),
            abi.encodeWithSignature("bridge(uint256,address)", 123, recipient),
            1 ether,
            20  // max iterations
        );

        // Verify all callbacks succeeded
        for (uint256 i = 0; i < results.length; i++) {
            assertCallbackSuccess(results, i);
        }
    }
}
```

### Self-Callbacks (Same-Chain Reactive Callbacks)

When a reactive contract emits `Callback(reactiveChainId, address(this), ...)`, the callback targets the same chain. These are delivered via `vm.prank(SERVICE_ADDR)` — matching the real network where RVM-to-RN callbacks come from `SERVICE_ADDR`, not the callback proxy.

This is critical for contracts like `ReactiveBridge` that use `AbstractCallback(address(SERVICE_ADDR))` and have entry points guarded by `authorizedSenderOnly`.

```solidity
// In react():
emit Callback(reactiveChainId, address(this), GAS_LIMIT, payload);
// → Simulator detects chainId == reactiveChainId
// → Delivers via vm.prank(SERVICE_ADDR) instead of proxy
// → authorizedSenderOnly passes because msg.sender == SERVICE_ADDR
```

No special test setup needed — the simulator handles this automatically based on `reactiveChainId`.

### Passing Callback Sender for `authorizedSenderOnly`

For **cross-chain** callbacks, `AbstractCallback` authorizes `_callback_sender` in its constructor. Pass `address(proxy)` so the mock proxy satisfies the modifier:

```solidity
myCallback = new MyCallbackContract(address(proxy));
```

For **same-chain** callbacks (reactive contracts that use `AbstractCallback(address(SERVICE_ADDR))`), the simulator delivers via `SERVICE_ADDR` automatically.

### Passing RVM ID for `rvmIdOnly`

`AbstractCallback` stores `msg.sender` as `rvm_id`. Both the proxy (cross-chain) and the simulator (same-chain) inject `rvmId` into the first callback argument. Override `rvmId` in your test if needed:

```solidity
function testWithCustomDeployer() public {
    rvmId = makeAddr("deployer");
    // ... callbacks will now inject this address
}
```

## Advanced Usage

### Using the Simulator Directly

For fine-grained control, use `ReactiveSimulator` and `CronSimulator` libraries directly:

```solidity
import {ReactiveSimulator} from "reactive-test-lib/simulator/ReactiveSimulator.sol";
import {LogRecord, IReactive} from "reactive-test-lib/interfaces/IReactiveInterfaces.sol";

// Deliver a hand-crafted LogRecord to a specific reactive contract
LogRecord memory log = LogRecord({
    chain_id: 1,
    _contract: address(origin),
    topic_0: uint256(keccak256("Transfer(address,address,uint256)")),
    topic_1: 0,
    topic_2: 0,
    topic_3: 0,
    data: abi.encode(100),
    block_number: block.number,
    op_code: 0,
    block_hash: 0,
    tx_hash: 0,
    log_index: 0
});

ReactiveSimulator.deliverRawEvent(vm, IReactive(address(rc)), log);
```

### Using Fixtures Without Inheritance

If you prefer composition over inheritance:

```solidity
import {ReactiveFixtures} from "reactive-test-lib/base/ReactiveFixtures.sol";
import {MockSystemContract} from "reactive-test-lib/mock/MockSystemContract.sol";
import {MockCallbackProxy} from "reactive-test-lib/mock/MockCallbackProxy.sol";

contract MyCustomTest is Test {
    function setUp() public {
        (MockSystemContract sys, MockCallbackProxy proxy) = ReactiveFixtures.deployAll(vm);
        // ... custom setup
    }
}
```

## How It Works

### Single-Chain Simulation

Everything runs on a single EVM instance. Chain IDs are purely logical values stamped on `LogRecord.chain_id` and `Callback.chain_id`. There is no actual cross-chain communication.

### Callback Routing

The simulator routes callbacks based on the `Callback` event's `chain_id`:

- **Cross-chain** (`chain_id != reactiveChainId`): Executed via `MockCallbackProxy`, which injects RVM ID and calls the target. This simulates the real callback proxy on destination chains.
- **Same-chain** (`chain_id == reactiveChainId`): Executed via `vm.prank(SERVICE_ADDR)` with RVM ID injection. This simulates how RVM-to-RN callbacks are delivered by `SERVICE_ADDR` on the Reactive Network.

### Multi-Step Cycle

`simulateFullCycle` orchestrates multi-hop protocols:

1. Execute initial call, capture events
2. Match events against subscriptions, call `react()`, collect `Callback` specs
3. Execute each callback while recording events emitted by the target
4. Tag new events with the callback's `chain_id` (events from a Sepolia callback are Sepolia events)
5. Feed events back to step 2
6. Stop when no callbacks are produced or `maxIterations` is reached

This handles complex protocols like bridges where a single user action triggers a chain of reactive cycles across multiple logical chains.

### Chain Registry

The chain registry maps contract addresses to logical chain IDs. When using auto-detect trigger methods, the simulator looks up the origin's chain ID from the registry instead of requiring it as a parameter.

In full-cycle mode, events captured during callback execution are automatically tagged with the correct chain ID (the callback's destination chain), so the registry is mainly useful for the initial trigger.

### `vmOnly` / `rnOnly` Modifiers

`AbstractReactive.detectVm()` checks `extcodesize(SERVICE_ADDR)`. Since we etch mock code to that address, `detectVm()` sets `vm = false` (thinks it's on Reactive Network). This allows `subscribe()` to work in constructors. If your `react()` function uses `vmOnly`, call `enableVmMode(address(rc))` after deployment to flip the flag.

### RVM ID Injection

The real Reactive Network overwrites the first 20 bytes of the first callback argument with the deployer's address. Both `MockCallbackProxy` (cross-chain) and the simulator's direct delivery (same-chain) replicate this behavior, so `rvmIdOnly` modifiers work correctly in tests.

### Subscription Matching

`MockSystemContract` supports the same wildcard semantics as the real system contract:

| Field | Wildcard Value | Meaning |
|---|---|---|
| `chain_id` | `0` | Match any chain |
| `_contract` | `address(0)` | Match any contract |
| `topic_0..3` | `REACTIVE_IGNORE` | Match any topic value |

## Project Structure

```
src/
  base/
    ReactiveTest.sol          # Base test contract (extends forge-std/Test)
    ReactiveFixtures.sol      # Factory helpers for standalone usage
  constants/
    ReactiveConstants.sol     # SERVICE_ADDR, REACTIVE_IGNORE, cron topics
  interfaces/
    IReactiveInterfaces.sol   # LogRecord, CallbackResult, CronType, IReactive
    IReactiveTest.sol         # Internal interfaces
  mock/
    MockSystemContract.sol    # Subscription registry with wildcard matching
    MockCallbackProxy.sol     # Callback executor with RVM ID injection
  simulator/
    ReactiveSimulator.sol     # Core: event -> react() -> callback pipeline
    CronSimulator.sol         # Synthetic cron event triggers
  ReactiveTest.sol            # Convenience re-export of all library components
```

## License

MIT
