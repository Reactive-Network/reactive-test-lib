// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {MockSystemContract} from "../mock/MockSystemContract.sol";
import {MockCallbackProxy} from "../mock/MockCallbackProxy.sol";
import {ReactiveSimulator} from "../simulator/ReactiveSimulator.sol";
import {CronSimulator} from "../simulator/CronSimulator.sol";
import {ReactiveConstants} from "../constants/ReactiveConstants.sol";
import {CallbackResult, CronType} from "../interfaces/IReactiveInterfaces.sol";

/// @title ReactiveTest
/// @notice Base test contract for testing Reactive Network contracts locally.
///         Extends forge-std/Test.sol and wires up the mock environment automatically.
///
/// @dev Usage:
///   1. Inherit from ReactiveTest
///   2. Call super.setUp() in your setUp()
///   3. Deploy your reactive/callback contracts — they will interact with MockSystemContract
///   4. Use triggerAndReact() / triggerCron() to simulate the reactive lifecycle
abstract contract ReactiveTest is Test {
    MockSystemContract internal sys;
    MockCallbackProxy internal proxy;
    address internal rvmId;

    function setUp() public virtual {
        // 1. Deploy MockSystemContract to a regular address
        MockSystemContract sysImpl = new MockSystemContract();

        // 2. Etch its runtime code to SERVICE_ADDR so AbstractReactive constructors detect code
        //    and subscribe() calls route to our mock
        address serviceAddr = address(ReactiveConstants.SERVICE_ADDR);
        vm.etch(serviceAddr, address(sysImpl).code);
        sys = MockSystemContract(payable(serviceAddr));

        // 3. Deploy MockCallbackProxy
        proxy = new MockCallbackProxy();

        // 4. Set rvmId to the test contract address (simulates the deployer)
        rvmId = address(this);
    }

    // ---- Convenience: Enable VM mode on a reactive contract ----

    /// @notice Enables VM mode on a reactive contract so vmOnly modifiers pass.
    /// @dev After etching SERVICE_ADDR, detectVm() sets vm=false (code exists).
    ///      This flips the `vm` storage slot (slot 2 in AbstractReactive) to true.
    ///      Call this after deploying each reactive contract.
    function enableVmMode(address rc) internal {
        vm.store(rc, ReactiveConstants.VM_STORAGE_SLOT, bytes32(uint256(1)));
    }

    // ---- Convenience: Trigger and react ----

    /// @notice Trigger an event on an origin contract and run the full reactive cycle.
    /// @param origin The contract to call (emits triggering events).
    /// @param callData Encoded function call to execute on origin.
    /// @param originChainId Chain ID to stamp on LogRecords.
    /// @return results Array of callback execution results.
    function triggerAndReact(
        address origin,
        bytes memory callData,
        uint256 originChainId
    ) internal returns (CallbackResult[] memory results) {
        return ReactiveSimulator.simulateReaction(
            vm, origin, callData, 0, originChainId, sys, proxy, rvmId
        );
    }

    /// @notice Trigger an event with ETH value and run the full reactive cycle.
    /// @param origin The contract to call.
    /// @param callData Encoded function call.
    /// @param value ETH value to send.
    /// @param originChainId Chain ID to stamp on LogRecords.
    /// @return results Array of callback execution results.
    function triggerAndReactWithValue(
        address origin,
        bytes memory callData,
        uint256 value,
        uint256 originChainId
    ) internal returns (CallbackResult[] memory results) {
        return ReactiveSimulator.simulateReaction(
            vm, origin, callData, value, originChainId, sys, proxy, rvmId
        );
    }

    // ---- Convenience: Cron ----

    /// @notice Trigger a cron event and deliver to matching subscribers.
    function triggerCron(CronType cronType) internal returns (CallbackResult[] memory) {
        return CronSimulator.triggerCron(vm, cronType, sys, proxy, rvmId);
    }

    /// @notice Advance blocks and trigger a cron event.
    function advanceAndTriggerCron(uint256 blocks, CronType cronType)
        internal
        returns (CallbackResult[] memory)
    {
        return CronSimulator.advanceAndTriggerCron(vm, blocks, cronType, sys, proxy, rvmId);
    }

    // ---- Assertion helpers ----

    /// @notice Assert that a callback was emitted targeting a specific address.
    function assertCallbackEmitted(CallbackResult[] memory results, address expectedTarget) internal pure {
        for (uint256 i = 0; i < results.length; i++) {
            if (results[i].target == expectedTarget) return;
        }
        revert("ReactiveTest: no callback emitted to expected target");
    }

    /// @notice Assert the exact number of callbacks produced.
    function assertCallbackCount(CallbackResult[] memory results, uint256 expected) internal pure {
        require(
            results.length == expected,
            string.concat(
                "ReactiveTest: expected ",
                vm.toString(expected),
                " callbacks, got ",
                vm.toString(results.length)
            )
        );
    }

    /// @notice Assert no callbacks were produced.
    function assertNoCallbacks(CallbackResult[] memory results) internal pure {
        require(results.length == 0, "ReactiveTest: expected no callbacks");
    }

    /// @notice Assert that a specific callback succeeded.
    function assertCallbackSuccess(CallbackResult[] memory results, uint256 index) internal pure {
        require(index < results.length, "ReactiveTest: callback index out of bounds");
        require(results[index].success, "ReactiveTest: callback did not succeed");
    }

    /// @notice Assert that a specific callback failed.
    function assertCallbackFailure(CallbackResult[] memory results, uint256 index) internal pure {
        require(index < results.length, "ReactiveTest: callback index out of bounds");
        require(!results[index].success, "ReactiveTest: callback did not fail");
    }
}
