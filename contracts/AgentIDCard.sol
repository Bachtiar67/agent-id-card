// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title Agent ID Card
/// @notice Free-mint on-chain profile card for Binance Agent ID holders.
/// @dev Self-contained, no external imports, no owner/admin, no funds.
///      One soulbound ERC-721 card per wallet that holds an Agent ID.
///      Daily check-ins build a streak; streak sets the card level (1-5).
///      Card art + metadata are fully on-chain (SVG + JSON, base64).
interface IAgentID {
    function balanceOf(address owner) external view returns (uint256);
}

/// @dev Minimal Base64 encoder (pure Solidity, no assembly) — tokenURI is
///      a view, so the extra gas vs an assembly encoder is irrelevant.
library Base64 {
    function encode(bytes memory data) internal pure returns (string memory) {
        if (data.length == 0) return "";
        bytes memory table = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        uint256 encodedLen = 4 * ((data.length + 2) / 3);
        bytes memory result = new bytes(encodedLen);
        uint256 j = 0;
        for (uint256 i = 0; i < data.length; i += 3) {
            uint256 b0 = uint8(data[i]);
            uint256 b1 = i + 1 < data.length ? uint8(data[i + 1]) : 0;
            uint256 b2 = i + 2 < data.length ? uint8(data[i + 2]) : 0;
            uint256 n = (b0 << 16) | (b1 << 8) | b2;
            result[j++] = table[(n >> 18) & 0x3F];
            result[j++] = table[(n >> 12) & 0x3F];
            result[j++] = table[(n >> 6) & 0x3F];
            result[j++] = table[n & 0x3F];
        }
        uint256 mod = data.length % 3;
        if (mod == 1) {
            result[encodedLen - 1] = "=";
            result[encodedLen - 2] = "=";
        } else if (mod == 2) {
            result[encodedLen - 1] = "=";
        }
        return string(result);
    }
}

contract AgentIDCard {
    // ------------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------------
    string public constant name = "Agent ID Card";
    string public constant symbol = "AIDC";
    uint256 public constant MAX_SUPPLY = 1000;
    /// @dev SPACE ID Agent ID registry on BSC (ERC-721, soulbound).
    address public constant AGENT_ID = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;

    uint256 public constant MAX_BIO_BYTES = 140;
    uint256 public constant MAX_LINK_BYTES = 120;

    // ------------------------------------------------------------------------
    // Errors (single, consistent style: custom errors)
    // ------------------------------------------------------------------------
    error NotAgentIDHolder();
    error AlreadyMinted();
    error MaxSupplyReached();
    error BioTooLong();
    error LinkTooLong();
    error NoCard();
    error AlreadyCheckedInToday();
    error TokenDoesNotExist();
    error Soulbound();

    // ------------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------------
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event CardMinted(address indexed owner, uint256 indexed tokenId, string bio);
    event CheckedIn(address indexed owner, uint256 indexed tokenId, uint256 streak, uint256 level);
    event ProfileUpdated(address indexed owner, uint256 indexed tokenId);

    // ------------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------------
    struct Profile {
        string bio;
        string link;
        uint256 mintedAt;
        uint256 streak;
        uint256 lastCheckInDay; // day number = block.timestamp / 86400 (UTC)
    }

    uint256 public totalMinted;
    mapping(uint256 => address) private _owners;
    mapping(address => uint256) private _tokenOfOwner; // 0 = no card
    mapping(uint256 => Profile) private _profiles;

    // ------------------------------------------------------------------------
    // Mint / check-in / profile
    // ------------------------------------------------------------------------
    /// @notice Mint one free card. Caller must hold an Agent ID and not
    ///         have minted before. bio <= 140 bytes, link <= 120 bytes
    ///         (either may be empty).
    function mint(string calldata bio, string calldata link) external {
        if (IAgentID(AGENT_ID).balanceOf(msg.sender) == 0) revert NotAgentIDHolder();
        if (_tokenOfOwner[msg.sender] != 0) revert AlreadyMinted();
        if (totalMinted >= MAX_SUPPLY) revert MaxSupplyReached();
        if (bytes(bio).length > MAX_BIO_BYTES) revert BioTooLong();
        if (bytes(link).length > MAX_LINK_BYTES) revert LinkTooLong();

        totalMinted += 1;
        uint256 tokenId = totalMinted;
        _owners[tokenId] = msg.sender;
        _tokenOfOwner[msg.sender] = tokenId;
        _profiles[tokenId] = Profile({
            bio: bio,
            link: link,
            mintedAt: block.timestamp,
            streak: 0,
            lastCheckInDay: 0
        });

        emit Transfer(address(0), msg.sender, tokenId);
        emit CardMinted(msg.sender, tokenId, bio);
    }

    /// @notice Check in once per UTC day. Consecutive days grow the streak;
    ///         missing a day resets it to 1.
    function checkIn() external {
        uint256 tokenId = _tokenOfOwner[msg.sender];
        if (tokenId == 0) revert NoCard();
        Profile storage p = _profiles[tokenId];

        uint256 today = block.timestamp / 86400;
        // streak == 0 is the "never checked in" sentinel: day 0 (1970) would
        // otherwise collide with the zero initial lastCheckInDay.
        if (p.streak != 0 && p.lastCheckInDay == today) revert AlreadyCheckedInToday();
        if (p.streak != 0 && p.lastCheckInDay == today - 1) {
            p.streak += 1;
        } else {
            p.streak = 1;
        }
        p.lastCheckInDay = today;

        emit CheckedIn(msg.sender, tokenId, p.streak, levelOf(p.streak));
    }

    /// @notice Update your own card's bio/link.
    function updateProfile(string calldata bio, string calldata link) external {
        uint256 tokenId = _tokenOfOwner[msg.sender];
        if (tokenId == 0) revert NoCard();
        if (bytes(bio).length > MAX_BIO_BYTES) revert BioTooLong();
        if (bytes(link).length > MAX_LINK_BYTES) revert LinkTooLong();

        _profiles[tokenId].bio = bio;
        _profiles[tokenId].link = link;

        emit ProfileUpdated(msg.sender, tokenId);
    }

    // ------------------------------------------------------------------------
    // Levels
    // ------------------------------------------------------------------------
    /// @notice Streak -> level: 1 (<3), 2 (>=3), 3 (>=7), 4 (>=14), 5 (>=30).
    function levelOf(uint256 streak) public pure returns (uint256) {
        if (streak >= 30) return 5;
        if (streak >= 14) return 4;
        if (streak >= 7) return 3;
        if (streak >= 3) return 2;
        return 1;
    }

    // ------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------
    function profileOf(address owner)
        external
        view
        returns (
            string memory bio,
            string memory link,
            uint256 tokenId,
            uint256 streak,
            uint256 level,
            uint256 lastCheckInDay
        )
    {
        tokenId = _tokenOfOwner[owner];
        if (tokenId == 0) revert NoCard();
        Profile storage p = _profiles[tokenId];
        return (p.bio, p.link, tokenId, p.streak, levelOf(p.streak), p.lastCheckInDay);
    }

    /// @notice Full card info by tokenId (handy for the wall/leaderboard).
    function cardInfo(uint256 tokenId)
        external
        view
        returns (
            address owner,
            string memory bio,
            string memory link,
            uint256 mintedAt,
            uint256 streak,
            uint256 level,
            uint256 lastCheckInDay
        )
    {
        owner = _owners[tokenId];
        if (owner == address(0)) revert TokenDoesNotExist();
        Profile storage p = _profiles[tokenId];
        return (owner, p.bio, p.link, p.mintedAt, p.streak, levelOf(p.streak), p.lastCheckInDay);
    }

    function tokenOfOwner(address owner) external view returns (uint256) {
        return _tokenOfOwner[owner];
    }

    function hasMinted(address owner) external view returns (bool) {
        return _tokenOfOwner[owner] != 0;
    }

    // ------------------------------------------------------------------------
    // Minimal ERC-721 (soulbound: transfers + approvals always revert)
    // ------------------------------------------------------------------------
    function balanceOf(address owner) external view returns (uint256) {
        if (owner == address(0)) revert TokenDoesNotExist();
        return _tokenOfOwner[owner] == 0 ? 0 : 1;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        address owner = _owners[tokenId];
        if (owner == address(0)) revert TokenDoesNotExist();
        return owner;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x01ffc9a7 || // ERC165
            interfaceId == 0x80ac58cd || // ERC721
            interfaceId == 0x5b5e139f; // ERC721Metadata
    }

    function transferFrom(address, address, uint256) external pure {
        revert Soulbound();
    }

    function safeTransferFrom(address, address, uint256) external pure {
        revert Soulbound();
    }

    function safeTransferFrom(address, address, uint256, bytes calldata) external pure {
        revert Soulbound();
    }

    function approve(address, uint256) external pure {
        revert Soulbound();
    }

    function setApprovalForAll(address, bool) external pure {
        revert Soulbound();
    }

    function getApproved(uint256) external pure returns (address) {
        return address(0);
    }

    function isApprovedForAll(address, address) external pure returns (bool) {
        return false;
    }

    // ------------------------------------------------------------------------
    // Metadata (fully on-chain: JSON + SVG, both base64)
    // ------------------------------------------------------------------------
    function tokenURI(uint256 tokenId) external view returns (string memory) {
        address owner = _owners[tokenId];
        if (owner == address(0)) revert TokenDoesNotExist();
        Profile storage p = _profiles[tokenId];
        uint256 lvl = levelOf(p.streak);
        string memory svg = _buildSVG(tokenId, owner, lvl, p.streak, p.bio);
        return _buildMetadata(tokenId, lvl, p.streak, svg);
    }

    function _buildMetadata(uint256 tokenId, uint256 lvl, uint256 streak, string memory svg)
        internal
        pure
        returns (string memory)
    {
        string memory jsonHead = string(
            abi.encodePacked(
                '{"name":"Agent ID Card #',
                _toString(tokenId),
                '","description":"On-chain profile card for Binance Agent ID holders. Check in daily to raise your level.","image":"data:image/svg+xml;base64,',
                Base64.encode(bytes(svg)),
                '","attributes":['
            )
        );
        string memory jsonTail = string(
            abi.encodePacked(
                '{"trait_type":"Level","value":',
                _toString(lvl),
                '},{"trait_type":"Streak","value":',
                _toString(streak),
                "}]}"
            )
        );
        string memory json = string(abi.encodePacked(jsonHead, jsonTail));
        return string(abi.encodePacked("data:application/json;base64,", Base64.encode(bytes(json))));
    }

    function _buildSVG(uint256 tokenId, address owner, uint256 lvl, uint256 streak, string memory bio)
        internal
        pure
        returns (string memory)
    {
        string memory color = _levelColor(lvl);
        string memory head = _svgHead(color);
        string memory mid = _svgMid(tokenId, lvl, color);
        string memory tail = _svgTail(owner, streak, bio);
        return string(abi.encodePacked(head, mid, tail));
    }

    function _svgHead(string memory color) internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                '<svg xmlns="http://www.w3.org/2000/svg" width="480" height="280" viewBox="0 0 480 280">',
                '<rect width="480" height="280" rx="20" fill="#0f172a"/>',
                '<rect x="8" y="8" width="464" height="264" rx="16" fill="none" stroke="',
                color,
                '" stroke-width="3"/>',
                '<text x="28" y="48" font-family="monospace" font-size="24" font-weight="bold" fill="',
                color,
                '">AGENT ID CARD</text>'
            )
        );
    }

    function _svgMid(uint256 tokenId, uint256 lvl, string memory color) internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                '<text x="28" y="88" font-family="monospace" font-size="16" fill="#e2e8f0">#',
                _toString(tokenId),
                "</text>",
                '<text x="452" y="88" font-family="monospace" font-size="16" fill="',
                color,
                '" text-anchor="end">LEVEL ',
                _toString(lvl),
                "</text>"
            )
        );
    }

    function _svgTail(address owner, uint256 streak, string memory bio) internal pure returns (string memory) {
        string memory dayLabel = streak == 1 ? " DAY</text>" : " DAYS</text>";
        return string(
            abi.encodePacked(
                '<text x="28" y="130" font-family="monospace" font-size="15" fill="#94a3b8">STREAK: ',
                _toString(streak),
                dayLabel,
                '<text x="28" y="162" font-family="monospace" font-size="15" fill="#e2e8f0">',
                _shortAddress(owner),
                "</text>",
                '<text x="28" y="202" font-family="monospace" font-size="14" fill="#cbd5e1">',
                _escapeXML(_truncateChars(bio, 40)),
                "</text>",
                '<text x="28" y="248" font-family="monospace" font-size="12" fill="#64748b">BNB CHAIN - BINANCE AGENT ID</text>',
                "</svg>"
            )
        );
    }

    function _levelColor(uint256 lvl) internal pure returns (string memory) {
        if (lvl == 2) return "#3b82f6"; // blue
        if (lvl == 3) return "#8b5cf6"; // purple
        if (lvl == 4) return "#f59e0b"; // gold
        if (lvl == 5) return "#22c55e"; // green
        return "#9ca3af"; // gray (level 1)
    }

    function _shortAddress(address a) internal pure returns (string memory) {
        bytes memory hexChars = "0123456789abcdef";
        bytes20 b = bytes20(a);
        bytes memory out = new bytes(13); // "0x" + 4 + "..." + 4
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

    /// @dev Truncate to maxChars *characters* (UTF-8 aware: never splits a
    ///      multi-byte char; breaks only at a new leading byte).
    function _truncateChars(string memory s, uint256 maxChars) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        uint256 count = 0;
        uint256 i = 0;
        while (i < b.length) {
            if ((b[i] & 0xC0) != 0x80) {
                if (count >= maxChars) break;
                count++;
            }
            i++;
        }
        bytes memory out = new bytes(i);
        for (uint256 j = 0; j < i; j++) {
            out[j] = b[j];
        }
        return string(out);
    }

    function _escapeXML(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        string memory out = "";
        for (uint256 i = 0; i < b.length; i++) {
            bytes1 c = b[i];
            if (c == 0x26) out = string(abi.encodePacked(out, "&amp;"));
            else if (c == 0x3C) out = string(abi.encodePacked(out, "&lt;"));
            else if (c == 0x3E) out = string(abi.encodePacked(out, "&gt;"));
            else if (c == 0x22) out = string(abi.encodePacked(out, "&quot;"));
            else if (c == 0x27) out = string(abi.encodePacked(out, "&#39;"));
            else out = string(abi.encodePacked(out, c));
        }
        return out;
    }

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
