// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { DSTestPlus } from "solmate/test/utils/DSTestPlus.sol";
import { Vm } from "forge-std/Vm.sol";
import { FractionalPool, IVotingToken, IFractionalGovernor } from "../src/FractionalPool.sol";
import "./GovToken.sol";
import "./FractionalGovernor.sol";
import "./ProposalReceiverMock.sol";


contract FractionalPoolTest is DSTestPlus {
    enum ProposalState {
        Pending,
        Active,
        Canceled,
        Defeated,
        Succeeded,
        Queued,
        Expired,
        Executed
    }

    enum VoteType {
        Against,
        For,
        Abstain
    }

    Vm vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    FractionalPool pool;
    GovToken token;
    FractionalGovernor governor;
    ProposalReceiverMock receiver;

    function setUp() public {
        token = new GovToken();
        vm.label(address(token), "token");

        governor = new FractionalGovernor("Governor", IVotes(token));
        vm.label(address(governor), "governor");

        pool = new FractionalPool(IVotingToken(address(token)), IFractionalGovernor(address(governor)));
        vm.label(address(pool), "pool");

        receiver = new ProposalReceiverMock();
        vm.label(address(receiver), "receiver");
    }

    function _mintGovAndApprovePool(address _holder, uint256 _amount) public {
        vm.assume(_holder != address(0));
        token.mint(_holder, _amount);
        vm.prank(_holder);
        token.approve(address(pool), type(uint256).max);
    }

    function _mintGovAndDepositIntoPool(address _address, uint256 _amount) internal {
      _mintGovAndApprovePool(_address, _amount);
      vm.prank(_address);
      pool.deposit(_amount);
    }

    function _createAndSubmitProposal() internal returns(uint256 proposalId) {
      // proposal will underflow if we're on the zero block
      if (block.number == 0) vm.roll(42);

      // create a proposal
      bytes memory receiverCallData = abi.encodeWithSignature("mockReceiverFunction()");
      address[] memory targets = new address[](1);
      uint256[] memory values = new uint256[](1);
      bytes[] memory calldatas = new bytes[](1);
      targets[0] = address(receiver);
      values[0] = 0; // no ETH will be sent
      calldatas[0] = receiverCallData;

      // submit the proposal
      proposalId = governor.propose(targets, values, calldatas, "A great proposal");
      assertEq(uint(governor.state(proposalId)), uint(ProposalState.Pending));

      // advance proposal to active state
      vm.roll(governor.proposalSnapshot(proposalId) + 1);
      assertEq(uint(governor.state(proposalId)), uint(ProposalState.Active));
    }
}

contract Deployment is FractionalPoolTest {

    function test_FractionalPoolDeployment() public {
        assertEq(token.name(), "Governance Token");
        assertEq(token.symbol(), "GOV");

        assertEq(address(pool.token()), address(token));
        assertEq(token.delegates(address(pool)), address(pool));

        assertEq(governor.name(), "Governor");
        assertEq(address(governor.token()), address(token));
    }
}

contract Deposit is FractionalPoolTest {

    function test_UserCanDepositGovTokens(address _holder, uint256 _amount) public {
        _amount = bound(_amount, 0, type(uint224).max);
        uint256 initialBalance = token.balanceOf(_holder);
        _mintGovAndApprovePool(_holder, _amount);

        vm.prank(_holder);
        pool.deposit(_amount);

        assertEq(token.balanceOf(address(pool)), _amount);
        assertEq(token.balanceOf(_holder), initialBalance);
        assertEq(token.getVotes(address(pool)), _amount);
    }
}

contract Vote is FractionalPoolTest {
    function _commonFuzzerAssumptions(address _address, uint256 _voteWeight) public returns(uint256) {
      return _commonFuzzerAssumptions(_address, _voteWeight, uint8(VoteType.Against));
    }

    function _commonFuzzerAssumptions(address _address, uint256 _voteWeight, uint8 _supportType) public returns(uint256) {
        vm.assume(_address != address(pool));
        vm.assume(_supportType <= uint8(VoteType.Abstain)); // couldn't get fuzzer to work w/ the enum
        // This max is a limitation of the fractional governance protocol storage.
        return bound(_voteWeight, 1, type(uint128).max);
    }

    function testFuzz_UserCanCastVotes(
      address _hodler,
      uint256 _voteWeight,
      uint8 _supportType
    ) public {
        _voteWeight = _commonFuzzerAssumptions(_hodler, _voteWeight, _supportType);

        // Deposit some funds.
        _mintGovAndDepositIntoPool(_hodler, _voteWeight);
        emit Debug("block time of deposit:");
        emit Debug(block.timestamp);

        // create the proposal
        uint256 _proposalId = _createAndSubmitProposal();

        // _holder should now be able to express his/her vote on the proposal
        vm.prank(_hodler);
        pool.expressVote(_proposalId, _supportType);
        (
          uint256 _againstVotesExpressed,
          uint256 _forVotesExpressed,
          uint256 _abstainVotesExpressed
        ) = pool.proposalVotes(_proposalId);
        assertEq(_forVotesExpressed, _supportType == uint8(VoteType.For) ? _voteWeight : 0);
        assertEq(_againstVotesExpressed, _supportType == uint8(VoteType.Against) ? _voteWeight : 0);
        assertEq(_abstainVotesExpressed, _supportType == uint8(VoteType.Abstain) ? _voteWeight : 0);

        // no votes have been cast yet
        (uint256 _againstVotes, uint256 _forVotes, uint256 _abstainVotes) = governor.proposalVotes(_proposalId);
        assertEq(_forVotes, 0);
        assertEq(_againstVotes, 0);
        assertEq(_abstainVotes, 0);

        // submit votes on behalf of the pool
        pool.castVote(_proposalId);

        // governor should now record votes from the pool
        (_againstVotes, _forVotes, _abstainVotes) = governor.proposalVotes(_proposalId);
        assertEq(_forVotes, _forVotesExpressed);
        assertEq(_againstVotes, _againstVotesExpressed);
        assertEq(_abstainVotes, _abstainVotesExpressed);
    }

    // user has weight in pool but had no tokens at the time of the snapshot (e.g. funds
    //   were sent to pool before the proposal was created)
    // user can deposit only part of their holdings
    // user cannot vote if he had no token weight at the time of proposal (even if he hadn't deposited at that time)
    // castVote can only be called within a narrow window prior to deadline
    function testFuzz_UserCannotCastWithoutWeightInPool(
      address _hodler,
      uint256 _voteWeight,
      uint8 _supportType
    ) public {
        _voteWeight = _commonFuzzerAssumptions(_hodler, _voteWeight, _supportType);

        // Mint gov but do not deposit
        _mintGovAndApprovePool(_hodler, _voteWeight);
        assertEq(token.balanceOf(_hodler), _voteWeight);
        assertEq(pool.deposits(_hodler), 0);

        // create the proposal
        uint256 _proposalId = _createAndSubmitProposal();

        // _holder should NOT be able to express his/her vote on the proposal
        vm.expectRevert(bytes("no weight"));
        vm.prank(_hodler);
        pool.expressVote(_proposalId, uint8(_supportType));
    }

    function testFuzz_NoDoubleVoting(
      address _hodler,
      uint256 _voteWeight,
      uint8 _supportType
    ) public {
        _voteWeight = _commonFuzzerAssumptions(_hodler, _voteWeight, _supportType);

        // Deposit some funds.
        _mintGovAndApprovePool(_hodler, _voteWeight);
        vm.prank(_hodler);
        pool.deposit(_voteWeight);

        // create the proposal
        uint256 _proposalId = _createAndSubmitProposal();

        // _holder should now be able to express his/her vote on the proposal
        vm.prank(_hodler);
        pool.expressVote(_proposalId, _supportType);

        (
          uint256 _againstVotesExpressedInit,
          uint256 _forVotesExpressedInit,
          uint256 _abstainVotesExpressedInit
        ) = pool.proposalVotes(_proposalId);
        assertEq(_forVotesExpressedInit, _supportType == uint8(VoteType.For) ? _voteWeight : 0);
        assertEq(_againstVotesExpressedInit, _supportType == uint8(VoteType.Against) ? _voteWeight : 0);
        assertEq(_abstainVotesExpressedInit, _supportType == uint8(VoteType.Abstain) ? _voteWeight : 0);

        // vote early and often, people
        vm.expectRevert(bytes("already voted"));
        vm.prank(_hodler);
        pool.expressVote(_proposalId, _supportType);

        // no votes changed
        (
          uint256 _againstVotesExpressed,
          uint256 _forVotesExpressed,
          uint256 _abstainVotesExpressed
        ) = pool.proposalVotes(_proposalId);
        assertEq(_forVotesExpressed, _forVotesExpressedInit);
        assertEq(_againstVotesExpressed, _againstVotesExpressedInit);
        assertEq(_abstainVotesExpressed, _abstainVotesExpressedInit);
    }

    function testFuzz_MultipleUsersCanCastVotes(
      address _hodlerA,
      address _hodlerB,
      uint256 _voteWeightA,
      uint256 _voteWeightB
    ) public {
        // This max is a limitation of the fractional governance protocol storage.
        _voteWeightA = bound(_voteWeightA, 1, type(uint120).max);
        _voteWeightB = bound(_voteWeightB, 1, type(uint120).max);

        vm.assume(_hodlerA != address(pool));
        vm.assume(_hodlerB != address(pool));
        vm.assume(_hodlerA != _hodlerB);

        // Deposit some funds.
        _mintGovAndDepositIntoPool(_hodlerA, _voteWeightA);
        _mintGovAndDepositIntoPool(_hodlerB, _voteWeightB);

        // create the proposal
        uint256 _proposalId = _createAndSubmitProposal();

        // Hodlers should now be able to express their votes on the proposal
        vm.prank(_hodlerA);
        pool.expressVote(_proposalId, uint8(VoteType.Against));
        vm.prank(_hodlerB);
        pool.expressVote(_proposalId, uint8(VoteType.Abstain));

        (
          uint256 _againstVotesExpressed,
          uint256 _forVotesExpressed,
          uint256 _abstainVotesExpressed
        ) = pool.proposalVotes(_proposalId);
        assertEq(_forVotesExpressed, 0);
        assertEq(_againstVotesExpressed, _voteWeightA);
        assertEq(_abstainVotesExpressed, _voteWeightB);

        // the governor should have not recieved any votes yet
        (uint256 _againstVotes, uint256 _forVotes, uint256 _abstainVotes) = governor.proposalVotes(_proposalId);
        assertEq(_forVotes, 0);
        assertEq(_againstVotes, 0);
        assertEq(_abstainVotes, 0);

        // submit votes on behalf of the pool
        pool.castVote(_proposalId);

        // governor should now record votes for the pool
        (_againstVotes, _forVotes, _abstainVotes) = governor.proposalVotes(_proposalId);
        assertEq(_forVotes, 0);
        assertEq(_againstVotes, _voteWeightA);
        assertEq(_abstainVotes, _voteWeightB);
    }
}
