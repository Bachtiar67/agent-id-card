// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../contracts/AgentIDCard.sol";
import "./MockAgentID.sol";

contract AgentIDCardTest is Test {
    AgentIDCard public card;
    MockAgentID public mock; // etched at the real Agent ID address

    address public constant AGENT_ID_ADDR = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;

    address public alice = makeAddr("alice"); // Agent ID holder
    address public bob = makeAddr("bob"); // no Agent ID
    address public carol = makeAddr("carol"); // Agent ID holder

    event CardMinted(address indexed owner, uint256 indexed tokenId, string bio);
    event CheckedIn(address indexed owner, uint256 indexed tokenId, uint256 streak, uint256 level);
    event ProfileUpdated(address indexed owner, uint256 indexed tokenId);
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);

    function setUp() public {
        // Realistic mainnet-like timestamp (~Nov 2026) so day math is sane.
        vm.warp(1_795_000_000);
        mock = new MockAgentID();
        // Place the mock's code at the real Agent ID address so the card's
        // hardcoded AGENT_ID constant points at controllable code.
        vm.etch(AGENT_ID_ADDR, address(mock).code);
        mock = MockAgentID(AGENT_ID_ADDR);
        mock.setBalance(alice, 1);
        mock.setBalance(carol, 1);
        // bob intentionally has 0
        card = new AgentIDCard();
    }

    // ------------------------------------------------------------------------
    // Constants / metadata
    // ------------------------------------------------------------------------
    function testConstants() public view {
        assertEq(card.name(), "Agent ID Card");
        assertEq(card.symbol(), "AIDC");
        assertEq(card.MAX_SUPPLY(), 1000);
        assertEq(card.AGENT_ID(), AGENT_ID_ADDR);
        assertEq(card.totalMinted(), 0);
    }

    function testSupportsInterface() public view {
        assertTrue(card.supportsInterface(0x01ffc9a7)); // ERC165
        assertTrue(card.supportsInterface(0x80ac58cd)); // ERC721
        assertTrue(card.supportsInterface(0x5b5e139f)); // ERC721Metadata
        assertFalse(card.supportsInterface(0x12345678));
    }

    // ------------------------------------------------------------------------
    // (1) mint sukses oleh pemegang Agent ID
    // ------------------------------------------------------------------------
    function testMintSuccess() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), alice, 1);
        vm.expectEmit(true, true, false, true);
        emit CardMinted(alice, 1, "Builder dari Indonesia");

        vm.prank(alice);
        card.mint("Builder dari Indonesia", "https://x.com/alice");

        assertEq(card.totalMinted(), 1);
        assertEq(card.ownerOf(1), alice);
        assertEq(card.balanceOf(alice), 1);
        assertEq(card.tokenOfOwner(alice), 1);
        assertTrue(card.hasMinted(alice));

        (string memory bio, string memory link, uint256 tokenId, uint256 streak, uint256 level, uint256 lastDay) =
            card.profileOf(alice);
        assertEq(bio, "Builder dari Indonesia");
        assertEq(link, "https://x.com/alice");
        assertEq(tokenId, 1);
        assertEq(streak, 0);
        assertEq(level, 1);
        assertEq(lastDay, 0);
    }

    function testMintEmptyBioLink() public {
        vm.prank(carol);
        card.mint("", "");
        assertEq(card.totalMinted(), 1);
        (string memory bio, string memory link,,,,) = card.profileOf(carol);
        assertEq(bio, "");
        assertEq(link, "");
    }

    // ------------------------------------------------------------------------
    // (2) mint gagal tanpa Agent ID
    // ------------------------------------------------------------------------
    function testMintWithoutAgentIDReverts() public {
        vm.prank(bob);
        vm.expectRevert(AgentIDCard.NotAgentIDHolder.selector);
        card.mint("halo", "");
    }

    // ------------------------------------------------------------------------
    // (3) mint kedua oleh wallet sama gagal
    // ------------------------------------------------------------------------
    function testSecondMintReverts() public {
        vm.prank(alice);
        card.mint("satu", "");
        vm.prank(alice);
        vm.expectRevert(AgentIDCard.AlreadyMinted.selector);
        card.mint("dua", "");
    }

    // ------------------------------------------------------------------------
    // (4) mint gagal saat supply habis (MAX_SUPPLY = 1000)
    // ------------------------------------------------------------------------
    function testSupplyCap() public {
        for (uint256 i = 0; i < 1000; i++) {
            address user = address(uint160(1000 + i));
            mock.setBalance(user, 1);
            vm.prank(user);
            card.mint("", "");
        }
        assertEq(card.totalMinted(), 1000);
        address late = address(uint160(99999));
        mock.setBalance(late, 1);
        vm.prank(late);
        vm.expectRevert(AgentIDCard.MaxSupplyReached.selector);
        card.mint("", "");
    }

    // ------------------------------------------------------------------------
    // Batas panjang bio / link
    // ------------------------------------------------------------------------
    function testBioTooLongReverts() public {
        string memory longBio = new string(141);
        vm.prank(alice);
        vm.expectRevert(AgentIDCard.BioTooLong.selector);
        card.mint(longBio, "");
    }

    function testLinkTooLongReverts() public {
        string memory longLink = new string(121);
        vm.prank(alice);
        vm.expectRevert(AgentIDCard.LinkTooLong.selector);
        card.mint("", longLink);
    }

    function testBioLinkAtLimitOk() public {
        vm.prank(alice);
        card.mint(new string(140), new string(120));
        assertEq(card.totalMinted(), 1);
    }

    // ------------------------------------------------------------------------
    // (5) checkIn: hari sama gagal, hari berikut naik, jeda 2 hari reset
    // ------------------------------------------------------------------------
    function testCheckInFlow() public {
        vm.prank(alice);
        card.mint("streaker", "");
        uint256 day0 = block.timestamp / 86400;

        vm.expectEmit(true, true, false, true);
        emit CheckedIn(alice, 1, 1, 1);
        vm.prank(alice);
        card.checkIn();
        (,,, uint256 s1,, uint256 d1) = card.profileOf(alice);
        assertEq(s1, 1);
        assertEq(d1, day0);

        // Same day again -> revert
        vm.prank(alice);
        vm.expectRevert(AgentIDCard.AlreadyCheckedInToday.selector);
        card.checkIn();

        // Next day -> streak 2
        vm.warp(block.timestamp + 86400);
        vm.prank(alice);
        card.checkIn();
        (,,, uint256 s2,,) = card.profileOf(alice);
        assertEq(s2, 2);

        // Next day -> streak 3, level 2
        vm.warp(block.timestamp + 86400);
        vm.prank(alice);
        card.checkIn();
        (,,, uint256 s3, uint256 l3,) = card.profileOf(alice);
        assertEq(s3, 3);
        assertEq(l3, 2);

        // Skip a day (warp +2 days) -> streak resets to 1
        vm.warp(block.timestamp + 2 * 86400);
        vm.prank(alice);
        card.checkIn();
        (,,, uint256 s4,,) = card.profileOf(alice);
        assertEq(s4, 1);
    }

    function testCheckInWithoutCardReverts() public {
        vm.prank(bob);
        vm.expectRevert(AgentIDCard.NoCard.selector);
        card.checkIn();
    }

    /// @dev Day-0 edge: timestamp < 86400 must not confuse the
    ///      "never checked in" sentinel (streak == 0).
    function testCheckInDayZero() public {
        vm.warp(1);
        vm.prank(alice);
        card.mint("day zero", "");
        vm.prank(alice);
        card.checkIn();
        (,,, uint256 s,,) = card.profileOf(alice);
        assertEq(s, 1);
        vm.prank(alice);
        vm.expectRevert(AgentIDCard.AlreadyCheckedInToday.selector);
        card.checkIn();
    }

    // ------------------------------------------------------------------------
    // (6) level thresholds
    // ------------------------------------------------------------------------
    function testLevelThresholds() public view {
        assertEq(card.levelOf(0), 1);
        assertEq(card.levelOf(1), 1);
        assertEq(card.levelOf(2), 1);
        assertEq(card.levelOf(3), 2);
        assertEq(card.levelOf(6), 2);
        assertEq(card.levelOf(7), 3);
        assertEq(card.levelOf(13), 3);
        assertEq(card.levelOf(14), 4);
        assertEq(card.levelOf(29), 4);
        assertEq(card.levelOf(30), 5);
        assertEq(card.levelOf(100), 5);
    }

    /// @dev 30 consecutive daily check-ins -> streak 30, level 5.
    function testLevelEndToEnd30Days() public {
        vm.prank(alice);
        card.mint("grinder", "");
        for (uint256 i = 0; i < 30; i++) {
            vm.prank(alice);
            card.checkIn();
            if (i < 29) vm.warp(block.timestamp + 86400);
        }
        (,,, uint256 streak, uint256 level,) = card.profileOf(alice);
        assertEq(streak, 30);
        assertEq(level, 5);
    }

    /// @dev 7 consecutive daily check-ins -> streak 7, level 3.
    function testLevelEndToEnd7Days() public {
        vm.prank(alice);
        card.mint("week", "");
        for (uint256 i = 0; i < 7; i++) {
            vm.prank(alice);
            card.checkIn();
            if (i < 6) vm.warp(block.timestamp + 86400);
        }
        (,,, uint256 streak, uint256 level,) = card.profileOf(alice);
        assertEq(streak, 7);
        assertEq(level, 3);
    }

    // ------------------------------------------------------------------------
    // (7) tokenURI: decode base64 -> JSON valid, SVG valid, isi benar
    // ------------------------------------------------------------------------
    function testTokenURI() public {
        // Bio with XML-special chars to prove escaping; 3-day streak -> level 2.
        vm.prank(alice);
        card.mint("Builder & artist <3", "https://x.com/alice");
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(alice);
            card.checkIn();
            if (i < 2) vm.warp(block.timestamp + 86400);
        }

        string memory uri = card.tokenURI(1);
        string memory jsonPrefix = "data:application/json;base64,";
        bytes memory uriBytes = bytes(uri);
        assertEq(_slice(uriBytes, 0, bytes(jsonPrefix).length), bytes(jsonPrefix));
        bytes memory json =
            _b64decode(string(_slice(uriBytes, bytes(jsonPrefix).length, uriBytes.length)));

        assertTrue(_contains(json, '"name":"Agent ID Card #1"'));
        assertTrue(_contains(json, '"trait_type":"Level"'));
        assertTrue(_contains(json, '"value":2'));
        assertTrue(_contains(json, '"trait_type":"Streak"'));
        assertTrue(_contains(json, '"value":3'));
        assertTrue(_contains(json, '"image":"data:image/svg+xml;base64,'));

        // Extract inner SVG base64 from the JSON and decode it.
        string memory imgPrefix = "data:image/svg+xml;base64,";
        uint256 imgStart = _indexOf(json, imgPrefix) + bytes(imgPrefix).length;
        uint256 imgEnd = imgStart;
        while (imgEnd < json.length && json[imgEnd] != '"') imgEnd++;
        bytes memory svg = _b64decode(string(_slice(json, imgStart, imgEnd)));

        assertTrue(_contains(svg, "<svg"));
        assertTrue(_contains(svg, "</svg>"));
        assertTrue(_contains(svg, "AGENT ID CARD"));
        assertTrue(_contains(svg, "#1"));
        assertTrue(_contains(svg, "LEVEL 2"));
        assertTrue(_contains(svg, "STREAK: 3 DAYS"));
        assertTrue(_contains(svg, "#3b82f6")); // level 2 = blue
        assertTrue(_contains(svg, _expectedShort(alice)));
        assertTrue(_contains(svg, "Builder &amp; artist &lt;3")); // XML-escaped bio
    }

    function testTokenURINonexistentReverts() public {
        vm.expectRevert(AgentIDCard.TokenDoesNotExist.selector);
        card.tokenURI(999);
    }

    function testTokenURILevelColors() public {
        // Level 1 (gray) at mint, level 5 (green) after 30-day streak.
        vm.prank(alice);
        card.mint("colors", "");
        bytes memory svg1 = _decodeSVG(card.tokenURI(1));
        assertTrue(_contains(svg1, "#9ca3af"));
        assertTrue(_contains(svg1, "LEVEL 1"));
        assertTrue(_contains(svg1, "STREAK: 0 DAYS"));

        // Singular "DAY" after the first check-in.
        vm.prank(alice);
        card.checkIn();
        bytes memory svgDay1 = _decodeSVG(card.tokenURI(1));
        assertTrue(_contains(svgDay1, "STREAK: 1 DAY"));
        assertFalse(_contains(svgDay1, "STREAK: 1 DAYS"));

        for (uint256 i = 1; i < 30; i++) {
            vm.warp(block.timestamp + 86400);
            vm.prank(alice);
            card.checkIn();
        }
        bytes memory svg5 = _decodeSVG(card.tokenURI(1));
        assertTrue(_contains(svg5, "#22c55e"));
        assertTrue(_contains(svg5, "LEVEL 5"));
        assertTrue(_contains(svg5, "STREAK: 30 DAYS"));
    }

    function testTokenURIBioTruncatedTo40Chars() public {
        // 100-char bio: SVG must show only the first 40 chars.
        string memory longBio =
            "0123456789012345678901234567890123456789TRUNCATED_PART_SHOULD_NOT_APPEAR_IN_SVG_0123456789";
        vm.prank(alice);
        card.mint(longBio, "");
        bytes memory svg = _decodeSVG(card.tokenURI(1));
        assertTrue(_contains(svg, "0123456789012345678901234567890123456789"));
        assertFalse(_contains(svg, "TRUNCATED_PART"));
    }

    // ------------------------------------------------------------------------
    // (8) updateProfile hanya oleh pemilik
    // ------------------------------------------------------------------------
    function testUpdateProfile() public {
        vm.prank(alice);
        card.mint("lama", "https://old.example");
        vm.prank(carol);
        card.mint("carol", "");

        vm.expectEmit(true, true, false, false);
        emit ProfileUpdated(alice, 1);
        vm.prank(alice);
        card.updateProfile("baru", "https://new.example");
        (string memory bio, string memory link,,,,) = card.profileOf(alice);
        assertEq(bio, "baru");
        assertEq(link, "https://new.example");

        // carol's update touches only carol's card
        vm.prank(carol);
        card.updateProfile("carol baru", "");
        (string memory bioC,,,,,) = card.profileOf(carol);
        assertEq(bioC, "carol baru");
        (bio,,,,,) = card.profileOf(alice);
        assertEq(bio, "baru");

        // no card -> revert
        vm.prank(bob);
        vm.expectRevert(AgentIDCard.NoCard.selector);
        card.updateProfile("x", "");

        // limits still apply on update
        vm.prank(alice);
        vm.expectRevert(AgentIDCard.BioTooLong.selector);
        card.updateProfile(new string(141), "");
    }

    // ------------------------------------------------------------------------
    // Soulbound: transfer / approve selalu revert
    // ------------------------------------------------------------------------
    function testSoulbound() public {
        vm.prank(alice);
        card.mint("soul", "");
        vm.prank(alice);
        vm.expectRevert(AgentIDCard.Soulbound.selector);
        card.transferFrom(alice, bob, 1);
        vm.prank(alice);
        vm.expectRevert(AgentIDCard.Soulbound.selector);
        card.safeTransferFrom(alice, bob, 1);
        vm.prank(alice);
        vm.expectRevert(AgentIDCard.Soulbound.selector);
        card.approve(bob, 1);
        vm.prank(alice);
        vm.expectRevert(AgentIDCard.Soulbound.selector);
        card.setApprovalForAll(bob, true);
        assertEq(card.getApproved(1), address(0));
        assertFalse(card.isApprovedForAll(alice, bob));
    }

    function testOwnerOfNonexistentReverts() public {
        vm.expectRevert(AgentIDCard.TokenDoesNotExist.selector);
        card.ownerOf(42);
        vm.expectRevert(AgentIDCard.TokenDoesNotExist.selector);
        card.balanceOf(address(0));
    }

    function testCardInfo() public {
        vm.prank(alice);
        card.mint("info", "https://x.com/alice");
        (address owner, string memory bio, string memory link, uint256 mintedAt, uint256 streak, uint256 level, uint256 lastDay) =
            card.cardInfo(1);
        assertEq(owner, alice);
        assertEq(bio, "info");
        assertEq(link, "https://x.com/alice");
        assertEq(mintedAt, block.timestamp);
        assertEq(streak, 0);
        assertEq(level, 1);
        assertEq(lastDay, 0);

        vm.expectRevert(AgentIDCard.TokenDoesNotExist.selector);
        card.cardInfo(999);
    }

    // ------------------------------------------------------------------------
    // Gas deploy (angka untuk BUILD.md; angka mainnet persis diukur via anvil)
    // ------------------------------------------------------------------------
    function testDeployGas() public {
        uint256 before = gasleft();
        new AgentIDCard();
        uint256 used = before - gasleft();
        emit log_named_uint("deploy gas (forge test env, approx)", used);
    }

    // ------------------------------------------------------------------------
    // Helpers: base64 decode, substring, contains
    // ------------------------------------------------------------------------
    function _decodeSVG(string memory uri) internal pure returns (bytes memory) {
        string memory jsonPrefix = "data:application/json;base64,";
        bytes memory uriBytes = bytes(uri);
        bytes memory json =
            _b64decode(string(_slice(uriBytes, bytes(jsonPrefix).length, uriBytes.length)));
        string memory imgPrefix = "data:image/svg+xml;base64,";
        uint256 imgStart = _indexOf(json, imgPrefix) + bytes(imgPrefix).length;
        uint256 imgEnd = imgStart;
        while (imgEnd < json.length && json[imgEnd] != '"') imgEnd++;
        return _b64decode(string(_slice(json, imgStart, imgEnd)));
    }

    function _b64decode(string memory s) internal pure returns (bytes memory) {
        bytes memory data = bytes(s);
        uint256 len = data.length;
        require(len % 4 == 0, "bad b64 len");
        uint256 pad = 0;
        if (len > 0 && data[len - 1] == "=") pad++;
        if (len > 1 && data[len - 2] == "=") pad++;
        uint256 outLen = (len / 4) * 3 - pad;
        bytes memory out = new bytes(outLen);
        uint256 o = 0;
        for (uint256 i = 0; i < len; i += 4) {
            uint256 n = (_b64val(data[i]) << 18) | (_b64val(data[i + 1]) << 12) | (_b64val(data[i + 2]) << 6)
                | _b64val(data[i + 3]);
            out[o++] = bytes1(uint8(n >> 16));
            if (o < outLen) out[o++] = bytes1(uint8(n >> 8));
            if (o < outLen) out[o++] = bytes1(uint8(n));
        }
        return out;
    }

    function _b64val(bytes1 c) internal pure returns (uint256) {
        if (c >= "A" && c <= "Z") return uint8(c) - uint8(bytes1("A"));
        if (c >= "a" && c <= "z") return uint8(c) - uint8(bytes1("a")) + 26;
        if (c >= "0" && c <= "9") return uint8(c) - uint8(bytes1("0")) + 52;
        if (c == "+") return 62;
        if (c == "/") return 63;
        return 0; // '=' padding
    }

    function _slice(bytes memory b, uint256 start, uint256 end) internal pure returns (bytes memory) {
        require(start <= end && end <= b.length, "bad slice");
        bytes memory out = new bytes(end - start);
        for (uint256 i = 0; i < end - start; i++) {
            out[i] = b[start + i];
        }
        return out;
    }

    function _contains(bytes memory hay, string memory needle) internal pure returns (bool) {
        bytes memory n = bytes(needle);
        if (n.length == 0) return true;
        if (hay.length < n.length) return false;
        for (uint256 i = 0; i <= hay.length - n.length; i++) {
            bool found = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (hay[i + j] != n[j]) {
                    found = false;
                    break;
                }
            }
            if (found) return true;
        }
        return false;
    }

    function _indexOf(bytes memory hay, string memory needle) internal pure returns (uint256) {
        bytes memory n = bytes(needle);
        require(hay.length >= n.length, "needle too long");
        for (uint256 i = 0; i <= hay.length - n.length; i++) {
            bool found = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (hay[i + j] != n[j]) {
                    found = false;
                    break;
                }
            }
            if (found) return i;
        }
        revert("not found");
    }

    function _expectedShort(address a) internal pure returns (string memory) {
        bytes memory hexChars = "0123456789abcdef";
        bytes20 b = bytes20(a);
        bytes memory out = new bytes(13);
        out[0] = "0";
        out[1] = "x";
        out[2] = hexChars[uint8(b[0]) >> 4];
        out[3] = hexChars[uint8(b[0]) & 0x0f];
        out[4] = hexChars[uint8(b[1]) >> 4];
        out[5] = hexChars[uint8(b[1]) & 0x0f];
        out[6] = ".";
        out[7] = ".";
        out[8] = ".";
        out[9] = hexChars[uint8(b[18]) >> 4];
        out[10] = hexChars[uint8(b[18]) & 0x0f];
        out[11] = hexChars[uint8(b[19]) >> 4];
        out[12] = hexChars[uint8(b[19]) & 0x0f];
        return string(out);
    }
}
