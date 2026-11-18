// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {MorphoPostCheckTest, MarketParams, Position, Id, IPolicyManager, IPolicy, IMorpho, IERC20} from "./MorphoPostCheck.t.sol";
import {MorphoLoanProtectionPolicy} from "../src/policies-fixed/MorphoLoanProtectionPolicy.sol";
import {MorphoWethLoanProtectionPolicy} from "../src/policies-fixed/MorphoWethLoanProtectionPolicy.sol";
import {Test, console} from "forge-std/Test.sol";

/// @title MORPHO-01 negative control — repo-HEAD (fixed) policies.
/// @dev Same flow as the live PoC, but the policy deployed is the CURRENT repo HEAD
///      (base/account-policies @ e7e85ca), which adds `_onPostExecute`: after the top-up
///      it recomputes LTV and reverts `PostTopUpLtvAboveLltv` if the position is still
///      at/above LLTV. Expected: execute reverts, one-shot NOT consumed, no WETH supplied.
///      The fixed policy is deployed fresh by the test (it is not live); the rest of the
///      stack (PolicyManager, Morpho, market, oracle, SmartWallet factory) is live on-fork.
contract FixedPolicyControlTest is MorphoPostCheckTest {
    error PostTopUpLtvAboveLltv(uint256 postTopUpLtv, uint256 lltv);

    function _deployFixedLoanProt() internal returns (address) {
        return address(new MorphoLoanProtectionPolicy(PM, address(this), MORPHO, 0.95 ether));
    }

    function _deployFixedWethLoanProt() internal returns (address) {
        return address(new MorphoWethLoanProtectionPolicy(PM, address(this), MORPHO, WETH, 0.95 ether));
    }

    /// @dev Assert that `PM.execute` reverts with PostTopUpLtvAboveLltv(postLtv >= lltv).
    ///      Uses a low-level call + selector check (robust to the fork-dependent LTV value).
    function _expectPostTopUpRevert(address fixedPolicy, bytes32 policyId, bytes memory policyConfig, bytes memory executionData) internal {
        (bool ok, bytes memory ret) = PM.call(
            abi.encodeWithSelector(IPolicyManager.execute.selector, fixedPolicy, policyId, policyConfig, executionData)
        );
        assertFalse(ok, "fixed policy execute must revert");
        assertEq(bytes4(ret), PostTopUpLtvAboveLltv.selector, "must revert PostTopUpLtvAboveLltv");
        bytes memory args = new bytes(ret.length - 4);
        for (uint256 i; i < args.length; i++) args[i] = ret[i + 4];
        (uint256 postLtv, uint256 lltv) = abi.decode(args, (uint256, uint256));
        console.log("fixed-control post-top-up LTV (wad):", postLtv);
        assertGe(postLtv, lltv, "revert must carry a post-top-up LTV >= LLTV");
    }

    function test_fixedLoanProt_revertsWhenTopUpCannotRestoreHealth() public {
        address fixedPolicy = _deployFixedLoanProt();
        MarketParams memory mp = _marketParams();
        address account = _createAccount();
        deal(WETH, account, COLLATERAL + TOP_UP);
        _openPosition(account, mp);
        (bytes32 policyId, bytes memory policyConfig) = _installPolicy(account, fixedPolicy, mp);

        vm.warp(block.timestamp + 4380 days);
        uint256 ltvAtTrigger = _currentLtv(account, mp);
        console.log("fixed-control LTV at trigger (wad):", ltvAtTrigger);
        assertGe(ltvAtTrigger, mp.lltv, "position must be liquidatable before top-up");

        bytes memory executionData = _signedExecution(
            fixedPolicy, "Morpho Loan Protection Policy", policyId, account, policyConfig, TOP_UP
        );

        _expectPostTopUpRevert(fixedPolicy, policyId, policyConfig, executionData);

        assertFalse(IPolicy(fixedPolicy).isPolicyUsed(policyId), "one-shot must be preserved");
        Position memory pos = IMorpho(MORPHO).position(Id.wrap(MARKET_ID), account);
        assertEq(uint256(pos.collateral), COLLATERAL, "no top-up WETH must be supplied");
        assertEq(IERC20(WETH).balanceOf(account), TOP_UP, "spare WETH must stay in the account");
    }

    function test_fixedWethLoanProt_revertsWhenTopUpCannotRestoreHealth() public {
        address fixedPolicy = _deployFixedWethLoanProt();
        MarketParams memory mp = _marketParams();
        address account = _createAccount();
        deal(WETH, account, COLLATERAL);
        deal(account, TOP_UP);
        _openPosition(account, mp);
        (bytes32 policyId, bytes memory policyConfig) = _installPolicy(account, fixedPolicy, mp);

        vm.warp(block.timestamp + 4380 days);
        assertGe(_currentLtv(account, mp), mp.lltv, "position must be liquidatable before top-up");

        bytes memory executionData = _signedExecution(
            fixedPolicy, "Morpho WETH Loan Protection Policy", policyId, account, policyConfig, TOP_UP
        );

        _expectPostTopUpRevert(fixedPolicy, policyId, policyConfig, executionData);

        assertFalse(IPolicy(fixedPolicy).isPolicyUsed(policyId), "one-shot must be preserved");
        Position memory pos = IMorpho(MORPHO).position(Id.wrap(MARKET_ID), account);
        assertEq(uint256(pos.collateral), COLLATERAL, "no top-up WETH must be supplied");
        assertEq(account.balance, TOP_UP, "spare ETH must stay in the account");
    }
}
