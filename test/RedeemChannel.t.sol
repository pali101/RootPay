// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTestHelper} from "./helper/BaseTestHelper.sol";
import {MerkleHelper} from "./helper/MerkleHelper.sol";
import {RootPay} from "../src/RootPay.sol";

/**
 * @title RedeemChannelTest
 * @dev Tests for RootPay.redeemChannel() using native currency (ETH).
 *
 * Coverage:
 *  - Successful redemption at various leaf indices (first, last, middle, full)
 *  - Payout math: merchant amount, payer refund, dust handling
 *  - Storage cleanup after redemption
 *  - Event emission
 *  - All revert conditions: channel not found, too early, index out of bounds,
 *    proof length mismatch, wrong secret, tampered proof, nothing payable
 */
contract RedeemChannelTest is BaseTestHelper, MerkleHelper {
    // -------------------------------------------------------------------------
    // Setup
    // -------------------------------------------------------------------------

    bytes32 internal _root;

    function setUp() public override {
        super.setUp();
        _root = buildTree(DEFAULT_TREE_SIZE);
        _createNativeChannel(PAYER, PAYEE, _root, DEFAULT_TREE_SIZE);
        _advancePastMerchantWindow();
    }

    // -------------------------------------------------------------------------
    // Successful Redemption — Leaf Positions
    // -------------------------------------------------------------------------

    function test_RedeemChannel_LeafZero() public {
        (bytes32 secret, bytes32[] memory proof) = getRedeemParams(0);

        vm.prank(PAYEE);
        rootPay.redeemChannel(PAYER, NATIVE_TOKEN, 0, secret, proof);

        uint256 expectedMerchant = _expectedMerchantPayout(0, DEFAULT_TREE_SIZE, DEPOSIT_AMOUNT);
        assertGt(expectedMerchant, 0, "merchant should receive non-zero amount");
    }

    function test_RedeemChannel_LastLeaf() public {
        uint16 lastIndex = DEFAULT_TREE_SIZE - 1;
        (bytes32 secret, bytes32[] memory proof) = getRedeemParams(lastIndex);

        uint256 merchantBefore = PAYEE.balance;
        uint256 payerBefore = PAYER.balance;

        vm.prank(PAYEE);
        rootPay.redeemChannel(PAYER, NATIVE_TOKEN, lastIndex, secret, proof);

        // Last leaf = full tree consumed, merchant gets entire deposit
        assertEq(PAYEE.balance, merchantBefore + DEPOSIT_AMOUNT, "merchant should receive full deposit");
        assertEq(PAYER.balance, payerBefore, "payer should receive nothing");
    }

    function test_RedeemChannel_MiddleLeaf() public {
        uint16 midIndex = DEFAULT_TREE_SIZE / 2 - 1; // 0-based: half the tree consumed
        (bytes32 secret, bytes32[] memory proof) = getRedeemParams(midIndex);

        uint256 merchantBefore = PAYEE.balance;
        uint256 payerBefore = PAYER.balance;

        vm.prank(PAYEE);
        rootPay.redeemChannel(PAYER, NATIVE_TOKEN, midIndex, secret, proof);

        uint256 expectedMerchant = _expectedMerchantPayout(midIndex, DEFAULT_TREE_SIZE, DEPOSIT_AMOUNT);
        uint256 expectedPayer = DEPOSIT_AMOUNT - expectedMerchant;

        assertEq(PAYEE.balance, merchantBefore + expectedMerchant, "merchant payout mismatch");
        assertEq(PAYER.balance, payerBefore + expectedPayer, "payer refund mismatch");
    }

    // -------------------------------------------------------------------------
    // Payout Math
    // -------------------------------------------------------------------------

    function test_RedeemChannel_PayoutFormula() public {
        // Verify (leafIndex + 1) * amount / treeSize at multiple indices
        uint16[4] memory indices = [
            uint16(0),
            uint16(DEFAULT_TREE_SIZE / 4 - 1),
            uint16(DEFAULT_TREE_SIZE / 2 - 1),
            uint16(DEFAULT_TREE_SIZE - 1)
        ];

        for (uint256 i = 0; i < indices.length; i++) {
            // Fresh channel per iteration with distinct salt
            bytes32 root = buildTreeWithSalt(DEFAULT_TREE_SIZE, bytes32(uint256(i + 100)));
            _createNativeChannel(PAYER2, PAYEE, root, DEFAULT_TREE_SIZE);
            _advancePastMerchantWindow();

            uint16 leafIndex = indices[i];
            (bytes32 secret, bytes32[] memory proof) = getRedeemParams(leafIndex);

            uint256 merchantBefore = PAYEE.balance;

            vm.prank(PAYEE);
            rootPay.redeemChannel(PAYER2, NATIVE_TOKEN, leafIndex, secret, proof);

            uint256 expectedMerchant = _expectedMerchantPayout(leafIndex, DEFAULT_TREE_SIZE, DEPOSIT_AMOUNT);
            assertEq(PAYEE.balance - merchantBefore, expectedMerchant, "payout formula mismatch");
        }
    }

    function test_RedeemChannel_DustReturnedToPayer() public {
        uint256 dustAmount = 513; // wei — not divisible by 512

        vm.deal(PAYER2, dustAmount);

        bytes32 root = buildTreeWithSalt(DEFAULT_TREE_SIZE, bytes32(uint256(999)));

        vm.prank(PAYER2);
        rootPay.createChannel{value: dustAmount}(
            PAYEE, NATIVE_TOKEN, root, dustAmount, DEFAULT_TREE_SIZE, MERCHANT_DURATION, RECLAIM_DELAY
        );

        _advancePastMerchantWindow();

        uint16 leafIndex = DEFAULT_TREE_SIZE / 2 - 1;
        (bytes32 secret, bytes32[] memory proof) = getRedeemParams(leafIndex);

        uint256 payerBefore = PAYER2.balance;

        vm.prank(PAYEE);
        rootPay.redeemChannel(PAYER2, NATIVE_TOKEN, leafIndex, secret, proof);

        uint256 merchantPayout = _expectedMerchantPayout(leafIndex, DEFAULT_TREE_SIZE, dustAmount);
        uint256 expectedDust = dustAmount - merchantPayout;

        assertEq(PAYER2.balance - payerBefore, expectedDust, "dust should be returned to payer");
    }

    function test_RedeemChannel_FullTree_NoRefund() public {
        uint16 lastIndex = DEFAULT_TREE_SIZE - 1;
        (bytes32 secret, bytes32[] memory proof) = getRedeemParams(lastIndex);

        uint256 payerBefore = PAYER.balance;

        vm.prank(PAYEE);
        rootPay.redeemChannel(PAYER, NATIVE_TOKEN, lastIndex, secret, proof);

        assertEq(PAYER.balance, payerBefore, "payer should receive no refund on full redemption");
    }

    // -------------------------------------------------------------------------
    // Storage Cleanup
    // -------------------------------------------------------------------------

    function test_RedeemChannel_ChannelDeleted() public {
        (bytes32 secret, bytes32[] memory proof) = getRedeemParams(DEFAULT_TREE_SIZE - 1);

        vm.prank(PAYEE);
        rootPay.redeemChannel(PAYER, NATIVE_TOKEN, DEFAULT_TREE_SIZE - 1, secret, proof);

        _assertChannelDeleted(PAYER, PAYEE, NATIVE_TOKEN);
    }

    function test_RedeemChannel_CannotRedeemTwice() public {
        (bytes32 secret, bytes32[] memory proof) = getRedeemParams(DEFAULT_TREE_SIZE - 1);

        vm.prank(PAYEE);
        rootPay.redeemChannel(PAYER, NATIVE_TOKEN, DEFAULT_TREE_SIZE - 1, secret, proof);

        vm.expectRevert(RootPay.ChannelDoesNotExistOrWithdrawn.selector);
        vm.prank(PAYEE);
        rootPay.redeemChannel(PAYER, NATIVE_TOKEN, DEFAULT_TREE_SIZE - 1, secret, proof);
    }

    // -------------------------------------------------------------------------
    // Event Emission
    // -------------------------------------------------------------------------

    function test_RedeemChannel_EmitsChannelRedeemed() public {
        uint16 leafIndex = DEFAULT_TREE_SIZE / 2 - 1;
        (bytes32 secret, bytes32[] memory proof) = getRedeemParams(leafIndex);

        uint256 expectedMerchant = _expectedMerchantPayout(leafIndex, DEFAULT_TREE_SIZE, DEPOSIT_AMOUNT);

        vm.expectEmit(true, true, false, true);
        emit RootPay.ChannelRedeemed(PAYER, PAYEE, NATIVE_TOKEN, expectedMerchant, leafIndex);

        vm.prank(PAYEE);
        rootPay.redeemChannel(PAYER, NATIVE_TOKEN, leafIndex, secret, proof);
    }

    function test_RedeemChannel_EmitsChannelRefunded() public {
        uint16 leafIndex = DEFAULT_TREE_SIZE / 2 - 1;
        (bytes32 secret, bytes32[] memory proof) = getRedeemParams(leafIndex);

        uint256 expectedMerchant = _expectedMerchantPayout(leafIndex, DEFAULT_TREE_SIZE, DEPOSIT_AMOUNT);
        uint256 expectedRefund = DEPOSIT_AMOUNT - expectedMerchant;

        vm.expectEmit(true, true, false, true);
        emit RootPay.ChannelRefunded(PAYER, PAYEE, NATIVE_TOKEN, expectedRefund);

        vm.prank(PAYEE);
        rootPay.redeemChannel(PAYER, NATIVE_TOKEN, leafIndex, secret, proof);
    }

    // -------------------------------------------------------------------------
    // Revert: Channel State
    // -------------------------------------------------------------------------

    function test_Revert_RedeemChannel_ChannelNotExists() public {
        (bytes32 secret, bytes32[] memory proof) = getRedeemParams(0);

        vm.expectRevert(RootPay.ChannelDoesNotExistOrWithdrawn.selector);
        vm.prank(PAYEE);
        rootPay.redeemChannel(PAYER2, NATIVE_TOKEN, 0, secret, proof);
    }

    function test_Revert_RedeemChannel_InvalidPayer() public {
        (bytes32 secret, bytes32[] memory proof) = getRedeemParams(0);

        vm.expectRevert(bytes("Invalid address"));
        vm.prank(PAYEE);
        rootPay.redeemChannel(address(0), NATIVE_TOKEN, 0, secret, proof);
    }

    function test_Revert_RedeemChannel_TooEarly() public {
        // Create a fresh channel without advancing blocks
        bytes32 root = buildTreeWithSalt(DEFAULT_TREE_SIZE, bytes32(uint256(55)));

        vm.prank(PAYER2);
        rootPay.createChannel{value: DEPOSIT_AMOUNT}(
            PAYEE, NATIVE_TOKEN, root, DEPOSIT_AMOUNT, DEFAULT_TREE_SIZE, MERCHANT_DURATION, RECLAIM_DELAY
        );

        // merchantWithdrawAfterBlocks stored as block.number + MERCHANT_DURATION at creation time
        uint64 expectedUnlockBlock = uint64(block.number) + MERCHANT_DURATION;

        (bytes32 secret, bytes32[] memory proof) = getRedeemParams(0);

        vm.expectRevert(abi.encodeWithSelector(RootPay.MerchantCannotRedeemChannelYet.selector, expectedUnlockBlock));
        vm.prank(PAYEE);
        rootPay.redeemChannel(PAYER2, NATIVE_TOKEN, 0, secret, proof);
    }

    // -------------------------------------------------------------------------
    // Revert: Leaf Index
    // -------------------------------------------------------------------------

    function test_Revert_RedeemChannel_LeafIndexOutOfBounds() public {
        uint16 outOfBounds = DEFAULT_TREE_SIZE; // valid range is [0, treeSize-1]
        (bytes32 secret, bytes32[] memory proof) = getRedeemParams(DEFAULT_TREE_SIZE - 1);

        vm.expectRevert(abi.encodeWithSelector(RootPay.LeafIndexOutOfBounds.selector, outOfBounds, DEFAULT_TREE_SIZE));
        vm.prank(PAYEE);
        rootPay.redeemChannel(PAYER, NATIVE_TOKEN, outOfBounds, secret, proof);
    }

    // -------------------------------------------------------------------------
    // Revert: Proof Integrity
    // -------------------------------------------------------------------------

    function test_Revert_RedeemChannel_ProofLengthMismatch_TooShort() public {
        (bytes32 secret, bytes32[] memory proof) = getRedeemParams(0);

        // Truncate proof by one element
        bytes32[] memory shortProof = new bytes32[](proof.length - 1);
        for (uint256 i = 0; i < shortProof.length; i++) {
            shortProof[i] = proof[i];
        }

        vm.expectRevert(abi.encodeWithSelector(RootPay.ProofLengthMismatch.selector, shortProof.length, proof.length));
        vm.prank(PAYEE);
        rootPay.redeemChannel(PAYER, NATIVE_TOKEN, 0, secret, shortProof);
    }

    function test_Revert_RedeemChannel_ProofLengthMismatch_TooLong() public {
        (bytes32 secret, bytes32[] memory proof) = getRedeemParams(0);

        // Extend proof by one element
        bytes32[] memory longProof = new bytes32[](proof.length + 1);
        for (uint256 i = 0; i < proof.length; i++) {
            longProof[i] = proof[i];
        }
        longProof[proof.length] = bytes32(0);

        vm.expectRevert(abi.encodeWithSelector(RootPay.ProofLengthMismatch.selector, longProof.length, proof.length));
        vm.prank(PAYEE);
        rootPay.redeemChannel(PAYER, NATIVE_TOKEN, 0, secret, longProof);
    }

    function test_Revert_RedeemChannel_WrongSecret() public {
        bytes32[] memory proof = getProof(0);
        bytes32 wrongSecret = getWrongSecret(0);

        vm.expectRevert(RootPay.MerkleProofVerificationFailed.selector);
        vm.prank(PAYEE);
        rootPay.redeemChannel(PAYER, NATIVE_TOKEN, 0, wrongSecret, proof);
    }

    function test_Revert_RedeemChannel_TamperedProof() public {
        bytes32 secret = getSecret(0);
        bytes32[] memory proof = getTamperedProof(0, 0);

        vm.expectRevert(RootPay.MerkleProofVerificationFailed.selector);
        vm.prank(PAYEE);
        rootPay.redeemChannel(PAYER, NATIVE_TOKEN, 0, secret, proof);
    }

    function test_Revert_RedeemChannel_WrongLeafIndexForSecret() public {
        // Submit leaf 0's secret but claim it is leaf 1
        bytes32 secret = getSecret(0);
        bytes32[] memory proof = getProof(1);

        vm.expectRevert(RootPay.MerkleProofVerificationFailed.selector);
        vm.prank(PAYEE);
        rootPay.redeemChannel(PAYER, NATIVE_TOKEN, 1, secret, proof);
    }

    // -------------------------------------------------------------------------
    // Revert: Nothing Payable
    // -------------------------------------------------------------------------

    function test_Revert_RedeemChannel_NothingPayable() public {
        uint256 tinyDeposit = uint256(DEFAULT_TREE_SIZE) - 1; // 511 wei

        vm.deal(PAYER2, tinyDeposit);
        bytes32 root = buildTreeWithSalt(DEFAULT_TREE_SIZE, bytes32(uint256(777)));

        vm.prank(PAYER2);
        rootPay.createChannel{value: tinyDeposit}(
            PAYEE, NATIVE_TOKEN, root, tinyDeposit, DEFAULT_TREE_SIZE, MERCHANT_DURATION, RECLAIM_DELAY
        );

        _advancePastMerchantWindow();

        (bytes32 secret, bytes32[] memory proof) = getRedeemParams(0);

        vm.expectRevert(RootPay.NothingPayable.selector);
        vm.prank(PAYEE);
        rootPay.redeemChannel(PAYER2, NATIVE_TOKEN, 0, secret, proof);
    }

    // -------------------------------------------------------------------------
    // Revert: Only Merchant Can Redeem
    // -------------------------------------------------------------------------

    function test_Revert_RedeemChannel_PayerCannotRedeem() public {
        // Payer tries to redeem their own channel — maps to wrong channel slot
        (bytes32 secret, bytes32[] memory proof) = getRedeemParams(DEFAULT_TREE_SIZE - 1);

        // channelsMapping[PAYER][PAYER][token] does not exist
        vm.expectRevert(RootPay.ChannelDoesNotExistOrWithdrawn.selector);
        vm.prank(PAYER);
        rootPay.redeemChannel(PAYER, NATIVE_TOKEN, DEFAULT_TREE_SIZE - 1, secret, proof);
    }

    function test_Revert_RedeemChannel_ThirdPartyCannotRedeem() public {
        (bytes32 secret, bytes32[] memory proof) = getRedeemParams(DEFAULT_TREE_SIZE - 1);

        // channelsMapping[PAYER][PAYER2][token] does not exist
        vm.expectRevert(RootPay.ChannelDoesNotExistOrWithdrawn.selector);
        vm.prank(PAYER2);
        rootPay.redeemChannel(PAYER, NATIVE_TOKEN, DEFAULT_TREE_SIZE - 1, secret, proof);
    }
}
