// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mayowa Akande. All rights reserved.
pragma solidity 0.8.24;

/*
 * KNOWN LIMITATION: GRIEFING UNDER IRRATIONALITY
 * The bond schedule assumes rational economic actors. A party willing to lose
 * money can escalate past the event horizon, forcing both sides to forfeit
 * collateral: the loser's collateral and the winner's post-horizon collateral
 * are routed to the treasury. There is no turn cap and escalation is not
 * bounded by lifetime. It is bounded by cost: each turn's bond grows by
 * 2000 bps of the disputed amount, so the attacker's cumulative cost grows
 * quadratically with turn count, and by the attacker's balance. The treasury
 * benefits financially from long disputes.
 
 * KNOWN LIMITATION: NO ORACLE, NO TRUTH VERIFICATION
 * The contract never judges who is right. Disputes are resolved by a
 * bond-escalation game: whoever holds the last turn wins, regardless of the
 * merits. The outcome therefore favours the party with more capital or a
 * higher tolerance for loss, not necessarily the honest one. A decentralized
 * court or ZK verification of the deliverable was deliberately left out:
 * both add substantial cost and complexity, and the design accepts this
 * trade-off. Parties should size escrows with that in mind and settle through
 * settlePartial where possible, since escalation is the expensive path.
 */

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title Liars_Game
/// @author Mayowa Akande (https://x.com/0xunavailable)
/// @notice Trust-minimized escrow with bond-escalation dispute resolution.

contract Liars_Game {
        constructor(address _treasury) {
        if (_treasury == address(0)) revert ZeroAddress();
        owner = msg.sender;
        treasury = _treasury;
    }
    using SafeERC20 for IERC20;
    address public owner;
    address public treasury;

    enum EscrowState {
        CREATED,
        SUBMITTED,
        PARTIAL_SETTLEMENT,
        AWAITING_ESCALATION,
        ESCALATION,
        RESOLVED,
        CANCELLED
    }

    enum Reason {
        DEFAULT, 
        FOLDED,
        TIMEOUT, 
        RESET,
        CANCELLED,
        TURN_TIMEOUT
    
    }

    struct Dispute {
        address lastActor;
        uint256 currentTurn;
        uint256  turnDeadline;
        uint256 disputedDelta;
        uint256 buyerCollateral;
        uint256 sellerCollateral;

    }

    struct Escrow {
        address buyer;
        address seller;        
        address integrator;     
        address token;          
        uint32  evaluationWindow;
        uint32  lifetime;
        uint256 escrowAmount;   

        EscrowState state;
        string workPointer;
        // Off-chain-encrypted pointer. The seller encrypts the deliverable
        // to the buyer's key before calling submitWork. The contract stores
        // only the resulting ciphertext pointer — no on-chain encryption occurs.

        uint256 evaluationDeadline;
        uint16 alphaBps;
        // Buyer's declared acceptance ratio. Range: 0–10,000.
        // type(uint16).max = unset sentinel (no input recorded yet).
        uint256  settlementFinalizedTime;
        uint256  escalationDeadline;
        Dispute dispute;
    }

    mapping(bytes32 => Escrow) internal escrows;
    mapping(address => bool) public approvedTokens;
    mapping(address => mapping(address => uint256)) internal pendingWithdrawals;


    // EVENTS

    /// @notice A new escrow has been created and funded.
    event EscrowCreated(
        bytes32 indexed escrowId,
        address indexed buyer,
        address indexed seller,
        address token,
        uint256 amount,
        address integrator,
        uint256 lifetime
    );

    /// @notice The seller submitted or overwrote a workPointer.
    /// @param newEvaluationDeadline May exceed lifetime by up to evaluationWindow (grace period).
    event WorkSubmitted(
        bytes32 indexed escrowId,
        string  workPointer,
        uint256 newEvaluationDeadline
    );

    /// @notice The buyer recorded or overwrote a settlement input.
    event SettlementInputRecorded(
        bytes32 indexed escrowId,
        uint16 alphaBps,
        uint256 settlementFinalizedTime
    );

    /// @notice A settlement was finalized and funds began moving.
    event SettlementFinalized(
        bytes32 indexed escrowId,
        uint16 alphaBps,
        uint256 sellerPayout,
        uint256 disputedDelta
    );

    /// @notice A party opened or advanced the escalation by depositing a bond.
    event EscalationTurn(
        bytes32 indexed escrowId,
        uint256 turn,
        address indexed actor,
        uint256 bondPaid,
        uint256 newTurnDeadline
    );

    /// @notice A party folded, conceding the dispute.
    event Folded(
        bytes32 indexed escrowId,
        address indexed folder,
        address indexed winner
    );

    /// @notice An escrow reached a terminal or reset state.
    /// @param reason One of: "DEFAULT" | "FOLDED" | "TIMEOUT" | "RESET" | "CANCELLED" | "TURN_TIMEOUT"  

    event EscrowResolved(
        bytes32 indexed escrowId,
        address winner,
        uint256 sellerPayout,
        uint256 buyerRefund,
        Reason reason
    );

    /// @notice A party withdrew from the pending-withdrawal ledger.
    event Withdrawn(
        address indexed recipient,
        address indexed token,
        uint256 amount
    );

    event TreasuryUpdated(address indexed newTreasury);
    event TokenApproved(address indexed token);
    event TokenRemoved(address indexed token);


    // Errors
    error ZeroAddress();
    error BuyerSellerSame();
    error InvalidAmount();
    error InvalidEvaluationWindow();
    error InvalidLifetime();
    error WrongState();
    error NotAuthorised();
    error NotAParty();
    error LifetimeElapsed();            
    error EvaluationWindowOpen();       
    error EvaluationWindowExpired();    
    error SettlementWindowOpen();      
    error SettlementWindowExpired();   
    error EscalationWindowOpen();       
    error EscalationWindowExpired();    
    error TurnDeadlineOpen();           
    error TurnDeadlineExpired();       
    error NotYourTurn();                
    error InvalidAlphaBps();            
    error NothingToWithdraw();
    error TokenNotApproved();           
    error AlreadyApproved();            
    error NotApproved();                
    error DustOutput();    
    error EmptyworkPointer();         

    /// @dev Global nonce for collision-resistant escrow ID generation.
    uint256 internal nonce;

    // Constants 
    uint16  public constant PROTOCOL_FEE_BPS         = 200;  
    uint16  public constant INTEGRATOR_SHARE_BPS     = 7000;
    uint16  public constant TREASURY_SHARE_BPS       = 3000;
    uint16 public constant SELLER_BOND_BPS           = 5000; // seller posts 50% of each nominal bond
    uint256 public constant MIN_EVALUATION_WINDOW    = 1 hours;
    uint256 public constant MAX_EVALUATION_WINDOW    = 90 days;
    uint256 public constant SETTLEMENT_OVERWRITE_WINDOW = 2 hours;
    uint256 public constant ESCALATION_OPEN_WINDOW   = 1 days;
    uint256 public constant TURN_DEADLINE_WINDOW     = 1 days;
    uint8   public constant EVENT_HORIZON_TURN       = 5;
    uint16  public constant UNSET_ALPHA              = type(uint16).max;

    // EXTERNAL FUNCTIONS

    /// @notice Buyer opens an escrow and deposits `amount` of an approved token.
    /// @dev `lifetimeDuration` is an absolute timestamp, not an offset.
   function createEscrow(address seller, address integrator, address token, uint256 amount, uint32 evaluationWindow, uint32 lifetimeDuration) external returns (bytes32 escrowId) {
        if (msg.sender == address(0) || seller == address(0) || integrator == address(0) || token == address(0)) 
        revert ZeroAddress();
        if (msg.sender == seller) revert BuyerSellerSame();
        if (!approvedTokens[token]) revert TokenNotApproved();
        if (amount == 0) revert InvalidAmount();
        if (evaluationWindow < MIN_EVALUATION_WINDOW || evaluationWindow > MAX_EVALUATION_WINDOW) revert InvalidEvaluationWindow();
        if (lifetimeDuration <= block.timestamp + evaluationWindow) revert InvalidLifetime();

        nonce++;
        escrowId = keccak256(abi.encode(msg.sender, seller, nonce));
        Escrow storage escrow = escrows[escrowId];
        escrow.buyer = msg.sender;
        escrow.seller = seller;
        escrow.integrator = integrator;
        escrow.token = token;
        escrow.evaluationWindow = evaluationWindow;
        escrow.lifetime = lifetimeDuration;
        escrow.escrowAmount = amount;
        escrow.alphaBps = UNSET_ALPHA;
        escrow.state = EscrowState.CREATED;
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        emit EscrowCreated(escrowId, msg.sender, seller, token, amount, integrator, lifetimeDuration);
    }

    /// @notice Seller submits (or resubmits) work and starts the evaluation window.
    function submitWork(bytes32 escrowId, string calldata workPointer) external {
        Escrow storage escrow = escrows[escrowId];
        if (escrow.state != EscrowState.CREATED && escrow.state != EscrowState.SUBMITTED) revert WrongState();
        if (msg.sender != escrow.seller) revert NotAuthorised();
        if (block.timestamp >= escrow.lifetime) revert LifetimeElapsed();
        if (bytes(workPointer).length == 0) revert EmptyworkPointer();
        escrow.state = EscrowState.SUBMITTED;
        escrow.workPointer = workPointer;
        escrow.evaluationDeadline = block.timestamp + escrow.evaluationWindow;
        
        emit WorkSubmitted(escrowId, workPointer, escrow.evaluationDeadline);
    }

    /// @notice Buyer records a settlement percentage (0–10000 bps) during evaluation; may be overwritten until the settlement window closes.
    /// @dev alphaBps == 0 means reject; the dust check applies only when alphaBps > 0.
    function settlePartial(bytes32 escrowId, uint16 alphaBps) external {
        Escrow storage escrow = escrows[escrowId];
        EscrowState state = escrow.state;
        if (state != EscrowState.SUBMITTED && state != EscrowState.PARTIAL_SETTLEMENT) revert WrongState();
        if (msg.sender != escrow.buyer) revert NotAuthorised();
        if (alphaBps > 10000) revert InvalidAlphaBps();
        uint256 settlementAmount = (escrow.escrowAmount * alphaBps) / 10000;

        if (alphaBps > 0) {
            uint256 netToSeller = _distributeFundsPreview(settlementAmount);
            if (netToSeller == 0) revert DustOutput();
        }
        if (state == EscrowState.SUBMITTED) {
            if (block.timestamp > escrow.evaluationDeadline) revert EvaluationWindowExpired();
            escrow.state = EscrowState.PARTIAL_SETTLEMENT;
        } else {
            if (block.timestamp >= escrow.settlementFinalizedTime) revert SettlementWindowExpired();
        }

        uint256 settlementFinalizedTime = block.timestamp + SETTLEMENT_OVERWRITE_WINDOW;
        uint256 evaluationDeadlineWindow = escrow.evaluationDeadline + SETTLEMENT_OVERWRITE_WINDOW;
        escrow.settlementFinalizedTime = settlementFinalizedTime < evaluationDeadlineWindow ? settlementFinalizedTime : evaluationDeadlineWindow;
        escrow.alphaBps = alphaBps;
        
        emit SettlementInputRecorded(escrowId, alphaBps, escrow.settlementFinalizedTime);
    }

    /// @notice Finalizes a 100% settlement after the settlement window: seller is paid in full, minus fee.
    function finalizeSettlementFull(bytes32 escrowId) external {
        Escrow storage escrow = escrows[escrowId];
        if (escrow.state != EscrowState.PARTIAL_SETTLEMENT) revert WrongState();
        if (msg.sender != escrow.buyer && msg.sender != escrow.seller) revert NotAParty();
        if (block.timestamp < escrow.settlementFinalizedTime) revert SettlementWindowOpen();
        if (escrow.alphaBps != 10000) revert InvalidAlphaBps();

        escrow.state = EscrowState.RESOLVED;
        uint256 escrowAmount = escrow.escrowAmount;
        escrow.escrowAmount = 0;
        uint256 netToSeller = _distributeFunds(escrowId, escrowAmount);
        
        emit SettlementFinalized(escrowId, 10000, netToSeller, 0);
    }

    /// @notice Buyer finalizes a 0% settlement: the whole amount becomes contested and the escalation window opens.
   function finalizeSettlementRejected(bytes32 escrowId) external {
        Escrow storage escrow = escrows[escrowId];
        if (escrow.state != EscrowState.PARTIAL_SETTLEMENT) revert WrongState();
        if (msg.sender != escrow.buyer) revert NotAuthorised();
        if (block.timestamp < escrow.settlementFinalizedTime) revert SettlementWindowOpen();
        if (escrow.alphaBps != 0) revert InvalidAlphaBps();

        escrow.state = EscrowState.AWAITING_ESCALATION;
        uint256 escrowAmount = escrow.escrowAmount;
        escrow.escrowAmount = 0;
        escrow.dispute.disputedDelta = escrowAmount;
        escrow.escalationDeadline = block.timestamp + ESCALATION_OPEN_WINDOW;
        
        emit SettlementFinalized(escrowId, 0, 0, escrowAmount);
    }

    /// @notice Finalizes a partial settlement: seller's share is paid, the remainder becomes contested and the escalation window opens.
    function finalizeSettlementPartial(bytes32 escrowId) external {
        Escrow storage escrow = escrows[escrowId];
        if (escrow.state != EscrowState.PARTIAL_SETTLEMENT) revert WrongState();
        if (msg.sender != escrow.buyer && msg.sender != escrow.seller) revert NotAParty();
        if (block.timestamp < escrow.settlementFinalizedTime) revert SettlementWindowOpen();
        if (escrow.alphaBps == 0 || escrow.alphaBps >= 10000) revert InvalidAlphaBps();

        escrow.state = EscrowState.AWAITING_ESCALATION;
        uint256 escrowAmount = escrow.escrowAmount;
        escrow.escrowAmount = 0;
        uint256 sellerPortion = (escrowAmount * escrow.alphaBps) / 10000;
        uint256 disputedDelta = escrowAmount - sellerPortion;
        escrow.dispute.disputedDelta = disputedDelta;
        escrow.escalationDeadline = block.timestamp + ESCALATION_OPEN_WINDOW;
        uint256 netToSeller = _distributeFunds(escrowId, sellerPortion);
        
        emit SettlementFinalized(escrowId, escrow.alphaBps, netToSeller, disputedDelta);
    }

    /// @notice Either party opens a dispute within the escalation window and posts the turn-1 bond.
    function openDispute(bytes32 escrowId) external {
        Escrow storage escrow = escrows[escrowId];
        if (escrow.state != EscrowState.AWAITING_ESCALATION) revert WrongState();
        if (msg.sender != escrow.buyer && msg.sender != escrow.seller) revert NotAParty();
        if (block.timestamp > escrow.escalationDeadline) revert EscalationWindowExpired();
        uint256 bond = _calculateTurnBond(escrow.dispute.disputedDelta, 1, msg.sender == escrow.seller);

        escrow.dispute.currentTurn = 1;
        escrow.dispute.lastActor = msg.sender;
        escrow.dispute.turnDeadline = block.timestamp + TURN_DEADLINE_WINDOW;
        if (msg.sender == escrow.buyer) {
            escrow.dispute.buyerCollateral += bond;
        } else {
            escrow.dispute.sellerCollateral += bond;
        }
        escrow.state = EscrowState.ESCALATION;
        IERC20(escrow.token).safeTransferFrom(msg.sender, address(this), bond);
        
        emit EscalationTurn(escrowId, 1, msg.sender, bond, escrow.dispute.turnDeadline);
    }

    /// @notice The non-last actor posts the next, larger bond and passes the turn back before the turn deadline.
    function advanceTurn(bytes32 escrowId) external {
        Escrow storage escrow = escrows[escrowId];
        if (escrow.state != EscrowState.ESCALATION) revert WrongState();
        if (msg.sender != escrow.buyer && msg.sender != escrow.seller) revert NotAParty();
        if (msg.sender == escrow.dispute.lastActor) revert NotYourTurn();
        if (block.timestamp > escrow.dispute.turnDeadline) revert TurnDeadlineExpired();

        escrow.dispute.currentTurn++;
        uint256 newCurrentTurn = escrow.dispute.currentTurn;
        uint256 bond = _calculateTurnBond(escrow.dispute.disputedDelta, newCurrentTurn, msg.sender == escrow.seller);
        if (msg.sender == escrow.buyer) {
            escrow.dispute.buyerCollateral += bond;
        } else {
            escrow.dispute.sellerCollateral += bond;
        }
        escrow.dispute.turnDeadline = block.timestamp + TURN_DEADLINE_WINDOW;
        escrow.dispute.lastActor = msg.sender;
        IERC20(escrow.token).safeTransferFrom(msg.sender, address(this), bond);
        
        emit EscalationTurn(escrowId, newCurrentTurn, msg.sender, bond, escrow.dispute.turnDeadline);
    }

    /// @notice Responder concedes on their own turn: the last actor wins and the dispute resolves.
    function fold(bytes32 escrowId) external {
        Escrow storage escrow = escrows[escrowId];
        if (escrow.state != EscrowState.ESCALATION) revert WrongState();
        if (msg.sender != escrow.buyer && msg.sender != escrow.seller) revert NotAParty();
        if (block.timestamp > escrow.dispute.turnDeadline) revert TurnDeadlineExpired();
        if (msg.sender == escrow.dispute.lastActor) revert NotYourTurn();

        address winner = _otherParty(escrowId, msg.sender);
        _resolveDispute(escrowId, winner, Reason.FOLDED);
        
        emit Folded(escrowId, msg.sender, winner);
    }

    /// @notice Seller claims the full amount if the buyer stayed silent past the evaluation deadline.
    function claimDefault(bytes32 escrowId) external {
        Escrow storage escrow = escrows[escrowId];
        if (escrow.state != EscrowState.SUBMITTED) revert WrongState();
        if (msg.sender != escrow.seller) revert NotAuthorised();
        if (block.timestamp <= escrow.evaluationDeadline) revert EvaluationWindowOpen();

        escrow.state = EscrowState.RESOLVED;
        uint256 escrowAmount = escrow.escrowAmount;
        escrow.escrowAmount = 0;
        uint256 netToSeller = _distributeFunds(escrowId, escrowAmount);
        
        emit EscrowResolved(escrowId, escrow.seller, netToSeller, 0, Reason.DEFAULT);
    }

    /// @notice Refunds the contested amount to the buyer if nobody opened a dispute before the escalation deadline.
    function claimEscalationTimeout(bytes32 escrowId) external {
        Escrow storage escrow = escrows[escrowId];
        if (escrow.state != EscrowState.AWAITING_ESCALATION) revert WrongState();
        if (msg.sender != escrow.buyer && msg.sender != escrow.seller) revert NotAParty();
        if (block.timestamp <= escrow.escalationDeadline) revert EscalationWindowOpen();
        escrow.state = EscrowState.RESOLVED;

        uint256 disputedDelta = escrow.dispute.disputedDelta;
        escrow.dispute.disputedDelta = 0;
        pendingWithdrawals[escrow.buyer][escrow.token] += disputedDelta;

        emit EscrowResolved(escrowId, escrow.buyer, 0, disputedDelta, Reason.TIMEOUT);
    }

    /// @notice After a turn deadline lapses, the last actor wins by default and the dispute resolves.
    function claimTurnTimeout(bytes32 escrowId) external {
        Escrow storage escrow = escrows[escrowId];
        if (escrow.state != EscrowState.ESCALATION) revert WrongState();
        if (msg.sender != escrow.buyer && msg.sender != escrow.seller) revert NotAParty();
        if (block.timestamp <= escrow.dispute.turnDeadline) revert TurnDeadlineOpen();

        address winner = escrow.dispute.lastActor;
        _resolveDispute(escrowId, winner, Reason.TURN_TIMEOUT);
    }

    /// @notice Buyer cancels an escrow still in CREATED (no work submitted) and gets a full refund.
   function cancelEscrow(bytes32 escrowId) external {
        Escrow storage escrow = escrows[escrowId];
        if (escrow.state != EscrowState.CREATED) revert WrongState();
        if (msg.sender != escrow.buyer) revert NotAuthorised();

        escrow.state = EscrowState.CANCELLED;
        uint256 escrowAmount = escrow.escrowAmount;
        escrow.escrowAmount = 0;
        pendingWithdrawals[escrow.buyer][escrow.token] += escrowAmount;
        
        emit EscrowResolved(escrowId, address(0), 0, escrowAmount, Reason.CANCELLED);
    }

    /// @notice Withdraws the caller's full credited balance of `token`.
    /// @dev Balance is zeroed before the transfer; delisted tokens remain withdrawable.
   function withdraw(address token) external {
        uint256 amount = pendingWithdrawals[msg.sender][token];
        if (amount == 0) revert NothingToWithdraw();

        pendingWithdrawals[msg.sender][token] = 0;
        IERC20(token).safeTransfer(msg.sender, amount);
        
        emit Withdrawn(msg.sender, token, amount);
    }


   
    //  ADMIN FUNCTIONS

    /// @notice Owner whitelists a token for new escrows.
    function addApprovedToken(address token) external {
        if (msg.sender != owner) revert NotAuthorised();
        if (token == address(0)) revert ZeroAddress();
        if (approvedTokens[token]) revert AlreadyApproved();
        
        approvedTokens[token] = true;

        emit TokenApproved(token);
    }

    /// @notice Owner delists a token for new escrows. Existing escrows and withdrawals are unaffected.
    function removeApprovedToken(address token) external {
        if (msg.sender != owner) revert NotAuthorised();
        if (!approvedTokens[token]) revert NotApproved();

        approvedTokens[token] = false;
        
        emit TokenRemoved(token);
    }

    /// @notice Owner updates the treasury. Affects only future fee credits, not balances already accrued.
    function setTreasury(address newTreasury) external {
        if (msg.sender != owner) revert NotAuthorised();
        if (newTreasury == address(0)) revert ZeroAddress();

        treasury = newTreasury;
        
        emit TreasuryUpdated(newTreasury);
    }


    //  VIEW FUNCTIONS
    /// @notice Returns the full escrow struct.
    function getEscrow(bytes32 escrowId) external view returns (Escrow memory) {
        return escrows[escrowId];
    }

    /// @notice Returns the dispute data for an escrow.
    function getDispute(bytes32 escrowId) external view returns (Dispute memory) {
        return escrows[escrowId].dispute;
    }

    /// @notice Bond required for the next dispute action; 0 outside AWAITING_ESCALATION and ESCALATION.
    function requiredBondFor(bytes32 escrowId, address who) external view returns (uint256) {
        Escrow storage escrow = escrows[escrowId];
        bool isSeller = who == escrow.seller;

        if (escrow.state == EscrowState.AWAITING_ESCALATION) {
            return _calculateTurnBond(escrow.dispute.disputedDelta, 1, isSeller);
        } else if (escrow.state == EscrowState.ESCALATION) {
            return _calculateTurnBond(escrow.dispute.disputedDelta, escrow.dispute.currentTurn + 1, isSeller);
        } else {
            return 0;
        }
    }

    /// @notice True once the game turn counter has passed EVENT_HORIZON_TURN.
    function isPostHorizon(bytes32 escrowId) external view returns (bool) {
        return escrows[escrowId].dispute.currentTurn > EVENT_HORIZON_TURN;
    }

    /// @notice Seconds left on the clock that applies to the escrow's current state; 0 once elapsed or terminal.
    function secondsRemaining(bytes32 escrowId) external view returns (uint256) {
        Escrow storage escrow = escrows[escrowId];
        EscrowState state = escrow.state;
        
        if (state == EscrowState.CREATED) {
            return escrow.lifetime > block.timestamp ? escrow.lifetime - block.timestamp : 0;
        } else if (state == EscrowState.SUBMITTED) {
            return escrow.evaluationDeadline > block.timestamp ? escrow.evaluationDeadline - block.timestamp : 0;
        } else if (state == EscrowState.PARTIAL_SETTLEMENT) {
            return escrow.settlementFinalizedTime > block.timestamp ? escrow.settlementFinalizedTime - block.timestamp : 0;
        } else if (state == EscrowState.AWAITING_ESCALATION) {
            return escrow.escalationDeadline > block.timestamp ? escrow.escalationDeadline - block.timestamp : 0;
        } else if (state == EscrowState.ESCALATION) {
            return escrow.dispute.turnDeadline > block.timestamp ? escrow.dispute.turnDeadline - block.timestamp : 0;
        } else {
            return 0;
        }
    }

    /// @notice Credited, not yet withdrawn balance of `token` for `account`.
    function pendingWithdrawal(address account, address token) external view returns (uint256) {
        return pendingWithdrawals[account][token];
    }


    //  INTERNAL HELPERS

    /// @dev Bond size in bps of the disputed amount for a given game turn.
    /// Turns 1-4 are fixed (50, 200, 600, 1500); from turn 5 it starts at 3500 and grows by 2000 per turn.
    function _getTurnBps(uint256 turn) internal pure returns (uint256) {
        if (turn == 1) return 50;
        if (turn == 2) return 200;
        if (turn == 3) return 600;
        if (turn == 4) return 1500;
        return 3500 + (turn - 5) * 2000;
    }

    /// @dev Bond a party must post on `turn`: disputedDelta * _getTurnBps(turn) / 10000 
   function _calculateTurnBond(uint256 disputedDelta, uint256 turn, bool isSeller) internal pure returns (uint256) {
        uint256 bond = disputedDelta * _getTurnBps(turn) / 10000;
        return isSeller ? bond * SELLER_BOND_BPS / 10000 : bond;
    }

    /// @dev Splits `amount` into seller net, treasury cut and integrator cut (ceil-rounded fee), credits all three to pendingWithdrawals, returns the seller's net.
    function _distributeFunds(bytes32 escrowId, uint256 amount) internal returns (uint256 netToSeller) {
        Escrow storage escrow = escrows[escrowId];
        address seller = escrow.seller;
        address integrator = escrow.integrator;
        address token = escrow.token;
        uint256 fee = (amount * PROTOCOL_FEE_BPS + 9999) / 10000;
        uint256 treasuryCut = (fee * TREASURY_SHARE_BPS + 9999) / 10000;
        uint256 integratorCut = fee - treasuryCut;
        netToSeller = amount - fee;
        pendingWithdrawals[seller][token] += netToSeller;
        pendingWithdrawals[treasury][token] += treasuryCut;
        pendingWithdrawals[integrator][token] += integratorCut;

        return netToSeller;
    }

    /// @dev Pure preview of _distributeFunds: returns the seller's net without touching storage.
    function _distributeFundsPreview(uint256 amount) internal pure returns (uint256 netToSeller) {
        uint256 fee = (amount * PROTOCOL_FEE_BPS + 9999) / 10000;        
        return amount - fee;
    }

    /// @dev Splits the winner's collateral into `total` (recoverable, capped at deposits) and `remainder` (to treasury) using cumulative challenger/defender BPS.
    function _computeHorizonSplit(uint256 disputedDelta, uint256 totalCollateral, bool isChallenger, bool isSeller) 
    internal pure returns (uint256 total, uint256 remainder)
    {
        uint256 bps = isChallenger ? 4150 : 1700;
        total = (disputedDelta * bps) / 10000;
        if (isSeller) total = total * SELLER_BOND_BPS / 10000;
        if (total > totalCollateral) total = totalCollateral;
        remainder = totalCollateral - total;
    }

    /// @dev Zeroes both collaterals, credits the loser's to treasury and the winner's back to them.
    /// Past EVENT_HORIZON_TURN the winner only recovers the capped horizon share; the rest goes to treasury.
    function _routeCollateral(bytes32 escrowId, address winner) internal {
        Escrow storage escrow = escrows[escrowId];
        address token = escrow.token;

        uint256 winnerCollateral;
        uint256 loserCollateral;
        uint256 maxCollateral;
        uint256 disputedDelta;
        uint256 currentTurn;

        {
            Dispute storage dispute = escrow.dispute;
            disputedDelta = dispute.disputedDelta;
            currentTurn = dispute.currentTurn;
            uint256 b = dispute.buyerCollateral;
            uint256 s = dispute.sellerCollateral;

            dispute.buyerCollateral = 0;
            dispute.sellerCollateral = 0;

            bool winnerIsBuyer = winner == escrow.buyer;
            winnerCollateral = winnerIsBuyer ? b : s;
            loserCollateral = winnerIsBuyer ? s : b;
            maxCollateral = b > s ? b : s;
        }

            pendingWithdrawals[treasury][token] += loserCollateral;

        if (currentTurn <= EVENT_HORIZON_TURN) {
            pendingWithdrawals[winner][token] += winnerCollateral;
        } else {
            (uint256 total, uint256 remainder) =
            _computeHorizonSplit(disputedDelta, winnerCollateral, currentTurn % 2 == 1, winner == escrow.seller);
            pendingWithdrawals[winner][token] += total;
            pendingWithdrawals[treasury][token] += remainder;
        }
    }

   /// @dev Picks the final outcome (reset, cancel, buyer refund or seller payout) from the winner, alphaBps and lifetime.
   function _routeOutcome(bytes32 escrowId, address winner, Reason reason) internal {
        Escrow storage escrow = escrows[escrowId];
        block.timestamp;
        if (winner == escrow.buyer) {
            if (escrow.alphaBps == 0) {
                if (block.timestamp < escrow.lifetime) {
                    _resetToCreated(escrowId);
                } else {
                    _cancelWithRefund(escrowId);
                }
            } else {
                _resolveForBuyer(escrowId, reason);
            }
        } else {
            _resolveForSeller(escrowId, reason);
        }
    }

    /// @dev Buyer won with alphaBps == 0 before lifetime: puts the contested amount back into escrow and reopens it as CREATED. Identity fields are kept.
    function _resetToCreated(bytes32 escrowId) internal {
        Escrow storage escrow = escrows[escrowId];
        uint256 disputedDelta = escrow.dispute.disputedDelta;
        escrow.state = EscrowState.CREATED;
        escrow.escrowAmount = disputedDelta;
        escrow.dispute = Dispute(address(0), 0, 0, 0, 0, 0);
        escrow.workPointer = "";
        escrow.evaluationDeadline = 0;
        escrow.alphaBps = UNSET_ALPHA;
        escrow.settlementFinalizedTime = 0;
        escrow.escalationDeadline = 0;
        
        emit EscrowResolved(escrowId, escrow.buyer, 0, 0, Reason.RESET);
    }

    /// @dev Buyer won with alphaBps == 0 after lifetime: cancels the escrow and refunds the contested amount in full, no fee.
    function _cancelWithRefund(bytes32 escrowId) internal {
        Escrow storage escrow = escrows[escrowId];
        escrow.state = EscrowState.CANCELLED;
        uint256 disputedDelta = escrow.dispute.disputedDelta;
        escrow.dispute.disputedDelta = 0;
        pendingWithdrawals[escrow.buyer][escrow.token] += disputedDelta;
        emit EscrowResolved(escrowId, escrow.buyer, 0, disputedDelta, Reason.CANCELLED);
    }

    /// @dev Buyer won with alphaBps > 0: refunds the contested amount in full, no fee.
   function _resolveForBuyer(bytes32 escrowId, Reason reason) internal {
        Escrow storage escrow = escrows[escrowId];
        escrow.state = EscrowState.RESOLVED;
        uint256 disputedDelta = escrow.dispute.disputedDelta;
        escrow.dispute.disputedDelta = 0;
        pendingWithdrawals[escrow.buyer][escrow.token] += disputedDelta;
        emit EscrowResolved(escrowId, escrow.buyer, 0, disputedDelta, reason);
    }

    /// @dev Seller won: pays the contested amount to the seller through _distributeFunds (fee applies).
   function _resolveForSeller(bytes32 escrowId, Reason reason) internal {
        Escrow storage escrow = escrows[escrowId];
        escrow.state = EscrowState.RESOLVED;
        uint256 disputedDelta = escrow.dispute.disputedDelta;
        escrow.dispute.disputedDelta = 0;
        uint256 netToSeller = _distributeFunds(escrowId, disputedDelta);
        emit EscrowResolved(escrowId, escrow.seller, netToSeller, 0, reason);
    }

    /// @dev Dispute ending: routes collateral first, then resolves the escrowed funds.
    function _resolveDispute(bytes32 escrowId, address winner, Reason reason) internal {
        _routeCollateral(escrowId, winner);
        _routeOutcome(escrowId, winner, reason);
    }

    /// @dev True if `addr` is the escrow's buyer or seller.
   function _isParty(bytes32 escrowId, address addr) internal view returns (bool) {
        Escrow storage escrow = escrows[escrowId];
        return addr == escrow.buyer || addr == escrow.seller;
    }

    /// @dev Returns the counterparty of `addr`. Reverts NotAParty if `addr` is neither.
   function _otherParty(bytes32 escrowId, address addr) internal view returns (address) {
        Escrow storage escrow = escrows[escrowId];
        if (addr != escrow.buyer && addr != escrow.seller) revert NotAParty();
        
        return addr == escrow.buyer ? escrow.seller : escrow.buyer;
    }
}
