# Reactive Foundry Test

A Solidity testing library for [Reactive Network](https://reactive.network) contracts. Test your reactive contracts locally with `forge test` — no testnet deployment required.

This library simulates the full Reactive Network lifecycle (event subscriptions, `react()` invocations, cross-chain callbacks, and cron triggers) entirely within Foundry's testing framework.

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
- Deploys `MockCallbackProxy` for callback execution
- Sets `rvmId` to `address(this)` (the simulated deployer identity)

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
}
```

### 3. Simulate the Reactive Lifecycle

```solidity
function testCallbackFires() public {
    // Trigger an event and run the full reactive cycle
    CallbackResult[] memory results = triggerAndReact(
        address(origin),
        abi.encodeWithSignature("doSomething()"),
        ORIGIN_CHAIN_ID
    );

    // Assert on results
    assertCallbackCount(results, 1);
    assertCallbackSuccess(results, 0);
    assertCallbackEmitted(results, address(callback));
}
```

## What It Simulates

The library replaces the three Reactive Network runtime components:

| Real Component | Local Simulation | Purpose |
|---|---|---|
| System Contract | `MockSystemContract` | Subscription registry and matching |
| ReactVM | `ReactiveSimulator` | Event delivery and `react()` invocation |
| Callback Proxy | `MockCallbackProxy` | Cross-chain callback execution |

### Data Flow

```
1. Test calls origin contract            (normal Solidity call)
2. Simulator captures emitted events     (vm.getRecordedLogs())
3. Simulator matches events to subscriptions
4. For each match: builds LogRecord, calls rc.react(logRecord)
5. Simulator captures Callback events from react()
6. Simulator injects RVM ID into callback payload
7. Simulator executes callback on destination contract via MockCallbackProxy
```

## API Reference

### `ReactiveTest` (Base Contract)

Inherit this in your test files. Provides:

#### Setup

| Member | Type | Description |
|---|---|---|
| `sys` | `MockSystemContract` | System contract at `SERVICE_ADDR` |
| `proxy` | `MockCallbackProxy` | Callback proxy for executing callbacks |
| `rvmId` | `address` | Simulated deployer/RVM identity (default: `address(this)`) |

#### Trigger Methods

```solidity
// Trigger event + full reactive cycle (no ETH)
function triggerAndReact(
    address origin,
    bytes memory callData,
    uint256 originChainId
) internal returns (CallbackResult[] memory);

// Trigger event + full reactive cycle (with ETH)
function triggerAndReactWithValue(
    address origin,
    bytes memory callData,
    uint256 value,
    uint256 originChainId
) internal returns (CallbackResult[] memory);

// Trigger a cron event
function triggerCron(CronType cronType)
    internal returns (CallbackResult[] memory);

// Advance N blocks, then trigger cron
function advanceAndTriggerCron(uint256 blocks, CronType cronType)
    internal returns (CallbackResult[] memory);
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
    }

    function testReactionTriggered() public {
        CallbackResult[] memory results = triggerAndReact(
            address(origin),
            abi.encodeWithSignature("emitEvent()"),
            SEPOLIA
        );

        assertCallbackCount(results, 1);
        assertCallbackSuccess(results, 0);
    }

    function testNoReactionForUnrelatedEvent() public {
        address unrelated = makeAddr("unrelated");
        vm.etch(unrelated, address(origin).code);

        CallbackResult[] memory results = triggerAndReact(
            unrelated,      // different contract address
            abi.encodeWithSignature("emitEvent()"),
            SEPOLIA
        );

        assertNoCallbacks(results); // subscription doesn't match
    }

    function testRvmIdInjection() public {
        triggerAndReact(
            address(origin),
            abi.encodeWithSignature("emitEvent()"),
            SEPOLIA
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

### Passing Callback Sender for `authorizedSenderOnly`

`AbstractCallback` authorizes `_callback_sender` in its constructor. Pass `address(proxy)` so the mock proxy satisfies the modifier:

```solidity
// In setUp():
myCallback = new MyCallbackContract(address(proxy));
```

### Passing RVM ID for `rvmIdOnly`

`AbstractCallback` stores `msg.sender` as `rvm_id`. The proxy overwrites the first callback argument with `rvmId`. Override `rvmId` in your test if needed:

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

### `vmOnly` / `rnOnly` Modifiers

`AbstractReactive.detectVm()` checks `extcodesize(SERVICE_ADDR)`. Since we etch mock code to that address, `detectVm()` sets `vm = false` (thinks it's on Reactive Network). This allows `subscribe()` to work in constructors. If your `react()` function uses `vmOnly`, call `enableVmMode(address(rc))` after deployment to flip the flag.

### RVM ID Injection

The real Reactive Network overwrites the first 20 bytes of the first callback argument with the deployer's address. `MockCallbackProxy` replicates this behavior, so `rvmIdOnly` modifiers work correctly in tests.

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
