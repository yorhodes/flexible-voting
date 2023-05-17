// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.10;

import {Comet} from "comet/Comet.sol";
import {CometConfiguration} from "comet/CometConfiguration.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/Checkpoints.sol";

import {FlexVotingClient} from "src/FlexVotingClient.sol";

// TODO add description
contract CometFlexVoting is Comet, FlexVotingClient {
  using Checkpoints for Checkpoints.History;

  /// @param _config The configuration struct for this Comet instance.
  /// @param _governor The address of the flex-voting-compatible governance contract.
  constructor(CometConfiguration.Configuration memory _config, address _governor)
    Comet(_config)
    FlexVotingClient(_governor)
  {
    _selfDelegate();
  }

  /// @notice Returns the current balance in storage for the `account`.
  function _rawBalanceOf(address account) internal view override returns (uint256) {
    int104 _principal = userBasic[account].principal;
    return _principal > 0 ? uint256(int256(_principal)) : 0;
  }

  //===========================================================================
  // BEGIN: Comet overrides
  //===========================================================================
  //
  // This function is called any time the underlying balance is changed.
  function updateBasePrincipal(address _account, UserBasic memory _userBasic, int104 _principalNew)
    internal
    override
  {
    Comet.updateBasePrincipal(_account, _userBasic, _principalNew);
    FlexVotingClient._checkpointRawBalanceOf(_account);
    FlexVotingClient.totalDepositCheckpoints.push(uint224(totalSupplyBase));
  }
  //===========================================================================
  // END: Comet overrides
  //===========================================================================
}
