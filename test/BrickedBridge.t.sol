// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

/*
 * Boba LZ bridge is bricked by empty adapter params (ULNv301)
 *
 * Every Boba LayerZero bridge forces empty adapter params
 * (useCustomAdapterParams == false), but the live LayerZero send
 * libraries (ULNv301 on ETH/BSC/Fantom, ULNv3 on Avalanche) reject
 * empty options with LZ_ULN_InvalidWorkerOptions(0). All deposits
 * and all withdrawals revert, except Moonbeam (still on ULNv2).
 * LayerZero announced this on 2026-08-07: the default V1 library
 * moved from ULNv2 to ULNv301 on 2026-08-04, and empty adapter
 * params revert under ULNv301. Boba never applied the fix.
 *
 * Each contract below runs against its own chain fork. See README.md
 * for the exact commands. Fork blocks are pinned per chain.
 */

error LZ_ULN_InvalidWorkerOptions(uint256);

interface IAltL1Bridge {
    function withdraw(address _l2Token, uint256 _amount, address _zroPaymentAddress, bytes memory _adapterParams, bytes calldata _data) external payable;
    function setUseCustomAdapterParams(bool _use, uint _dstGasAmount) external;
    function useCustomAdapterParams() external view returns (bool);
    function transferredAmount() external view returns (uint256);
    function owner() external view returns (address);
}

interface IEthBridge {
    function depositERC20(address _l1Token, address _l2Token, uint256 _amount, address _zroPaymentAddress, bytes memory _adapterParams, bytes memory _data) external payable;
    function setUseCustomAdapterParams(bool _use, uint _dstGasAmount) external;
    function useCustomAdapterParams() external view returns (bool);
    function owner() external view returns (address);
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

abstract contract BrickedBridgeBase is Test {
    address constant USER = 0x1111111111111111111111111111111111111111;

    function v1Params() internal pure returns (bytes memory) {
        return abi.encodePacked(uint16(1), uint256(200000));
    }
}

/// BSC fork, block 134081699. BSC -> ETH withdrawals are bricked.
contract BscWithdrawTest is BrickedBridgeBase {
    address constant BRIDGE = 0x819FF4d9215C9dAC76f5eC676b1355973157eBBa;
    address constant BSC_BOBA = 0xE0DB679377A0F5Ae2BaE485DE475c9e1d8A4607D;

    function test_bscWithdrawRevertsAsDeployed() public {
        assertFalse(IAltL1Bridge(BRIDGE).useCustomAdapterParams());
        // 4,126,452 BSC BOBA exist and cannot be withdrawn.
        assertEq(IERC20(BSC_BOBA).totalSupply(), 4126452070570443977414501);

        deal(BSC_BOBA, USER, 100 ether);
        deal(USER, 10 ether);
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(LZ_ULN_InvalidWorkerOptions.selector, 0));
        IAltL1Bridge(BRIDGE).withdraw{value: 0.5 ether}(BSC_BOBA, 1 ether, address(0), bytes(""), bytes(""));

        // The user keeps the tokens but cannot move them back to Ethereum.
        assertEq(IERC20(BSC_BOBA).balanceOf(USER), 100 ether);
    }

    function test_bscWithdrawWorksAfterOwnerFix() public {
        address owner = IAltL1Bridge(BRIDGE).owner();
        vm.prank(owner);
        IAltL1Bridge(BRIDGE).setUseCustomAdapterParams(true, 200000);
        assertTrue(IAltL1Bridge(BRIDGE).useCustomAdapterParams());

        uint256 before = IAltL1Bridge(BRIDGE).transferredAmount();
        // The May 2026 window expired long ago, so this withdrawal resets
        // the daily counter instead of adding to it.
        assertEq(before, 9428160105653974135539);
        deal(BSC_BOBA, USER, 100 ether);
        deal(USER, 10 ether);
        vm.prank(USER);
        IAltL1Bridge(BRIDGE).withdraw{value: 0.5 ether}(BSC_BOBA, 1 ether, address(0), v1Params(), bytes(""));

        // Tokens are burned and the cross-chain message is sent.
        assertEq(IERC20(BSC_BOBA).balanceOf(USER), 99 ether);
        assertEq(IAltL1Bridge(BRIDGE).transferredAmount(), 1 ether);
    }
}

/// ETH fork, block 26433408. ETH -> BSC deposits are bricked.
contract EthDepositTest is BrickedBridgeBase {
    address constant BRIDGE = 0x1A36E24D61BC1aDa68C21C2Da1aD53EaB8E03e55;
    address constant L1_BOBA = 0x42bBFa2e77757C645eeaAd1655E0911a7553Efbc;
    address constant BSC_BOBA = 0xE0DB679377A0F5Ae2BaE485DE475c9e1d8A4607D;

    function test_ethDepositRevertsAsDeployed() public {
        assertFalse(IEthBridge(BRIDGE).useCustomAdapterParams());
        // The bridge holds 4,126,452 BOBA locked against BSC claims.
        assertEq(IERC20(L1_BOBA).balanceOf(BRIDGE), 4126452070570443977414501);

        deal(L1_BOBA, USER, 100 ether);
        deal(USER, 10 ether);
        vm.startPrank(USER);
        IERC20(L1_BOBA).approve(BRIDGE, 100 ether);
        vm.expectRevert(abi.encodeWithSelector(LZ_ULN_InvalidWorkerOptions.selector, 0));
        IEthBridge(BRIDGE).depositERC20{value: 0.1 ether}(L1_BOBA, BSC_BOBA, 1 ether, address(0), bytes(""), bytes(""));
        vm.stopPrank();

        assertEq(IERC20(L1_BOBA).balanceOf(USER), 100 ether);
    }

    function test_ethDepositWorksAfterOwnerFix() public {
        address owner = IEthBridge(BRIDGE).owner();
        vm.prank(owner);
        IEthBridge(BRIDGE).setUseCustomAdapterParams(true, 200000);
        assertTrue(IEthBridge(BRIDGE).useCustomAdapterParams());

        deal(L1_BOBA, USER, 100 ether);
        deal(USER, 10 ether);
        vm.startPrank(USER);
        IERC20(L1_BOBA).approve(BRIDGE, 100 ether);
        IEthBridge(BRIDGE).depositERC20{value: 0.1 ether}(L1_BOBA, BSC_BOBA, 1 ether, address(0), v1Params(), bytes(""));
        vm.stopPrank();

        // The deposit locks the tokens in the bridge.
        assertEq(IERC20(L1_BOBA).balanceOf(USER), 99 ether);
        assertEq(IERC20(L1_BOBA).balanceOf(BRIDGE), 4126452070570443977414501 + 1 ether);
    }
}

/// Avalanche fork, block 100546228. Avax -> ETH withdrawals are bricked.
contract AvaxWithdrawTest is BrickedBridgeBase {
    address constant BRIDGE = 0x351F4853A0E94DB055ed6ad5DF1b3590791c1F71;
    address constant AVAX_BOBA = 0x3cD790449CF7D187a143d4Bd7F4654d4f2403e02;

    function test_avaxWithdrawRevertsAsDeployed() public {
        assertFalse(IAltL1Bridge(BRIDGE).useCustomAdapterParams());
        deal(AVAX_BOBA, USER, 100 ether);
        deal(USER, 10 ether);
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(LZ_ULN_InvalidWorkerOptions.selector, 0));
        IAltL1Bridge(BRIDGE).withdraw{value: 0.5 ether}(AVAX_BOBA, 1 ether, address(0), bytes(""), bytes(""));
        assertEq(IERC20(AVAX_BOBA).balanceOf(USER), 100 ether);
    }

    function test_avaxWithdrawWorksAfterOwnerFix() public {
        address owner = IAltL1Bridge(BRIDGE).owner();
        vm.prank(owner);
        IAltL1Bridge(BRIDGE).setUseCustomAdapterParams(true, 200000);
        deal(AVAX_BOBA, USER, 100 ether);
        deal(USER, 10 ether);
        vm.prank(USER);
        IAltL1Bridge(BRIDGE).withdraw{value: 0.5 ether}(AVAX_BOBA, 1 ether, address(0), v1Params(), bytes(""));
        assertEq(IERC20(AVAX_BOBA).balanceOf(USER), 99 ether);
    }
}

/// Fantom fork, block 124098365. Fantom -> ETH withdrawals are bricked.
/// Note: the Fantom -> ETH fee quote is about 20 FTM, so the fix test
/// attaches 25 FTM. With only 0.5 FTM it reverts for insufficient fees.
contract FantomWithdrawTest is BrickedBridgeBase {
    address constant BRIDGE = 0x409e3693A23D4331F613c36f6D5f439a5b9834e8;
    address constant FTM_BOBA = 0x4389b230D15119c347B9E8BEA6d930A21aaDF6BA;

    function test_ftmWithdrawRevertsAsDeployed() public {
        assertFalse(IAltL1Bridge(BRIDGE).useCustomAdapterParams());
        deal(FTM_BOBA, USER, 100 ether);
        deal(USER, 1000 ether);
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(LZ_ULN_InvalidWorkerOptions.selector, 0));
        IAltL1Bridge(BRIDGE).withdraw{value: 25 ether}(FTM_BOBA, 1 ether, address(0), bytes(""), bytes(""));
        assertEq(IERC20(FTM_BOBA).balanceOf(USER), 100 ether);
    }

    function test_ftmWithdrawWorksAfterOwnerFix() public {
        address owner = IAltL1Bridge(BRIDGE).owner();
        vm.prank(owner);
        IAltL1Bridge(BRIDGE).setUseCustomAdapterParams(true, 200000);
        deal(FTM_BOBA, USER, 100 ether);
        deal(USER, 1000 ether);
        vm.prank(USER);
        IAltL1Bridge(BRIDGE).withdraw{value: 25 ether}(FTM_BOBA, 1 ether, address(0), v1Params(), bytes(""));
        assertEq(IERC20(FTM_BOBA).balanceOf(USER), 99 ether);
    }
}

/// Moonbeam fork, block 16796699. Control case: Moonbeam still uses the
/// old ULNv2 send library, so empty adapter params still work there.
/// Note: the Moonbeam -> ETH fee quote is about 262 GLMR, so the test
/// attaches 300 GLMR. LayerZero will deprecate the ULNv2 relayer on
/// 2026-12-15, after which this route breaks too unless it migrates.
contract MoonbeamWithdrawTest is BrickedBridgeBase {
    address constant BRIDGE = 0x9F868333DB1720Fb1412AFfb1AeF47e8C6cFc8c3;
    address constant GLMR_BOBA = 0x18D17A9fD652D7d6a59903E23792ab97F832Ed6C;

    function test_moonbeamWithdrawWorksWithEmptyParams() public {
        assertFalse(IAltL1Bridge(BRIDGE).useCustomAdapterParams());
        deal(GLMR_BOBA, USER, 100 ether);
        deal(USER, 1000 ether);
        vm.prank(USER);
        IAltL1Bridge(BRIDGE).withdraw{value: 300 ether}(GLMR_BOBA, 1 ether, address(0), bytes(""), bytes(""));
        assertEq(IERC20(GLMR_BOBA).balanceOf(USER), 99 ether);
    }
}
