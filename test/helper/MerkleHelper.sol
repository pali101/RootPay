// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {RootPay} from "../../src/RootPay.sol";

/**
 * @title MerkleHelper
 * @dev Test utility for building Merkle trees and generating proofs compatible
 * with RootPay's verification scheme.
 *
 * Leaf construction:  Leaf(i) = keccak256(abi.encode(i, secret_i))
 * Secret derivation:  secret_i = keccak256(abi.encode("rootpay-secret", salt, i))
 *
 * Tree layout (example, treeSize = 4):
 *
 *              root
 *            /      \
 *         h(0,1)   h(2,3)
 *         /   \    /   \
 *        L0   L1  L2   L3
 *
 * Level 0 = leaves, Level log2(N) = root.
 * tree[level][index] stores the node hash at that level and index.
 */
contract MerkleHelper is Test {
    // -------------------------------------------------------------------------
    // Internal State
    // -------------------------------------------------------------------------

    // tree[level][nodeIndex] => node hash
    // level 0 = leaves, level depth = root
    mapping(uint256 => mapping(uint256 => bytes32)) internal _tree;

    // secrets[leafIndex] => secret for that leaf
    mapping(uint256 => bytes32) internal _secrets;

    // Depth of the last built tree (log2 of treeSize)
    uint256 internal _depth;

    // Size of the last built tree
    uint16 internal _treeSize;

    // Salt mixed into secret derivation — set per test to avoid cross-test collisions
    bytes32 internal _salt;

    // -------------------------------------------------------------------------
    // Tree Construction
    // -------------------------------------------------------------------------

    /**
     * @dev Builds a Merkle tree of the given size using a default salt.
     * treeSize must be a power of 2.
     * @param treeSize Number of leaves.
     * @return root The Merkle root.
     */
    function buildTree(uint16 treeSize) internal returns (bytes32 root) {
        return buildTreeWithSalt(treeSize, bytes32(uint256(uint160(address(this)))));
    }

    /**
     * @dev Builds a Merkle tree with an explicit salt.
     * Use distinct salts in tests that open multiple channels to prevent
     * secret/root collisions between channels.
     * @param treeSize Number of leaves. Must be a power of 2.
     * @param salt     Unique salt for secret derivation.
     * @return root The Merkle root.
     */
    function buildTreeWithSalt(uint16 treeSize, bytes32 salt) internal returns (bytes32 root) {
        require(treeSize > 0 && (treeSize & (treeSize - 1)) == 0, "MerkleHelper: treeSize must be power of 2");

        _treeSize = treeSize;
        _salt = salt;
        _depth = _log2(treeSize);

        // --- Level 0: build leaves ---
        for (uint256 i = 0; i < treeSize; i++) {
            bytes32 secret = _deriveSecret(salt, uint16(i));
            _secrets[i] = secret;
            _tree[0][i] = _computeLeaf(uint16(i), secret);
        }

        // --- Levels 1..depth: build internal nodes bottom-up ---
        for (uint256 level = 1; level <= _depth; level++) {
            uint256 nodesAtLevel = treeSize >> level; // treeSize / 2^level
            for (uint256 i = 0; i < nodesAtLevel; i++) {
                _tree[level][i] = keccak256(abi.encode(_tree[level - 1][2 * i], _tree[level - 1][2 * i + 1]));
            }
        }

        return _tree[_depth][0];
    }

    // -------------------------------------------------------------------------
    // Proof Generation
    // -------------------------------------------------------------------------

    /**
     * @dev Returns the Merkle proof for a given leaf index.
     * Proof is ordered from the leaf level up to (but not including) the root,
     * matching RootPay's verifyMerkleProof() traversal.
     * @param leafIndex The 0-based index of the leaf.
     * @return proof Array of sibling hashes, leaf-to-root order.
     */
    function getProof(uint16 leafIndex) internal view returns (bytes32[] memory proof) {
        require(leafIndex < _treeSize, "MerkleHelper: leafIndex out of bounds");

        proof = new bytes32[](_depth);
        uint256 index = leafIndex;

        for (uint256 level = 0; level < _depth; level++) {
            // Sibling is at index^1 (flips last bit: left<->right)
            uint256 siblingIndex = index % 2 == 0 ? index + 1 : index - 1;
            proof[level] = _tree[level][siblingIndex];
            index /= 2;
        }
    }

    // -------------------------------------------------------------------------
    // Secret Access
    // -------------------------------------------------------------------------

    /**
     * @dev Returns the secret for a given leaf index.
     * Only valid after buildTree() or buildTreeWithSalt() has been called.
     */
    function getSecret(uint16 leafIndex) internal view returns (bytes32) {
        require(leafIndex < _treeSize, "MerkleHelper: leafIndex out of bounds");
        return _secrets[leafIndex];
    }

    /**
     * @dev Returns the leaf hash for a given leaf index.
     */
    function getLeaf(uint16 leafIndex) internal view returns (bytes32) {
        require(leafIndex < _treeSize, "MerkleHelper: leafIndex out of bounds");
        return _tree[0][leafIndex];
    }

    /**
     * @dev Returns the Merkle root of the last built tree.
     */
    function getRoot() internal view returns (bytes32) {
        return _tree[_depth][0];
    }

    // -------------------------------------------------------------------------
    // Convenience: Proof + Secret in One Call
    // -------------------------------------------------------------------------

    /**
     * @dev Returns both the secret and Merkle proof for a leaf index.
     * Reduces boilerplate in redeem tests.
     */
    function getRedeemParams(uint16 leafIndex) internal view returns (bytes32 secret, bytes32[] memory proof) {
        secret = getSecret(leafIndex);
        proof = getProof(leafIndex);
    }

    // -------------------------------------------------------------------------
    // Tamper Utilities (for negative tests)
    // -------------------------------------------------------------------------

    /**
     * @dev Returns a proof with one sibling hash corrupted at the given level.
     * Use in tests expecting MerkleProofVerificationFailed.
     */
    function getTamperedProof(uint16 leafIndex, uint256 tamperLevel) internal view returns (bytes32[] memory proof) {
        proof = getProof(leafIndex);
        require(tamperLevel < proof.length, "MerkleHelper: tamperLevel out of range");
        proof[tamperLevel] = keccak256(abi.encode("tampered", proof[tamperLevel]));
    }

    /**
     * @dev Returns a wrong secret (derived from a different leaf index).
     * Use in tests expecting MerkleProofVerificationFailed.
     */
    function getWrongSecret(uint16 leafIndex) internal view returns (bytes32) {
        // Derive a secret as if it belonged to the next leaf
        uint16 wrongIndex = leafIndex == _treeSize - 1 ? 0 : leafIndex + 1;
        return _deriveSecret(_salt, wrongIndex);
    }

    // -------------------------------------------------------------------------
    // Internal Utilities
    // -------------------------------------------------------------------------

    /**
     * @dev Derives a deterministic secret for a leaf.
     * Matches: secret_i = keccak256(abi.encode("rootpay-secret", salt, i))
     */
    function _deriveSecret(bytes32 salt, uint16 leafIndex) internal pure returns (bytes32) {
        return keccak256(abi.encode("rootpay-secret", salt, leafIndex));
    }

    /**
     * @dev Computes a leaf hash. Must match RootPay.computeLeaf().
     */
    function _computeLeaf(uint16 leafIndex, bytes32 secret) internal pure returns (bytes32) {
        return keccak256(abi.encode(leafIndex, secret));
    }

    /**
     * @dev Computes log2 of a power-of-2 value. Matches RootPay._log2().
     */
    function _log2(uint16 x) internal pure returns (uint256 n) {
        while (x > 1) {
            x >>= 1;
            n++;
        }
    }
}
