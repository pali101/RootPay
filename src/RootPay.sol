// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

/**
 * @title RootPay - Merkle-Indexed Payment Channel
 * @dev Enables high-frequency micropayment channels between a payer and a merchant
 * using a Merkle tree commitment scheme for O(log n) on-chain settlement.
 *
 * The payer pre-commits to a Merkle tree of N leaves (N must be a power of 2).
 * Each leaf has an implicit fixed value of (channelAmount / N).
 * Settlement requires only the highest verified leaf index and its Merkle proof.
 *
 * Leaf construction: Leaf(i) = keccak256(abi.encode(i, secret_i))
 * Payout formula:    merchantAmount = (leafIndex + 1) * amount / treeSize
 */
contract RootPay is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Data Structures
    // -------------------------------------------------------------------------

    /**
     * @dev Represents a payment channel between a payer and a merchant.
     */
    struct Channel {
        address token; // Token address, address(0) for native currency
        bytes32 merkleRoot; // Merkle root committed at channel creation
        uint256 amount; // Total deposit in the payment channel
        uint16 treeSize; // Number of leaves in the Merkle tree (must be power of 2)
        uint64 merchantWithdrawAfterBlocks; // Block number after which the merchant can withdraw
        uint64 payerWithdrawAfterBlocks; // Block number after which the payer can reclaim funds
    }

    // payer -> merchant -> token -> channel
    mapping(address => mapping(address => mapping(address => Channel))) public channelsMapping;

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error IncorrectAmount(uint256 sent, uint256 expected);
    error MerchantCannotRedeemChannelYet(uint64 blockNumber);
    error ChannelDoesNotExistOrWithdrawn();
    error MerkleProofVerificationFailed();
    error NothingPayable();
    error FailedToSendEther();
    error PayerCannotRedeemChannelYet(uint64 blockNumber);
    error ChannelAlreadyExist(address payer, address merchant, address token, uint256 amount, uint16 treeSize);
    error TreeSizeNotPowerOfTwo(uint16 treeSize);
    error TreeSizeIsZero();
    error MerchantWithdrawTimeTooShort();
    error LeafIndexOutOfBounds(uint16 leafIndex, uint16 treeSize);
    error ProofLengthMismatch(uint256 proofLength, uint256 expectedLength);
    error InsufficientAllowance(uint256 required, uint256 actual);
    error AddressIsNotContract(address token);
    error AddressIsNotERC20(address token);
    error DepositWithPermitNotSupportedForNative();

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event ChannelCreated(
        address indexed payer,
        address indexed merchant,
        address token,
        uint256 amount,
        uint16 treeSize,
        uint64 merchantWithdrawAfterBlocks
    );
    event ChannelRedeemed(
        address indexed payer, address indexed merchant, address token, uint256 amountPaid, uint16 leafIndex
    );
    event ChannelRefunded(address indexed payer, address indexed merchant, address token, uint256 refundAmount);
    event ChannelReclaimed(address indexed payer, address indexed merchant, address token, uint64 blockNumber);

    // -------------------------------------------------------------------------
    // Core Merkle Logic
    // -------------------------------------------------------------------------

    /**
     * @dev Constructs a leaf from a leaf index and its secret.
     * @param leafIndex The position of the leaf in the tree (0-based).
     * @param secret The secret pre-image known only to the payer.
     * @return The leaf hash.
     */
    function computeLeaf(uint16 leafIndex, bytes32 secret) public pure returns (bytes32) {
        return keccak256(abi.encode(leafIndex, secret));
    }

    /**
     * @dev Verifies a Merkle proof for a given leaf.
     *
     * Proof siblings are ordered from the leaf level up to (but not including)
     * the root. At each level, the current node is placed left or right based
     * on whether the current index is even or odd respectively.
     *
     * @param merkleRoot   The committed root of the Merkle tree.
     * @param leafIndex    The 0-based index of the leaf being proven.
     * @param secret       The secret pre-image of the leaf.
     * @param proof        The Merkle proof (sibling hashes, leaf to root).
     * @return True if the proof is valid against the root.
     */
    function verifyMerkleProof(bytes32 merkleRoot, uint16 leafIndex, bytes32 secret, bytes32[] calldata proof)
        public
        pure
        returns (bool)
    {
        bytes32 computed = computeLeaf(leafIndex, secret);
        uint256 index = leafIndex;

        for (uint256 i = 0; i < proof.length; i++) {
            if (index % 2 == 0) {
                // current node is a left child
                computed = keccak256(abi.encode(computed, proof[i]));
            } else {
                // current node is a right child
                computed = keccak256(abi.encode(proof[i], computed));
            }
            index /= 2;
        }

        return computed == merkleRoot;
    }

    // -------------------------------------------------------------------------
    // Channel Creation
    // -------------------------------------------------------------------------

    /**
     * @dev Creates a new payment channel between a payer and a merchant.
     * @param merchant                  The merchant receiving payments.
     * @param token                     ERC-20 token address, or address(0) for native currency.
     * @param merkleRoot                The Merkle root of the payer's pre-committed leaf tree.
     * @param amount                    Total deposit amount for the channel.
     * @param treeSize                  Number of leaves in the Merkle tree. Must be a power of 2.
     * @param merchantWithdrawAfterBlocks  Block offset after which the merchant may redeem.
     * @param payerWithdrawAfterBlocks     Block offset after which the payer may reclaim.
     */
    function createChannel(
        address merchant,
        address token,
        bytes32 merkleRoot,
        uint256 amount,
        uint16 treeSize,
        uint64 merchantWithdrawAfterBlocks,
        uint64 payerWithdrawAfterBlocks
    ) public payable nonReentrant {
        _validateChannelParams(merchant, treeSize, merchantWithdrawAfterBlocks, payerWithdrawAfterBlocks);

        if (token == address(0)) {
            _createNativeChannel(amount);
        } else {
            _createERC20Channel(msg.sender, token, amount);
        }

        _initChannel(
            msg.sender,
            merchant,
            token,
            merkleRoot,
            amount,
            treeSize,
            merchantWithdrawAfterBlocks,
            payerWithdrawAfterBlocks
        );

        emit ChannelCreated(
            msg.sender, merchant, token, amount, treeSize, uint64(block.number) + merchantWithdrawAfterBlocks
        );
    }

    /**
     * @dev Creates a new payment channel using EIP-2612 permit for gasless approval.
     * @param payer                     The address of the user funding the channel.
     * @param merchant                  The merchant receiving payments.
     * @param token                     ERC-20 token address (native currency not supported with permit).
     * @param merkleRoot                The Merkle root of the payer's pre-committed leaf tree.
     * @param amount                    Total deposit amount for the channel.
     * @param treeSize                  Number of leaves in the Merkle tree. Must be a power of 2.
     * @param merchantWithdrawAfterBlocks  Block offset after which the merchant may redeem.
     * @param payerWithdrawAfterBlocks     Block offset after which the payer may reclaim.
     * @param deadline                  Permit deadline timestamp.
     * @param v, r, s                   EIP-2612 signature parameters.
     */
    function createChannelWithPermit(
        address payer,
        address merchant,
        address token,
        bytes32 merkleRoot,
        uint256 amount,
        uint16 treeSize,
        uint64 merchantWithdrawAfterBlocks,
        uint64 payerWithdrawAfterBlocks,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public nonReentrant {
        require(token != address(0), DepositWithPermitNotSupportedForNative());
        require(payer != address(0), "Invalid payer address");

        _validateChannelParams(merchant, treeSize, merchantWithdrawAfterBlocks, payerWithdrawAfterBlocks);

        IERC20Permit(token).permit(payer, address(this), amount, deadline, v, r, s);
        _createERC20Channel(payer, token, amount);
        _initChannel(
            payer, merchant, token, merkleRoot, amount, treeSize, merchantWithdrawAfterBlocks, payerWithdrawAfterBlocks
        );

        emit ChannelCreated(
            payer, merchant, token, amount, treeSize, uint64(block.number) + merchantWithdrawAfterBlocks
        );
    }

    // -------------------------------------------------------------------------
    // Channel Redemption
    // -------------------------------------------------------------------------

    /**
     * @dev Redeems a payment channel by submitting the highest verified Merkle leaf.
     *
     * The merchant receives (leafIndex + 1) * amount / treeSize tokens.
     * Integer division dust is returned to the payer.
     *
     * @param payer      The address of the payer.
     * @param token      ERC-20 token address, or address(0) for native currency.
     * @param leafIndex  The 0-based index of the highest leaf the merchant has verified.
     * @param secret     The secret pre-image for the leaf at leafIndex.
     * @param proof      The Merkle proof for the leaf (sibling hashes, leaf to root).
     */
    function redeemChannel(address payer, address token, uint16 leafIndex, bytes32 secret, bytes32[] calldata proof)
        public
        nonReentrant
    {
        require(payer != address(0), "Invalid address");

        Channel storage channel = channelsMapping[payer][msg.sender][token];
        _validateRedeemChannel(channel, leafIndex, secret, proof);

        uint256 payableAmountMerchant = (channel.amount * (uint256(leafIndex) + 1)) / channel.treeSize;
        uint256 payableAmountPayer = channel.amount - payableAmountMerchant;

        if (payableAmountMerchant == 0) revert NothingPayable();

        delete channelsMapping[payer][msg.sender][token];

        _transferAmount(token, msg.sender, payableAmountMerchant);
        if (payableAmountPayer > 0) {
            _transferAmount(token, payer, payableAmountPayer);
        }

        emit ChannelRedeemed(payer, msg.sender, token, payableAmountMerchant, leafIndex);
        emit ChannelRefunded(payer, msg.sender, token, payableAmountPayer);
    }

    // -------------------------------------------------------------------------
    // Channel Reclaim
    // -------------------------------------------------------------------------

    /**
     * @dev Allows the payer to reclaim their deposit after payerWithdrawAfterBlocks.
     * @param merchant  The address of the merchant.
     * @param token     ERC-20 token address, or address(0) for native currency.
     */
    function reclaimChannel(address merchant, address token) public nonReentrant {
        require(merchant != address(0), "Invalid address");

        Channel storage channel = channelsMapping[msg.sender][merchant][token];
        _validateReclaimChannel(channel);

        uint256 amountToReclaim = channel.amount;
        delete channelsMapping[msg.sender][merchant][token];

        _transferAmount(token, msg.sender, amountToReclaim);

        emit ChannelReclaimed(msg.sender, merchant, token, uint64(block.number));
    }

    // -------------------------------------------------------------------------
    // Internal Helpers
    // -------------------------------------------------------------------------

    /**
     * @dev Validates parameters common to all channel creation paths.
     */
    function _validateChannelParams(
        address merchant,
        uint16 treeSize,
        uint64 merchantWithdrawAfterBlocks,
        uint64 payerWithdrawAfterBlocks
    ) internal pure {
        require(merchant != address(0), "Invalid address");

        if (treeSize == 0) {
            revert TreeSizeIsZero();
        }

        // Power-of-2 check: a power of 2 has exactly one bit set
        if ((treeSize & (treeSize - 1)) != 0) {
            revert TreeSizeNotPowerOfTwo(treeSize);
        }

        // Payer reclaim window must give merchant sufficient buffer:
        // payerWithdrawAfterBlocks >= 1.1 * merchantWithdrawAfterBlocks
        if ((11 * merchantWithdrawAfterBlocks) / 10 > payerWithdrawAfterBlocks) {
            revert MerchantWithdrawTimeTooShort();
        }
    }

    /**
     * @dev Validates channel state and Merkle proof before redemption.
     */
    function _validateRedeemChannel(Channel storage channel, uint16 leafIndex, bytes32 secret, bytes32[] calldata proof)
        internal
        view
    {
        if (channel.amount == 0) {
            revert ChannelDoesNotExistOrWithdrawn();
        }

        if (channel.merchantWithdrawAfterBlocks > block.number) {
            revert MerchantCannotRedeemChannelYet(channel.merchantWithdrawAfterBlocks);
        }

        // leafIndex is 0-based, valid range is [0, treeSize - 1]
        if (leafIndex >= channel.treeSize) {
            revert LeafIndexOutOfBounds(leafIndex, channel.treeSize);
        }

        // Proof length must equal log2(treeSize)
        // Since treeSize is a power of 2, log2 = number of trailing zeros = position of set bit
        uint256 expectedProofLength = _log2(channel.treeSize);
        if (proof.length != expectedProofLength) {
            revert ProofLengthMismatch(proof.length, expectedProofLength);
        }

        if (!verifyMerkleProof(channel.merkleRoot, leafIndex, secret, proof)) {
            revert MerkleProofVerificationFailed();
        }
    }

    /**
     * @dev Validates reclaim conditions for a payment channel.
     */
    function _validateReclaimChannel(Channel storage channel) internal view {
        if (channel.amount == 0) revert ChannelDoesNotExistOrWithdrawn();
        if (channel.payerWithdrawAfterBlocks >= block.number) {
            revert PayerCannotRedeemChannelYet(channel.payerWithdrawAfterBlocks);
        }
    }

    /**
     * @dev Handles native currency deposit validation.
     */
    function _createNativeChannel(uint256 amount) internal view {
        if (msg.value != amount) {
            revert IncorrectAmount(msg.value, amount);
        }
    }

    /**
     * @dev Handles ERC-20 token validation and transfer.
     */
    function _createERC20Channel(address payer, address token, uint256 amount) internal {
        if (msg.value != 0) {
            revert IncorrectAmount(msg.value, 0);
        }

        if (token.code.length == 0) {
            revert AddressIsNotContract(token);
        }

        try IERC20(token).totalSupply() returns (
            uint256
        ) {
        // Lightweight ERC-20 sanity check
        }
        catch {
            revert AddressIsNotERC20(token);
        }

        uint256 allowance = IERC20(token).allowance(payer, address(this));
        if (allowance < amount) {
            revert InsufficientAllowance(amount, allowance);
        }

        IERC20(token).safeTransferFrom(payer, address(this), amount);
    }

    /**
     * @dev Initializes the channel in storage.
     */
    function _initChannel(
        address payer,
        address merchant,
        address token,
        bytes32 merkleRoot,
        uint256 amount,
        uint16 treeSize,
        uint64 merchantWithdrawAfterBlocks,
        uint64 payerWithdrawAfterBlocks
    ) internal {
        if (channelsMapping[payer][merchant][token].amount != 0) {
            revert ChannelAlreadyExist(
                payer,
                merchant,
                token,
                channelsMapping[payer][merchant][token].amount,
                channelsMapping[payer][merchant][token].treeSize
            );
        }

        channelsMapping[payer][merchant][token] = Channel({
            token: token,
            merkleRoot: merkleRoot,
            amount: amount,
            treeSize: treeSize,
            merchantWithdrawAfterBlocks: uint64(block.number) + merchantWithdrawAfterBlocks,
            payerWithdrawAfterBlocks: uint64(block.number) + payerWithdrawAfterBlocks
        });
    }

    /**
     * @dev Transfers amount to recipient in ERC-20 tokens or native currency.
     */
    function _transferAmount(address token, address recipient, uint256 amount) internal {
        if (amount == 0) revert NothingPayable();

        if (token == address(0)) {
            (bool sent,) = payable(recipient).call{value: amount}("");
            if (!sent) revert FailedToSendEther();
        } else {
            IERC20(token).safeTransfer(recipient, amount);
        }
    }

    /**
     * @dev Computes log2 of a power-of-2 value using a bit-shift loop.
     * Only call this with values already validated as powers of 2.
     * @param x A non-zero power-of-2 uint16 value.
     * @return n such that 2^n == x.
     */
    function _log2(uint16 x) internal pure returns (uint256) {
        uint256 n = 0;
        while (x > 1) {
            x >>= 1;
            n++;
        }
        return n;
    }

    // -------------------------------------------------------------------------
    // Safety
    // -------------------------------------------------------------------------

    receive() external payable {
        revert("RootPay: Direct ETH deposits are not allowed");
    }

    fallback() external payable {
        revert("RootPay: Invalid function call or ETH transfer");
    }
}
