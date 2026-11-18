// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test, console} from "forge-std/Test.sol";

/// @title MORPHO-01 PoC — live MorphoLoanProtectionPolicy / MorphoWETHLoanProtectionPolicy
///        lack the post-execution health check (repo HEAD adds it).
///
/// @dev Forks Base mainnet at block 59043631 and uses the LIVE deployed contracts
///      (PolicyManager 0x75b3.., MorphoLoanProtectionPolicy 0x001B.., MorphoWETHLoanProtectionPolicy
///      0xe14A.., Morpho Blue 0xBBBB.., WETH/USDC market 0x8793.. (LLTV 86%, supply ~$94M,
///      oracle 0xFEa2..)).
///      All keys are fresh test keys; the executor intent is genuinely EIP-712 signed with vm.sign.
///      No vm.prank as any owner/admin. The test contract is a co-owner of the freshly created
///      SmartWallet (matching production setup where the user adds the PolicyManager as owner).
///      The only unreal element is vm.warp (standard fork testing).
///
///      Scenario (per test):
///        1. Create a SmartWallet (owners: test contract + PolicyManager), fund with 100 WETH.
///        2. Supply 100 WETH to Morpho WETH/USDC (LLTV 86%), borrow USDC to ~85% LTV.
///        3. Install the live policy (trigger 75%, maxTopUp 1 WETH, executor = fresh test key).
///        4. Warp 4380 days: interest pushes debt up, LTV crosses LLTV and keeps climbing
///           (the warp stands in for a price move, which would jump LTV the same way in
///           production — the oracle price is pinned on a fork, so interest is the only
///           lever that moves LTV here; a ~15% WETH price drop would do the same instantly).
///        5. Executor signs a 1-WETH top-up intent; PolicyManager.execute succeeds.
///        6. ASSERT: execution succeeded, one-shot consumed, top-up WETH supplied,
///           post-top-up LTV is STILL >= LLTV (position still liquidatable).
///        7. Liquidate the whole position: the liquidator seizes the topped-up WETH too.
///      Counterfactual (no top-up): the same 1 WETH stays in the wallet after liquidation.
///      Fixed-code control lives in scratch/poc-fixed (same test vs repo-HEAD policy).
interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IWETH is IERC20 {
    function deposit() external payable;
}

interface IOracle {
    function price() external view returns (uint256);
}

type Id is bytes32;

struct MarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

struct Position {
    uint256 supplyShares;
    uint128 borrowShares;
    uint128 collateral;
}

struct Market {
    uint128 totalSupplyAssets;
    uint128 totalSupplyShares;
    uint128 totalBorrowAssets;
    uint128 totalBorrowShares;
    uint128 lastUpdate;
    uint128 fee;
}

interface IMorpho {
    function idToMarketParams(Id id) external view returns (MarketParams memory);
    function position(Id id, address user) external view returns (Position memory);
    function market(Id id) external view returns (Market memory);
    function accrueInterest(MarketParams memory marketParams) external;
    function supplyCollateral(MarketParams memory marketParams, uint256 assets, address onBehalf, bytes memory data)
        external;
    function borrow(MarketParams memory marketParams, uint256 assets, uint256 shares, address onBehalf, address receiver)
        external returns (uint256, uint256);
    function liquidate(MarketParams memory marketParams, address borrower, uint256 seizedAssets, uint256 shares, bytes memory data)
        external returns (uint256, uint256);
}

struct PolicyBinding {
    address account;
    address policy;
    bytes policyConfig;
    uint40 validAfter;
    uint40 validUntil;
    uint256 salt;
}

interface IPolicyManager {
    function install(PolicyBinding calldata binding) external;
    function execute(address policy, bytes32 policyId, bytes calldata policyConfig, bytes calldata executionData) external;
    function getPolicyId(PolicyBinding calldata binding) external pure returns (bytes32 policyId);
}

interface IPolicy {
    function isPolicyUsed(bytes32 policyId) external view returns (bool);
}

struct Call {
    address target;
    uint256 value;
    bytes data;
}

interface ISmartWallet {
    function execute(address target, uint256 value, bytes calldata data) external payable;
    function executeBatch(Call[] calldata calls) external payable;
}

interface IFactory {
    function createAccount(bytes[] calldata owners, uint256 nonce) external payable returns (address);
}

struct SingleExecutorExecutionData {
    uint256 nonce;
    uint256 deadline;
    bytes signature;
}

contract MorphoPostCheckTest is Test {
    uint256 constant FORK_BLOCK = 59043631;

    address constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant PM = 0x75b3015780776952102a8bFA6202d2e3c1F4EFc5;
    address constant LOAN_PROT = 0x001B6f938eA6D0A57D02B3e9503b958149A2a7e3;
    address constant WETH_LOAN_PROT = 0xe14A101ADF9AE492Dd8e9D2ED7763460A6AE8Cd7;
    address constant FACTORY = 0x0BA5ED0c6AA8c49038F819E587E2633c4A9F428a;

    bytes32 constant MARKET_ID = 0x8793cf302b8ffd655ab97bd1c695dbd967807e8367a65cb2f4edaf1380ba1bda;
    uint256 constant TRIGGER_LTV = 0.75 ether; // 75% < LLTV 86%
    uint256 constant MAX_TOP_UP = 1 ether;
    uint256 constant COLLATERAL = 100 ether;
    uint256 constant TOP_UP = 1 ether;

    bytes32 constant EXECUTION_TYPEHASH = keccak256(
        "Execution(bytes32 policyId,address account,bytes32 policyConfigHash,ExecutionData executionData)"
        "ExecutionData(bytes actionData,uint256 nonce,uint256 deadline)"
    );
    bytes32 constant EXECUTION_DATA_TYPEHASH =
        keccak256("ExecutionData(bytes actionData,uint256 nonce,uint256 deadline)");

    uint256 internal executorPk = 0xBEEF1234;
    address internal executor;

    function setUp() public {
        vm.createSelectFork("base", FORK_BLOCK);
        executor = vm.addr(executorPk);
        vm.deal(address(this), 100 ether);
    }

    /*//////////////////////////////////////////////////////////////
                              HELPERS
    //////////////////////////////////////////////////////////////*/

    function _marketParams() internal view returns (MarketParams memory) {
        return IMorpho(MORPHO).idToMarketParams(Id.wrap(MARKET_ID));
    }

    function _createAccount() internal returns (address account) {
        bytes[] memory owners = new bytes[](2);
        owners[0] = abi.encode(address(this));
        owners[1] = abi.encode(PM);
        account = IFactory(FACTORY).createAccount(owners, 0);
    }

    function _accountCall(address account, address target, uint256 value, bytes memory data) internal {
        ISmartWallet(account).execute(target, value, data);
    }

    /// @dev Supply 100 WETH, borrow USDC to ~84% LTV. Returns the borrow amount (USDC, 6 dec).
    function _openPosition(address account, MarketParams memory mp) internal returns (uint256 borrowAssets) {
        _accountCall(account, WETH, 0, abi.encodeWithSelector(IERC20.approve.selector, MORPHO, COLLATERAL));
        Call[] memory calls = new Call[](2);
        calls[0] = Call({
            target: MORPHO,
            value: 0,
            data: abi.encodeWithSelector(
                IMorpho.supplyCollateral.selector, mp, COLLATERAL, account, bytes("")
            )
        });
        uint256 price = IOracle(mp.oracle).price();
        uint256 collateralValue = (COLLATERAL * price) / 1e36; // USDC smallest units (6 dec)
        borrowAssets = (collateralValue * 85) / 100;
        calls[1] = Call({
            target: MORPHO,
            value: 0,
            data: abi.encodeWithSelector(IMorpho.borrow.selector, mp, borrowAssets, 0, account, account)
        });
        ISmartWallet(account).executeBatch(calls);
    }

    function _installPolicy(address account, address policy, MarketParams memory mp)
        internal
        returns (bytes32 policyId, bytes memory policyConfig)
    {
        // policyConfig = abi.encode(SingleExecutorConfig(executor), abi.encode(LoanProtectionPolicyConfig(...)))
        bytes memory specific = abi.encode(MARKET_ID, TRIGGER_LTV, MAX_TOP_UP);
        policyConfig = abi.encode(executor, specific);
        PolicyBinding memory binding = PolicyBinding({
            account: account,
            policy: policy,
            policyConfig: policyConfig,
            validAfter: 0,
            validUntil: 0,
            salt: 1
        });
        policyId = IPolicyManager(PM).getPolicyId(binding);
        _accountCall(account, PM, 0, abi.encodeWithSelector(IPolicyManager.install.selector, binding));
    }

    function _execDigest(address policy, string memory domainName, bytes32 policyId, address account, bytes32 configHash, bytes memory actionData, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 executionDataHash =
            keccak256(abi.encode(EXECUTION_DATA_TYPEHASH, keccak256(actionData), nonce, deadline));
        bytes32 structHash =
            keccak256(abi.encode(EXECUTION_TYPEHASH, policyId, account, configHash, executionDataHash));
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(domainName)),
                keccak256(bytes("1")),
                block.chainid,
                policy
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function _signedExecution(
        address policy,
        string memory domainName,
        bytes32 policyId,
        address account,
        bytes memory policyConfig,
        uint256 topUpAssets
    ) internal returns (bytes memory executionData) {
        bytes memory actionData = abi.encode(topUpAssets); // TopUpData(topUpAssets)
        uint256 nonce = 1;
        uint256 deadline = 0;
        bytes32 digest = _execDigest(
            policy, domainName, policyId, account, keccak256(policyConfig), actionData, nonce, deadline
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(executorPk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);
        // executionData = abi.encode(SingleExecutorExecutionData(nonce, deadline, signature), actionData)
        // NOTE: the struct is a dynamic tuple, so it must be encoded as a tuple (with the
        // leading offset), not as flat (nonce, deadline, sig, actionData) words.
        executionData = abi.encode(SingleExecutorExecutionData(nonce, deadline, sig), actionData);
    }

    /// @dev Current LTV (wad) of `account` in market `mp`, after accruing interest.
    function _currentLtv(address account, MarketParams memory mp) internal returns (uint256 ltvWad) {
        IMorpho(MORPHO).accrueInterest(mp);
        Position memory pos = IMorpho(MORPHO).position(Id.wrap(MARKET_ID), account);
        Market memory mkt = IMorpho(MORPHO).market(Id.wrap(MARKET_ID));
        uint256 debtAssets;
        if (pos.borrowShares > 0) {
            // Morpho virtual shares/assets: totalBorrowAssets+1 / totalBorrowShares+1 (rounding up)
            debtAssets = (uint256(pos.borrowShares) * (uint256(mkt.totalBorrowAssets) + 1))
                / (uint256(mkt.totalBorrowShares) + 1);
            // round up to be conservative
            if ((uint256(pos.borrowShares) * (uint256(mkt.totalBorrowAssets) + 1)) % (uint256(mkt.totalBorrowShares) + 1) != 0) {
                debtAssets += 1;
            }
        }
        uint256 price = IOracle(mp.oracle).price();
        uint256 collateralValue = (uint256(pos.collateral) * price) / 1e36;
        require(collateralValue > 0, "zero collateral value");
        ltvWad = (debtAssets * 1e18) / collateralValue;
    }

    function _liquidateAll(address account, MarketParams memory mp, uint256 seizedAssets) internal {
        uint256 usdcNeeded = 200_000e6;
        deal(USDC, address(this), usdcNeeded);
        IERC20(USDC).approve(MORPHO, usdcNeeded);
        IMorpho(MORPHO).liquidate(mp, account, seizedAssets, 0, bytes(""));
    }

    /*//////////////////////////////////////////////////////////////
                              TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice LIVE MorphoLoanProtectionPolicy: top-up executes while the position stays
    ///         liquidatable afterwards; the topped-up WETH is then seized by a liquidator.
    function test_liveLoanProt_topUpIntoLiquidatablePosition() public {
        MarketParams memory mp = _marketParams();
        require(mp.lltv == 0.86 ether, "unexpected LLTV");

        address account = _createAccount();
        deal(WETH, account, COLLATERAL + TOP_UP); // 100 WETH to supply + 1 WETH spare for the top-up
        uint256 borrowAssets = _openPosition(account, mp);
        (bytes32 policyId, bytes memory policyConfig) = _installPolicy(account, LOAN_PROT, mp);

        uint256 ltvBefore = _currentLtv(account, mp);
        console.log("LTV after open (wad):", ltvBefore);
        assertApproxEqRel(ltvBefore, 0.85 ether, 0.01 ether, "open LTV should be ~85%");

        vm.warp(block.timestamp + 4380 days);

        uint256 ltvAtTrigger = _currentLtv(account, mp);
        console.log("LTV after 4380d warp (wad):", ltvAtTrigger);
        console.log("LLTV (wad):", mp.lltv);
        assertGe(ltvAtTrigger, mp.lltv, "position must be liquidatable (LTV >= LLTV) before top-up");

        // Executor signs a 1-WETH top-up intent (genuine EIP-712 signature, fresh test key).
        bytes memory executionData = _signedExecution(
            LOAN_PROT, "Morpho Loan Protection Policy", policyId, account, policyConfig, TOP_UP
        );

        // THE BUG: this succeeds even though the top-up cannot restore health.
        IPolicyManager(PM).execute(LOAN_PROT, policyId, policyConfig, executionData);

        // Post-execution state: one-shot consumed, top-up supplied, position STILL liquidatable.
        assertTrue(IPolicy(LOAN_PROT).isPolicyUsed(policyId), "one-shot must be consumed");
        Position memory pos = IMorpho(MORPHO).position(Id.wrap(MARKET_ID), account);
        assertEq(uint256(pos.collateral), COLLATERAL + TOP_UP, "top-up WETH must be supplied");
        assertEq(IERC20(WETH).balanceOf(account), 0, "spare WETH must have left the account");

        uint256 ltvAfter = _currentLtv(account, mp);
        console.log("LTV after top-up (wad):", ltvAfter);
        assertGe(ltvAfter, mp.lltv, "BUG: post-top-up LTV still >= LLTV (position still liquidatable)");

        // Liquidator seizes the whole position — including the freshly topped-up WETH.
        uint256 wethBefore = IERC20(WETH).balanceOf(address(this));
        _liquidateAll(account, mp, COLLATERAL + TOP_UP);
        uint256 seized = IERC20(WETH).balanceOf(address(this)) - wethBefore;
        console.log("WETH seized by liquidator:", seized);
        assertEq(seized, COLLATERAL + TOP_UP, "liquidator must seize all 101 WETH incl. the top-up");
        Position memory posAfter = IMorpho(MORPHO).position(Id.wrap(MARKET_ID), account);
        assertEq(uint256(posAfter.collateral), 0, "position collateral must be zero after liquidation");
        console.log("borrowAssets at open (USDC 6dec):", borrowAssets);
    }

    /// @notice Counterfactual: same setup, no top-up executed. The spare 1 WETH stays in the
    ///         wallet after liquidation — the top-up is what loses it in the main test.
    function test_counterfactual_noTopUp_spareWethSurvives() public {
        MarketParams memory mp = _marketParams();
        address account = _createAccount();
        deal(WETH, account, COLLATERAL + TOP_UP);
        _openPosition(account, mp);
        // Policy installed but never executed.
        _installPolicy(account, LOAN_PROT, mp);

        vm.warp(block.timestamp + 4380 days);
        assertGe(_currentLtv(account, mp), mp.lltv, "position must be liquidatable");

        uint256 wethBefore = IERC20(WETH).balanceOf(address(this));
        _liquidateAll(account, mp, COLLATERAL);
        uint256 seized = IERC20(WETH).balanceOf(address(this)) - wethBefore;
        assertEq(seized, COLLATERAL, "liquidator seizes only the 100 WETH supplied");
        assertEq(IERC20(WETH).balanceOf(account), TOP_UP, "spare 1 WETH must survive in the wallet");
    }

    /// @notice LIVE MorphoWETHLoanProtectionPolicy: same bug via the ETH-wrapping variant.
    function test_liveWethLoanProt_topUpIntoLiquidatablePosition() public {
        MarketParams memory mp = _marketParams();
        address account = _createAccount();
        deal(WETH, account, COLLATERAL);
        deal(account, TOP_UP); // 1 ETH for the policy to wrap into WETH
        _openPosition(account, mp);
        (bytes32 policyId, bytes memory policyConfig) = _installPolicy(account, WETH_LOAN_PROT, mp);

        vm.warp(block.timestamp + 4380 days);
        uint256 ltvAtTrigger = _currentLtv(account, mp);
        console.log("WETH variant LTV at trigger (wad):", ltvAtTrigger);
        assertGe(ltvAtTrigger, mp.lltv, "position must be liquidatable before top-up");

        bytes memory executionData = _signedExecution(
            WETH_LOAN_PROT, "Morpho WETH Loan Protection Policy", policyId, account, policyConfig, TOP_UP
        );

        IPolicyManager(PM).execute(WETH_LOAN_PROT, policyId, policyConfig, executionData);

        assertTrue(IPolicy(WETH_LOAN_PROT).isPolicyUsed(policyId), "one-shot must be consumed");
        Position memory pos = IMorpho(MORPHO).position(Id.wrap(MARKET_ID), account);
        assertEq(uint256(pos.collateral), COLLATERAL + TOP_UP, "top-up WETH must be supplied");
        assertEq(account.balance, 0, "spare ETH must have been wrapped and supplied");

        uint256 ltvAfter = _currentLtv(account, mp);
        console.log("WETH variant LTV after top-up (wad):", ltvAfter);
        assertGe(ltvAfter, mp.lltv, "BUG: post-top-up LTV still >= LLTV (position still liquidatable)");

        uint256 wethBefore = IERC20(WETH).balanceOf(address(this));
        _liquidateAll(account, mp, COLLATERAL + TOP_UP);
        uint256 seized = IERC20(WETH).balanceOf(address(this)) - wethBefore;
        assertEq(seized, COLLATERAL + TOP_UP, "liquidator must seize all 101 WETH incl. the top-up");
    }
}
