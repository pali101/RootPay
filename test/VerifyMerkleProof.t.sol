// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTestHelper} from "./helper/BaseTestHelper.sol";
import {MerkleHelper} from "./helper/MerkleHelper.sol";

/**
 * @title VerifyMerkleProofTest
 * @dev Tests for RootPay.verifyMerkleProof() in isolation.
 *
 * These tests validate the core cryptographic primitive before any channel
 * logic is involved. Every redeem test depends on this being correct.
 *
 * Coverage:
 *  - Valid proofs across tree sizes and leaf positions
 *  - Invalid proofs: wrong secret, wrong index, tampered siblings
 *  - Edge cases: smallest tree, largest tree, first leaf, last leaf
 */
contract VerifyMerkleProofTest is BaseTestHelper, MerkleHelper {
    // -------------------------------------------------------------------------
    // Valid Proofs
    // -------------------------------------------------------------------------

    function test_ValidProof_LeafZero_DefaultTree() public {
        bytes32 root = buildTree(DEFAULT_TREE_SIZE);
        (bytes32 secret, bytes32[] memory proof) = getRedeemParams(0);

        assertTrue(rootPay.verifyMerkleProof(root, 0, secret, proof), "leaf 0 proof should be valid");
    }

    function test_ValidProof_LastLeaf_DefaultTree() public {
        uint16 lastIndex = DEFAULT_TREE_SIZE - 1;
        bytes32 root = buildTree(DEFAULT_TREE_SIZE);
        (bytes32 secret, bytes32[] memory proof) = getRedeemParams(lastIndex);

        assertTrue(rootPay.verifyMerkleProof(root, lastIndex, secret, proof), "last leaf proof should be valid");
    }

    function test_ValidProof_MiddleLeaf_DefaultTree() public {
        uint16 midIndex = DEFAULT_TREE_SIZE / 2;
        bytes32 root = buildTree(DEFAULT_TREE_SIZE);
        (bytes32 secret, bytes32[] memory proof) = getRedeemParams(midIndex);

        assertTrue(rootPay.verifyMerkleProof(root, midIndex, secret, proof), "middle leaf proof should be valid");
    }

    function test_ValidProof_AllLeaves_DefaultTree() public {
        bytes32 root = buildTree(DEFAULT_TREE_SIZE);

        for (uint16 i = 0; i < DEFAULT_TREE_SIZE; i++) {
            (bytes32 secret, bytes32[] memory proof) = getRedeemParams(i);
            assertTrue(rootPay.verifyMerkleProof(root, i, secret, proof), "every leaf proof should be valid");
        }
    }

    // -------------------------------------------------------------------------
    // Valid Proofs — Tree Size Boundaries
    // -------------------------------------------------------------------------

    function test_ValidProof_TreeSize2_LeafZero() public {
        bytes32 root = buildTree(2);
        (bytes32 secret, bytes32[] memory proof) = getRedeemParams(0);

        assertTrue(rootPay.verifyMerkleProof(root, 0, secret, proof), "treeSize=2 leaf 0 should be valid");
    }

    function test_ValidProof_TreeSize2_LeafOne() public {
        bytes32 root = buildTree(2);
        (bytes32 secret, bytes32[] memory proof) = getRedeemParams(1);

        assertTrue(rootPay.verifyMerkleProof(root, 1, secret, proof), "treeSize=2 leaf 1 should be valid");
    }

    function test_ValidProof_TreeSize1_LeafZero() public {
        // treeSize=1: single leaf, proof is empty, root == leaf
        bytes32 root = buildTree(1);
        (bytes32 secret, bytes32[] memory proof) = getRedeemParams(0);

        assertEq(proof.length, 0, "treeSize=1 proof should be empty");
        assertTrue(rootPay.verifyMerkleProof(root, 0, secret, proof), "treeSize=1 single leaf should be valid");
    }

    function test_ValidProof_LargeTree_LeafZero() public {
        bytes32 root = buildTree(LARGE_TREE_SIZE);
        (bytes32 secret, bytes32[] memory proof) = getRedeemParams(0);

        assertTrue(rootPay.verifyMerkleProof(root, 0, secret, proof), "large tree leaf 0 proof should be valid");
    }

    function test_ValidProof_LargeTree_LastLeaf() public {
        uint16 lastIndex = LARGE_TREE_SIZE - 1;
        bytes32 root = buildTree(LARGE_TREE_SIZE);
        (bytes32 secret, bytes32[] memory proof) = getRedeemParams(lastIndex);

        assertTrue(
            rootPay.verifyMerkleProof(root, lastIndex, secret, proof), "large tree last leaf proof should be valid"
        );
    }

    function test_ValidProof_LargeTree_MiddleLeaf() public {
        uint16 midIndex = LARGE_TREE_SIZE / 2;
        bytes32 root = buildTree(LARGE_TREE_SIZE);
        (bytes32 secret, bytes32[] memory proof) = getRedeemParams(midIndex);

        assertTrue(
            rootPay.verifyMerkleProof(root, midIndex, secret, proof), "large tree middle leaf proof should be valid"
        );
    }

    // -------------------------------------------------------------------------
    // Valid Proofs — Proof Length
    // -------------------------------------------------------------------------

    function test_ProofLength_TreeSize2() public {
        buildTree(2);
        bytes32[] memory proof = getProof(0);
        assertEq(proof.length, 1, "treeSize=2 proof should have 1 sibling");
    }

    function test_ProofLength_TreeSize512() public {
        buildTree(512);
        bytes32[] memory proof = getProof(0);
        assertEq(proof.length, 9, "treeSize=512 proof should have 9 siblings");
    }

    function test_ProofLength_LargeTree() public {
        buildTree(LARGE_TREE_SIZE); // 2^12 = 4096
        bytes32[] memory proof = getProof(0);
        assertEq(proof.length, 12, "treeSize=4096 proof should have 12 siblings");
    }

    // -------------------------------------------------------------------------
    // Invalid Proofs — Wrong Secret
    // -------------------------------------------------------------------------

    function test_InvalidProof_WrongSecret_LeafZero() public {
        bytes32 root = buildTree(DEFAULT_TREE_SIZE);
        bytes32[] memory proof = getProof(0);
        bytes32 wrongSecret = getWrongSecret(0);

        assertFalse(rootPay.verifyMerkleProof(root, 0, wrongSecret, proof), "wrong secret should fail verification");
    }

    function test_InvalidProof_WrongSecret_MiddleLeaf() public {
        uint16 midIndex = DEFAULT_TREE_SIZE / 2;
        bytes32 root = buildTree(DEFAULT_TREE_SIZE);
        bytes32[] memory proof = getProof(midIndex);
        bytes32 wrongSecret = getWrongSecret(midIndex);

        assertFalse(
            rootPay.verifyMerkleProof(root, midIndex, wrongSecret, proof), "wrong secret on middle leaf should fail"
        );
    }

    function test_InvalidProof_ZeroSecret() public {
        bytes32 root = buildTree(DEFAULT_TREE_SIZE);
        bytes32[] memory proof = getProof(0);

        assertFalse(rootPay.verifyMerkleProof(root, 0, bytes32(0), proof), "zero secret should fail verification");
    }

    // -------------------------------------------------------------------------
    // Invalid Proofs — Wrong Leaf Index
    // -------------------------------------------------------------------------

    function test_InvalidProof_WrongIndex_CorrectSecretAndProof() public {
        // Submit leaf 0's secret+proof but claim it is leaf 1
        bytes32 root = buildTree(DEFAULT_TREE_SIZE);
        bytes32 secret = getSecret(0);
        bytes32[] memory proof = getProof(0);

        assertFalse(
            rootPay.verifyMerkleProof(root, 1, secret, proof),
            "correct secret/proof for leaf 0 should fail when claiming leaf 1"
        );
    }

    function test_InvalidProof_SecretProofMismatch() public {
        // Secret from leaf 0, proof from leaf 1
        bytes32 root = buildTree(DEFAULT_TREE_SIZE);
        bytes32 secret = getSecret(0);
        bytes32[] memory proof = getProof(1);

        assertFalse(rootPay.verifyMerkleProof(root, 0, secret, proof), "secret/proof index mismatch should fail");
    }

    // -------------------------------------------------------------------------
    // Invalid Proofs — Tampered Siblings
    // -------------------------------------------------------------------------

    function test_InvalidProof_TamperedSibling_LevelZero() public {
        bytes32 root = buildTree(DEFAULT_TREE_SIZE);
        bytes32 secret = getSecret(0);
        bytes32[] memory proof = getTamperedProof(0, 0);

        assertFalse(rootPay.verifyMerkleProof(root, 0, secret, proof), "tampered level-0 sibling should fail");
    }

    function test_InvalidProof_TamperedSibling_TopLevel() public {
        bytes32 root = buildTree(DEFAULT_TREE_SIZE);
        uint256 topLevel = proof_depth(DEFAULT_TREE_SIZE) - 1;
        bytes32 secret = getSecret(0);
        bytes32[] memory proof = getTamperedProof(0, topLevel);

        assertFalse(rootPay.verifyMerkleProof(root, 0, secret, proof), "tampered top-level sibling should fail");
    }

    function test_InvalidProof_AllSiblingsTampered() public {
        bytes32 root = buildTree(DEFAULT_TREE_SIZE);
        bytes32 secret = getSecret(0);
        bytes32[] memory proof = getProof(0);

        // Corrupt every sibling
        for (uint256 i = 0; i < proof.length; i++) {
            proof[i] = keccak256(abi.encode("tampered", i));
        }

        assertFalse(rootPay.verifyMerkleProof(root, 0, secret, proof), "all-tampered proof should fail");
    }

    // -------------------------------------------------------------------------
    // Invalid Proofs — Wrong Root
    // -------------------------------------------------------------------------

    function test_InvalidProof_WrongRoot() public {
        buildTree(DEFAULT_TREE_SIZE);
        bytes32 wrongRoot = keccak256(abi.encode("wrong root"));
        (bytes32 secret, bytes32[] memory proof) = getRedeemParams(0);

        assertFalse(rootPay.verifyMerkleProof(wrongRoot, 0, secret, proof), "wrong root should fail verification");
    }

    function test_InvalidProof_ZeroRoot() public {
        buildTree(DEFAULT_TREE_SIZE);
        (bytes32 secret, bytes32[] memory proof) = getRedeemParams(0);

        assertFalse(rootPay.verifyMerkleProof(bytes32(0), 0, secret, proof), "zero root should fail verification");
    }

    function test_InvalidProof_RootFromDifferentTree() public {
        // Build two trees with different salts, use root from tree A with proof from tree B
        bytes32 rootA = buildTreeWithSalt(DEFAULT_TREE_SIZE, bytes32(uint256(1)));
        buildTreeWithSalt(DEFAULT_TREE_SIZE, bytes32(uint256(2)));

        (bytes32 secret, bytes32[] memory proof) = getRedeemParams(0); // from tree B

        assertFalse(rootPay.verifyMerkleProof(rootA, 0, secret, proof), "proof from different tree should fail");
    }

    // -------------------------------------------------------------------------
    // Internal Utility
    // -------------------------------------------------------------------------

    /**
     * @dev Returns expected proof depth (log2) for a given treeSize.
     * Mirrors MerkleHelper._log2 — used for top-level tamper index calculation.
     */
    function proof_depth(uint16 treeSize) internal pure returns (uint256 n) {
        uint16 x = treeSize;
        while (x > 1) {
            x >>= 1;
            n++;
        }
    }
}
