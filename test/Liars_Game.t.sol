// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/Liars_Game.sol";



contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MOCK") {}

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

contract FalseReturnToken is ERC20 {
    constructor() ERC20("F", "F") { _mint(msg.sender, 1e40); }
    function transferFrom(address, address, uint256) public pure override returns (bool) { return false; }
    
}


contract Attacker {
    Liars_Game public game;
    bytes public payload;
    bool public armed;
    bool public reenterOk;

    constructor(Liars_Game g) { game = g; }

    function forward(address target, bytes calldata data) external {
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) { assembly { revert(add(ret, 32), mload(ret)) } }
    }
    function arm(bytes calldata data) external { payload = data; armed = true; }
    function onHook() external {
        if (!armed) return;
        armed = false;
        (reenterOk,) = address(game).call(payload);
    }
}

contract ReentrantToken is ERC20 {
    constructor() ERC20("R", "R") { _mint(msg.sender, 1e40); }
    function transfer(address to, uint256 amt) public override returns (bool ok) {
        ok = super.transfer(to, amt);
        _hook(to);
    }
    function transferFrom(address from, address to, uint256 amt) public override returns (bool ok) {
        ok = super.transferFrom(from, to, amt);
        _hook(from);
    }
    function _hook(address a) internal {
        if (a.code.length > 0) { try Attacker(a).onHook() {} catch {} }
    }
}


abstract contract Base is Test {
    Liars_Game internal game;
    MockERC20 internal token;
    MockERC20 internal token2; // never whitelisted unless a test does it

    address internal buyer = makeAddr("buyer");
    address internal seller = makeAddr("seller");
    address internal integrator = makeAddr("integrator");
    address internal treasury = makeAddr("treasury");
    address internal stranger = makeAddr("stranger");
    address internal poor = makeAddr("poor"); // funded, but never approves the game

    uint256 internal constant AMOUNT = 1_000e18;

    // cached contract constants (never call game.X() between expectRevert and the target call)
    uint256 internal feeBps;
    uint256 internal tShareBps;
    uint256 internal minEW;
    uint256 internal maxEW;
    uint256 internal defaultEW;
    uint256 internal settleWin;
    uint256 internal escWin;
    uint256 internal turnWin;
    uint256 internal horizon;
    uint256 internal sellerBps;

    Liars_Game.EscrowState internal constant S_CREATED = Liars_Game.EscrowState.CREATED;
    Liars_Game.EscrowState internal constant S_SUBMITTED = Liars_Game.EscrowState.SUBMITTED;
    Liars_Game.EscrowState internal constant S_PARTIAL = Liars_Game.EscrowState.PARTIAL_SETTLEMENT;
    Liars_Game.EscrowState internal constant S_AWAITING = Liars_Game.EscrowState.AWAITING_ESCALATION;
    Liars_Game.EscrowState internal constant S_ESCALATION = Liars_Game.EscrowState.ESCALATION;
    Liars_Game.EscrowState internal constant S_RESOLVED = Liars_Game.EscrowState.RESOLVED;
    Liars_Game.EscrowState internal constant S_CANCELLED = Liars_Game.EscrowState.CANCELLED;

    struct Snap {
        uint256 b;
        uint256 s;
        uint256 i;
        uint256 t;
    }

    function setUp() public virtual {
        vm.warp(1_700_000_000);

        game = new Liars_Game(treasury); 
        token = new MockERC20();
        token2 = new MockERC20();

        game.setTreasury(treasury);
        game.addApprovedToken(address(token));

        feeBps = uint256(game.PROTOCOL_FEE_BPS());
        tShareBps = uint256(game.TREASURY_SHARE_BPS());
        minEW = uint256(game.MIN_EVALUATION_WINDOW());
        maxEW = uint256(game.MAX_EVALUATION_WINDOW());
        settleWin = uint256(game.SETTLEMENT_OVERWRITE_WINDOW());
        escWin = uint256(game.ESCALATION_OPEN_WINDOW());
        turnWin = uint256(game.TURN_DEADLINE_WINDOW());
        horizon = uint256(game.EVENT_HORIZON_TURN());
        sellerBps = uint256(game.SELLER_BOND_BPS());
        defaultEW = minEW == 0 ? 1 : minEW;

        address[5] memory users = [buyer, seller, stranger, address(this), poor];
        for (uint256 i; i < users.length; i++) {
            token.mint(users[i], 1e40);
            token2.mint(users[i], 1e40);
            if (users[i] == poor) continue;
            vm.startPrank(users[i]);
            token.approve(address(game), type(uint256).max);
            token2.approve(address(game), type(uint256).max);
            vm.stopPrank();
        }
    }
    
    function _turnBps(uint256 n) internal pure returns (uint256) {
    if (n == 1) return 50;
    if (n == 2) return 200;
    if (n == 3) return 600;
    if (n == 4) return 1500;
    return 3500 + (n - 5) * 2000;
}

    function _bond(uint256 delta, uint256 turn, bool isSeller) internal view returns (uint256) {
        uint256 b = delta * _turnBps(turn) / 10000;
        return isSeller ? b * sellerBps / 10000 : b;
    }

    function _cap(uint256 delta, bool challenger, bool isSeller) internal view returns (uint256) {
        uint256 t = delta * (challenger ? 4150 : 1700) / 10000;
        return isSeller ? t * sellerBps / 10000 : t;
    }


    /*──────────────────────── math mirrors ────────────────────────*/

    function _fee(uint256 a) internal view returns (uint256) {
        return (a * feeBps + 9999) / 10000;
    }

    function _tCut(uint256 fee) internal view returns (uint256) {
        return (fee * tShareBps + 9999) / 10000;
    }

    function _net(uint256 a) internal view returns (uint256) {
        return a - _fee(a);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /*──────────────────────── readers ────────────────────────*/

    function _esc(bytes32 id) internal view returns (Liars_Game.Escrow memory) {
        return game.getEscrow(id);
    }

    function _dsp(bytes32 id) internal view returns (Liars_Game.Dispute memory) {
        return game.getDispute(id);
    }

    function _pending(address a) internal view returns (uint256) {
        return game.pendingWithdrawal(a, address(token));
    }

    function _other(address a) internal view returns (address) {
        return a == buyer ? seller : buyer;
    }

    function _snap() internal view returns (Snap memory x) {
        x.b = _pending(buyer);
        x.s = _pending(seller);
        x.i = _pending(integrator);
        x.t = _pending(treasury);
    }

    function _assertState(bytes32 id, Liars_Game.EscrowState s) internal  {
        assertEq(uint256(uint8(_esc(id).state)), uint256(uint8(s)), "unexpected state");
    }

    /// Solvency for a single-escrow test: every token the game holds is either
    /// still locked in the escrow/dispute or owed via pendingWithdrawals.
    function _assertConserved(bytes32 id) internal {
        Liars_Game.Escrow memory e = _esc(id);
        uint256 owed = uint256(e.escrowAmount) + uint256(e.dispute.disputedDelta)
            + uint256(e.dispute.buyerCollateral) + uint256(e.dispute.sellerCollateral);
        owed += _pending(buyer) + _pending(seller) + _pending(integrator) + _pending(treasury);
        assertEq(token.balanceOf(address(game)), owed, "solvency broken");
    }

    /*──────────────────────── state builders ────────────────────────*/

    function _createRaw(
        address from,
        address s,
        address integ,
        address tk,
        uint256 amt,
        uint256 ew,
        uint256 life
    ) internal returns (bytes32) {
        vm.prank(from);
        return game.createEscrow(s, integ, tk, amt, uint32(ew), uint32(life));
    }

    function _create(uint256 amount, uint256 ew) internal returns (bytes32) {
        return _createRaw(buyer, seller, integrator, address(token), amount, ew, block.timestamp + 365 days);
    }

    function _create() internal returns (bytes32) {
        return _create(AMOUNT, defaultEW);
    }

    function _createSubmitted(uint256 amount) internal returns (bytes32 id) {
        id = _create(amount, defaultEW);
        vm.prank(seller);
        game.submitWork(id, "ipfs://work");
    }

    function _toPartial(uint256 amount, uint16 alpha) internal returns (bytes32 id) {
        id = _createSubmitted(amount);
        vm.prank(buyer);
        game.settlePartial(id, alpha);
    }

    /// CREATED -> SUBMITTED -> PARTIAL_SETTLEMENT(50%) -> AWAITING_ESCALATION (disputedDelta = amount - 50%)
    function _toAwaiting(uint256 amount) internal returns (bytes32 id) {
        id = _toPartial(amount, 5000);
        vm.warp(uint256(_esc(id).settlementFinalizedTime));
        vm.prank(buyer);
        game.finalizeSettlementPartial(id);
    }

    function _open(bytes32 id, address who) internal {
        vm.prank(who);
        game.openDispute(id);
    }

    function _advance(bytes32 id, address who) internal {
        vm.prank(who);
        game.advanceTurn(id);
    }

    /// opener plays turn 1, then parties alternate until currentTurn == turns
    function _playTo(bytes32 id, address opener, uint256 turns) internal {
        _open(id, opener);
        address cur = _other(opener);
        for (uint256 t = 2; t <= turns; t++) {
            _advance(id, cur);
            cur = _other(cur);
        }
    }


    function test_badToken_createEscrowRevertsWhenTransferFromReturnsFalse() public {
    FalseReturnToken bad = new FalseReturnToken();
    game.addApprovedToken(address(bad));
    uint256 life = block.timestamp + 365 days;
    vm.expectRevert();
    _createRaw(buyer, seller, integrator, address(bad), AMOUNT, defaultEW, life);
}



function test_reentrancy_withdrawPaysExactlyOnce() public {
    ReentrantToken rt = new ReentrantToken();
    game.addApprovedToken(address(rt));
    Attacker atk = new Attacker(game);
    rt.transfer(buyer, 1e30);
    vm.prank(buyer);
    rt.approve(address(game), type(uint256).max);

    vm.prank(buyer);
    bytes32 id = game.createEscrow(
        address(atk), integrator, address(rt), AMOUNT, uint32(defaultEW), uint32(block.timestamp + 365 days)
    );
    atk.forward(address(game), abi.encodeWithSignature("submitWork(bytes32,string)", id, "w"));
    vm.warp(uint256(_esc(id).evaluationDeadline) + 1);
    atk.forward(address(game), abi.encodeWithSignature("claimDefault(bytes32)", id));

    uint256 owed = game.pendingWithdrawal(address(atk), address(rt));
    atk.arm(abi.encodeWithSignature("withdraw(address)", address(rt)));
    atk.forward(address(game), abi.encodeWithSignature("withdraw(address)", address(rt)));

    assertFalse(atk.reenterOk(), "re-entrant withdraw must fail");
    assertEq(rt.balanceOf(address(atk)), owed);
    assertEq(
        rt.balanceOf(address(game)),
        game.pendingWithdrawal(treasury, address(rt)) + game.pendingWithdrawal(integrator, address(rt))
    );
}

function test_reentrancy_advanceTurnCannotBeDoubleAdvanced() public {
    ReentrantToken rt = new ReentrantToken();
    game.addApprovedToken(address(rt));
    Attacker atk = new Attacker(game);
    rt.transfer(buyer, 1e30);
    rt.transfer(address(atk), 1e30);
    vm.prank(buyer);
    rt.approve(address(game), type(uint256).max);
    atk.forward(address(rt), abi.encodeWithSignature("approve(address,uint256)", address(game), type(uint256).max));

    vm.prank(buyer);
    bytes32 id = game.createEscrow(
        address(atk), integrator, address(rt), AMOUNT, uint32(defaultEW), uint32(block.timestamp + 365 days)
    );
    atk.forward(address(game), abi.encodeWithSignature("submitWork(bytes32,string)", id, "w"));
    vm.prank(buyer);
    game.settlePartial(id, 5000);
    vm.warp(uint256(_esc(id).settlementFinalizedTime));
    vm.prank(buyer);
    game.finalizeSettlementPartial(id);
    vm.prank(buyer);
    game.openDispute(id);

    // while the bond is being pulled from the attacker, it tries to advance again
    atk.arm(abi.encodeWithSignature("advanceTurn(bytes32)", id));
    atk.forward(address(game), abi.encodeWithSignature("advanceTurn(bytes32)", id));

    assertFalse(atk.reenterOk(), "re-entrant advanceTurn must fail");
    assertEq(uint256(_dsp(id).currentTurn), 2);
}






function test_overlap_sellerIsIntegratorAndTreasury() public {
    game.setTreasury(seller);
    bytes32 id = _createRaw(buyer, seller, seller, address(token), AMOUNT, defaultEW, block.timestamp + 365 days);
    vm.prank(seller);
    game.submitWork(id, "w");
    vm.warp(uint256(_esc(id).evaluationDeadline) + 1);
    vm.prank(seller);
    game.claimDefault(id);

    assertEq(_pending(seller), AMOUNT, "all three credits land on one address, none lost");
    vm.prank(seller);
    game.withdraw(address(token));
    assertEq(token.balanceOf(address(game)), 0);
}

function test_overlap_buyerIsTreasury_disputeRouting() public {
    game.setTreasury(buyer);
    bytes32 id = _toAwaiting(AMOUNT);
    _playTo(id, buyer, 3); // lastActor = buyer
    vm.prank(seller);
    game.fold(id);
    assertEq(
        token.balanceOf(address(game)),
        _pending(buyer) + _pending(seller) + _pending(integrator),
        "solvency with buyer == treasury"
    );
}





function test_bondSchedule_exactValuesTurns1to8() public {
    bytes32 id = _toAwaiting(AMOUNT);
    uint256 delta = uint256(_dsp(id).disputedDelta);
    uint256[8] memory bps = [uint256(50), 200, 600, 1500, 3500, 5500, 7500, 9500];
    address cur = buyer;
    for (uint256 t = 1; t <= 8; t++) {
        uint256 expected = delta * bps[t - 1] / 10000;
        if (cur == seller) expected = expected * sellerBps / 10000;
        uint256 before = token.balanceOf(cur);
        if (t == 1) _open(id, cur);
        else _advance(id, cur);
        assertEq(before - token.balanceOf(cur), expected, "bond for turn");
        cur = _other(cur);
    }
}

function test_horizonBps_matchBondSchedule() public {
    bytes32 id = _toAwaiting(AMOUNT);
    _playTo(id, buyer, 5);
    Liars_Game.Dispute memory d = _dsp(id);
    uint256 delta = uint256(d.disputedDelta);
    uint256 bColl = uint256(d.buyerCollateral);
    uint256 sColl = uint256(d.sellerCollateral);

    // buyer (challenger, turns 1, 3, 5) pays full bonds; seller (defender, turns 2, 4) pays scaled bonds
    assertEq(bColl, delta * 50 / 10000 + delta * 600 / 10000 + delta * 3500 / 10000);
    assertEq(
        sColl,
        (delta * 200 / 10000) * sellerBps / 10000 + (delta * 1500 / 10000) * sellerBps / 10000
    );

    // the horizon caps equal each side's deposits through turn 5, up to rounding
    assertLe(bColl, _cap(delta, true, false));
    assertGe(bColl + 3, _cap(delta, true, false));
    assertLe(sColl, _cap(delta, false, true));
    assertGe(sColl + 4, _cap(delta, false, true));
}

function test_constants_sanity() public {
    assertLe(feeBps, 10000);
    assertLe(tShareBps, 10000);
    assertLe(minEW, maxEW);
}

function testFuzz_treasuryCutNeverExceedsFee(uint256 amount) public {
    amount = bound(amount, 1, 1e40);
    uint256 fee = _fee(amount);
    assertLe(_tCut(fee), fee, "integratorCut would underflow");
    assertLe(fee, amount, "netToSeller would underflow");
}


function testFuzz_rejectLoop_staysSolvent(uint256 amount, uint256 cycles) public {
    amount = bound(amount, 1e6, 1e24);
    cycles = bound(cycles, 1, 5);
    bytes32 id = _createRaw(buyer, seller, integrator, address(token), amount, defaultEW, block.timestamp + 365 days);

    for (uint256 c; c < cycles; c++) {
        vm.prank(seller);
        game.submitWork(id, "w");
        vm.prank(buyer);
        game.settlePartial(id, 0);
        vm.warp(uint256(_esc(id).settlementFinalizedTime));
        vm.prank(buyer);
        game.finalizeSettlementRejected(id);

        _open(id, seller);
        _advance(id, buyer); // lastActor = buyer
        vm.prank(seller);
        game.fold(id); // buyer wins -> reset

        _assertState(id, S_CREATED);
        assertEq(uint256(_esc(id).escrowAmount), amount, "amount restored each cycle");
        _assertConserved(id);
    }
}

function test_race_evaluationDeadlineBlock() public {
    bytes32 id = _createSubmitted(AMOUNT);
    vm.warp(uint256(_esc(id).evaluationDeadline)); // t == deadline
    vm.expectRevert(Liars_Game.EvaluationWindowOpen.selector);
    vm.prank(seller);
    game.claimDefault(id); // seller too early...
    vm.prank(buyer);
    game.settlePartial(id, 5000); // ...buyer still in time
    _assertState(id, S_PARTIAL);
}

    function test_events_foldAndTurnTimeoutReasons() public {
        bytes32 id = _toAwaiting(AMOUNT);
        _open(id, buyer);
        Liars_Game.Dispute memory d = _dsp(id);

        vm.expectEmit(true, true, true, true);
        emit Liars_Game.EscrowResolved(
            id, buyer, 0, uint256(d.disputedDelta), Liars_Game.Reason.FOLDED
        );
        vm.prank(seller);
        game.fold(id);
    }
    function test_events_resolutionReasons() public {
    // default
    bytes32 id = _createSubmitted(AMOUNT);
    vm.warp(uint256(_esc(id).evaluationDeadline) + 1);
    vm.expectEmit(true, true, true, true);
    emit Liars_Game.EscrowResolved(id, seller, AMOUNT - _fee(AMOUNT), 0, Liars_Game.Reason.DEFAULT);
    vm.prank(seller);
    game.claimDefault(id);

    // cancelled
    bytes32 id2 = _create();
    vm.expectEmit(true, true, true, true);
    emit Liars_Game.EscrowResolved(id2, address(0), 0, AMOUNT, Liars_Game.Reason.CANCELLED);
    vm.prank(buyer);
    game.cancelEscrow(id2);

    // timeout
    bytes32 id3 = _toAwaiting(AMOUNT);
    uint256 delta = uint256(_dsp(id3).disputedDelta);
    vm.warp(uint256(_esc(id3).escalationDeadline) + 1);
    vm.expectEmit(true, true, true, true);
    emit Liars_Game.EscrowResolved(id3, buyer, 0, delta, Liars_Game.Reason.TIMEOUT);
    vm.prank(seller);
    game.claimEscalationTimeout(id3);
    }

    function test_events_turnTimeoutReason() public {
    bytes32 id = _toAwaiting(AMOUNT);
    _open(id, buyer);
    Liars_Game.Dispute memory d = _dsp(id);
    vm.warp(uint256(d.turnDeadline) + 1);

    vm.expectEmit(true, true, true, true);
    emit Liars_Game.EscrowResolved(id, buyer, 0, uint256(d.disputedDelta), Liars_Game.Reason.TURN_TIMEOUT);
    vm.prank(seller);
    game.claimTurnTimeout(id);
}

    

    /// After a dispute ends with `winner`, check the exact credit deltas (pre-horizon routing).
    function _assertResolution(Snap memory pre, address winner, Liars_Game.Dispute memory d) internal {
        uint256 winnerColl = winner == buyer ? uint256(d.buyerCollateral) : uint256(d.sellerCollateral);
        uint256 loserColl = winner == buyer ? uint256(d.sellerCollateral) : uint256(d.buyerCollateral);
        uint256 delta = uint256(d.disputedDelta);
        Snap memory post = _snap();

        if (winner == buyer) {
            assertEq(post.b - pre.b, winnerColl + delta, "buyer credit");
            assertEq(post.t - pre.t, loserColl, "treasury credit");
            assertEq(post.s, pre.s, "seller untouched");
            assertEq(post.i, pre.i, "integrator untouched");
        } else {
            uint256 fee = _fee(delta);
            uint256 tc = _tCut(fee);
            assertEq(post.s - pre.s, winnerColl + delta - fee, "seller credit");
            assertEq(post.t - pre.t, loserColl + tc, "treasury credit");
            assertEq(post.i - pre.i, fee - tc, "integrator credit");
            assertEq(post.b, pre.b, "buyer untouched");
        }
    }

    function _toRejected(uint256 amount, uint256 life) internal returns (bytes32 id) {
    id = _createRaw(buyer, seller, integrator, address(token), amount, defaultEW, life);
    vm.prank(seller);
    game.submitWork(id, "w");
    vm.prank(buyer);
    game.settlePartial(id, 0);
    vm.warp(uint256(_esc(id).settlementFinalizedTime));
    vm.prank(buyer);
    game.finalizeSettlementRejected(id);
}

    /// Every state-changing escrow function must revert, for every caller, once an escrow is terminal.
    function _assertDead(bytes32 id) internal {
        vm.warp(block.timestamp + 30 days); // open every timing window so only the state gate can save us
        bytes[] memory calls = new bytes[](12);
        calls[0] = abi.encodeWithSignature("submitWork(bytes32,string)", id, "x");
        calls[1] = abi.encodeWithSignature("settlePartial(bytes32,uint16)", id, uint16(5000));
        calls[2] = abi.encodeWithSignature("finalizeSettlementFull(bytes32)", id);
        calls[3] = abi.encodeWithSignature("finalizeSettlementRejected(bytes32)", id);
        calls[4] = abi.encodeWithSignature("finalizeSettlementPartial(bytes32)", id);
        calls[5] = abi.encodeWithSignature("openDispute(bytes32)", id);
        calls[6] = abi.encodeWithSignature("advanceTurn(bytes32)", id);
        calls[7] = abi.encodeWithSignature("fold(bytes32)", id);
        calls[8] = abi.encodeWithSignature("claimDefault(bytes32)", id);
        calls[9] = abi.encodeWithSignature("claimEscalationTimeout(bytes32)", id);
        calls[10] = abi.encodeWithSignature("claimTurnTimeout(bytes32)", id);
        calls[11] = abi.encodeWithSignature("cancelEscrow(bytes32)", id);

        address[4] memory callers = [buyer, seller, stranger, address(this)];
        for (uint256 c; c < callers.length; c++) {
            for (uint256 k; k < calls.length; k++) {
                vm.prank(callers[c]);
                (bool ok,) = address(game).call(calls[k]);
                assertFalse(ok, "mutator succeeded on terminal escrow");
            }
        }
    }
}





contract LiarsGame_Test is Base {
    /*══════════════════════ createEscrow ══════════════════════*/

    function test_create_happy() public {
        uint256 bBefore = token.balanceOf(buyer);
        bytes32 id = _create();

        Liars_Game.Escrow memory e = _esc(id);
        assertEq(e.buyer, buyer);
        assertEq(e.seller, seller);
        assertEq(e.integrator, integrator);
        assertEq(e.token, address(token));
        assertEq(uint256(e.evaluationWindow), defaultEW);
        assertEq(uint256(e.lifetime), uint256(uint32(block.timestamp + 365 days)));
        assertEq(uint256(e.escrowAmount), AMOUNT);
        assertEq(uint256(e.alphaBps), uint256(type(uint16).max), "alpha must start UNSET");
        _assertState(id, S_CREATED);
        assertEq(token.balanceOf(buyer), bBefore - AMOUNT);
        assertEq(token.balanceOf(address(game)), AMOUNT);
        _assertConserved(id);
    }

    function test_create_uniqueIdsForSamePair() public {
        bytes32 a = _create();
        bytes32 b = _create();
        assertTrue(a != b, "ids must differ across nonces");
        assertEq(uint256(_esc(a).escrowAmount), AMOUNT);
        assertEq(uint256(_esc(b).escrowAmount), AMOUNT);
        assertEq(token.balanceOf(address(game)), 2 * AMOUNT);
    }

    function test_create_revert_zeroAddresses() public {
        uint256 life = block.timestamp + 365 days;

        vm.expectRevert(Liars_Game.ZeroAddress.selector);
        _createRaw(buyer, address(0), integrator, address(token), AMOUNT, defaultEW, life);

        vm.expectRevert(Liars_Game.ZeroAddress.selector);
        _createRaw(buyer, seller, address(0), address(token), AMOUNT, defaultEW, life);

        vm.expectRevert(Liars_Game.ZeroAddress.selector);
        _createRaw(buyer, seller, integrator, address(0), AMOUNT, defaultEW, life);
    }

    function test_create_revert_buyerIsSeller() public {
        uint256 life = block.timestamp + 365 days;
        vm.expectRevert(Liars_Game.BuyerSellerSame.selector);
        _createRaw(buyer, buyer, integrator, address(token), AMOUNT, defaultEW, life);
    }

    function test_create_revert_tokenNotApproved() public {
        uint256 life = block.timestamp + 365 days;
        vm.expectRevert(Liars_Game.TokenNotApproved.selector);
        _createRaw(buyer, seller, integrator, address(token2), AMOUNT, defaultEW, life);
    }

    function test_create_revert_zeroAmount() public {
        uint256 life = block.timestamp + 365 days;
        vm.expectRevert(Liars_Game.InvalidAmount.selector);
        _createRaw(buyer, seller, integrator, address(token), 0, defaultEW, life);
    }

    function test_create_revert_evaluationWindowBounds() public {
        uint256 life = block.timestamp + 365 days;
        if (minEW > 0) {
            vm.expectRevert(Liars_Game.InvalidEvaluationWindow.selector);
            _createRaw(buyer, seller, integrator, address(token), AMOUNT, minEW - 1, life);
        }
        if (maxEW < type(uint32).max) {
            vm.expectRevert(Liars_Game.InvalidEvaluationWindow.selector);
            _createRaw(buyer, seller, integrator, address(token), AMOUNT, maxEW + 1, life);
        }
    }

    function test_unaffordableBond_partyCanStillFold() public {
        bytes32 id = _toAwaiting(AMOUNT);
        _open(id, buyer);

        // drain the seller completely
        uint256 bal = token.balanceOf(seller);
        vm.startPrank(seller);
        token.transfer(stranger, bal);
        vm.stopPrank();
        assertEq(token.balanceOf(seller), 0, "seller was not drained");

        // seller cannot pay the turn-2 bond
        vm.expectRevert();
        vm.prank(seller);
        game.advanceTurn(id);

        // folding costs nothing, so the dispute can still end
        vm.prank(seller);
        game.fold(id);
        _assertState(id, S_RESOLVED);
        _assertConserved(id);
    }

    function test_constructor_revert_zeroTreasury() public {
        vm.expectRevert(Liars_Game.ZeroAddress.selector);
        new Liars_Game(address(0));
    }

    function test_constructor_treasuryReceivesFeesFromFirstEscrow() public {
        Liars_Game fresh = new Liars_Game(treasury); // no setTreasury call
        fresh.addApprovedToken(address(token));
        vm.prank(buyer);
        token.approve(address(fresh), type(uint256).max);

        vm.prank(buyer);
        bytes32 id = fresh.createEscrow(
            seller, integrator, address(token), AMOUNT, uint32(defaultEW), uint32(block.timestamp + 365 days)
        );
        vm.prank(seller);
        fresh.submitWork(id, "w");
        vm.warp(uint256(fresh.getEscrow(id).evaluationDeadline) + 1);
        vm.prank(seller);
        fresh.claimDefault(id);

        assertEq(fresh.pendingWithdrawal(treasury, address(token)), _tCut(_fee(AMOUNT)));
        assertEq(fresh.pendingWithdrawal(address(0), address(token)), 0, "nothing credited to the zero address");
    }



    function test_create_evaluationWindowBoundsInclusive() public {
        uint256 life = block.timestamp + maxEW + 30 days;
        _createRaw(buyer, seller, integrator, address(token), AMOUNT, minEW, life);
        _createRaw(buyer, seller, integrator, address(token), AMOUNT, maxEW, life);
    }

    function test_create_revert_lifetimeBoundary() public {
        uint256 life = block.timestamp + defaultEW; // exactly now + window -> must revert (strict >)
        vm.expectRevert(Liars_Game.InvalidLifetime.selector);
        _createRaw(buyer, seller, integrator, address(token), AMOUNT, defaultEW, life);

        // one second more is the minimum valid lifetime
        bytes32 id = _createRaw(buyer, seller, integrator, address(token), AMOUNT, defaultEW, life + 1);
        assertEq(uint256(_esc(id).lifetime), life + 1);
    }

    function test_create_revert_lifetimeAlreadyPast() public {
        vm.expectRevert(Liars_Game.InvalidLifetime.selector);
        _createRaw(buyer, seller, integrator, address(token), AMOUNT, defaultEW, block.timestamp - 1);
    }

    function test_create_gateOrdering() public {
        uint256 life = block.timestamp + 365 days;
        // zero seller AND zero amount -> ZeroAddress first
        vm.expectRevert(Liars_Game.ZeroAddress.selector);
        _createRaw(buyer, address(0), integrator, address(token), 0, defaultEW, life);
        // buyer == seller AND unapproved token -> BuyerSellerSame first
        vm.expectRevert(Liars_Game.BuyerSellerSame.selector);
        _createRaw(buyer, buyer, integrator, address(token2), AMOUNT, defaultEW, life);
        // unapproved token AND zero amount -> TokenNotApproved first
        vm.expectRevert(Liars_Game.TokenNotApproved.selector);
        _createRaw(buyer, seller, integrator, address(token2), 0, defaultEW, life);
        // zero amount AND bad window -> InvalidAmount first
        vm.expectRevert(Liars_Game.InvalidAmount.selector);
        _createRaw(buyer, seller, integrator, address(token), 0, maxEW + 1, life);
    }

    function test_create_revert_noAllowanceOrBalance() public {
        uint256 life = block.timestamp + 365 days;
        vm.expectRevert(); // poor never approved the game
        _createRaw(poor, seller, integrator, address(token), AMOUNT, defaultEW, life);

        vm.expectRevert(); // more than buyer's balance
        _createRaw(buyer, seller, integrator, address(token), 1e41, defaultEW, life);
    }

    function test_create_afterTokenRemoved_reverts() public {
        game.removeApprovedToken(address(token));
        uint256 life = block.timestamp + 365 days;
        vm.expectRevert(Liars_Game.TokenNotApproved.selector);
        _createRaw(buyer, seller, integrator, address(token), AMOUNT, defaultEW, life);
    }

    function testFuzz_create_validParams(uint256 amount, uint256 ew, uint256 extra, address integ) public {
        vm.assume(integ != address(0));
        amount = bound(amount, 1, 1e30);
        ew = bound(ew, minEW, _min(maxEW, 1000 days));
        extra = bound(extra, 1, 365 days);
        uint256 life = block.timestamp + ew + extra;

        uint256 gameBefore = token.balanceOf(address(game));
        bytes32 id = _createRaw(buyer, seller, integ, address(token), amount, ew, life);

        Liars_Game.Escrow memory e = _esc(id);
        assertEq(uint256(e.escrowAmount), amount);
        assertEq(uint256(e.evaluationWindow), ew);
        assertEq(uint256(e.lifetime), life);
        assertEq(e.integrator, integ);
        assertEq(token.balanceOf(address(game)), gameBefore + amount);
        _assertState(id, S_CREATED);
    }

    function testFuzz_create_badLifetimeAlwaysReverts(uint256 ew, uint256 life) public {
        ew = bound(ew, minEW, _min(maxEW, 1000 days));
        life = bound(life, 0, block.timestamp + ew); // <= now + ew
        vm.expectRevert(Liars_Game.InvalidLifetime.selector);
        _createRaw(buyer, seller, integrator, address(token), AMOUNT, ew, life);
    }

    function testFuzz_create_badWindowAlwaysReverts(uint32 ew) public {
        vm.assume(uint256(ew) < minEW || uint256(ew) > maxEW);
        vm.expectRevert(Liars_Game.InvalidEvaluationWindow.selector);
        _createRaw(buyer, seller, integrator, address(token), AMOUNT, ew, block.timestamp + 3000 days);
    }

    /*══════════════════════ submitWork ══════════════════════*/

    function test_submit_happy() public {
        bytes32 id = _create();
        vm.prank(seller);
        game.submitWork(id, "ipfs://work");

        Liars_Game.Escrow memory e = _esc(id);
        _assertState(id, S_SUBMITTED);
        assertEq(e.workPointer, "ipfs://work");
        assertEq(uint256(e.evaluationDeadline), block.timestamp + defaultEW);
    }

    function test_submit_resubmitOverwritesAndResetsDeadline() public {
        bytes32 id = _create();
        vm.prank(seller);
        game.submitWork(id, "v1");
        uint256 d1 = uint256(_esc(id).evaluationDeadline);

        vm.warp(block.timestamp + 1);
        vm.prank(seller);
        game.submitWork(id, "v2");

        Liars_Game.Escrow memory e = _esc(id);
        assertEq(e.workPointer, "v2");
        assertEq(uint256(e.evaluationDeadline), d1 + 1);
        _assertState(id, S_SUBMITTED);
    }

    function test_submit_revert_notSeller() public {
        bytes32 id = _create();
        vm.expectRevert(Liars_Game.NotAuthorised.selector);
        vm.prank(buyer);
        game.submitWork(id, "x");
        vm.expectRevert(Liars_Game.NotAuthorised.selector);
        vm.prank(stranger);
        game.submitWork(id, "x");
    }

    function test_submit_revert_lifetimeBoundary() public {
        bytes32 id = _create();
        uint256 life = uint256(_esc(id).lifetime);

        vm.warp(life);
        vm.expectRevert(Liars_Game.LifetimeElapsed.selector);
        vm.prank(seller);
        game.submitWork(id, "x");

        vm.warp(life - 1);
        vm.prank(seller);
        game.submitWork(id, "x");

        // grace period: evaluation deadline is NOT capped by lifetime
        assertEq(uint256(_esc(id).evaluationDeadline), life - 1 + defaultEW);
    }

    function test_submit_revert_wrongState() public {
        bytes32 id = _create();
        vm.prank(buyer);
        game.cancelEscrow(id);
        vm.expectRevert(Liars_Game.WrongState.selector);
        vm.prank(seller);
        game.submitWork(id, "x");

        bytes32 id2 = _toPartial(AMOUNT, 5000);
        vm.expectRevert(Liars_Game.WrongState.selector);
        vm.prank(seller);
        game.submitWork(id2, "x");
    }

    function test_submit_gateOrdering() public {
        bytes32 id = _create();
        // stranger after lifetime: NotAuthorised precedes LifetimeElapsed
        vm.warp(uint256(_esc(id).lifetime) + 1);
        vm.expectRevert(Liars_Game.NotAuthorised.selector);
        vm.prank(stranger);
        game.submitWork(id, "x");
        // seller after lifetime: LifetimeElapsed
        vm.expectRevert(Liars_Game.LifetimeElapsed.selector);
        vm.prank(seller);
        game.submitWork(id, "x");

        // stranger on cancelled: WrongState precedes NotAuthorised
        bytes32 id2 = _create();
        vm.prank(buyer);
        game.cancelEscrow(id2);
        vm.expectRevert(Liars_Game.WrongState.selector);
        vm.prank(stranger);
        game.submitWork(id2, "x");
    }

    /*══════════════════════ claimDefault ══════════════════════*/

    function test_claimDefault_feeSplitExact() public {
        bytes32 id = _createSubmitted(AMOUNT);
        vm.warp(uint256(_esc(id).evaluationDeadline) + 1);

        vm.prank(seller);
        game.claimDefault(id);

        uint256 fee = _fee(AMOUNT);
        uint256 tc = _tCut(fee);
        assertEq(_pending(seller), AMOUNT - fee);
        assertEq(_pending(treasury), tc);
        assertEq(_pending(integrator), fee - tc);
        assertEq(uint256(_esc(id).escrowAmount), 0);
        _assertState(id, S_RESOLVED);
        _assertConserved(id);
    }

    function test_claimDefault_boundary() public {
        bytes32 id = _createSubmitted(AMOUNT);
        uint256 dl = uint256(_esc(id).evaluationDeadline);

        vm.warp(dl); // still inside window (<=)
        vm.expectRevert(Liars_Game.EvaluationWindowOpen.selector);
        vm.prank(seller);
        game.claimDefault(id);

        vm.warp(dl + 1);
        vm.prank(seller);
        game.claimDefault(id);
        _assertState(id, S_RESOLVED);
    }

    function test_claimDefault_revert_notSeller() public {
        bytes32 id = _createSubmitted(AMOUNT);
        vm.warp(uint256(_esc(id).evaluationDeadline) + 1);
        vm.expectRevert(Liars_Game.NotAuthorised.selector);
        vm.prank(buyer);
        game.claimDefault(id);
        vm.expectRevert(Liars_Game.NotAuthorised.selector);
        vm.prank(stranger);
        game.claimDefault(id);
    }

    function test_claimDefault_revert_wrongState() public {
        bytes32 id = _create(); // CREATED, never submitted
        vm.warp(block.timestamp + 365 days);
        vm.expectRevert(Liars_Game.WrongState.selector);
        vm.prank(seller);
        game.claimDefault(id);
    }

    function test_claimDefault_cannotBeClaimedTwice() public {
        bytes32 id = _createSubmitted(AMOUNT);
        vm.warp(uint256(_esc(id).evaluationDeadline) + 1);
        vm.prank(seller);
        game.claimDefault(id);
        vm.expectRevert(Liars_Game.WrongState.selector);
        vm.prank(seller);
        game.claimDefault(id);
    }

    function test_claimDefault_blockedOncePartialSettlementStarted() public {
        bytes32 id = _toPartial(AMOUNT, 4000);
        vm.warp(block.timestamp + 365 days);
        vm.expectRevert(Liars_Game.WrongState.selector);
        vm.prank(seller);
        game.claimDefault(id);
    }

    function testFuzz_claimDefault_splitsSumToAmount(uint256 amount) public {
        amount = bound(amount, 1, 1e30);
        bytes32 id = _createSubmitted(amount);
        vm.warp(uint256(_esc(id).evaluationDeadline) + 1);
        vm.prank(seller);
        game.claimDefault(id);

        uint256 fee = _fee(amount);
        assertLe(fee, amount, "fee exceeds amount");
        assertEq(_pending(seller), amount - fee);
        assertEq(_pending(treasury), _tCut(fee));
        assertEq(_pending(integrator), fee - _tCut(fee));
        assertEq(_pending(seller) + _pending(treasury) + _pending(integrator), amount, "value created/destroyed");
        _assertConserved(id);
    }

    function testFuzz_claimDefault_timing(uint256 offset) public {
        bytes32 id = _createSubmitted(AMOUNT);
        uint256 dl = uint256(_esc(id).evaluationDeadline);
        offset = bound(offset, 0, 2 * defaultEW + 10);
        vm.warp(block.timestamp + offset);

        if (block.timestamp <= dl) {
            vm.expectRevert(Liars_Game.EvaluationWindowOpen.selector);
            vm.prank(seller);
            game.claimDefault(id);
        } else {
            vm.prank(seller);
            game.claimDefault(id);
            _assertState(id, S_RESOLVED);
        }
    }

    /*══════════════════════ settlePartial ══════════════════════*/

    function test_settlePartial_happy() public {
        bytes32 id = _createSubmitted(AMOUNT);
        vm.prank(buyer);
        game.settlePartial(id, 6000);

        Liars_Game.Escrow memory e = _esc(id);
        _assertState(id, S_PARTIAL);
        assertEq(uint256(e.alphaBps), 6000);
        assertEq(uint256(e.settlementFinalizedTime), block.timestamp + settleWin);
        assertEq(uint256(e.escrowAmount), AMOUNT, "no funds move on settlePartial");
        _assertConserved(id);
    }

    function test_settlePartial_fullAlphaAllowed() public {
        bytes32 id = _createSubmitted(AMOUNT);
        vm.prank(buyer);
        game.settlePartial(id, 10000);
        assertEq(uint256(_esc(id).alphaBps), 10000);
    }

    function test_settlePartial_revert_alphaAbove10000() public {
        bytes32 id = _createSubmitted(AMOUNT);
        vm.expectRevert(Liars_Game.InvalidAlphaBps.selector);
        vm.prank(buyer);
        game.settlePartial(id, 10001);
        vm.expectRevert(Liars_Game.InvalidAlphaBps.selector);
        vm.prank(buyer);
        game.settlePartial(id, type(uint16).max);
    }

    function test_settlePartial_revert_notBuyer() public {
        bytes32 id = _createSubmitted(AMOUNT);
        vm.expectRevert(Liars_Game.NotAuthorised.selector);
        vm.prank(seller);
        game.settlePartial(id, 5000);
        vm.expectRevert(Liars_Game.NotAuthorised.selector);
        vm.prank(stranger);
        game.settlePartial(id, 5000);
    }

    function test_settlePartial_revert_wrongState() public {
        bytes32 id = _create();
        vm.expectRevert(Liars_Game.WrongState.selector);
        vm.prank(buyer);
        game.settlePartial(id, 5000);
    }

    function test_settlePartial_evaluationWindowBoundary() public {
        bytes32 id = _createSubmitted(AMOUNT);
        uint256 dl = uint256(_esc(id).evaluationDeadline);

        vm.warp(dl + 1);
        vm.expectRevert(Liars_Game.EvaluationWindowExpired.selector);
        vm.prank(buyer);
        game.settlePartial(id, 5000);

        vm.warp(dl); // inclusive
        vm.prank(buyer);
        game.settlePartial(id, 5000);
        _assertState(id, S_PARTIAL);
    }

    function test_settlePartial_dustOutputOnTinyEscrow() public {
        bytes32 id = _createSubmitted(1); // 1 wei: fee ceil-rounds to 1, net = 0
        vm.expectRevert(Liars_Game.DustOutput.selector);
        vm.prank(buyer);
        game.settlePartial(id, 10000);
    }

   function testFuzz_settlePartial_zeroAlphaAccepted(uint256 amount) public {
        amount = bound(amount, 1, 1e30);
        bytes32 id = _createSubmitted(amount);
        vm.prank(buyer);
        game.settlePartial(id, 0);

        _assertState(id, S_PARTIAL);
        assertEq(uint256(_esc(id).alphaBps), 0);
        assertEq(uint256(_esc(id).escrowAmount), amount, "no funds move");
        _assertConserved(id);
    }

    function test_settlePartial_overwriteBetweenZeroAndNonZero() public {
        bytes32 id = _toPartial(AMOUNT, 5000);
        vm.prank(buyer);
        game.settlePartial(id, 0);
        assertEq(uint256(_esc(id).alphaBps), 0);
        vm.prank(buyer);
        game.settlePartial(id, 8000);
        assertEq(uint256(_esc(id).alphaBps), 8000);
    } 

    function test_settlePartial_overwriteWithinWindow() public {
        bytes32 id = _createSubmitted(AMOUNT);
        uint256 dl = uint256(_esc(id).evaluationDeadline);
        vm.prank(buyer);
        game.settlePartial(id, 3000);
        uint256 sft1 = uint256(_esc(id).settlementFinalizedTime);

        vm.warp(sft1 - 1);
        vm.prank(buyer);
        game.settlePartial(id, 7000);

        Liars_Game.Escrow memory e = _esc(id);
        assertEq(uint256(e.alphaBps), 7000);
        assertEq(uint256(e.settlementFinalizedTime), _min(block.timestamp + settleWin, dl + settleWin));
        _assertState(id, S_PARTIAL);
    }

    function test_settlePartial_overwriteRevertsAtWindowEnd() public {
        bytes32 id = _toPartial(AMOUNT, 3000);
        vm.warp(uint256(_esc(id).settlementFinalizedTime));
        vm.expectRevert(Liars_Game.SettlementWindowExpired.selector);
        vm.prank(buyer);
        game.settlePartial(id, 7000);
    }

    function testFuzz_settlePartial_overwriteTiming(uint256 dt, uint16 a1, uint16 a2) public {
        a1 = uint16(bound(a1, 1, 10000));
        a2 = uint16(bound(a2, 1, 10000));
        dt = bound(dt, 0, settleWin - 1);

        bytes32 id = _createSubmitted(AMOUNT);
        uint256 dl = uint256(_esc(id).evaluationDeadline);
        vm.prank(buyer);
        game.settlePartial(id, a1);

        vm.warp(block.timestamp + dt);
        vm.prank(buyer);
        game.settlePartial(id, a2);

        assertEq(uint256(_esc(id).alphaBps), a2);
        assertEq(uint256(_esc(id).settlementFinalizedTime), _min(block.timestamp + settleWin, dl + settleWin));
    }

    function testFuzz_settlePartial_dustBoundaryMatchesPreview(uint256 amount, uint16 alpha) public {
        amount = bound(amount, 1, 1e6); // small amounts stress the ceil-fee dust edge
        alpha = uint16(bound(alpha, 0, 10000));
        bytes32 id = _createSubmitted(amount);
        uint256 portion = amount * alpha / 10000;

        if (alpha != 0 && _net(portion) == 0) {
            vm.expectRevert(Liars_Game.DustOutput.selector);
            vm.prank(buyer);
            game.settlePartial(id, alpha);
        } else {
            vm.prank(buyer);
            game.settlePartial(id, alpha);
            assertEq(uint256(_esc(id).alphaBps), alpha);
        }
    }


    function test_finalizeRejected_happy() public {
        bytes32 id = _toRejected(AMOUNT, block.timestamp + 365 days);
        Liars_Game.Escrow memory e = _esc(id);

        _assertState(id, S_AWAITING);
        assertEq(uint256(e.escrowAmount), 0);
        assertEq(uint256(e.dispute.disputedDelta), AMOUNT, "whole escrow becomes contested");
        assertEq(uint256(e.escalationDeadline), block.timestamp + escWin);
        assertEq(_pending(seller) + _pending(treasury) + _pending(integrator) + _pending(buyer), 0, "nothing paid out");
        _assertConserved(id);
    }

    function test_rejected_buyerWins_resetsToCreated() public {
        uint256 life = block.timestamp + 365 days;
        bytes32 id = _toRejected(AMOUNT, life);
        _playTo(id, seller, 2); // lastActor = buyer
        Liars_Game.Dispute memory d = _dsp(id);
        Snap memory pre = _snap();

        vm.prank(seller);
        game.fold(id); // buyer wins, alpha == 0, now < lifetime -> reset

        Liars_Game.Escrow memory e = _esc(id);
        _assertState(id, S_CREATED);
        assertEq(uint256(e.escrowAmount), AMOUNT, "contested amount goes back into escrow");
        assertEq(uint256(e.alphaBps), uint256(type(uint16).max), "alpha back to UNSET");
        assertEq(uint256(e.evaluationDeadline), 0);
        assertEq(uint256(e.settlementFinalizedTime), 0);
        assertEq(uint256(e.escalationDeadline), 0);
        assertEq(e.workPointer, "");
        assertEq(uint256(e.dispute.disputedDelta), 0);
        assertEq(uint256(e.dispute.currentTurn), 0);
        // identity fields survive
        assertEq(e.buyer, buyer);
        assertEq(e.seller, seller);
        assertEq(e.integrator, integrator);
        assertEq(e.token, address(token));
        assertEq(uint256(e.lifetime), life);
        assertEq(uint256(e.evaluationWindow), defaultEW);
        // collateral: winner gets theirs back, loser's goes to treasury, delta is NOT credited
        Snap memory post = _snap();
        assertEq(post.b - pre.b, uint256(d.buyerCollateral));
        assertEq(post.t - pre.t, uint256(d.sellerCollateral));
        _assertConserved(id);

        // the escrow is fully live again
        vm.prank(seller);
        game.submitWork(id, "resubmitted");
        _assertState(id, S_SUBMITTED);
    }

    function test_rejected_buyerWinsAfterLifetime_cancelsWithRefund() public {
        uint256 life = block.timestamp + defaultEW + settleWin + 1 days;
        bytes32 id = _toRejected(AMOUNT, life);
        _playTo(id, seller, 2); // lastActor = buyer
        Liars_Game.Dispute memory d = _dsp(id);
        Snap memory pre = _snap();

        vm.warp(_min(type(uint256).max, life > uint256(d.turnDeadline) ? life : uint256(d.turnDeadline) + 1));
        vm.prank(seller);
        game.claimTurnTimeout(id); // buyer wins, alpha == 0, now >= lifetime -> cancel

        _assertState(id, S_CANCELLED);
        Snap memory post = _snap();
        assertEq(post.b - pre.b, uint256(d.buyerCollateral) + AMOUNT, "buyer: collateral + full refund, no fee");
        assertEq(post.t - pre.t, uint256(d.sellerCollateral));
        _assertConserved(id);
        _assertDead(id);
    }

    function test_rejected_sellerWins_getsFullAmountMinusFee() public {
        bytes32 id = _toRejected(AMOUNT, block.timestamp + 365 days);
        _playTo(id, buyer, 2); // lastActor = seller
        Liars_Game.Dispute memory d = _dsp(id);
        Snap memory pre = _snap();

        vm.prank(buyer);
        game.fold(id);

        _assertState(id, S_RESOLVED);
        _assertResolution(pre, seller, d); // delta == full AMOUNT here
        _assertConserved(id);
    }

    /*══════════════════════ finalizeSettlementFull ══════════════════════*/

    function test_finalizeFull_happy() public {
        bytes32 id = _toPartial(AMOUNT, 10000);
        vm.warp(uint256(_esc(id).settlementFinalizedTime));

        vm.prank(seller); // either party may finalize
        game.finalizeSettlementFull(id);

        uint256 fee = _fee(AMOUNT);
        assertEq(_pending(seller), AMOUNT - fee);
        assertEq(_pending(treasury), _tCut(fee));
        assertEq(_pending(integrator), fee - _tCut(fee));
        assertEq(uint256(_esc(id).escrowAmount), 0);
        _assertState(id, S_RESOLVED);
        _assertConserved(id);
    }

    function test_finalizeFull_gates() public {
        bytes32 id = _toPartial(AMOUNT, 10000);
        uint256 sft = uint256(_esc(id).settlementFinalizedTime);

        vm.expectRevert(Liars_Game.NotAParty.selector); // precedes window check
        vm.prank(stranger);
        game.finalizeSettlementFull(id);

        vm.warp(sft - 1);
        vm.expectRevert(Liars_Game.SettlementWindowOpen.selector);
        vm.prank(buyer);
        game.finalizeSettlementFull(id);

        vm.warp(sft);
        vm.expectRevert(Liars_Game.NotAParty.selector);
        vm.prank(stranger);
        game.finalizeSettlementFull(id);
    }

    function test_finalizeFull_revert_alphaNot10000() public {
        bytes32 id = _toPartial(AMOUNT, 9999);
        vm.warp(uint256(_esc(id).settlementFinalizedTime));
        vm.expectRevert(Liars_Game.InvalidAlphaBps.selector);
        vm.prank(buyer);
        game.finalizeSettlementFull(id);
    }

    function test_finalizeFull_revert_wrongState() public {
        bytes32 id = _createSubmitted(AMOUNT);
        vm.expectRevert(Liars_Game.WrongState.selector);
        vm.prank(buyer);
        game.finalizeSettlementFull(id);
    }

    function test_finalizeFull_cannotRepeat() public {
        bytes32 id = _toPartial(AMOUNT, 10000);
        vm.warp(uint256(_esc(id).settlementFinalizedTime));
        vm.prank(buyer);
        game.finalizeSettlementFull(id);
        vm.expectRevert(Liars_Game.WrongState.selector);
        vm.prank(buyer);
        game.finalizeSettlementFull(id);
    }

    /*══════════════════════ finalizeSettlementPartial ══════════════════════*/

    function test_finalizePartial_happy() public {
        bytes32 id = _toPartial(AMOUNT, 3000);
        uint256 sft = uint256(_esc(id).settlementFinalizedTime);
        vm.warp(sft);

        vm.prank(seller);
        game.finalizeSettlementPartial(id);

        uint256 portion = AMOUNT * 3000 / 10000;
        uint256 fee = _fee(portion);
        Liars_Game.Escrow memory e = _esc(id);

        _assertState(id, S_AWAITING);
        assertEq(uint256(e.escrowAmount), 0);
        assertEq(uint256(e.dispute.disputedDelta), AMOUNT - portion);
        assertEq(uint256(e.escalationDeadline), sft + escWin);
        assertEq(_pending(seller), portion - fee);
        assertEq(_pending(treasury), _tCut(fee));
        assertEq(_pending(integrator), fee - _tCut(fee));
        _assertConserved(id);
    }

    function test_finalizePartial_gates() public {
        bytes32 id = _toPartial(AMOUNT, 3000);
        uint256 sft = uint256(_esc(id).settlementFinalizedTime);

        vm.expectRevert(Liars_Game.NotAParty.selector);
        vm.prank(stranger);
        game.finalizeSettlementPartial(id);

        vm.warp(sft - 1);
        vm.expectRevert(Liars_Game.SettlementWindowOpen.selector);
        vm.prank(buyer);
        game.finalizeSettlementPartial(id);
    }

    function test_finalizePartial_revert_alphaFull() public {
        bytes32 id = _toPartial(AMOUNT, 10000);
        vm.warp(uint256(_esc(id).settlementFinalizedTime));
        vm.expectRevert(Liars_Game.InvalidAlphaBps.selector);
        vm.prank(buyer);
        game.finalizeSettlementPartial(id);
    }

    function test_finalizePartial_revert_wrongState() public {
        bytes32 id = _toAwaiting(AMOUNT);
        vm.expectRevert(Liars_Game.WrongState.selector);
        vm.prank(buyer);
        game.finalizeSettlementPartial(id);
    }

    function testFuzz_finalizePartial_conservation(uint256 amount, uint16 alpha) public {
        amount = bound(amount, 2, 1e30);
        alpha = uint16(bound(alpha, 1, 9999));
        bytes32 id = _createSubmitted(amount);
        uint256 portion = amount * alpha / 10000;

        if (_net(portion) == 0) {
            vm.expectRevert(Liars_Game.DustOutput.selector);
            vm.prank(buyer);
            game.settlePartial(id, alpha);
            return;
        }
        vm.prank(buyer);
        game.settlePartial(id, alpha);
        vm.warp(uint256(_esc(id).settlementFinalizedTime));
        vm.prank(seller);
        game.finalizeSettlementPartial(id);

        Liars_Game.Escrow memory e = _esc(id);
        assertEq(uint256(e.dispute.disputedDelta), amount - portion, "delta");
        assertEq(uint256(e.dispute.disputedDelta) + portion, amount, "split must sum to amount");
        assertEq(_pending(seller), _net(portion));
        _assertConserved(id);
    }

    /*══════════════════════ finalizeSettlementRejected (see FINDING above) ══════════════════════*/

    function test_finalizeRejected_gatesAndDeadPath() public {
        bytes32 id = _toPartial(AMOUNT, 5000);
        uint256 sft = uint256(_esc(id).settlementFinalizedTime);

        vm.expectRevert(Liars_Game.NotAuthorised.selector);
        vm.prank(seller);
        game.finalizeSettlementRejected(id);

        vm.warp(sft - 1);
        vm.expectRevert(Liars_Game.SettlementWindowOpen.selector);
        vm.prank(buyer);
        game.finalizeSettlementRejected(id);

        vm.warp(sft);
        vm.expectRevert(Liars_Game.InvalidAlphaBps.selector); // alpha is 5000, not 0
        vm.prank(buyer);
        game.finalizeSettlementRejected(id);
    }

    function test_finalizeRejected_revert_wrongState() public {
        bytes32 id = _createSubmitted(AMOUNT);
        vm.expectRevert(Liars_Game.WrongState.selector);
        vm.prank(buyer);
        game.finalizeSettlementRejected(id);
    }

    /*══════════════════════ openDispute ══════════════════════*/

  function test_open_byBuyer() public {
    bytes32 id = _toAwaiting(AMOUNT);
    uint256 delta = uint256(_dsp(id).disputedDelta);
    uint256 bond = game.requiredBondFor(id, buyer);
    assertEq(bond, _bond(delta, 1, false), "quote matches schedule");
    uint256 balBefore = token.balanceOf(buyer);

    _open(id, buyer);

    Liars_Game.Dispute memory d = _dsp(id);
    _assertState(id, S_ESCALATION);
    assertEq(uint256(d.currentTurn), 1);
    assertEq(d.lastActor, buyer);
    assertEq(uint256(d.turnDeadline), block.timestamp + turnWin);
    assertEq(uint256(d.buyerCollateral), bond);
    assertEq(uint256(d.sellerCollateral), 0);
    assertEq(balBefore - token.balanceOf(buyer), bond);
    _assertConserved(id);
}

function test_open_bySeller() public {
    bytes32 id = _toAwaiting(AMOUNT);
    uint256 delta = uint256(_dsp(id).disputedDelta);
    uint256 bond = game.requiredBondFor(id, seller);
    assertEq(bond, _bond(delta, 1, true), "quote matches the seller's scaled bond");
    uint256 balBefore = token.balanceOf(seller);

    _open(id, seller);

    Liars_Game.Dispute memory d = _dsp(id);
    assertEq(d.lastActor, seller);
    assertEq(uint256(d.sellerCollateral), bond);
    assertEq(uint256(d.buyerCollateral), 0);
    assertEq(balBefore - token.balanceOf(seller), bond);
    _assertConserved(id);
}

    function test_open_revert_gates() public {
        bytes32 id = _toAwaiting(AMOUNT);
        vm.expectRevert(Liars_Game.NotAParty.selector);
        vm.prank(stranger);
        game.openDispute(id);

        bytes32 id2 = _createSubmitted(AMOUNT);
        vm.expectRevert(Liars_Game.WrongState.selector);
        vm.prank(buyer);
        game.openDispute(id2);
    }

    function test_open_escalationWindowBoundary() public {
        bytes32 id = _toAwaiting(AMOUNT);
        uint256 dl = uint256(_esc(id).escalationDeadline);

        vm.warp(dl + 1);
        vm.expectRevert(Liars_Game.EscalationWindowExpired.selector);
        vm.prank(buyer);
        game.openDispute(id);

        vm.warp(dl); // inclusive
        _open(id, buyer);
        _assertState(id, S_ESCALATION);
    }

    function test_open_cannotOpenTwice() public {
        bytes32 id = _toAwaiting(AMOUNT);
        _open(id, buyer);
        vm.expectRevert(Liars_Game.WrongState.selector);
        vm.prank(seller);
        game.openDispute(id);
    }

    function test_open_revert_withoutBondAllowance() public {
        // fresh escrow where the seller revokes allowance before opening
        bytes32 id = _toAwaiting(AMOUNT);
        vm.prank(seller);
        token.approve(address(game), 0);
        vm.expectRevert();
        vm.prank(seller);
        game.openDispute(id);
        _assertState(id, S_AWAITING); // state rolled back
    }

    /*══════════════════════ advanceTurn ══════════════════════*/

 function test_advance_alternatesAndTracksCollateral() public {
    bytes32 id = _toAwaiting(AMOUNT);
    uint256 delta = uint256(_dsp(id).disputedDelta);
    _open(id, buyer);
    uint256 bColl = uint256(_dsp(id).buyerCollateral);

    uint256 quote2 = game.requiredBondFor(id, seller); // turn 2, seller
    assertEq(quote2, _bond(delta, 2, true));
    uint256 sBal = token.balanceOf(seller);
    _advance(id, seller);
    uint256 paid2 = sBal - token.balanceOf(seller);
    assertEq(paid2, quote2, "seller paid exactly the quoted bond");

    Liars_Game.Dispute memory d = _dsp(id);
    assertEq(uint256(d.currentTurn), 2);
    assertEq(d.lastActor, seller);
    assertEq(uint256(d.sellerCollateral), paid2);
    assertEq(uint256(d.buyerCollateral), bColl);
    assertEq(uint256(d.turnDeadline), block.timestamp + turnWin);
    _assertConserved(id);

    uint256 quote3 = game.requiredBondFor(id, buyer); // turn 3, buyer
    assertEq(quote3, _bond(delta, 3, false), "quote now points at the next turn");
    uint256 bBal = token.balanceOf(buyer);
    _advance(id, buyer);
    uint256 paid3 = bBal - token.balanceOf(buyer);
    assertEq(paid3, quote3);
    assertEq(uint256(_dsp(id).buyerCollateral), bColl + paid3);
    assertEq(uint256(_dsp(id).currentTurn), 3);
    _assertConserved(id);
}

    function test_advance_revert_sameActorTwice() public {
        bytes32 id = _toAwaiting(AMOUNT);
        _open(id, buyer);
        vm.expectRevert(Liars_Game.NotYourTurn.selector);
        vm.prank(buyer);
        game.advanceTurn(id);
    }

    function test_advance_revert_stranger_wrongState() public {
        bytes32 id = _toAwaiting(AMOUNT);
        vm.expectRevert(Liars_Game.WrongState.selector); // not yet ESCALATION
        vm.prank(buyer);
        game.advanceTurn(id);

        _open(id, buyer);
        vm.expectRevert(Liars_Game.NotAParty.selector);
        vm.prank(stranger);
        game.advanceTurn(id);
    }

    function test_advance_deadlineBoundary() public {
        bytes32 id = _toAwaiting(AMOUNT);
        _open(id, buyer);
        uint256 dl = uint256(_dsp(id).turnDeadline);

        vm.warp(dl + 1);
        vm.expectRevert(Liars_Game.TurnDeadlineExpired.selector);
        vm.prank(seller);
        game.advanceTurn(id);

        vm.warp(dl); // inclusive
        _advance(id, seller);
        assertEq(uint256(_dsp(id).currentTurn), 2);
    }

    function test_advance_gateOrdering_notYourTurnBeforeDeadline() public {
        bytes32 id = _toAwaiting(AMOUNT);
        _open(id, buyer);
        vm.warp(uint256(_dsp(id).turnDeadline) + 1);
        vm.expectRevert(Liars_Game.NotYourTurn.selector); // lastActor, deadline already blown
        vm.prank(buyer);
        game.advanceTurn(id);
    }

    function test_advance_revert_insufficientAllowance() public {
        bytes32 id = _toAwaiting(AMOUNT);
        _open(id, buyer);
        vm.prank(seller);
        token.approve(address(game), 0);
        vm.expectRevert();
        vm.prank(seller);
        game.advanceTurn(id);
        assertEq(uint256(_dsp(id).currentTurn), 1, "turn must not advance on failed pull");
    }

    function test_advance_manyTurnsKeepsSolvent() public {
        bytes32 id = _toAwaiting(AMOUNT);
        _playTo(id, buyer, 14);
        assertEq(uint256(_dsp(id).currentTurn), 14);
        _assertConserved(id);
    }

    /*══════════════════════ fold ══════════════════════*/

    function test_fold_responderFoldsAndLastActorWins() public {
        bytes32 id = _toAwaiting(AMOUNT);
        _open(id, buyer); // lastActor = buyer, seller must respond
        Liars_Game.Dispute memory d = _dsp(id);
        Snap memory pre = _snap();

        vm.expectEmit(true, true, true, true);
        emit Liars_Game.Folded(id, seller, buyer);
        vm.prank(seller);
        game.fold(id);

        _assertState(id, S_RESOLVED);
        _assertResolution(pre, buyer, d);
        Liars_Game.Dispute memory after_ = _dsp(id);
        assertEq(uint256(after_.buyerCollateral), 0);
        assertEq(uint256(after_.sellerCollateral), 0);
        assertEq(uint256(after_.disputedDelta), 0);
        _assertConserved(id);
    }

    function test_fold_sellerWinsPaysFee() public {
        bytes32 id = _toAwaiting(AMOUNT);
        _open(id, seller);
        _advance(id, buyer); // turn 2, lastActor = buyer
        _advance(id, seller); // turn 3, lastActor = seller
        Liars_Game.Dispute memory d = _dsp(id);
        Snap memory pre = _snap();

        vm.prank(buyer);
        game.fold(id);

        _assertResolution(pre, seller, d);
        _assertConserved(id);
        _assertDead(id);
    }

    function test_fold_revert_lastActorCannotFold() public {
        bytes32 id = _toAwaiting(AMOUNT);
        _open(id, buyer);
        vm.expectRevert(Liars_Game.NotYourTurn.selector);
        vm.prank(buyer);
        game.fold(id);
    }

    function test_fold_revert_afterDeadline() public {
        bytes32 id = _toAwaiting(AMOUNT);
        _open(id, buyer);
        vm.warp(uint256(_dsp(id).turnDeadline) + 1);
        vm.expectRevert(Liars_Game.TurnDeadlineExpired.selector);
        vm.prank(seller);
        game.fold(id);
        // deadline gate precedes turn gate
        vm.expectRevert(Liars_Game.TurnDeadlineExpired.selector);
        vm.prank(buyer);
        game.fold(id);
    }

    function test_fold_revert_stranger_wrongState() public {
        bytes32 id = _toAwaiting(AMOUNT);
        vm.expectRevert(Liars_Game.WrongState.selector);
        vm.prank(seller);
        game.fold(id);

        _open(id, buyer);
        vm.expectRevert(Liars_Game.NotAParty.selector);
        vm.prank(stranger);
        game.fold(id);
    }

    function test_fold_deadlineInclusive() public {
        bytes32 id = _toAwaiting(AMOUNT);
        _open(id, buyer);
        vm.warp(uint256(_dsp(id).turnDeadline));
        vm.prank(seller);
        game.fold(id);
        _assertState(id, S_RESOLVED);
    }

    /*══════════════════════ claimTurnTimeout ══════════════════════*/

    function test_turnTimeout_lastActorWins() public {
        bytes32 id = _toAwaiting(AMOUNT);
        _open(id, seller);
        _advance(id, buyer); // turn 2, lastActor = buyer, seller is stalling
        Liars_Game.Dispute memory d = _dsp(id);
        Snap memory pre = _snap();

        vm.warp(uint256(d.turnDeadline) + 1);
        vm.prank(seller); // the stalling party can trigger it too; outcome is identical
        game.claimTurnTimeout(id);

        _assertState(id, S_RESOLVED);
        _assertResolution(pre, buyer, d);
        _assertConserved(id);
    }

    function test_turnTimeout_revert_whileOpen() public {
        bytes32 id = _toAwaiting(AMOUNT);
        _open(id, buyer);
        vm.warp(uint256(_dsp(id).turnDeadline)); // == deadline is still open
        vm.expectRevert(Liars_Game.TurnDeadlineOpen.selector);
        vm.prank(buyer);
        game.claimTurnTimeout(id);
    }

    function test_turnTimeout_revert_stranger_wrongState() public {
        bytes32 id = _toAwaiting(AMOUNT);
        vm.expectRevert(Liars_Game.WrongState.selector);
        vm.prank(buyer);
        game.claimTurnTimeout(id);

        _open(id, buyer);
        vm.warp(block.timestamp + turnWin + 1);
        vm.expectRevert(Liars_Game.NotAParty.selector);
        vm.prank(stranger);
        game.claimTurnTimeout(id);
    }

    function test_turnTimeout_cannotClaimTwice() public {
        bytes32 id = _toAwaiting(AMOUNT);
        _open(id, buyer);
        vm.warp(block.timestamp + turnWin + 1);
        vm.prank(buyer);
        game.claimTurnTimeout(id);
        vm.expectRevert(Liars_Game.WrongState.selector);
        vm.prank(buyer);
        game.claimTurnTimeout(id);
    }

    function test_turnTimeout_foldAndTimeoutAreMutuallyExclusive() public {
        bytes32 id = _toAwaiting(AMOUNT);
        _open(id, buyer);
        vm.warp(block.timestamp + turnWin + 1);
        vm.expectRevert(Liars_Game.TurnDeadlineExpired.selector);
        vm.prank(seller);
        game.fold(id);
        vm.prank(seller);
        game.claimTurnTimeout(id);
    }

    /*══════════════════════ claimEscalationTimeout ══════════════════════*/

    function test_escalationTimeout_refundsBuyerNoFee() public {
        bytes32 id = _toAwaiting(AMOUNT);
        uint256 delta = uint256(_dsp(id).disputedDelta);
        Snap memory pre = _snap();

        vm.warp(uint256(_esc(id).escalationDeadline) + 1);
        vm.prank(seller); // either party may trigger
        game.claimEscalationTimeout(id);

        Snap memory post = _snap();
        assertEq(post.b - pre.b, delta);
        assertEq(post.t, pre.t, "no fee on timeout refund");
        assertEq(post.i, pre.i);
        assertEq(post.s, pre.s);
        assertEq(uint256(_dsp(id).disputedDelta), 0);
        _assertState(id, S_RESOLVED);
        _assertConserved(id);
        _assertDead(id);
    }

    function test_escalationTimeout_boundaryAndGates() public {
        bytes32 id = _toAwaiting(AMOUNT);
        uint256 dl = uint256(_esc(id).escalationDeadline);

        vm.warp(dl); // inclusive window still open
        vm.expectRevert(Liars_Game.EscalationWindowOpen.selector);
        vm.prank(buyer);
        game.claimEscalationTimeout(id);

        vm.warp(dl + 1);
        vm.expectRevert(Liars_Game.NotAParty.selector);
        vm.prank(stranger);
        game.claimEscalationTimeout(id);

        vm.prank(buyer);
        game.claimEscalationTimeout(id);
    }

    function test_escalationTimeout_revert_wrongState() public {
        bytes32 id = _toAwaiting(AMOUNT);
        _open(id, buyer);
        vm.warp(block.timestamp + 365 days);
        vm.expectRevert(Liars_Game.WrongState.selector);
        vm.prank(buyer);
        game.claimEscalationTimeout(id);
    }

    function test_escalationTimeout_racesWithOpen() public {
        // after the window closes openDispute is dead, timeout is the only exit
        bytes32 id = _toAwaiting(AMOUNT);
        vm.warp(uint256(_esc(id).escalationDeadline) + 1);
        vm.expectRevert(Liars_Game.EscalationWindowExpired.selector);
        vm.prank(buyer);
        game.openDispute(id);
        vm.prank(seller);
        game.claimEscalationTimeout(id);
        _assertState(id, S_RESOLVED);
    }

    /*══════════════════════ collateral routing ══════════════════════*/

    function test_routing_defenderWins_turn2() public {
        bytes32 id = _toAwaiting(AMOUNT);
        _playTo(id, buyer, 2); // lastActor seller (defender)
        Liars_Game.Dispute memory d = _dsp(id);
        Snap memory pre = _snap();
        vm.prank(buyer);
        game.fold(id);
        _assertResolution(pre, seller, d);
        _assertConserved(id);
    }

    function test_routing_challengerWins_turn5() public {
        bytes32 id = _toAwaiting(AMOUNT);
        _playTo(id, seller, 5); // lastActor seller (challenger on odd turns)
        Liars_Game.Dispute memory d = _dsp(id);
        Snap memory pre = _snap();
        vm.prank(buyer);
        game.fold(id);
        _assertResolution(pre, seller, d);
        _assertConserved(id);
    }

    function test_routing_loserCollateralAlwaysToTreasury() public {
        bytes32 id = _toAwaiting(AMOUNT);
        _playTo(id, buyer, 4); // lastActor seller
        Liars_Game.Dispute memory d = _dsp(id);
        uint256 treasuryBefore = _pending(treasury);
        vm.prank(buyer);
        game.fold(id);
        uint256 fee = _fee(uint256(d.disputedDelta));
        assertEq(_pending(treasury) - treasuryBefore, uint256(d.buyerCollateral) + _tCut(fee));
    }

    function test_routing_postHorizon_challengerWinsTurn11() public {
        bytes32 id = _toAwaiting(AMOUNT);
        _playTo(id, buyer, 11); // buyer = challenger, last actor
        Liars_Game.Dispute memory d = _dsp(id);
        assertEq(d.lastActor, buyer);
        assertTrue(game.isPostHorizon(id));
        Snap memory pre = _snap();

        vm.prank(seller);
        game.fold(id);

        uint256 total = uint256(d.disputedDelta) * 4150 / 10000;
        uint256 rem = uint256(d.buyerCollateral) > total ? uint256(d.buyerCollateral) - total : 0;
        Snap memory post = _snap();
        assertEq(post.b - pre.b, total + uint256(d.disputedDelta), "buyer: horizon share + delta refund");
        assertEq(post.t - pre.t, rem + uint256(d.sellerCollateral), "treasury: post-horizon remainder + loser");
        _assertConserved(id);
    }

   function test_routing_postHorizon_defenderWinsTurn12() public {
    bytes32 id = _toAwaiting(AMOUNT);
    _playTo(id, buyer, 12); // lastActor seller (defender)
    Liars_Game.Dispute memory d = _dsp(id);
    assertEq(d.lastActor, seller);
    Snap memory pre = _snap();

    vm.prank(buyer);
    game.fold(id);

    uint256 delta = uint256(d.disputedDelta);
    uint256 sColl = uint256(d.sellerCollateral);
    uint256 total = _cap(delta, false, true); // seller's scaled cap
    if (total > sColl) total = sColl;         // the contract never credits more than was deposited
    uint256 rem = sColl - total;
    uint256 fee = _fee(delta);
    Snap memory post = _snap();
    assertEq(post.s - pre.s, total + delta - fee);
    assertEq(post.t - pre.t, rem + uint256(d.buyerCollateral) + _tCut(fee));
    _assertConserved(id);
}

    /// FINDING (expected to FAIL against the current spec/impl):
    /// isPostHorizon() flips at currentTurn > EVENT_HORIZON_TURN (5), but _routeCollateral only applies the
    /// horizon split when the WINNER's own turn count (ceil(currentTurn/2)) exceeds 5, i.e. currentTurn >= 11.
    /// For currentTurn 6..10 the winner recovers collateral deposited after the event horizon.
    function test_FINDING_collateralPastHorizonRecoveredBetweenTurns6And10() public {
        bytes32 id = _toAwaiting(AMOUNT);
        _playTo(id, buyer, 7);
        assertTrue(game.isPostHorizon(id), "turn 7 is past the event horizon");
        Liars_Game.Dispute memory d = _dsp(id);
        Snap memory pre = _snap();

        vm.prank(seller);
        game.fold(id); // buyer wins

        uint256 collateralBack = (_pending(buyer) - pre.b) - uint256(d.disputedDelta);
        uint256 allowedByHorizon = uint256(d.disputedDelta) * 4150 / 10000;
        assertLe(collateralBack, allowedByHorizon, "winner recovered post-horizon collateral");
    }

    /*══════════════════════ fuzz: full dispute lifecycle ══════════════════════*/

    function testFuzz_dispute_lifecycle(uint256 amount, bool buyerOpens, uint256 turns, bool viaFold) public {
        amount = bound(amount, 1e6, 1e27);
        turns = bound(turns, 1, horizon);  // pre-horizon routing (winner turns <= 5)
        address opener = buyerOpens ? buyer : seller;

        bytes32 id = _toAwaiting(amount);
        _playTo(id, opener, turns);

        Liars_Game.Dispute memory d = _dsp(id);
        address expectedLast = turns % 2 == 1 ? opener : _other(opener);
        assertEq(d.lastActor, expectedLast, "alternation broken");
        assertEq(uint256(d.currentTurn), turns);
        _assertConserved(id);

        Snap memory pre = _snap();
        if (viaFold) {
            vm.prank(_other(expectedLast));
            game.fold(id);
        } else {
            vm.warp(uint256(d.turnDeadline) + 1);
            vm.prank(buyerOpens ? seller : buyer);
            game.claimTurnTimeout(id);
        }

        _assertState(id, S_RESOLVED);
        _assertResolution(pre, expectedLast, d);
        _assertConserved(id);

        Liars_Game.Dispute memory post = _dsp(id);
        assertEq(uint256(post.buyerCollateral), 0);
        assertEq(uint256(post.sellerCollateral), 0);
        assertEq(uint256(post.disputedDelta), 0);
    }

    function testFuzz_dispute_longGamesStaySolvent(uint256 amount, bool buyerOpens, uint256 turns) public {
        amount = bound(amount, 1e6, 1e24);
        turns = bound(turns, horizon + 1, 16);
        bytes32 id = _toAwaiting(amount);
        _playTo(id, buyerOpens ? buyer : seller, turns);
        _assertConserved(id);

        address last = _dsp(id).lastActor;
        vm.prank(_other(last));
        game.fold(id);
        _assertState(id, S_RESOLVED);
        _assertConserved(id); // would catch the winner being credited more than was deposited
    }

    
 function testFuzz_winnerNeverRecoversPastHorizonCollateral(uint256 amount, bool buyerOpens, uint256 turns) public {
    amount = bound(amount, 1e6, 1e24);
    turns = bound(turns, horizon + 1, 16);
    address opener = buyerOpens ? buyer : seller;

    bytes32 id = _toAwaiting(amount);
    _playTo(id, opener, turns);

    Liars_Game.Dispute memory d = _dsp(id);
    address winner = d.lastActor;
    uint256 delta = uint256(d.disputedDelta);
    uint256 winnerColl = winner == buyer ? uint256(d.buyerCollateral) : uint256(d.sellerCollateral);
    uint256 cap = _cap(delta, turns % 2 == 1, winner == seller);

    Snap memory pre = _snap();
    vm.prank(_other(winner));
    game.fold(id);
    Snap memory post = _snap();

    uint256 credited = winner == buyer
        ? post.b - pre.b - delta
        : post.s - pre.s - (delta - _fee(delta));

    assertLe(credited, cap, "winner recovered more than the horizon cap");
    assertLe(credited, winnerColl, "winner recovered more than they deposited");
    _assertConserved(id);
}   

    function testFuzz_dispute_tinyDeltaStaysSolvent(uint256 amount, uint256 turns, bool buyerOpens) public {
        amount = bound(amount, 4, 5_000); // rounding-dominated amounts
        turns = bound(turns, 1, 14);
        bytes32 id = _createSubmitted(amount);
        uint256 portion = amount * 5000 / 10000;
        if (_net(portion) == 0) return;
        vm.prank(buyer);
        game.settlePartial(id, 5000);
        vm.warp(uint256(_esc(id).settlementFinalizedTime));
        vm.prank(buyer);
        game.finalizeSettlementPartial(id);

        _playTo(id, buyerOpens ? buyer : seller, turns);
        vm.prank(_other(_dsp(id).lastActor));
        game.fold(id);
        _assertConserved(id);
    }

    /*══════════════════════ cancelEscrow ══════════════════════*/

    function test_cancel_refundsInFull() public {
        bytes32 id = _create();
        vm.prank(buyer);
        game.cancelEscrow(id);

        assertEq(_pending(buyer), AMOUNT);
        assertEq(_pending(treasury), 0);
        assertEq(uint256(_esc(id).escrowAmount), 0);
        _assertState(id, S_CANCELLED);
        _assertConserved(id);
        _assertDead(id);
    }

    function test_cancel_anytimeBeforeSubmission_evenAfterLifetime() public {
        bytes32 id = _create();
        vm.warp(uint256(_esc(id).lifetime) + 100 days);
        vm.prank(buyer);
        game.cancelEscrow(id);
        assertEq(_pending(buyer), AMOUNT);
    }

    function test_cancel_revert_notBuyer() public {
        bytes32 id = _create();
        vm.expectRevert(Liars_Game.NotAuthorised.selector);
        vm.prank(seller);
        game.cancelEscrow(id);
        vm.expectRevert(Liars_Game.NotAuthorised.selector);
        vm.prank(stranger);
        game.cancelEscrow(id);
    }

    function test_cancel_revert_onceSubmitted() public {
        bytes32 id = _createSubmitted(AMOUNT);
        vm.expectRevert(Liars_Game.WrongState.selector);
        vm.prank(buyer);
        game.cancelEscrow(id);
    }

    function test_cancel_cannotCancelTwice() public {
        bytes32 id = _create();
        vm.prank(buyer);
        game.cancelEscrow(id);
        vm.expectRevert(Liars_Game.WrongState.selector);
        vm.prank(buyer);
        game.cancelEscrow(id);
    }

    function test_cancel_doesNotAffectSiblingEscrows() public {
        bytes32 a = _create();
        bytes32 b = _create();
        vm.prank(buyer);
        game.cancelEscrow(a);
        _assertState(b, S_CREATED);
        assertEq(uint256(_esc(b).escrowAmount), AMOUNT);
        assertEq(token.balanceOf(address(game)), 2 * AMOUNT);
    }

    /*══════════════════════ withdraw ══════════════════════*/

    function test_withdraw_happy() public {
        bytes32 id = _createSubmitted(AMOUNT);
        vm.warp(uint256(_esc(id).evaluationDeadline) + 1);
        vm.prank(seller);
        game.claimDefault(id);

        uint256 owed = _pending(seller);
        uint256 balBefore = token.balanceOf(seller);

        vm.expectEmit(true, true, true, true);
        emit Liars_Game.Withdrawn(seller, address(token), owed);
        vm.prank(seller);
        game.withdraw(address(token));

        assertEq(token.balanceOf(seller), balBefore + owed);
        assertEq(_pending(seller), 0);
        _assertConserved(id);
    }

    function test_withdraw_everyoneCanDrainAndGameEndsEmpty() public {
        bytes32 id = _createSubmitted(AMOUNT);
        vm.warp(uint256(_esc(id).evaluationDeadline) + 1);
        vm.prank(seller);
        game.claimDefault(id);

        vm.prank(seller);
        game.withdraw(address(token));
        vm.prank(treasury);
        game.withdraw(address(token));
        vm.prank(integrator);
        game.withdraw(address(token));

        assertEq(token.balanceOf(address(game)), 0, "dust left behind / value leaked");
    }

    function test_withdraw_revert_nothingOwed() public {
        vm.expectRevert(Liars_Game.NothingToWithdraw.selector);
        vm.prank(stranger);
        game.withdraw(address(token));
    }

    function test_withdraw_revert_doubleWithdraw() public {
        bytes32 id = _create();
        vm.prank(buyer);
        game.cancelEscrow(id);
        vm.prank(buyer);
        game.withdraw(address(token));
        vm.expectRevert(Liars_Game.NothingToWithdraw.selector);
        vm.prank(buyer);
        game.withdraw(address(token));
    }

    function test_withdraw_isPerToken() public {
        bytes32 id = _create();
        vm.prank(buyer);
        game.cancelEscrow(id);
        vm.expectRevert(Liars_Game.NothingToWithdraw.selector);
        vm.prank(buyer);
        game.withdraw(address(token2));
    }

    function test_withdraw_worksAfterTokenDelisted() public {
        bytes32 id = _create();
        vm.prank(buyer);
        game.cancelEscrow(id);
        game.removeApprovedToken(address(token));
        vm.prank(buyer);
        game.withdraw(address(token)); // delisting must never trap funds
        assertEq(_pending(buyer), 0);
    }

    function test_withdraw_otherUsersBalanceUntouched() public {
        bytes32 id = _createSubmitted(AMOUNT);
        vm.warp(uint256(_esc(id).evaluationDeadline) + 1);
        vm.prank(seller);
        game.claimDefault(id);
        uint256 treasuryOwed = _pending(treasury);
        vm.prank(seller);
        game.withdraw(address(token));
        assertEq(_pending(treasury), treasuryOwed);
    }

    function testFuzz_withdraw_conservation(uint256 amount) public {
        amount = bound(amount, 1, 1e30);
        bytes32 id = _createSubmitted(amount);
        vm.warp(uint256(_esc(id).evaluationDeadline) + 1);
        vm.prank(seller);
        game.claimDefault(id);

        address[3] memory who = [seller, treasury, integrator];
        uint256 totalOut;
        for (uint256 i; i < who.length; i++) {
            uint256 owed = _pending(who[i]);
            if (owed == 0) {
                vm.expectRevert(Liars_Game.NothingToWithdraw.selector);
                vm.prank(who[i]);
                game.withdraw(address(token));
            } else {
                vm.prank(who[i]);
                game.withdraw(address(token));
                totalOut += owed;
            }
        }
        assertEq(totalOut, amount);
        assertEq(token.balanceOf(address(game)), 0);
    }

    /*══════════════════════ admin ══════════════════════*/

    function test_setTreasury_gates() public {
        vm.expectRevert(Liars_Game.NotAuthorised.selector);
        vm.prank(stranger);
        game.setTreasury(stranger);

        vm.expectRevert(Liars_Game.ZeroAddress.selector);
        game.setTreasury(address(0));
    }

    function test_setTreasury_isLivePointer() public {
        address newTreasury = makeAddr("newTreasury");
        bytes32 id = _createSubmitted(AMOUNT); // created while the old treasury was set
        game.setTreasury(newTreasury);

        vm.warp(uint256(_esc(id).evaluationDeadline) + 1);
        vm.prank(seller);
        game.claimDefault(id);

        uint256 fee = _fee(AMOUNT);
        assertEq(game.pendingWithdrawal(newTreasury, address(token)), _tCut(fee));
        assertEq(_pending(treasury), 0, "old treasury must not get fees from before the switch");
    }

    function test_setTreasury_oldTreasuryKeepsAccruedBalance() public {
        bytes32 id = _createSubmitted(AMOUNT);
        vm.warp(uint256(_esc(id).evaluationDeadline) + 1);
        vm.prank(seller);
        game.claimDefault(id);
        uint256 accrued = _pending(treasury);
        game.setTreasury(makeAddr("newTreasury"));
        assertEq(_pending(treasury), accrued);
        vm.prank(treasury);
        game.withdraw(address(token));
    }

    function test_whitelist_addGates() public {
        vm.expectRevert(Liars_Game.NotAuthorised.selector);
        vm.prank(stranger);
        game.addApprovedToken(address(token2));

        vm.expectRevert(Liars_Game.ZeroAddress.selector);
        game.addApprovedToken(address(0));

        vm.expectRevert(Liars_Game.AlreadyApproved.selector);
        game.addApprovedToken(address(token));
    }

    function test_whitelist_removeGates() public {
        vm.expectRevert(Liars_Game.NotAuthorised.selector);
        vm.prank(stranger);
        game.removeApprovedToken(address(token));

        vm.expectRevert(Liars_Game.NotApproved.selector);
        game.removeApprovedToken(address(token2));
    }

    function test_whitelist_removeThenReAdd() public {
        game.removeApprovedToken(address(token));
        vm.expectRevert(Liars_Game.NotApproved.selector);
        game.removeApprovedToken(address(token)); // already removed
        game.addApprovedToken(address(token));
        _create(); // works again
    }

    function test_whitelist_delistingDoesNotBreakLiveEscrows() public {
        bytes32 id = _createSubmitted(AMOUNT);
        game.removeApprovedToken(address(token));
        vm.warp(uint256(_esc(id).evaluationDeadline) + 1);
        vm.prank(seller);
        game.claimDefault(id);
        vm.prank(seller);
        game.withdraw(address(token));
        _assertState(id, S_RESOLVED);
    }

    /*══════════════════════ views ══════════════════════*/

    function test_view_secondsRemaining_everyState() public {
        bytes32 id = _create();
        assertEq(game.secondsRemaining(id), uint256(_esc(id).lifetime) - block.timestamp);

        vm.prank(seller);
        game.submitWork(id, "x");
        assertEq(game.secondsRemaining(id), defaultEW);

        vm.prank(buyer);
        game.settlePartial(id, 5000);
        assertEq(game.secondsRemaining(id), settleWin);

        vm.warp(uint256(_esc(id).settlementFinalizedTime));
        vm.prank(buyer);
        game.finalizeSettlementPartial(id);
        assertEq(game.secondsRemaining(id), escWin);

        _open(id, buyer);
        assertEq(game.secondsRemaining(id), turnWin);

        vm.prank(seller);
        game.fold(id);
        assertEq(game.secondsRemaining(id), 0, "RESOLVED");
    }

    function test_view_secondsRemaining_cancelledIsZero() public {
        bytes32 id = _create();
        vm.prank(buyer);
        game.cancelEscrow(id);
        assertEq(game.secondsRemaining(id), 0);
    }


    function testFuzz_rejected_endToEnd(uint256 amount, bool sellerOpens, uint256 turns, bool viaFold) public {
        amount = bound(amount, 1, 1e27);
        turns = bound(turns, 1, 12);
        bytes32 id = _toRejected(amount, block.timestamp + 365 days);
        _playTo(id, sellerOpens ? seller : buyer, turns);
        _assertConserved(id);

        address last = _dsp(id).lastActor;
        if (viaFold) {
            vm.prank(_other(last));
            game.fold(id);
        } else {
            vm.warp(uint256(_dsp(id).turnDeadline) + 1);
            vm.prank(buyer);
            game.claimTurnTimeout(id);
        }
        _assertConserved(id); // covers reset, cancel and seller-win outcomes
    }

    function testFuzz_view_secondsRemaining_neverUnderflows(uint256 dt) public {
        bytes32 id = _createSubmitted(AMOUNT);
        dt = bound(dt, 0, 3650 days);
        uint256 dl = uint256(_esc(id).evaluationDeadline);
        vm.warp(block.timestamp + dt);
        uint256 expected = block.timestamp >= dl ? 0 : dl - block.timestamp;
        assertEq(game.secondsRemaining(id), expected);
    }

    function test_view_requiredBond() public {
    bytes32 id = _create();
    assertEq(game.requiredBondFor(id, buyer), 0, "CREATED -> 0");
    assertEq(game.requiredBondFor(id, seller), 0, "CREATED -> 0");

    id = _toAwaiting(AMOUNT);
    uint256 delta = uint256(_dsp(id).disputedDelta);
    assertGt(game.requiredBondFor(id, buyer), 0, "AWAITING_ESCALATION quotes the turn-1 bond");
    assertEq(game.requiredBondFor(id, buyer), _bond(delta, 1, false));
    assertEq(game.requiredBondFor(id, seller), _bond(delta, 1, true));

    _open(id, buyer);
    assertEq(game.requiredBondFor(id, seller), _bond(delta, 2, true), "ESCALATION quotes the next turn");

    vm.prank(seller);
    game.fold(id);
    assertEq(game.requiredBondFor(id, buyer), 0, "RESOLVED -> 0");
    assertEq(game.requiredBondFor(id, seller), 0, "RESOLVED -> 0");
}

    function test_view_isPostHorizon_tracksTurnCounter() public {
        bytes32 id = _toAwaiting(AMOUNT);
        assertFalse(game.isPostHorizon(id));
        _open(id, buyer);
        address cur = seller;
        for (uint256 t = 2; t <= horizon + 2; t++) {
            _advance(id, cur);
            cur = _other(cur);
            assertEq(game.isPostHorizon(id), t > horizon, "horizon flag");
        }
    }

    function test_view_pendingWithdrawalDefaultsToZero() public {
        assertEq(game.pendingWithdrawal(stranger, address(token)), 0);
        assertEq(game.pendingWithdrawal(address(0), address(0)), 0);
    }

    /*══════════════════════ non-existent / adversarial ══════════════════════*/

    function testFuzz_unknownEscrowId_everyMutatorReverts(bytes32 id, address caller) public {
        vm.assume(caller != address(0));
        bytes[] memory calls = new bytes[](12);
        calls[0] = abi.encodeWithSignature("submitWork(bytes32,string)", id, "x");
        calls[1] = abi.encodeWithSignature("settlePartial(bytes32,uint16)", id, uint16(5000));
        calls[2] = abi.encodeWithSignature("finalizeSettlementFull(bytes32)", id);
        calls[3] = abi.encodeWithSignature("finalizeSettlementRejected(bytes32)", id);
        calls[4] = abi.encodeWithSignature("finalizeSettlementPartial(bytes32)", id);
        calls[5] = abi.encodeWithSignature("openDispute(bytes32)", id);
        calls[6] = abi.encodeWithSignature("advanceTurn(bytes32)", id);
        calls[7] = abi.encodeWithSignature("fold(bytes32)", id);
        calls[8] = abi.encodeWithSignature("claimDefault(bytes32)", id);
        calls[9] = abi.encodeWithSignature("claimEscalationTimeout(bytes32)", id);
        calls[10] = abi.encodeWithSignature("claimTurnTimeout(bytes32)", id);
        calls[11] = abi.encodeWithSignature("cancelEscrow(bytes32)", id);

        for (uint256 k; k < calls.length; k++) {
            vm.prank(caller);
            (bool ok,) = address(game).call(calls[k]);
            assertFalse(ok, "mutator succeeded on an escrow that does not exist");
        }
    }

  function testFuzz_unknownEscrowId_viewsReturnZero(bytes32 id, address who) public {
    assertEq(game.requiredBondFor(id, who), 0);
    assertFalse(game.isPostHorizon(id));
    assertEq(uint256(_esc(id).escrowAmount), 0);
    assertEq(_esc(id).buyer, address(0));
}

    /// A stranger can never move an escrow through any stage of its life.
    function testFuzz_stranger_cannotDriveAnyStage(address caller) public {
        vm.assume(caller != buyer && caller != seller && caller != address(0));

        bytes32 id = _create();
        vm.startPrank(caller);
        vm.expectRevert(Liars_Game.NotAuthorised.selector);
        game.submitWork(id, "x");
        vm.expectRevert(Liars_Game.NotAuthorised.selector);
        game.cancelEscrow(id);
        vm.stopPrank();

        vm.prank(seller);
        game.submitWork(id, "x");
        vm.startPrank(caller);
        vm.expectRevert(Liars_Game.NotAuthorised.selector);
        game.settlePartial(id, 5000);
        vm.expectRevert(Liars_Game.NotAuthorised.selector);
        game.claimDefault(id);
        vm.stopPrank();

        vm.prank(buyer);
        game.settlePartial(id, 5000);
        vm.warp(uint256(_esc(id).settlementFinalizedTime));
        vm.startPrank(caller);
        vm.expectRevert(Liars_Game.NotAParty.selector);
        game.finalizeSettlementFull(id);
        vm.expectRevert(Liars_Game.NotAParty.selector);
        game.finalizeSettlementPartial(id);
        vm.expectRevert(Liars_Game.NotAuthorised.selector);
        game.finalizeSettlementRejected(id);
        vm.stopPrank();

        vm.prank(buyer);
        game.finalizeSettlementPartial(id);
        vm.startPrank(caller);
        vm.expectRevert(Liars_Game.NotAParty.selector);
        game.openDispute(id);
        vm.expectRevert(Liars_Game.NotAParty.selector);
        game.claimEscalationTimeout(id);
        vm.stopPrank();
    }

    function testFuzz_stranger_cannotDriveEscalation(address caller) public {
        vm.assume(caller != buyer && caller != seller && caller != address(0));
        bytes32 id = _toAwaiting(AMOUNT);
        vm.prank(caller);
        vm.expectRevert(Liars_Game.NotAParty.selector);
        game.claimEscalationTimeout(id);

        _open(id, buyer);
        vm.startPrank(caller);
        vm.expectRevert(Liars_Game.NotAParty.selector);
        game.advanceTurn(id);
        vm.expectRevert(Liars_Game.NotAParty.selector);
        game.fold(id);
        vm.expectRevert(Liars_Game.NotAParty.selector);
        game.claimTurnTimeout(id);
        vm.stopPrank();
    }

    function test_terminal_matrix_afterDefault() public {
        bytes32 id = _createSubmitted(AMOUNT);
        vm.warp(uint256(_esc(id).evaluationDeadline) + 1);
        vm.prank(seller);
        game.claimDefault(id);
        _assertDead(id);
    }

    function test_terminal_matrix_afterFullSettlement() public {
        bytes32 id = _toPartial(AMOUNT, 10000);
        vm.warp(uint256(_esc(id).settlementFinalizedTime));
        vm.prank(buyer);
        game.finalizeSettlementFull(id);
        _assertDead(id);
    }

    function test_terminal_matrix_afterTurnTimeout() public {
        bytes32 id = _toAwaiting(AMOUNT);
        _open(id, buyer);
        vm.warp(block.timestamp + turnWin + 1);
        vm.prank(seller);
        game.claimTurnTimeout(id);
        _assertDead(id);
    }

    function test_stateMachine_noSkippingStages() public {
        bytes32 id = _create();
        // CREATED: only submitWork / cancelEscrow are legal
        vm.expectRevert(Liars_Game.WrongState.selector);
        vm.prank(buyer);
        game.settlePartial(id, 5000);
        vm.expectRevert(Liars_Game.WrongState.selector);
        vm.prank(buyer);
        game.openDispute(id);
        vm.expectRevert(Liars_Game.WrongState.selector);
        vm.prank(buyer);
        game.finalizeSettlementFull(id);
        vm.expectRevert(Liars_Game.WrongState.selector);
        vm.prank(buyer);
        game.claimEscalationTimeout(id);
        vm.expectRevert(Liars_Game.WrongState.selector);
        vm.prank(buyer);
        game.advanceTurn(id);
        vm.expectRevert(Liars_Game.WrongState.selector);
        vm.prank(buyer);
        game.fold(id);
        vm.expectRevert(Liars_Game.WrongState.selector);
        vm.prank(buyer);
        game.claimTurnTimeout(id);
    }

    function test_multipleEscrows_isolated() public {
        bytes32 a = _createSubmitted(AMOUNT);
        bytes32 b = _createSubmitted(AMOUNT / 2);

        vm.warp(uint256(_esc(a).evaluationDeadline) + 1);
        vm.prank(seller);
        game.claimDefault(a);

        _assertState(a, S_RESOLVED);
        _assertState(b, S_SUBMITTED);
        assertEq(uint256(_esc(b).escrowAmount), AMOUNT / 2);
        assertEq(token.balanceOf(address(game)), AMOUNT + AMOUNT / 2);
    }
}

/*//////////////////////////////////////////////////////////////
                  STATEFUL INVARIANT HARNESS
//////////////////////////////////////////////////////////////*/

contract Handler is Test {
    Liars_Game public game;
    MockERC20 public token;
    address[] internal actors;
    address public integrator;
    address public treasury;
    bytes32[] internal ids;
    uint256 internal minEW;
    uint256 internal maxEW;

    constructor(Liars_Game g, MockERC20 t, address[] memory a, address integ, address tre) {
        game = g;
        token = t;
        actors = a;
        integrator = integ;
        treasury = tre;
        minEW = uint256(g.MIN_EVALUATION_WINDOW());
        maxEW = uint256(g.MAX_EVALUATION_WINDOW());
    }

    function idsLength() external view returns (uint256) {
        return ids.length;
    }

    function idAt(uint256 i) external view returns (bytes32) {
        return ids[i];
    }

    function allAccounts() external view returns (address[] memory out) {
        out = new address[](actors.length + 2);
        for (uint256 i; i < actors.length; i++) out[i] = actors[i];
        out[actors.length] = integrator;
        out[actors.length + 1] = treasury;
    }

    function _a(uint256 s) internal view returns (address) {
        return actors[s % actors.length];
    }

    function _id(uint256 s) internal view returns (bytes32) {
        return ids[s % ids.length];
    }

    function create(uint256 bs, uint256 ss, uint256 amt, uint256 ew) external {
        if (ids.length >= 6) return;
        amt = bound(amt, 1, 1e24);
        ew = bound(ew, minEW, _min(maxEW, 365 days));
        vm.prank(_a(bs));
        try game.createEscrow(
            _a(ss), integrator, address(token), amt, uint32(ew), uint32(block.timestamp + ew + 30 days)
        ) returns (bytes32 id) {
            ids.push(id);
        } catch {}
    }

    function submit(uint256 s) external {
        if (ids.length == 0) return;
        bytes32 id = _id(s);
        vm.prank(game.getEscrow(id).seller);
        try game.submitWork(id, "w") {} catch {}
    }

    function settle(uint256 s, uint16 alpha) external {
        if (ids.length == 0) return;
        bytes32 id = _id(s);
        alpha = uint16(bound(alpha, 0, 10000));
        vm.prank(game.getEscrow(id).buyer);
        try game.settlePartial(id, alpha) {} catch {}
    }

    function finalizeFull(uint256 s, uint256 who) external {
        if (ids.length == 0) return;
        vm.prank(_a(who));
        try game.finalizeSettlementFull(_id(s)) {} catch {}
    }

    function finalizePartial(uint256 s, uint256 who) external {
        if (ids.length == 0) return;
        vm.prank(_a(who));
        try game.finalizeSettlementPartial(_id(s)) {} catch {}
    }

    function finalizeRejected(uint256 s) external {
        if (ids.length == 0) return;
        bytes32 id = _id(s);
        vm.prank(game.getEscrow(id).buyer);
        try game.finalizeSettlementRejected(id) {} catch {}
    }

    function claimDefault(uint256 s) external {
        if (ids.length == 0) return;
        bytes32 id = _id(s);
        vm.prank(game.getEscrow(id).seller);
        try game.claimDefault(id) {} catch {}
    }

    function cancel(uint256 s) external {
        if (ids.length == 0) return;
        bytes32 id = _id(s);
        vm.prank(game.getEscrow(id).buyer);
        try game.cancelEscrow(id) {} catch {}
    }

    function open(uint256 s, uint256 who) external {
        if (ids.length == 0) return;
        vm.prank(_a(who));
        try game.openDispute(_id(s)) {} catch {}
    }

    function advance(uint256 s, uint256 who) external {
        if (ids.length == 0) return;
        vm.prank(_a(who));
        try game.advanceTurn(_id(s)) {} catch {}
    }

    function fold(uint256 s, uint256 who) external {
        if (ids.length == 0) return;
        vm.prank(_a(who));
        try game.fold(_id(s)) {} catch {}
    }

    function turnTimeout(uint256 s, uint256 who) external {
        if (ids.length == 0) return;
        vm.prank(_a(who));
        try game.claimTurnTimeout(_id(s)) {} catch {}
    }

    function escalationTimeout(uint256 s, uint256 who) external {
        if (ids.length == 0) return;
        vm.prank(_a(who));
        try game.claimEscalationTimeout(_id(s)) {} catch {}
    }

    function withdraw(uint256 who) external {
        uint256 k = who % (actors.length + 2);
        address w = k < actors.length ? actors[k] : (k == actors.length ? integrator : treasury);
        vm.prank(w);
        try game.withdraw(address(token)) {} catch {}
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 3 days));
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}

contract LiarsGame_Invariant is Base {
    Handler internal handler;

    function setUp() public override {
        super.setUp();
        address[] memory acts = new address[](3);
        acts[0] = buyer;
        acts[1] = seller;
        acts[2] = stranger;
        handler = new Handler(game, token, acts, integrator, treasury);
        targetContract(address(handler));
    }

    /// Every token held by the game is either locked inside an escrow/dispute or owed in pendingWithdrawals.
    function invariant_solvency() public {
        address[] memory accts = handler.allAccounts();
        uint256 owed;
        for (uint256 i; i < accts.length; i++) {
            owed += game.pendingWithdrawal(accts[i], address(token));
        }
        uint256 n = handler.idsLength();
        for (uint256 i; i < n; i++) {
            Liars_Game.Escrow memory e = game.getEscrow(handler.idAt(i));
            owed += uint256(e.escrowAmount) + uint256(e.dispute.disputedDelta) + uint256(e.dispute.buyerCollateral)
                + uint256(e.dispute.sellerCollateral);
        }
        assertEq(token.balanceOf(address(game)), owed, "game balance != locked + owed");
    }

    /// RESOLVED / CANCELLED escrows must hold nothing.
    function invariant_terminalEscrowsHoldNothing() public {
        uint256 n = handler.idsLength();
        for (uint256 i; i < n; i++) {
            Liars_Game.Escrow memory e = game.getEscrow(handler.idAt(i));
            if (e.state == S_RESOLVED || e.state == S_CANCELLED) {
                assertEq(uint256(e.escrowAmount), 0, "terminal escrowAmount");
                assertEq(uint256(e.dispute.disputedDelta), 0, "terminal disputedDelta");
                assertEq(uint256(e.dispute.buyerCollateral), 0, "terminal buyerCollateral");
                assertEq(uint256(e.dispute.sellerCollateral), 0, "terminal sellerCollateral");
            }
        }
    }

    /// Identity fields never change after creation and buyer != seller always.
    function invariant_partiesDistinct() public {
        uint256 n = handler.idsLength();
        for (uint256 i; i < n; i++) {
            Liars_Game.Escrow memory e = game.getEscrow(handler.idAt(i));
            assertTrue(e.buyer != e.seller, "buyer == seller");
            assertTrue(e.buyer != address(0) && e.seller != address(0), "zero party");
        }
    }
}
