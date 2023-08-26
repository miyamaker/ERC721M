// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.20;

import "solady/auth/Ownable.sol";
import "solady/utils/LibString.sol";
import "solady/utils/SafeCastLib.sol";
import "./AlignedNFT.sol";

contract ERC721M is AlignedNFT {

    using LibString for uint256;
    using SafeCastLib for uint256;
    using SafeCastLib for int256;

    error Exceeded();
    error NotERC721();
    error NotActive();
    error NotMinted();
    error URILocked();
    error Underflow();
    error MintClosed();
    error CapReached();
    error NotBurnable();
    error LockedToken();
    error CapExceeded();
    error NoTokensLocked();
    error TokenNotBurned();
    error InsufficientLock();
    error MintBurnDisabled();
    error TokenNotLockable();
    error TokenNotUnlockable();
    error InsufficientPayment();
    error InsufficientBalance();

    event URILock();
    event URIChanged(string indexed baseUri);
    event PriceUpdated(uint256 indexed price);
    event TokensLocked(address indexed token, uint256 indexed amount);
    event BatchMetadataUpdate(uint256 indexed fromTokenId, uint256 indexed toTokenId);
    
    event NormalMint(address indexed to, uint64 indexed amount);
    event DiscountedMint(address indexed asset, address indexed to, uint64 indexed amount);
    event ConfigureMintDiscount(
        address indexed asset,
        bool indexed status,
        int64 indexed allocation,
        uint256 tokenBalance,
        uint256 price
    );
    event ConfigureMintBurn(
        address indexed asset,
        bool indexed status,
        int64 indexed allocation,
        uint256 tokenBalance,
        uint256 price
    );

    struct MintInfo {
        int64 supply;
        int64 allocated;
        bool active;
        uint40 timelock;
        uint256 tokenBalance;
        uint256 mintPrice;
    }
    struct MinterInfo {
        uint256 amount;
        uint256[] amounts;
        uint40[] timelocks;
    }

    bool public uriLocked;
    bool public mintOpen;
    string private _name;
    string private _symbol;
    string private _baseURI;
    string private _contractURI;
    uint256 public immutable maxSupply;
    uint256 public price;

    mapping(address => MintInfo) public mintDiscountInfo;
    mapping(address => MintInfo) public mintBurnInfo;
    mapping(address => MintInfo) public mintLockTokensInfo;
    mapping(address => MintInfo) public mintWithTokensInfo;
    mapping(address => MintInfo) public mintWithNftsInfo;
    mapping(address => mapping(address => MinterInfo)) public burnerInfo;
    mapping(address => mapping(address => MinterInfo)) public lockerInfo;

    modifier mintable(uint256 _amount) {
        if (!mintOpen) { revert MintClosed(); }
        if (totalSupply >= maxSupply) { revert CapReached(); }
        if (totalSupply + _amount > maxSupply) { revert CapExceeded(); }
        _;
    }

    constructor(
        uint16 _allocation, // Percentage of mint funds allocated to aligned collection in basis points (500 - 10000)
        uint16 _royaltyFee, // Percentage of royalty fees in basis points (0 - 10000)
        address _alignedNFT, // Address of aligned NFT collection mint funds are being dedicated to
        address _fundsRecipient, // Recipient of non-aligned mint funds
        string memory __name, // NFT collection name
        string memory __symbol, // NFT collection symbol/ticker
        string memory __baseURI, // Base URI for NFT metadata, preferably on IPFS
        string memory __contractURI, // Full Contract URI for NFT collection information
        uint256 _maxSupply, // Max mint supply
        uint256 _price // Standard mint price
    ) AlignedNFT(
        _alignedNFT,
        _fundsRecipient,
        _allocation
    )
    payable {
        // Prevent bad royalty fee
        if (_royaltyFee > 10000) { revert BadInput(); }
        // Set all relevant metadata and contract configurations
        _name = __name;
        _symbol = __symbol;
        _baseURI = __baseURI;
        _contractURI = __contractURI;
        maxSupply = _maxSupply;
        price = _price;

        // Set ownership using msg.sender or tx.origin to support factory deployment
        // Determination is made by checking if msg.sender is a smart contract or not by checking code size
        uint32 size;
        address sender;
        assembly { size:= extcodesize(sender) }
        if (size > 0) { sender = tx.origin; }
        else { sender = msg.sender; }
        _initializeOwner(sender);

        // Initialize royalties
        _setTokenRoyalty(0, sender, uint96(_royaltyFee));
        // Configure default royalties for contract owner
        _setDefaultRoyalty(sender, uint96(_royaltyFee));
    }


    // ERC721 Metadata
    function name() public view virtual override returns (string memory) { return (_name); }
    function symbol() public view virtual override returns (string memory) { return (_symbol); }
    function baseUri() public view virtual returns (string memory) { return (_baseURI); }
    function contractURI() public view virtual returns (string memory) { return (_contractURI); }
    function tokenURI(uint256 _tokenId) public view virtual override returns (string memory) {
        if (!_exists(_tokenId)) { revert NotMinted(); } // Require token exists
        string memory __baseURI = baseUri();

        return (bytes(__baseURI).length > 0 ? string(abi.encodePacked(__baseURI, _tokenId.toString())) : "");
    }

    // Contract management
    function changeFundsRecipient(address _to) public virtual onlyOwner { _changeFundsRecipient(_to); }
    function setPrice(uint256 _price) public virtual onlyOwner {
        price = _price;
        emit PriceUpdated(_price);
    }
    function openMint() public virtual onlyOwner { mintOpen = true; }
    function updateBaseURI(string memory __baseURI) public virtual onlyOwner {
        if (!uriLocked) {
            _baseURI = __baseURI;
            emit URIChanged(__baseURI);
            emit BatchMetadataUpdate(0, maxSupply);
        } else { revert URILocked(); }
    }
    function lockURI() public virtual onlyOwner {
        uriLocked = true;
        emit URILock();
    }

    // Standard mint function that supports batch minting
    function mint(address _to, uint64 _amount) public payable mintable(_amount) {
        if (msg.value < (price * _amount)) { revert InsufficientPayment(); }
        _mint(_to, uint256(_amount));
        emit NormalMint(_to, _amount);
    }

    // Discounted mint for owners of specific ERC20/721 tokens
    function mintDiscount(address _asset, address _to, uint64 _amount) public payable mintable(_amount) {
        MintInfo memory info = mintDiscountInfo[_asset];
        // Check if discount is active
        if (!info.active || info.supply == 0) { revert NotActive(); }
        // Determine if amount exceeds supply
        int64 amount = (uint256(_amount).toInt256()).toInt64();
        if (amount > info.supply) { revert Exceeded(); }
        // Ensure holder balance of asset is sufficient
        if (IAsset(_asset).balanceOf(msg.sender) < info.tokenBalance) { revert InsufficientBalance(); }
        if (_amount * info.mintPrice > msg.value) { revert InsufficientPayment(); }
        // Update MintInfo
        unchecked { info.supply -= amount; }
        if (info.supply == 0) { info.active = false; }
        mintDiscountInfo[_asset] = info;
        // Process mint
        _mint(_to, uint256(_amount));
        emit DiscountedMint(_asset, _to, _amount);
    }

    // Configure asset ownership-based discounted mints, bulk compatible
    // Each individual collection must have a corresponding discount price and total discounted mint quantity
    function configureMintDiscount(
        address[] memory _assets,
        bool[] memory _status,
        int64[] memory _allocations,
        uint256[] memory _tokenBalances,
        uint256[] memory _prices
    ) public virtual onlyOwner {
        // Confirm all arrays match in length to ensure each collection has proper values set
        uint256 length = _assets.length;
        if (
            length != _status.length
            || length != _allocations.length
            || length != _tokenBalances.length
            || length != _prices.length
        ) { revert ArrayLengthMismatch(); }

        // Loop through and configure each corresponding discount
        for (uint256 i; i < length;) {
            // Retrieve current mint info, if any
            MintInfo memory info = mintDiscountInfo[_assets[i]];
            info.active = _status[i];
            // Ensure supply or allocation cant underflow if theyre being reduced
            if (info.supply + _allocations[i] < 0 || info.allocated + _allocations[i] < 0) { 
                revert Underflow();
            }
            unchecked {
                info.supply += _allocations[i];
                info.allocated += _allocations[i];
            }
            // Enforced disable if adjustment eliminates mint availability
            if (info.supply == 0 || info.allocated == 0) { info.active = false; }
            info.tokenBalance = _tokenBalances[i];
            info.mintPrice = _prices[i];
            mintDiscountInfo[_assets[i]] = info;
            emit ConfigureMintDiscount(_assets[i], _status[i], _allocations[i], _tokenBalances[i], _prices[i]);
            unchecked { ++i; }
        }
    }

    // Internal function to burn tokens
    function _attemptBurn(address _asset, uint256 _tokens) internal {
        uint256 balance = IAsset(_asset).balanceOf(msg.sender);
        try IAsset(_asset).burn(_tokens) { } catch { }
        if (IAsset(_asset).balanceOf(msg.sender) >= balance) {
            try IAsset(_asset).transferFrom(msg.sender, address(0), _tokens) { }
            catch {
                try IAsset(_asset).transferFrom(msg.sender, address(0xdead), _tokens) { }
                catch {
                    try IAsset(_asset).transferFrom(msg.sender, address(69), _tokens) { } catch { }
                }
            }
        }
    }

    // Burn multiple different ERC20/ERC721 tokens to mint
    function mintBurn(
        address _to,
        address[] memory _assets,
        uint256[][] memory _burns
    ) public virtual payable {
        if (!mintOpen) { revert MintClosed(); }
        if (totalSupply >= maxSupply) { revert CapReached(); }
        if (_assets.length != _burns.length) { revert ArrayLengthMismatch(); }
        uint256 mintNum;
        uint256 requiredPayment;

        for (uint256 i; i < _assets.length;) {
            address asset = _assets[i];
            bool isERC721 = IAsset(asset).supportsInterface(0x80ac58cd);
            uint256 balance = IAsset(asset).balanceOf(msg.sender);
            MintInfo memory mintInfo = mintBurnInfo[asset];
            uint256 burntAmount = burnerInfo[msg.sender][asset].amount;

            if (_burns[i].length > 1 && !isERC721) { revert NotERC721(); }
            if (!mintInfo.active || mintInfo.supply == 0) { revert NotActive(); }
            
            if (isERC721) {
                if ((burntAmount + _burns[i].length) / mintInfo.tokenBalance > uint256(int256(mintInfo.supply))) {
                    revert Exceeded();
                }
            } else {
                if ((burntAmount + _burns[i][0]) / mintInfo.tokenBalance > uint256(int256(mintInfo.supply))) {
                    revert Exceeded();
                }
            }
            
            for (uint256 j; j < _burns[i].length;) {
                uint256 tokens = _burns[i][j];
                _attemptBurn(asset, tokens);
                uint256 newBalance = IAsset(asset).balanceOf(msg.sender);
                if (isERC721) {
                    if (balance - 1 != newBalance) { revert NotBurnable(); }
                    unchecked {
                        ++burntAmount;
                        burnerInfo[msg.sender][asset].amounts.push(tokens);
                        --balance;
                    }
                } else {
                    if (balance - tokens != newBalance) { revert NotBurnable(); }
                    unchecked {
                        ++burntAmount;
                        burnerInfo[msg.sender][asset].amounts.push(tokens);
                        // Balance reduction unneeded as ERC20s must be burned in one loop iteration
                    }
                }
                unchecked { ++j; }
            }

            uint256 burnMints = burntAmount / mintInfo.tokenBalance;
            burntAmount -= mintNum * mintInfo.tokenBalance;
            burnerInfo[msg.sender][asset].amount = burntAmount;

            mintInfo.supply -= burnMints.toInt256().toInt64();
            if (mintInfo.supply == 0) { mintInfo.active = false; }
            mintBurnInfo[asset] = mintInfo;

            mintNum += burnMints;
            requiredPayment += burnMints * mintInfo.mintPrice; 
            unchecked { ++i; }
        }

        if ((mintNum + totalSupply) > maxSupply) { revert CapExceeded(); }
        if (msg.value < requiredPayment) { revert InsufficientPayment(); }
        _mint(_to, mintNum);
    }
    
    // Configure mint to burn functionality by specifying allowed collections and how many tokens are required
    function configureMintBurn(
        address[] memory _assets,
        bool[] memory _status,
        int64[] memory _allocations,
        uint256[] memory _tokenBalances,
        uint256[] memory _prices
    ) public virtual onlyOwner {
        // Confirm all arrays match in length to ensure each collection has proper values set
        uint256 length = _assets.length;
        if (
            length != _status.length
            || length != _allocations.length
            || length != _tokenBalances.length
            || length != _prices.length
        ) { revert ArrayLengthMismatch(); }

        // Loop through and configure each corresponding discount
        for (uint256 i; i < length;) {
            // Retrieve current mint info, if any
            MintInfo memory info = mintBurnInfo[_assets[i]];
            info.active = _status[i];
            // Ensure supply or allocation cant underflow if theyre being reduced
            if (info.supply + _allocations[i] < 0 || info.allocated + _allocations[i] < 0) { 
                revert Underflow();
            }
            unchecked {
                info.supply += _allocations[i];
                info.allocated += _allocations[i];
            }
            // Enforced disable if adjustment eliminates mint availability
            if (info.supply == 0 || info.allocated == 0) { info.active = false; }
            info.tokenBalance = _tokenBalances[i];
            info.mintPrice = _prices[i];
            mintDiscountInfo[_assets[i]] = info;
            emit ConfigureMintBurn(_assets[i], _status[i], _allocations[i], _tokenBalances[i], _prices[i]);
            unchecked { ++i; }
        }
    }
    
    // Lock ERC20/721 tokens to mint
    function mintLock(
        address _to, 
        address[] memory _assets, 
        uint256[][] memory _locks
    ) public virtual payable {
        if (!mintOpen) { revert MintClosed(); }
        if (totalSupply >= maxSupply) { revert CapReached(); }
        if (_assets.length != _locks.length) { revert ArrayLengthMismatch(); }
        uint256 mintNum;
        uint256 requiredPayment;

        for (uint256 i; i < _assets.length;) {
            address asset = _assets[i];
            bool isERC721 = IAsset(asset).supportsInterface(0x80ac58cd);
            MintInfo memory mintInfo = mintLockTokensInfo[asset];

            if (_locks[i].length > 1 && !isERC721) { revert NotERC721(); }
            if (!mintInfo.active || mintInfo.supply == 0) { revert NotActive(); }

            if (isERC721) {
                if (_locks[i].length / mintInfo.tokenBalance > uint256(int256(mintInfo.supply))) {
                    revert Exceeded();
                }
                if (_locks[i].length / mintInfo.tokenBalance < 0) {
                    revert InsufficientLock();
                }
            } else {
                if (_locks[i][0] / mintInfo.tokenBalance > uint256(int256(mintInfo.supply))) {
                    revert Exceeded();
                }
                if (_locks[i][0] / mintInfo.tokenBalance < 0) {
                    revert InsufficientLock();
                }
            }

            uint256 balance = IAsset(asset).balanceOf(address(this));
            uint256 iterations;
            if (isERC721) { iterations = (_locks[i].length / mintInfo.tokenBalance) * mintInfo.tokenBalance; }
            else { iterations = 1; }
            for (uint256 j; j < iterations;) {
                uint256 tokens = _locks[i][j];
                if (!isERC721) {
                    uint256 lock;
                    unchecked { lock = (tokens / mintInfo.tokenBalance) * mintInfo.tokenBalance; }
                    IAsset(asset).transferFrom(msg.sender, address(this), lock);
                    lockerInfo[msg.sender][asset].amounts.push(lock);
                    unchecked { lockerInfo[address(this)][asset].amount += lock; }
                } else {
                    IAsset(asset).transferFrom(msg.sender, address(this), tokens);
                    lockerInfo[msg.sender][asset].amounts.push(tokens);
                    unchecked { ++lockerInfo[address(this)][asset].amount; }
                }
                lockerInfo[msg.sender][asset].timelocks.push(mintInfo.timelock + uint40(block.timestamp));
                
                if (IAsset(asset).balanceOf(address(this)) <= balance) { revert TransferFailed(); }
                if (isERC721) { unchecked { ++balance; } }
                else { unchecked { balance += tokens; } }
                unchecked { ++j; }
            }

            uint256 lockMints;
            if (isERC721) { unchecked { lockMints = iterations / mintInfo.tokenBalance; } }
            else { unchecked { lockMints = _locks[i][0] / mintInfo.tokenBalance; } }
            unchecked { mintNum += lockMints; }
            unchecked { requiredPayment += lockMints * mintInfo.mintPrice; }

            unchecked { mintInfo.supply -= lockMints.toInt256().toInt64(); }
            if (mintInfo.supply == 0) { mintInfo.active = false; }
            mintLockTokensInfo[asset] = mintInfo;
            unchecked { ++i; }
        }

        if ((mintNum + totalSupply) > maxSupply) { revert CapExceeded(); }
        if (msg.value < requiredPayment) { revert InsufficientPayment(); }
        _mint(_to, mintNum);
    }
    
    /*
    // Configure lock tokens to mint function by specifying token address, amounts, and timelock periods per token
    // Setting amount to zero will disable token as a lockable option
    function configureMintLock(
        address[] memory _tokens, 
        uint256[] memory _discounts, // Discounted mint price
        uint256[] memory _amounts, // Required token lock amount
        uint256[] memory _timestamps, // Lock duration
        uint256[] memory _quantity // Number of allowed mints for a specific token lock
    ) public virtual onlyOwner {
        // Confirm all arrays are equal length
        uint256 length = _tokens.length;
        if (length != _discounts.length || 
            length != _amounts.length ||
            length != _timestamps.length ||
            length != _quantity.length) { revert ArrayLengthMismatch(); }

        uint256[] memory lockConfig = new uint256[](4);
        // Loop through and configure each corresponding discount
        for (uint256 i; i < length;) {
            if (lockableTokens[_tokens[i]].length > 0) {
                uint256 remainingQty = lockableTokens[_tokens[i]][3];
                // Log if existing discount is being overwritten
                if (remainingQty > 0) {
                    emit MintLockDiscountOverwritten(
                        _tokens[i],
                        lockableTokens[_tokens[i]][0],
                        lockableTokens[_tokens[i]][1],
                        lockableTokens[_tokens[i]][2],
                        remainingQty
                    );
                }
            }
            // Store new discount, if _quantity is zero, discount is deleted
            if (_quantity[i] == 0) {
                delete lockableTokens[_tokens[i]];
                emit MintLockDiscountDeleted(_tokens[i]);
            } else {
                lockConfig[0] = _discounts[i];
                lockConfig[1] = _amounts[i];
                lockConfig[2] = _timestamps[i];
                lockConfig[3] = _quantity[i];
                lockableTokens[_tokens[i]] = lockConfig;
                emit MintLockDiscount(_tokens[i], lockConfig[0], lockConfig[1], lockConfig[2], lockConfig[3]);
            }
            unchecked { ++i; }
        }
    }
    // Refund tokens once lock period is over
    function unlockTokens(address _token) public {
        uint256 balance = lockedTokens[msg.sender][_token][0];
        if (balance == 0) { revert NoTokensLocked(); }
        if (lockedTokens[msg.sender][_token][1] > block.timestamp) { revert TokenNotUnlockable(); }
        bool success = IERC20(_token).transfer(msg.sender, balance);
        if (!success) { revert TransferFailed(); }
    }

    // Spend tokens to mint
    function mintWithTokens(
        address _to,
        address[] memory _tokens,
        uint256[] memory _amounts
    ) public virtual payable {
        // Mintable modifier checks
        if (!mintOpen) { revert MintClosed(); }
        if (totalSupply >= maxSupply) { revert CapReached(); }
        // Require NFT collection and array of tokenId arrays be equal length
        if (_tokens.length != _amounts.length) { revert ArrayLengthMismatch(); }
        uint256 mintNum;
        address recipient = fundsRecipient;

        for (uint256 i; i < _tokens.length;) {
            // Retrieve values
            address token = _tokens[i];
            uint256 amount = _amounts[i];
            uint256 tokenPrice = mintableWithTokens[token][0];
            uint256 discountQty = mintableWithTokens[token][1];
            uint256 num = amount / tokenPrice;

            // Ensure mint with token is allowed
            if (discountQty == 0) { revert NoDiscount(); }

            // Confirm discount isn't exceeded and that transfer is successful
            if (num > amount / discountQty) { revert DiscountExceeded(); }
            uint256 balance = IERC20(token).balanceOf(recipient);
            IERC20(token).transferFrom(msg.sender, recipient, num * tokenPrice);
            if (balance >= IERC20(token).balanceOf(recipient)) { revert TransferFailed(); }
            mintNum += num;
            
            // Reduce discount mint quantity by minted amount
            unchecked { 
                mintableWithTokens[token][1] -= num;
                ++i;
            }
        }

        // Prevent cap overage and process mint
        if (totalSupply + mintNum > maxSupply) { revert CapExceeded(); }
        _mint(_to, mintNum);
    }
    function configureMintWithTokens(
        address[] memory _tokens,
        uint256[] memory _prices,
        uint256[] memory _quantity
    ) public virtual onlyOwner {
        // Confirm array lengths all match
        uint256 length = _tokens.length;
        if (_prices.length != length && _quantity.length != length) { revert ArrayLengthMismatch(); }
        // Configure all tokens
        for (uint256 i; i < length;) {
            uint256[] memory mintConfig = new uint256[](2);
            mintConfig[0] = _prices[i];
            mintConfig[1] = _quantity[i];
            mintableWithTokens[_tokens[i]] = mintConfig;
            unchecked { ++i; }
        }
    }
    
    function mintWithNFTs(
        address _to,
        address[] memory _tokens,
        uint256[][] memory _tokenIds
    ) public virtual {
        // Mintable modifier checks
        if (!mintOpen) { revert MintClosed(); }
        if (totalSupply >= maxSupply) { revert CapReached(); }
        // Require NFT collection and array of tokenId arrays be equal length
        if (_tokens.length != _tokenIds.length) { revert ArrayLengthMismatch(); }
        uint256 mintNum;
        address recipient = owner();

        for (uint256 i; i < _tokens.length;) {
            // Retrieve values
            address token = _tokens[i];
            uint256 amount = _tokenIds[i].length;
            uint256 nftPrice = mintableWithNFTs[token][0];
            uint256 discountQty = mintableWithNFTs[token][1];
            uint256 mintQty = amount / nftPrice;

            // Ensure mint with NFT is allowed
            if (discountQty == 0) { revert NoDiscount(); }
            if (nftPrice > amount) { revert InsufficientPayment(); }
            if (mintQty > discountQty) { revert DiscountExceeded(); }

            // Process all token transfers
            for (uint256 j; j < mintQty * nftPrice;) {
                IERC721(token).transferFrom(msg.sender, recipient, _tokenIds[i][j]);
                if (IERC721(token).ownerOf(_tokenIds[i][j]) != recipient) { revert TransferFailed(); }
                unchecked { ++j; }
            }

            // Tally mint quantity
            mintNum += mintQty;
            unchecked { ++i; }
        }

        // Prevent cap overage and process mint
        if (totalSupply + mintNum > maxSupply) { revert CapExceeded(); }
        _mint(_to, mintNum);
    }
    function configureMintWithNFTs(
        address[] memory _tokens,
        uint256[] memory _prices,
        uint256[] memory _quantity
    ) public virtual onlyOwner {
        // Confirm array lengths all match
        uint256 length = _tokens.length;
        if (_prices.length != length && _quantity.length != length) { revert ArrayLengthMismatch(); }
        // Configure all tokens
        for (uint256 i; i < length;) {
            uint256[] memory mintConfig = new uint256[](2);
            mintConfig[0] = _prices[i];
            mintConfig[1] = _quantity[i];
            mintableWithNFTs[_tokens[i]] = mintConfig;
            unchecked { ++i; }
        }
    }*/

    // Vault contract management
    function wrap(uint256 _amount) public virtual onlyOwner { vault.wrap(_amount); }
    function addInventory(uint256[] calldata _tokenIds) public virtual onlyOwner { vault.addInventory(_tokenIds); }
    function addLiquidity(uint256[] calldata _tokenIds) public virtual onlyOwner { vault.addLiquidity(_tokenIds); }
    function deepenLiquidity(
        uint112 _eth,
        uint112 _weth,
        uint112 _nftxInv
    ) public virtual onlyOwner { vault.deepenLiquidity(_eth, _weth, _nftxInv); }
    function stakeLiquidity() public virtual onlyOwner { vault.stakeLiquidity(); }
    function claimRewards(address _recipient) public virtual onlyOwner { vault.claimRewards(_recipient); }
    function compoundRewards(uint112 _eth, uint112 _weth) public virtual onlyOwner { vault.compoundRewards(_eth, _weth); }
    // TODO: Fix this to not tamper with locked funds
    function rescueERC20(address _token, address _to) public virtual onlyOwner {
        //TODO: FIX if (lockedTokens[address(this)][_token].length != 0) { revert LockedToken(); }
        vault.rescueERC20(_token, _to);
    }
    // TODO: Fix this to not tamper with locked funds
    function rescueERC721(
        address _address,
        address _to,
        uint256 _tokenId
    ) public virtual onlyOwner { vault.rescueERC721(_address, _to, _tokenId); }
    function withdrawFunds(address _to, uint256 _amount) public virtual {
        // If renounced, send to fundsRecipient only
        if (owner() == address(0)) { _to = fundsRecipient; }
        // Otherwise, apply ownership check
        else if (owner() != msg.sender) { revert Unauthorized(); }
        _withdrawFunds(_to, _amount);
    }

    // Internal handling for receive() and fallback() to reduce code length
    function _processPayment() internal {
        if (mintOpen && msg.value >= price) { mint(msg.sender, uint64(msg.value / price)); }
        else {
            (bool success, ) = payable(address(vault)).call{ value: msg.value }("");
            if (!success) { revert TransferFailed(); }
        }
    }
    // Attempt to use funds sent directly to contract on mints if open and mintable, else send to vault
    receive() external payable { _processPayment(); }
    fallback() external payable { _processPayment(); }
}