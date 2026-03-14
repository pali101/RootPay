// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTestHelper} from "./helper/BaseTestHelper.sol";
import {MerkleHelper} from "./helper/MerkleHelper.sol";
import {RootPay} from "../src/RootPay.sol";

/**
 * @title CreateChannelTest
 * @dev Tests for RootPay.createChannel() using native currency (ETH).
 *
 * Coverage:
 *  - Successful channel creation and storage verification
 *  - Valid tree size boundaries
 *  - All revert conditions: zero tree, non-power-of-2, invalid addresses,
 *    timing constraints, incorrect ETH amount, duplicate channels
 */
contract CreateChannelTest is BaseTestHelper, MerkleHelper {
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

    function test_CreateChannel_Success() public {
        vm.prank(PAYER);
        rootPay.createChannel{value: DEPOSIT_AMOUNT}(
            PAYEE, NATIVE_TOKEN, _root, DEPOSIT_AMOUNT, DEFAULT_TREE_SIZE, MERCHANT_DURATION, RECLAIM_DELAY
        );

        _assertChannelExists(PAYER, PAYEE, NATIVE_TOKEN, _root, DEFAULT_TREE_SIZE);
    }

    function test_CreateChannel_ContractReceivesETH() public {
        uint256 before = address(rootPay).balance;

        vm.prank(PAYER);
        rootPay.createChannel{value: DEPOSIT_AMOUNT}(
            PAYEE, NATIVE_TOKEN, _root, DEPOSIT_AMOUNT, DEFAULT_TREE_SIZE, MERCHANT_DURATION, RECLAIM_DELAY
        );

        assertEq(address(rootPay).balance, before + DEPOSIT_AMOUNT, "contract balance should increase");
    }

    function test_CreateChannel_PayerBalanceDecreases() public {
        uint256 before = PAYER.balance;

        vm.prank(PAYER);
        rootPay.createChannel{value: DEPOSIT_AMOUNT}(
            PAYEE, NATIVE_TOKEN, _root, DEPOSIT_AMOUNT, DEFAULT_TREE_SIZE, MERCHANT_DURATION, RECLAIM_DELAY
        );

        assertEq(PAYER.balance, before - DEPOSIT_AMOUNT, "payer balance should decrease by deposit");
    }

    // -------------------------------------------------------------------------
    // Storage Field Verification
    // -------------------------------------------------------------------------

    function test_CreateChannel_StoredFields() public {
        vm.prank(PAYER);
        rootPay.createChannel{value: DEPOSIT_AMOUNT}(
            PAYEE, NATIVE_TOKEN, _root, DEPOSIT_AMOUNT, DEFAULT_TREE_SIZE, MERCHANT_DURATION, RECLAIM_DELAY
        );

        (
            address storedToken,
            bytes32 storedRoot,
            uint256 storedAmount,
            uint16 storedTreeSize,
            uint64 storedMerchantBlock,
            uint64 storedPayerBlock
        ) = rootPay.channelsMapping(PAYER, PAYEE, NATIVE_TOKEN);

        assertEq(storedToken, NATIVE_TOKEN, "token mismatch");
        assertEq(storedRoot, _root, "merkleRoot mismatch");
        assertEq(storedAmount, DEPOSIT_AMOUNT, "amount mismatch");
        assertEq(storedTreeSize, DEFAULT_TREE_SIZE, "treeSize mismatch");
        assertEq(storedMerchantBlock, uint64(block.number) + MERCHANT_DURATION, "merchantBlock mismatch");
        assertEq(storedPayerBlock, uint64(block.number) + RECLAIM_DELAY, "payerBlock mismatch");
    }

    // -------------------------------------------------------------------------
    // Event Emission
    // -------------------------------------------------------------------------

    function test_CreateChannel_EmitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit RootPay.ChannelCreated(
            PAYER, PAYEE, NATIVE_TOKEN, DEPOSIT_AMOUNT, DEFAULT_TREE_SIZE, uint64(block.number) + MERCHANT_DURATION
        );

        vm.prank(PAYER);
        rootPay.createChannel{value: DEPOSIT_AMOUNT}(
            PAYEE, NATIVE_TOKEN, _root, DEPOSIT_AMOUNT, DEFAULT_TREE_SIZE, MERCHANT_DURATION, RECLAIM_DELAY
        );
    }

    // -------------------------------------------------------------------------
    // Valid Tree Sizes
    // -------------------------------------------------------------------------

    function test_CreateChannel_TreeSize1() public {
        bytes32 root = buildTreeWithSalt(1, bytes32(uint256(10)));

        vm.prank(PAYER);
        rootPay.createChannel{value: DEPOSIT_AMOUNT}(
            PAYEE, NATIVE_TOKEN, root, DEPOSIT_AMOUNT, 1, MERCHANT_DURATION, RECLAIM_DELAY
        );

        _assertChannelExists(PAYER, PAYEE, NATIVE_TOKEN, root, 1);
    }

    function test_CreateChannel_TreeSize2() public {
        bytes32 root = buildTreeWithSalt(2, bytes32(uint256(20)));

        vm.prank(PAYER);
        rootPay.createChannel{value: DEPOSIT_AMOUNT}(
            PAYEE, NATIVE_TOKEN, root, DEPOSIT_AMOUNT, 2, MERCHANT_DURATION, RECLAIM_DELAY
        );

        _assertChannelExists(PAYER, PAYEE, NATIVE_TOKEN, root, 2);
    }

    function test_CreateChannel_TreeSize1024() public {
        bytes32 root = buildTreeWithSalt(1024, bytes32(uint256(30)));

        vm.prank(PAYER);
        rootPay.createChannel{value: DEPOSIT_AMOUNT}(
            PAYEE, NATIVE_TOKEN, root, DEPOSIT_AMOUNT, 1024, MERCHANT_DURATION, RECLAIM_DELAY
        );

        _assertChannelExists(PAYER, PAYEE, NATIVE_TOKEN, root, 1024);
    }

    function test_CreateChannel_LargeTree() public {
        bytes32 root = buildTreeWithSalt(LARGE_TREE_SIZE, bytes32(uint256(40)));

        vm.prank(PAYER);
        rootPay.createChannel{value: DEPOSIT_AMOUNT}(
            PAYEE, NATIVE_TOKEN, root, DEPOSIT_AMOUNT, LARGE_TREE_SIZE, MERCHANT_DURATION, RECLAIM_DELAY
        );

        _assertChannelExists(PAYER, PAYEE, NATIVE_TOKEN, root, LARGE_TREE_SIZE);
    }

    // -------------------------------------------------------------------------
    // Multiple Independent Channels
    // -------------------------------------------------------------------------

    function test_CreateChannel_TwoDifferentPayers() public {
        bytes32 root2 = buildTreeWithSalt(DEFAULT_TREE_SIZE, bytes32(uint256(99)));

        vm.prank(PAYER);
        rootPay.createChannel{value: DEPOSIT_AMOUNT}(
            PAYEE, NATIVE_TOKEN, _root, DEPOSIT_AMOUNT, DEFAULT_TREE_SIZE, MERCHANT_DURATION, RECLAIM_DELAY
        );

        vm.prank(PAYER2);
        rootPay.createChannel{value: DEPOSIT_AMOUNT}(
            PAYEE, NATIVE_TOKEN, root2, DEPOSIT_AMOUNT, DEFAULT_TREE_SIZE, MERCHANT_DURATION, RECLAIM_DELAY
        );

        _assertChannelExists(PAYER, PAYEE, NATIVE_TOKEN, _root, DEFAULT_TREE_SIZE);
        _assertChannelExists(PAYER2, PAYEE, NATIVE_TOKEN, root2, DEFAULT_TREE_SIZE);
    }

    function test_CreateChannel_TwoDifferentMerchants() public {
        bytes32 root2 = buildTreeWithSalt(DEFAULT_TREE_SIZE, bytes32(uint256(88)));

        vm.prank(PAYER);
        rootPay.createChannel{value: DEPOSIT_AMOUNT}(
            PAYEE, NATIVE_TOKEN, _root, DEPOSIT_AMOUNT, DEFAULT_TREE_SIZE, MERCHANT_DURATION, RECLAIM_DELAY
        );

        vm.prank(PAYER);
        rootPay.createChannel{value: DEPOSIT_AMOUNT}(
            PAYEE2, NATIVE_TOKEN, root2, DEPOSIT_AMOUNT, DEFAULT_TREE_SIZE, MERCHANT_DURATION, RECLAIM_DELAY
        );

        _assertChannelExists(PAYER, PAYEE, NATIVE_TOKEN, _root, DEFAULT_TREE_SIZE);
        _assertChannelExists(PAYER, PAYEE2, NATIVE_TOKEN, root2, DEFAULT_TREE_SIZE);
    }

    // -------------------------------------------------------------------------
    // Revert: Invalid Merchant
    // -------------------------------------------------------------------------

    function test_Revert_InvalidMerchant_ZeroAddress() public {
        vm.expectRevert(bytes("Invalid address"));
        vm.prank(PAYER);
        rootPay.createChannel{value: DEPOSIT_AMOUNT}(
            address(0), NATIVE_TOKEN, _root, DEPOSIT_AMOUNT, DEFAULT_TREE_SIZE, MERCHANT_DURATION, RECLAIM_DELAY
        );
    }

    // -------------------------------------------------------------------------
    // Revert: Tree Size
    // -------------------------------------------------------------------------

    function test_Revert_TreeSizeZero() public {
        vm.expectRevert(RootPay.TreeSizeIsZero.selector);
        vm.prank(PAYER);
        rootPay.createChannel{value: DEPOSIT_AMOUNT}(
            PAYEE, NATIVE_TOKEN, _root, DEPOSIT_AMOUNT, 0, MERCHANT_DURATION, RECLAIM_DELAY
        );
    }

    function test_Revert_TreeSizeNotPowerOfTwo_3() public {
        vm.expectRevert(abi.encodeWithSelector(RootPay.TreeSizeNotPowerOfTwo.selector, uint16(3)));
        vm.prank(PAYER);
        rootPay.createChannel{value: DEPOSIT_AMOUNT}(
            PAYEE, NATIVE_TOKEN, _root, DEPOSIT_AMOUNT, 3, MERCHANT_DURATION, RECLAIM_DELAY
        );
    }

    function test_Revert_TreeSizeNotPowerOfTwo_100() public {
        vm.expectRevert(abi.encodeWithSelector(RootPay.TreeSizeNotPowerOfTwo.selector, uint16(100)));
        vm.prank(PAYER);
        rootPay.createChannel{value: DEPOSIT_AMOUNT}(
            PAYEE, NATIVE_TOKEN, _root, DEPOSIT_AMOUNT, 100, MERCHANT_DURATION, RECLAIM_DELAY
        );
    }

    function test_Revert_TreeSizeNotPowerOfTwo_1000() public {
        vm.expectRevert(abi.encodeWithSelector(RootPay.TreeSizeNotPowerOfTwo.selector, uint16(1000)));
        vm.prank(PAYER);
        rootPay.createChannel{value: DEPOSIT_AMOUNT}(
            PAYEE, NATIVE_TOKEN, _root, DEPOSIT_AMOUNT, 1000, MERCHANT_DURATION, RECLAIM_DELAY
        );
    }

    // -------------------------------------------------------------------------
    // Revert: Timing
    // -------------------------------------------------------------------------

    function test_Revert_MerchantWithdrawTimeTooShort_Equal() public {
        // payerWithdrawAfterBlocks == merchantWithdrawAfterBlocks, fails 1.1x check
        vm.expectRevert(RootPay.MerchantWithdrawTimeTooShort.selector);
        vm.prank(PAYER);
        rootPay.createChannel{value: DEPOSIT_AMOUNT}(
            PAYEE,
            NATIVE_TOKEN,
            _root,
            DEPOSIT_AMOUNT,
            DEFAULT_TREE_SIZE,
            MERCHANT_DURATION,
            MERCHANT_DURATION // same as merchant window
        );
    }

    function test_Revert_MerchantWithdrawTimeTooShort_BelowBuffer() public {
        // 110% of 100 = 110, so 109 should fail
        vm.expectRevert(RootPay.MerchantWithdrawTimeTooShort.selector);
        vm.prank(PAYER);
        rootPay.createChannel{value: DEPOSIT_AMOUNT}(
            PAYEE, NATIVE_TOKEN, _root, DEPOSIT_AMOUNT, DEFAULT_TREE_SIZE, MERCHANT_DURATION, 109
        );
    }

    function test_CreateChannel_MerchantWithdrawTime_ExactBuffer() public {
        // 110% of 100 = 110, so 110 should succeed
        vm.prank(PAYER);
        rootPay.createChannel{value: DEPOSIT_AMOUNT}(
            PAYEE, NATIVE_TOKEN, _root, DEPOSIT_AMOUNT, DEFAULT_TREE_SIZE, MERCHANT_DURATION, 110
        );

        _assertChannelExists(PAYER, PAYEE, NATIVE_TOKEN, _root, DEFAULT_TREE_SIZE);
    }

    // -------------------------------------------------------------------------
    // Revert: Incorrect ETH Amount
    // -------------------------------------------------------------------------

    function test_Revert_IncorrectETH_TooLittle() public {
        vm.expectRevert(abi.encodeWithSelector(RootPay.IncorrectAmount.selector, DEPOSIT_AMOUNT - 1, DEPOSIT_AMOUNT));
        vm.prank(PAYER);
        rootPay.createChannel{value: DEPOSIT_AMOUNT - 1}(
            PAYEE, NATIVE_TOKEN, _root, DEPOSIT_AMOUNT, DEFAULT_TREE_SIZE, MERCHANT_DURATION, RECLAIM_DELAY
        );
    }

    function test_Revert_IncorrectETH_TooMuch() public {
        vm.expectRevert(abi.encodeWithSelector(RootPay.IncorrectAmount.selector, DEPOSIT_AMOUNT + 1, DEPOSIT_AMOUNT));
        vm.prank(PAYER);
        rootPay.createChannel{value: DEPOSIT_AMOUNT + 1}(
            PAYEE, NATIVE_TOKEN, _root, DEPOSIT_AMOUNT, DEFAULT_TREE_SIZE, MERCHANT_DURATION, RECLAIM_DELAY
        );
    }

    function test_Revert_IncorrectETH_Zero() public {
        vm.expectRevert(abi.encodeWithSelector(RootPay.IncorrectAmount.selector, 0, DEPOSIT_AMOUNT));
        vm.prank(PAYER);
        rootPay.createChannel{value: 0}(
            PAYEE, NATIVE_TOKEN, _root, DEPOSIT_AMOUNT, DEFAULT_TREE_SIZE, MERCHANT_DURATION, RECLAIM_DELAY
        );
    }

    // -------------------------------------------------------------------------
    // Revert: Duplicate Channel
    // -------------------------------------------------------------------------

    function test_Revert_DuplicateChannel() public {
        vm.prank(PAYER);
        rootPay.createChannel{value: DEPOSIT_AMOUNT}(
            PAYEE, NATIVE_TOKEN, _root, DEPOSIT_AMOUNT, DEFAULT_TREE_SIZE, MERCHANT_DURATION, RECLAIM_DELAY
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                RootPay.ChannelAlreadyExist.selector, PAYER, PAYEE, NATIVE_TOKEN, DEPOSIT_AMOUNT, DEFAULT_TREE_SIZE
            )
        );

        vm.prank(PAYER);
        rootPay.createChannel{value: DEPOSIT_AMOUNT}(
            PAYEE, NATIVE_TOKEN, _root, DEPOSIT_AMOUNT, DEFAULT_TREE_SIZE, MERCHANT_DURATION, RECLAIM_DELAY
        );
    }

    function test_Revert_DirectETHDeposit() public {
        vm.expectRevert(bytes("RootPay: Direct ETH deposits are not allowed"));
        vm.prank(PAYER);
        (bool sent,) = address(rootPay).call{value: 1 ether}("");
        // suppress unused variable warning — revert is expected before assignment
        (sent);
    }
}
