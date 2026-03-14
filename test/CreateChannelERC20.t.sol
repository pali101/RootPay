// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTestHelper} from "./helper/BaseTestHelper.sol";
import {MerkleHelper} from "./helper/MerkleHelper.sol";
import {RootPay} from "../src/RootPay.sol";

/**
 * @title CreateChannelERC20Test
 * @dev Tests for RootPay.createChannel() using ERC-20 tokens.
 *
 * Coverage:
 *  - Successful ERC-20 channel creation and storage verification
 *  - Token transfer and balance assertions
 *  - All ERC-20 specific revert conditions: ETH sent with ERC-20, not a
 *    contract, not an ERC-20, insufficient allowance
 *  - Shared revert conditions inherited from native: tree size, timing,
 *    duplicate channels
 */
contract CreateChannelERC20Test is BaseTestHelper, MerkleHelper {
    // -------------------------------------------------------------------------
    // Setup
    // -------------------------------------------------------------------------

    bytes32 internal _root;

    function setUp() public override {
        super.setUp();
        _root = buildTree(DEFAULT_TREE_SIZE);
    }

    // -------------------------------------------------------------------------
    // Successful Creation
    // -------------------------------------------------------------------------

    function test_CreateChannelERC20_Success() public {
        vm.prank(PAYER);
        rootPay.createChannel(
            PAYEE, address(erc20), _root, DEPOSIT_AMOUNT, DEFAULT_TREE_SIZE, MERCHANT_DURATION, RECLAIM_DELAY
        );

        _assertChannelExists(PAYER, PAYEE, address(erc20), _root, DEFAULT_TREE_SIZE);
    }

    function test_CreateChannelERC20_ContractReceivesTokens() public {
        uint256 before = erc20.balanceOf(address(rootPay));

        vm.prank(PAYER);
        rootPay.createChannel(
            PAYEE, address(erc20), _root, DEPOSIT_AMOUNT, DEFAULT_TREE_SIZE, MERCHANT_DURATION, RECLAIM_DELAY
        );

        assertEq(erc20.balanceOf(address(rootPay)), before + DEPOSIT_AMOUNT, "contract token balance should increase");
    }

    function test_CreateChannelERC20_PayerBalanceDecreases() public {
        uint256 before = erc20.balanceOf(PAYER);

        vm.prank(PAYER);
        rootPay.createChannel(
            PAYEE, address(erc20), _root, DEPOSIT_AMOUNT, DEFAULT_TREE_SIZE, MERCHANT_DURATION, RECLAIM_DELAY
        );

        assertEq(erc20.balanceOf(PAYER), before - DEPOSIT_AMOUNT, "payer token balance should decrease by deposit");
    }

    function test_CreateChannelERC20_NoETHTransferred() public {
        uint256 ethBefore = address(rootPay).balance;

        vm.prank(PAYER);
        rootPay.createChannel(
            PAYEE, address(erc20), _root, DEPOSIT_AMOUNT, DEFAULT_TREE_SIZE, MERCHANT_DURATION, RECLAIM_DELAY
        );

        assertEq(address(rootPay).balance, ethBefore, "ETH balance should not change for ERC-20 channel");
    }

    // -------------------------------------------------------------------------
    // Storage Field Verification
    // -------------------------------------------------------------------------

    function test_CreateChannelERC20_StoredFields() public {
        vm.prank(PAYER);
        rootPay.createChannel(
            PAYEE, address(erc20), _root, DEPOSIT_AMOUNT, DEFAULT_TREE_SIZE, MERCHANT_DURATION, RECLAIM_DELAY
        );

        (
            address storedToken,
            bytes32 storedRoot,
            uint256 storedAmount,
            uint16 storedTreeSize,
            uint64 storedMerchantBlock,
            uint64 storedPayerBlock
        ) = rootPay.channelsMapping(PAYER, PAYEE, address(erc20));

        assertEq(storedToken, address(erc20), "token mismatch");
        assertEq(storedRoot, _root, "merkleRoot mismatch");
        assertEq(storedAmount, DEPOSIT_AMOUNT, "amount mismatch");
        assertEq(storedTreeSize, DEFAULT_TREE_SIZE, "treeSize mismatch");
        assertEq(storedMerchantBlock, uint64(block.number) + MERCHANT_DURATION, "merchantBlock mismatch");
        assertEq(storedPayerBlock, uint64(block.number) + RECLAIM_DELAY, "payerBlock mismatch");
    }

    // -------------------------------------------------------------------------
    // Event Emission
    // -------------------------------------------------------------------------

    function test_CreateChannelERC20_EmitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit RootPay.ChannelCreated(
            PAYER, PAYEE, address(erc20), DEPOSIT_AMOUNT, DEFAULT_TREE_SIZE, uint64(block.number) + MERCHANT_DURATION
        );

        vm.prank(PAYER);
        rootPay.createChannel(
            PAYEE, address(erc20), _root, DEPOSIT_AMOUNT, DEFAULT_TREE_SIZE, MERCHANT_DURATION, RECLAIM_DELAY
        );
    }

    // -------------------------------------------------------------------------
    // Native and ERC-20 Channels Coexist
    // -------------------------------------------------------------------------

    function test_CreateChannel_NativeAndERC20_SamePayerMerchant() public {
        // Same payer and merchant can have both a native and ERC-20 channel open
        bytes32 root2 = buildTreeWithSalt(DEFAULT_TREE_SIZE, bytes32(uint256(77)));

        vm.prank(PAYER);
        rootPay.createChannel{value: DEPOSIT_AMOUNT}(
            PAYEE, NATIVE_TOKEN, _root, DEPOSIT_AMOUNT, DEFAULT_TREE_SIZE, MERCHANT_DURATION, RECLAIM_DELAY
        );

        vm.prank(PAYER);
        rootPay.createChannel(
            PAYEE, address(erc20), root2, DEPOSIT_AMOUNT, DEFAULT_TREE_SIZE, MERCHANT_DURATION, RECLAIM_DELAY
        );

        _assertChannelExists(PAYER, PAYEE, NATIVE_TOKEN, _root, DEFAULT_TREE_SIZE);
        _assertChannelExists(PAYER, PAYEE, address(erc20), root2, DEFAULT_TREE_SIZE);
    }

    // -------------------------------------------------------------------------
    // Revert: ETH Sent With ERC-20
    // -------------------------------------------------------------------------

    function test_Revert_ETHSentWithERC20() public {
        vm.expectRevert(abi.encodeWithSelector(RootPay.IncorrectAmount.selector, 1 ether, 0));
        vm.prank(PAYER);
        rootPay.createChannel{value: 1 ether}(
            PAYEE, address(erc20), _root, DEPOSIT_AMOUNT, DEFAULT_TREE_SIZE, MERCHANT_DURATION, RECLAIM_DELAY
        );
    }

    // -------------------------------------------------------------------------
    // Revert: Invalid Token Address
    // -------------------------------------------------------------------------

    function test_Revert_TokenNotAContract() public {
        address notAContract = address(0xdead);

        vm.expectRevert(abi.encodeWithSelector(RootPay.AddressIsNotContract.selector, notAContract));
        vm.prank(PAYER);
        rootPay.createChannel(
            PAYEE, notAContract, _root, DEPOSIT_AMOUNT, DEFAULT_TREE_SIZE, MERCHANT_DURATION, RECLAIM_DELAY
        );
    }

    function test_Revert_TokenNotERC20() public {
        // Deploy a contract with no ERC-20 interface
        NonERC20Contract nonERC20 = new NonERC20Contract();

        vm.expectRevert(abi.encodeWithSelector(RootPay.AddressIsNotERC20.selector, address(nonERC20)));
        vm.prank(PAYER);
        rootPay.createChannel(
            PAYEE, address(nonERC20), _root, DEPOSIT_AMOUNT, DEFAULT_TREE_SIZE, MERCHANT_DURATION, RECLAIM_DELAY
        );
    }

    // -------------------------------------------------------------------------
    // Revert: Allowance
    // -------------------------------------------------------------------------

    function test_Revert_InsufficientAllowance_Zero() public {
        // Revoke existing approval
        vm.prank(PAYER);
        erc20.approve(address(rootPay), 0);

        vm.expectRevert(abi.encodeWithSelector(RootPay.InsufficientAllowance.selector, DEPOSIT_AMOUNT, 0));
        vm.prank(PAYER);
        rootPay.createChannel(
            PAYEE, address(erc20), _root, DEPOSIT_AMOUNT, DEFAULT_TREE_SIZE, MERCHANT_DURATION, RECLAIM_DELAY
        );
    }

    function test_Revert_InsufficientAllowance_Partial() public {
        uint256 partialAllowance = DEPOSIT_AMOUNT - 1;

        vm.prank(PAYER);
        erc20.approve(address(rootPay), partialAllowance);

        vm.expectRevert(
            abi.encodeWithSelector(RootPay.InsufficientAllowance.selector, DEPOSIT_AMOUNT, partialAllowance)
        );
        vm.prank(PAYER);
        rootPay.createChannel(
            PAYEE, address(erc20), _root, DEPOSIT_AMOUNT, DEFAULT_TREE_SIZE, MERCHANT_DURATION, RECLAIM_DELAY
        );
    }

    function test_CreateChannelERC20_ExactAllowance() public {
        // Reset approval to exactly DEPOSIT_AMOUNT
        vm.prank(PAYER);
        erc20.approve(address(rootPay), DEPOSIT_AMOUNT);

        vm.prank(PAYER);
        rootPay.createChannel(
            PAYEE, address(erc20), _root, DEPOSIT_AMOUNT, DEFAULT_TREE_SIZE, MERCHANT_DURATION, RECLAIM_DELAY
        );

        _assertChannelExists(PAYER, PAYEE, address(erc20), _root, DEFAULT_TREE_SIZE);
    }

    // -------------------------------------------------------------------------
    // Revert: Tree Size (shared with native, spot-checked here)
    // -------------------------------------------------------------------------

    function test_Revert_ERC20_TreeSizeZero() public {
        vm.expectRevert(RootPay.TreeSizeIsZero.selector);
        vm.prank(PAYER);
        rootPay.createChannel(PAYEE, address(erc20), _root, DEPOSIT_AMOUNT, 0, MERCHANT_DURATION, RECLAIM_DELAY);
    }

    function test_Revert_ERC20_TreeSizeNotPowerOfTwo() public {
        vm.expectRevert(abi.encodeWithSelector(RootPay.TreeSizeNotPowerOfTwo.selector, uint16(3)));
        vm.prank(PAYER);
        rootPay.createChannel(PAYEE, address(erc20), _root, DEPOSIT_AMOUNT, 3, MERCHANT_DURATION, RECLAIM_DELAY);
    }

    // -------------------------------------------------------------------------
    // Revert: Duplicate Channel
    // -------------------------------------------------------------------------

    function test_Revert_ERC20_DuplicateChannel() public {
        vm.prank(PAYER);
        rootPay.createChannel(
            PAYEE, address(erc20), _root, DEPOSIT_AMOUNT, DEFAULT_TREE_SIZE, MERCHANT_DURATION, RECLAIM_DELAY
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                RootPay.ChannelAlreadyExist.selector, PAYER, PAYEE, address(erc20), DEPOSIT_AMOUNT, DEFAULT_TREE_SIZE
            )
        );

        vm.prank(PAYER);
        rootPay.createChannel(
            PAYEE, address(erc20), _root, DEPOSIT_AMOUNT, DEFAULT_TREE_SIZE, MERCHANT_DURATION, RECLAIM_DELAY
        );
    }
}

// -------------------------------------------------------------------------
// Helper Contracts
// -------------------------------------------------------------------------

/**
 * @dev A contract that exists on-chain but does not implement ERC-20.
 * Used to trigger AddressIsNotERC20 revert.
 */
contract NonERC20Contract {
    function doNothing() external pure returns (bool) {
        return true;
    }
}
