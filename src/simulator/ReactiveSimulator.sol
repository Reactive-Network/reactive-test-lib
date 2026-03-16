// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

import {Vm} from "forge-std/Vm.sol";
import {LogRecord, CallbackResult, IReactive} from "../interfaces/IReactiveInterfaces.sol";
import {MockSystemContract} from "../mock/MockSystemContract.sol";
import {MockCallbackProxy} from "../mock/MockCallbackProxy.sol";
import {ReactiveConstants} from "../constants/ReactiveConstants.sol";

/// @notice Bundled parameters for simulation to avoid stack-too-deep.
struct SimulationParams {
    Vm _vm;
    MockSystemContract sys;
    MockCallbackProxy proxy;
    address rvmId;
    uint256 reactiveChainId;
}

/// @title ReactiveSimulator
/// @notice Orchestrates the full reactive lifecycle (event -> react() -> callback) in a Foundry test.
library ReactiveSimulator {
    /// @notice Simulate the full event -> react() -> callback cycle.
    function simulateReaction(
        Vm _vm,
        address origin,
        bytes memory callData,
        uint256 value,
        uint256 originChainId,
        MockSystemContract sys,
        MockCallbackProxy proxy,
        address rvmId,
        uint256 reactiveChainId
    ) internal returns (CallbackResult[] memory) {
        SimulationParams memory p = SimulationParams(_vm, sys, proxy, rvmId, reactiveChainId);

        // Record logs and execute the triggering call
        _vm.recordLogs();
        (bool ok,) = origin.call{value: value}(callData);
        require(ok, "ReactiveSimulator: origin call failed");
        Vm.Log[] memory logs = _vm.getRecordedLogs();

        return _processLogs(p, logs, originChainId);
    }

    /// @notice Deliver a specific LogRecord to all matching subscribers and execute callbacks.
    function deliverEvent(
        Vm _vm,
        LogRecord memory log,
        MockSystemContract sys,
        MockCallbackProxy proxy,
        address rvmId,
        uint256 reactiveChainId
    ) internal returns (CallbackResult[] memory) {
        SimulationParams memory p = SimulationParams(_vm, sys, proxy, rvmId, reactiveChainId);

        address[] memory subscribers = sys.getMatchingSubscribers(
            log.chain_id, log._contract,
            log.topic_0, log.topic_1, log.topic_2, log.topic_3
        );

        CallbackResult[] memory tempResults = new CallbackResult[](subscribers.length * 4);
        uint256 resultCount = 0;

        for (uint256 i = 0; i < subscribers.length; i++) {
            CallbackResult[] memory cbResults = _deliverAndCapture(p, subscribers[i], log);
            for (uint256 j = 0; j < cbResults.length; j++) {
                tempResults[resultCount++] = cbResults[j];
            }
        }

        return _trimResults(tempResults, resultCount);
    }

    /// @notice Manually deliver a LogRecord to a specific reactive contract (no callback processing).
    function deliverRawEvent(
        Vm _vm,
        IReactive target,
        LogRecord memory log
    ) internal {
        _vm.prank(address(ReactiveConstants.SERVICE_ADDR));
        target.react(log);
    }

    // ---- Internal helpers ----

    function _processLogs(
        SimulationParams memory p,
        Vm.Log[] memory logs,
        uint256 originChainId
    ) private returns (CallbackResult[] memory) {
        CallbackResult[] memory tempResults = new CallbackResult[](logs.length * 4);
        uint256 resultCount = 0;

        for (uint256 i = 0; i < logs.length; i++) {
            uint256 rc = _processOneLog(p, logs[i], originChainId, tempResults, resultCount);
            resultCount = rc;
        }

        return _trimResults(tempResults, resultCount);
    }

    function _processOneLog(
        SimulationParams memory p,
        Vm.Log memory entry,
        uint256 originChainId,
        CallbackResult[] memory tempResults,
        uint256 resultCount
    ) private returns (uint256) {
        // Extract topics
        uint256 t0 = entry.topics.length > 0 ? uint256(entry.topics[0]) : 0;
        uint256 t1 = entry.topics.length > 1 ? uint256(entry.topics[1]) : 0;
        uint256 t2 = entry.topics.length > 2 ? uint256(entry.topics[2]) : 0;
        uint256 t3 = entry.topics.length > 3 ? uint256(entry.topics[3]) : 0;

        address[] memory subscribers = p.sys.getMatchingSubscribers(
            originChainId, entry.emitter, t0, t1, t2, t3
        );

        if (subscribers.length == 0) return resultCount;

        LogRecord memory log = _buildLogRecord(entry, originChainId, t0, t1, t2, t3);

        for (uint256 j = 0; j < subscribers.length; j++) {
            CallbackResult[] memory cbResults = _deliverAndCapture(p, subscribers[j], log);
            for (uint256 k = 0; k < cbResults.length; k++) {
                tempResults[resultCount++] = cbResults[k];
            }
        }

        return resultCount;
    }

    function _buildLogRecord(
        Vm.Log memory entry,
        uint256 chainId,
        uint256 t0,
        uint256 t1,
        uint256 t2,
        uint256 t3
    ) private view returns (LogRecord memory) {
        return LogRecord({
            chain_id: chainId,
            _contract: entry.emitter,
            topic_0: t0,
            topic_1: t1,
            topic_2: t2,
            topic_3: t3,
            data: entry.data,
            block_number: block.number,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });
    }

    /// @dev Calls react() on a subscriber, captures Callback events, and executes them.
    function _deliverAndCapture(
        SimulationParams memory p,
        address subscriber,
        LogRecord memory log
    ) private returns (CallbackResult[] memory) {
        // Record logs to capture Callback events from react()
        p._vm.recordLogs();
        p._vm.prank(address(ReactiveConstants.SERVICE_ADDR));
        IReactive(subscriber).react(log);
        Vm.Log[] memory reactLogs = p._vm.getRecordedLogs();

        return _extractCallbacks(p, reactLogs);
    }

    function _extractCallbacks(
        SimulationParams memory p,
        Vm.Log[] memory reactLogs
    ) private returns (CallbackResult[] memory) {
        bytes32 cbTopic = ReactiveConstants.CALLBACK_EVENT_TOPIC;

        // Count callback events
        uint256 cbCount = 0;
        for (uint256 i = 0; i < reactLogs.length; i++) {
            if (reactLogs[i].topics.length >= 4 && reactLogs[i].topics[0] == cbTopic) {
                cbCount++;
            }
        }

        CallbackResult[] memory results = new CallbackResult[](cbCount);
        uint256 idx = 0;

        for (uint256 i = 0; i < reactLogs.length; i++) {
            if (reactLogs[i].topics.length < 4 || reactLogs[i].topics[0] != cbTopic) continue;

            results[idx++] = _executeOneCallback(p, reactLogs[i]);
        }

        return results;
    }

    function _executeOneCallback(
        SimulationParams memory p,
        Vm.Log memory logEntry
    ) private returns (CallbackResult memory) {
        uint256 chainId = uint256(logEntry.topics[1]);
        address target = address(uint160(uint256(logEntry.topics[2])));
        uint64 gasLimit = uint64(uint256(logEntry.topics[3]));
        bytes memory payload = abi.decode(logEntry.data, (bytes));

        bool success;
        bytes memory returnData;

        if (chainId == p.reactiveChainId) {
            // Same-chain callback (reactive contract calling itself or another RN contract).
            // On the real network, these are delivered by SERVICE_ADDR, not the callback proxy.
            // Inject RVM ID into payload first argument (same as proxy does).
            if (payload.length >= 36) {
                assembly {
                    let argStart := add(add(payload, 0x20), 4)
                    mstore(argStart, mload(add(p, 0x60))) // p.rvmId is at offset 0x60 in struct
                }
            }
            p._vm.prank(address(ReactiveConstants.SERVICE_ADDR));
            (success, returnData) = target.call{gas: gasLimit}(payload);
        } else {
            // Cross-chain callback — deliver via the callback proxy.
            (success, returnData) = p.proxy.executeCallback(
                target, payload, gasLimit, p.rvmId
            );
        }

        return CallbackResult({
            chainId: chainId,
            target: target,
            gasLimit: gasLimit,
            payload: payload,
            success: success,
            returnData: returnData
        });
    }

    function _trimResults(
        CallbackResult[] memory tempResults,
        uint256 count
    ) private pure returns (CallbackResult[] memory) {
        CallbackResult[] memory results = new CallbackResult[](count);
        for (uint256 i = 0; i < count; i++) {
            results[i] = tempResults[i];
        }
        return results;
    }
}
