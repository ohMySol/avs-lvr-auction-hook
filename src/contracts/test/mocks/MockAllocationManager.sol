// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IAllocationManagerTypes} from "eigenlayer-contracts/src/contracts/interfaces/IAllocationManager.sol";
import {OperatorSet} from "eigenlayer-contracts/src/contracts/libraries/OperatorSetLib.sol";

/// @title MockAllocationManager
/// @author ohMySol
/// @notice Minimal in for EigenLayer's `AllocationManager`, implementing only the three
/// methods `AuctionServiceManager` actually calls: `isMemberOfOperatorSet`, `createOperatorSets`,
/// and `slashOperator`. Membership is set manually via `setMember`; slash calls are recorded so
/// tests can assert which operators were slashed. Test-only — never deploy to production.
/// @dev `AuctionServiceManager` holds this behind an `IAllocationManager` cast; only the
/// implemented selectors are ever invoked, so the unimplemented interface surface is irrelevant.
contract MockAllocationManager {
    /* MEMBERSHIP */

    /// @notice key(operator, avs, operatorSetId) => is member.
    mapping(bytes32 => bool) private _members;

    /* SLASHING / CREATION RECORDS */

    /// @notice Operators passed to `slashOperator`, in call order.
    address[] public slashedOperators;

    /// @notice Number of times `createOperatorSets` was called.
    uint256 public createOperatorSetsCalls;

    /* TEST SETUP HELPERS */

    /// @notice Marks `operator` as a member (or not) of operator set `id` for AVS `avs`.
    function setMember(address operator, address avs, uint32 id, bool isMember) external {
        _members[_key(operator, avs, id)] = isMember;
    }

    /// @notice Number of slash calls recorded.
    function slashCount() external view returns (uint256) {
        return slashedOperators.length;
    }

    /* IAllocationManager SUBSET */

    function isMemberOfOperatorSet(address operator, OperatorSet memory operatorSet)
        external
        view
        returns (bool)
    {
        return _members[_key(operator, operatorSet.avs, operatorSet.id)];
    }

    function createOperatorSets(address, IAllocationManagerTypes.CreateSetParams[] calldata)
        external
    {
        createOperatorSetsCalls++;
    }

    function slashOperator(address, IAllocationManagerTypes.SlashingParams calldata params)
        external
        returns (uint256 slashId, uint256[] memory shares)
    {
        slashedOperators.push(params.operator);
        shares = new uint256[](params.strategies.length);
        slashId = slashedOperators.length;
    }

    /* INTERNAL */

    function _key(address operator, address avs, uint32 id) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(operator, avs, id));
    }
}
