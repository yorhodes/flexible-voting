// SPDX-License-Identifier: Unlicensed
pragma solidity >=0.8.10;

import {IPool} from "aave-v3-core/contracts/interfaces/IPool.sol";
import {ATokenFlexVoting} from "src/ATokenFlexVoting.sol";

contract MockATokenFlexVoting is ATokenFlexVoting {
  constructor(IPool _pool, address _governor, uint32 _castVoteWindow)
    ATokenFlexVoting(_pool, _governor, _castVoteWindow)
  {}

  function handleRepayment(address user, uint256 amount) external virtual onlyPool {
    // We need this because the Aave code we compile is ahead of the Aave code deployed on
    // Optimism (where our tests fork from).
    //
    // Currently on Optimism, AToken.handleRepayment is a 2-argument function, as seen in the
    // existing AToken implementation:
    //
    //   https://optimistic.etherscan.io/address/0xa5ba6e5ec19a1bf23c857991c857db62b2aa187b#code
    //
    // But in the latest Aave v3 code, it is a 3-argument function:
    //
    //   https://github.com/aave/aave-v3-core/blob/c38c627683c0db0449b7c9ea2fbd68bde3f8dc01/contracts/protocol/tokenization/AToken.sol#L166-L170
    //
    // The change was made as a result of this issue:
    //
    //   https://github.com/aave/aave-v3-core/issues/742
    //
    // We expect that the on-chain AToken implementation will be upgraded to
    // AToken.handleRepayment/3 at some point in the future. If/when that happens, we should remove
    // this. But for now we need our aToken to have this function in our fork tests to maintain
    // backwards compatibility.
  }

  function exposed_RawBalanceOf(address _user) public view returns (uint256) {
    return _userState[_user].balance;
  }
}