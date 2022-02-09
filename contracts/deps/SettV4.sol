// SPDX-License-Identifier: MIT

pragma solidity ^0.6.11;

import "../../deps/@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "../../deps/@openzeppelin/contracts-upgradeable/math/SafeMathUpgradeable.sol";
import "../../deps/@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "../../deps/@openzeppelin/contracts-upgradeable/token/ERC20/SafeERC20Upgradeable.sol";
import "../../deps/@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "../../deps/@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "../../deps/@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import "interfaces/badger/IController.sol";
import "interfaces/erc20/IERC20Detailed.sol";
import "../../deps/SettAccessControlDefended.sol";
import "interfaces/yearn/BadgerGuestlistApi.sol";

/**** */
/*
import "../../deps/@openzeppelin/contracts/math/Math.sol";
import "../../deps/@openzeppelin/contracts/math/SafeMath.sol";
import "../../deps/@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../../deps/@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../../deps/@openzeppelin/contracts/token/ERC20/SafeERC20.sol";*/
import "../../deps/@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../../deps/@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3MintCallback.sol";
import "../../deps/@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import "../../deps/@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "../../deps/@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "../../deps/@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import "../../deps/@uniswap/v3-periphery/contracts/libraries/PositionKey.sol";

//import "interfaces/alpha/IVault.sol";
/**** */

/* 
    Source: https://github.com/iearn-finance/yearn-protocol/blob/develop/contracts/vaults/yVault.sol
    
    Changelog:

    V1.1
    * Strategist no longer has special function calling permissions
    * Version function added to contract
    * All write functions, with the exception of transfer, are pausable
    * Keeper or governance can pause
    * Only governance can unpause

    V1.2
    * Transfer functions are now pausable along with all other non-permissioned write functions
    * All permissioned write functions, with the exception of pause() & unpause(), are pausable as well

    V1.3
    * Add guest list functionality
    * All deposits can be optionally gated by external guestList approval logic on set guestList contract

    V1.4
    * Add depositFor() to deposit on the half of other users. That user will then be blockLocked.
*/

contract SettV4 is
    ERC20Upgradeable,
    SettAccessControlDefended,
    PausableUpgradeable,
    IUniswapV3MintCallback,
    IUniswapV3SwapCallback,
    ReentrancyGuard
{
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using AddressUpgradeable for address;
    using SafeMathUpgradeable for uint256;

    //IERC20Upgradeable public token;

    uint256 public amount0Min;
    uint256 public amount1Min;
    uint256 public constant max0 = 10000;
    uint256 public constant max1 = 10000;

    address public controller;

    mapping(address => uint256) public blockLock;

    string internal constant _defaultNamePrefix = "Badger Sett ";
    string internal constant _symbolSymbolPrefix = "b";

    address public guardian;

    BadgerGuestListAPI public guestList;

    /** */
    IUniswapV3Pool public pool;
    IERC20Upgradeable public token0;
    IERC20Upgradeable public token1;
    int24 public tickSpacing;

    uint256 public protocolFee;
    uint256 public maxTotalSupply;
    address public strategy;
    //address public governance;
    address public pendingGovernance;

    int24 public baseLower;
    int24 public baseUpper;
    int24 public limitLower;
    int24 public limitUpper;
    uint256 public accruedProtocolFees0;
    uint256 public accruedProtocolFees1;

    event Deposit(
        address indexed sender,
        address indexed to,
        uint256 shares,
        uint256 amount0,
        uint256 amount1
    );

    event Withdraw(
        address indexed sender,
        address indexed to,
        uint256 shares,
        uint256 amount0,
        uint256 amount1
    );

    event CollectFees(
        uint256 feesToVault0,
        uint256 feesToVault1,
        uint256 feesToProtocol0,
        uint256 feesToProtocol1
    );

    event Snapshot(
        int24 tick,
        uint256 totalAmount0,
        uint256 totalAmount1,
        uint256 totalSupply
    );

    /** */
    event FullPricePerShareUpdated(
        uint256 value1,
        uint256 value2,
        uint256 indexed timestamp,
        uint256 indexed blockNumber
    );

    function initialize(
        //address _token,
        address _controller,
        address _governance,
        address _keeper,
        address _guardian,
        bool _overrideTokenName,
        string memory _namePrefix,
        string memory _symbolPrefix,
        address _pool,
        uint256 _protocolFee,
        uint256 _maxTotalSupply
    ) public initializer whenNotPaused {
        /** */
        pool = IUniswapV3Pool(_pool);
        token0 = IERC20Upgradeable(IUniswapV3Pool(_pool).token0());
        token1 = IERC20Upgradeable(IUniswapV3Pool(_pool).token1());
        tickSpacing = IUniswapV3Pool(_pool).tickSpacing();

        protocolFee = _protocolFee;
        maxTotalSupply = _maxTotalSupply;
        governance = msg.sender;

        require(_protocolFee < 1e6, "protocolFee");
        /** */
        IERC20Detailed namedToken = IERC20Detailed(address(token0));
        string memory tokenName = namedToken.name();
        string memory tokenSymbol = namedToken.symbol();

        string memory name;
        string memory symbol;

        if (_overrideTokenName) {
            name = string(abi.encodePacked(_namePrefix, tokenName));
            symbol = string(abi.encodePacked(_symbolPrefix, tokenSymbol));
        } else {
            name = string(abi.encodePacked(_defaultNamePrefix, tokenName));
            symbol = string(abi.encodePacked(_symbolSymbolPrefix, tokenSymbol));
        }

        __ERC20_init(name, symbol);

        //token = IERC20Upgradeable(_token);
        governance = _governance;
        strategist = address(0);
        keeper = _keeper;
        controller = _controller;
        guardian = _guardian;

        //min = 9500;
        amount0Min = 0;
        amount1Min = 0;
        (uint256 v1, uint256 v2) = getPricePerFullShare();
        emit FullPricePerShareUpdated(v1, v2, now, block.number);

        // Paused on launch
        _pause();
    }

    /// ===== Modifiers =====

    function _onlyController() internal view {
        require(msg.sender == controller, "onlyController");
    }

    function _onlyAuthorizedPausers() internal view {
        require(
            msg.sender == guardian || msg.sender == governance,
            "onlyPausers"
        );
    }

    function _blockLocked() internal view {
        require(blockLock[msg.sender] < block.number, "blockLocked");
    }

    /// ===== View Functions =====

    function version() public view returns (string memory) {
        return "1.4";
    }

    function getPricePerFullShare()
        public
        view
        virtual
        returns (uint256, uint256)
    {
        if (totalSupply() == 0) {
            return (1e18, 1e18);
        }
        (uint256 b0, uint256 b1) = balance();
        return (
            b0.mul(1e18).div(totalSupply()),
            b1.mul(1e18).div(totalSupply())
        );
    }

    /// @notice Return the total balance of the underlying token within the system
    /// @notice Sums the balance in the Sett, the Controller, and the Strategy
    function balance() public view virtual returns (uint256, uint256) {
        return (
            token0.balanceOf(address(this)).add(
                IController(controller).balanceOf(address(token0))
            ),
            token1.balanceOf(address(this)).add(
                IController(controller).balanceOf(address(token1))
            )
        );
    }

    /// @notice Defines how much of the Setts' underlying can be borrowed by the Strategy for use
    /// @notice Custom logic in here for how much the vault allows to be borrowed
    /// @notice Sets minimum required on-hand to keep small withdrawals cheap
    function available() public view virtual returns (uint256, uint256) {
        // return (token0.balanceOf(address(this)).mul(amount0Min).div(max0),
        //         token1.balanceOf(address(this)).mul(amount1Min).div(max1));
        return (
            token0.balanceOf(address(this)),
            token1.balanceOf(address(this))
        );
    }

    /// ===== Public Actions =====

    /// @notice Deposit assets into the Sett, and return corresponding shares to the user
    /// @notice Only callable by EOA accounts that pass the _defend() check
    function deposit(uint256 _amount0, uint256 _amount1) public whenNotPaused {
        _defend();
        _blockLocked();

        _lockForBlock(msg.sender);
        _depositWithAuthorization(_amount0, _amount1, new bytes32[](0));
    }

    /// @notice Deposit variant with proof for merkle guest list
    function deposit(
        uint256 _amount0,
        uint256 _amount1,
        bytes32[] memory proof
    ) public whenNotPaused {
        _defend();
        _blockLocked();

        _lockForBlock(msg.sender);
        _depositWithAuthorization(_amount0, _amount1, proof);
    }

    /// @notice Convenience function: Deposit entire balance of asset into the Sett, and return corresponding shares to the user
    /// @notice Only callable by EOA accounts that pass the _defend() check
    function depositAll() external whenNotPaused {
        _defend();
        _blockLocked();

        _lockForBlock(msg.sender);
        _depositWithAuthorization(
            token0.balanceOf(msg.sender),
            token1.balanceOf(msg.sender),
            new bytes32[](0)
        );
    }

    /// @notice DepositAll variant with proof for merkle guest list
    function depositAll(bytes32[] memory proof) external whenNotPaused {
        _defend();
        _blockLocked();

        _lockForBlock(msg.sender);
        _depositWithAuthorization(
            token0.balanceOf(msg.sender),
            token1.balanceOf(msg.sender),
            proof
        );
    }

    /// @notice Deposit assets into the Sett, and return corresponding shares to the user
    /// @notice Only callable by EOA accounts that pass the _defend() check
    function depositFor(
        address _recipient,
        uint256 _amount0,
        uint256 _amount1
    ) public whenNotPaused {
        _defend();
        _blockLocked();

        _lockForBlock(_recipient);
        _depositForWithAuthorization(
            _recipient,
            _amount0,
            _amount1,
            new bytes32[](0)
        );
    }

    /// @notice Deposit variant with proof for merkle guest list
    function depositFor(
        address _recipient,
        uint256 _amount0,
        uint256 _amount1,
        bytes32[] memory proof
    ) public whenNotPaused {
        _defend();
        _blockLocked();

        _lockForBlock(_recipient);
        _depositForWithAuthorization(_recipient, _amount0, _amount1, proof);
    }

    /// @notice No rebalance implementation for lower fees and faster swaps
    function withdraw(uint256 _shares) public whenNotPaused {
        _defend();
        _blockLocked();

        _lockForBlock(msg.sender);
        _withdraw(_shares);
    }

    /// @notice Convenience function: Withdraw all shares of the sender
    function withdrawAll() external whenNotPaused {
        _defend();
        _blockLocked();

        _lockForBlock(msg.sender);
        _withdraw(balanceOf(msg.sender));
    }

    /// ===== Permissioned Actions: Governance =====

    function setGuestList(address _guestList) external whenNotPaused {
        _onlyGovernance();
        guestList = BadgerGuestListAPI(_guestList);
    }

    /// @notice Set minimum threshold of underlying that must be deposited in strategy
    /// @notice Can only be changed by governance
    function setMin(uint256 _amount0Min, uint256 _amount1Min)
        external
        whenNotPaused
    {
        _onlyGovernance();
        amount0Min = _amount0Min;
        amount1Min = _amount1Min;
    }

    /// @notice Change controller address
    /// @notice Can only be changed by governance
    function setController(address _controller) public whenNotPaused {
        _onlyGovernance();
        controller = _controller;
    }

    /// @notice Change guardian address
    /// @notice Can only be changed by governance
    function setGuardian(address _guardian) external whenNotPaused {
        _onlyGovernance();
        guardian = _guardian;
    }

    /// ===== Permissioned Actions: Controller =====

    /// @notice Used to swap any borrowed reserve over the debt limit to liquidate to 'token'
    /// @notice Only controller can trigger harvests
    function harvest(
        address reserve,
        uint256 amount0,
        uint256 amount1
    ) external whenNotPaused {
        _onlyController();
        require(reserve != address(token0), "token");
        IERC20Upgradeable(reserve).safeTransfer(controller, amount0);

        require(reserve != address(token1), "token");
        IERC20Upgradeable(reserve).safeTransfer(controller, amount1);
    }

    /// ===== Permissioned Functions: Trusted Actors =====

    /// @notice Transfer the underlying available to be claimed to the controller
    /// @notice The controller will deposit into the Strategy for yield-generating activities
    /// @notice Permissionless operation
    function earn() public whenNotPaused {
        _onlyAuthorizedActors();

        (uint256 _bal0, uint256 _bal1) = available();
        token0.safeTransfer(controller, _bal0);
        IController(controller).earn(address(token0), _bal0);
        token1.safeTransfer(controller, _bal1);
        IController(controller).earn(address(token1), _bal1);
    }

    /// @dev Emit event tracking current full price per share
    /// @dev Provides a pure on-chain way of approximating APY
    function trackFullPricePerShare() external whenNotPaused {
        _onlyAuthorizedActors();

        (uint256 v1, uint256 v2) = getPricePerFullShare();
        emit FullPricePerShareUpdated(v1, v2, now, block.number);
    }

    function pause() external {
        _onlyAuthorizedPausers();
        _pause();
    }

    function unpause() external {
        _onlyGovernance();
        _unpause();
    }

    /// ===== Internal Implementations =====

    /// @dev Calculate the number of shares to issue for a given deposit
    /// @dev This is based on the realized value of underlying assets between Sett & associated Strategy
    // @dev deposit for msg.sender
    function _deposit(uint256 _amount0, uint256 _amount1) internal {
        _depositFor(msg.sender, _amount0, _amount1);
    }

    function _depositFor(
        address recipient,
        uint256 amount0Desired,
        uint256 amount1Desired
    )
        internal
        virtual
        returns (
            uint256 shares,
            uint256 amount0,
            uint256 amount1
        )
    {
        /*uint256 _pool = balance();
        uint256 _before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), _amount);
        uint256 _after = token.balanceOf(address(this));
        _amount = _after.sub(_before); // Additional check for deflationary tokens
        uint256 shares = 0;
        if (totalSupply() == 0) {
            shares = _amount;
        } else {
            shares = (_amount.mul(totalSupply())).div(_pool);
        }
        _mint(recipient, shares);*/

        require(
            amount0Desired > 0 || amount1Desired > 0,
            "amount0Desired or amount1Desired"
        );
        require(
            recipient != address(0) && recipient != address(this),
            "recipient"
        );

        // Poke positions so vault's current holdings are up-to-date
        _poke(baseLower, baseUpper);
        _poke(limitLower, limitUpper);

        // Calculate amounts proportional to vault's holdings
        (shares, amount0, amount1) = _calcSharesAndAmounts(
            amount0Desired,
            amount1Desired
        );
        require(shares > 0, "shares");
        require(amount0 >= amount0Min, "amount0Min");
        require(amount1 >= amount1Min, "amount1Min");
        require(amount0 > 0, "amount0Min");
        require(amount1 > 0, "amount1Min");

        // Pull in tokens from sender
        // if (amount0 > 0) token0.safeTransferFrom(msg.sender, address(this), amount0);
        // if (amount1 > 0) token1.safeTransferFrom(msg.sender, address(this), amount1);
        if (amount0 > 0)
            token0.transferFrom(msg.sender, address(this), amount0);
        if (amount1 > 0)
            token1.transferFrom(msg.sender, address(this), amount1);

        // Mint shares to recipient
        _mint(recipient, shares);
        emit Deposit(msg.sender, recipient, shares, amount0, amount1);
        //require(totalSupply() <= maxTotalSupply, "maxTotalSupply"); //mod
    }

    function _depositWithAuthorization(
        uint256 _amount0,
        uint256 _amount1,
        bytes32[] memory proof
    ) internal virtual {
        if (address(guestList) != address(0)) {
            require(
                guestList.authorized(msg.sender, _amount0, proof),
                "guest-list-authorization1"
            );
            require(
                guestList.authorized(msg.sender, _amount1, proof),
                "guest-list-authorization2"
            );
        }
        _deposit(_amount0, _amount1);
    }

    function _depositForWithAuthorization(
        address _recipient,
        uint256 _amount0,
        uint256 _amount1,
        bytes32[] memory proof
    ) internal virtual {
        if (address(guestList) != address(0)) {
            require(
                guestList.authorized(_recipient, _amount0, proof),
                "guest-list-authorization1"
            );
            require(
                guestList.authorized(_recipient, _amount1, proof),
                "guest-list-authorization2"
            );
        }
        _depositFor(_recipient, _amount0, _amount1);
    }

    // No rebalance implementation for lower fees and faster swaps
    function _withdraw(uint256 _shares)
        internal
        virtual
        returns (uint256 amount0, uint256 amount1)
    {
        address to = msg.sender;
        require(_shares > 0, "shares");
        require(to != address(0) && to != address(this), "to");
        uint256 totalSupply = totalSupply();

        // Burn shares
        _burn(msg.sender, _shares);

        // Calculate token amounts proportional to unused balances
        uint256 unusedAmount0 = getBalance0().mul(_shares).div(totalSupply);
        uint256 unusedAmount1 = getBalance1().mul(_shares).div(totalSupply);

        // Withdraw proportion of liquidity from Uniswap pool
        (uint256 baseAmount0, uint256 baseAmount1) =
            _burnLiquidityShare(baseLower, baseUpper, _shares, totalSupply);
        (uint256 limitAmount0, uint256 limitAmount1) =
            _burnLiquidityShare(limitLower, limitUpper, _shares, totalSupply);

        // Sum up total amounts owed to recipient
        amount0 = unusedAmount0.add(baseAmount0).add(limitAmount0);
        amount1 = unusedAmount1.add(baseAmount1).add(limitAmount1);
        require(amount0 >= amount0Min, "amount0Min");
        require(amount1 >= amount1Min, "amount1Min");

        // Push tokens to recipient
        // if (amount0 > 0) token0.safeTransfer(to, amount0);
        // if (amount1 > 0) token1.safeTransfer(to, amount1);
        if (amount0 > 0) token0.transfer(to, amount0);
        if (amount1 > 0) token1.transfer(to, amount1);

        emit Withdraw(msg.sender, to, _shares, amount0, amount1);

        /*
        uint256 r = (balance().mul(_shares)).div(totalSupply());
        _burn(msg.sender, _shares);

        // Check balance
        uint256 b = token.balanceOf(address(this));
        if (b < r) {
            uint256 _toWithdraw = r.sub(b);
            IController(controller).withdraw(address(token), _toWithdraw);
            uint256 _after = token.balanceOf(address(this));
            uint256 _diff = _after.sub(b);
            if (_diff < _toWithdraw) {
                r = b.add(_diff);
            }
        }

        token.safeTransfer(msg.sender, r);*/
    }

    function _lockForBlock(address account) internal {
        blockLock[account] = block.number;
    }

    /// ===== ERC20 Overrides =====

    /// @dev Add blockLock to transfers, users cannot transfer tokens in the same block as a deposit or withdrawal.
    function transfer(address recipient, uint256 amount)
        public
        virtual
        override
        whenNotPaused
        returns (bool)
    {
        _blockLocked();
        return super.transfer(recipient, amount);
    }

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public virtual override whenNotPaused returns (bool) {
        _blockLocked();
        return super.transferFrom(sender, recipient, amount);
    }

    /// @dev Calculates the largest possible `amount0` and `amount1` such that
    /// they're in the same proportion as total amounts, but not greater than
    /// `amount0Desired` and `amount1Desired` respectively.
    function _calcSharesAndAmounts(
        uint256 amount0Desired,
        uint256 amount1Desired
    )
        internal
        view
        returns (
            uint256 shares,
            uint256 amount0,
            uint256 amount1
        )
    {
        uint256 totalSupply = totalSupply();
        (uint256 total0, uint256 total1) = getTotalAmounts();

        // If total supply > 0, vault can't be empty
        assert(totalSupply == 0 || total0 > 0 || total1 > 0);

        if (totalSupply == 0) {
            // For first deposit, just use the amounts desired
            amount0 = amount0Desired;
            amount1 = amount1Desired;
            //shares = math.max(amount0, amount1);
            if (amount0 >= amount1) shares = amount0;
            else shares = amount1;
        } else if (total0 == 0) {
            amount1 = amount1Desired;
            shares = amount1.mul(totalSupply).div(total1);
        } else if (total1 == 0) {
            amount0 = amount0Desired;
            shares = amount0.mul(totalSupply).div(total0);
        } else {
            // uint256 cross = math.min(amount0Desired.mul(total1), amount1Desired.mul(total0));
            uint256 cross = amount0Desired.mul(total0);
            uint256 t = amount1Desired.mul(total0);
            if (cross > t) cross = t;

            require(cross > 0, "cross");

            // Round up amounts
            amount0 = cross.sub(1).div(total1).add(1);
            amount1 = cross.sub(1).div(total0).add(1);
            shares = cross.mul(totalSupply).div(total0).div(total1);
        }
    }

    /// @dev Do zero-burns to poke a position on Uniswap so earned fees are
    /// updated. Should be called if total amounts needs to include up-to-date
    /// fees.
    function _poke(int24 tickLower, int24 tickUpper) internal {
        (uint128 liquidity, , , , ) = _position(tickLower, tickUpper);
        if (liquidity > 0) {
            pool.burn(tickLower, tickUpper, 0);
        }
    }

    /**
     * @notice Calculates the vault's total holdings of token0 and token1 - in
     * other words, how much of each token the vault would hold if it withdrew
     * all its liquidity from Uniswap.
     */
    function getTotalAmounts()
        public
        view
        returns (uint256 total0, uint256 total1)
    {
        (uint256 baseAmount0, uint256 baseAmount1) =
            getPositionAmounts(baseLower, baseUpper);
        (uint256 limitAmount0, uint256 limitAmount1) =
            getPositionAmounts(limitLower, limitUpper);
        total0 = getBalance0().add(baseAmount0).add(limitAmount0);
        total1 = getBalance1().add(baseAmount1).add(limitAmount1);
    }

    /**
     * @notice Amounts of token0 and token1 held in vault's position. Includes
     * owed fees but excludes the proportion of fees that will be paid to the
     * protocol. Doesn't include fees accrued since last poke.
     */
    function getPositionAmounts(int24 tickLower, int24 tickUpper)
        public
        view
        returns (uint256 amount0, uint256 amount1)
    {
        (uint128 liquidity, , , uint128 tokensOwed0, uint128 tokensOwed1) =
            _position(tickLower, tickUpper);
        (amount0, amount1) = _amountsForLiquidity(
            tickLower,
            tickUpper,
            liquidity
        );

        // Subtract protocol fees
        uint256 oneMinusFee = uint256(1e6).sub(protocolFee);
        amount0 = amount0.add(uint256(tokensOwed0).mul(oneMinusFee).div(1e6));
        amount1 = amount1.add(uint256(tokensOwed1).mul(oneMinusFee).div(1e6));
    }

    /**
     * @notice Balance of token0 in vault not used in any position.
     */
    function getBalance0() public view returns (uint256) {
        return token0.balanceOf(address(this)).sub(accruedProtocolFees0);
    }

    /**
     * @notice Balance of token1 in vault not used in any position.
     */
    function getBalance1() public view returns (uint256) {
        return token1.balanceOf(address(this)).sub(accruedProtocolFees1);
    }

    /// @dev Wrapper around `IUniswapV3Pool.positions()`.
    function _position(int24 tickLower, int24 tickUpper)
        internal
        view
        returns (
            uint128,
            uint256,
            uint256,
            uint128,
            uint128
        )
    {
        bytes32 positionKey =
            PositionKey.compute(address(this), tickLower, tickUpper);
        return pool.positions(positionKey);
    }

    /// @dev Wrapper around `LiquidityAmounts.getAmountsForLiquidity()`.
    function _amountsForLiquidity(
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) internal view returns (uint256, uint256) {
        (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();
        return
            LiquidityAmounts.getAmountsForLiquidity(
                sqrtRatioX96,
                TickMath.getSqrtRatioAtTick(tickLower),
                TickMath.getSqrtRatioAtTick(tickUpper),
                liquidity
            );
    }

    /// @dev Wrapper around `LiquidityAmounts.getLiquidityForAmounts()`.
    function _liquidityForAmounts(
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    ) internal view returns (uint128) {
        (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();
        return
            LiquidityAmounts.getLiquidityForAmounts(
                sqrtRatioX96,
                TickMath.getSqrtRatioAtTick(tickLower),
                TickMath.getSqrtRatioAtTick(tickUpper),
                amount0,
                amount1
            );
    }

    /// @dev Casts uint256 to uint128 with overflow check.
    function _toUint128(uint256 x) internal pure returns (uint128) {
        assert(x <= type(uint128).max);
        return uint128(x);
    }

    /// @dev Callback for Uniswap V3 pool.
    function uniswapV3MintCallback(
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external override {
        require(msg.sender == address(pool));
        // if (amount0 > 0) token0.safeTransfer(msg.sender, amount0);
        // if (amount1 > 0) token1.safeTransfer(msg.sender, amount1);
        if (amount0 > 0) token0.transfer(msg.sender, amount0);
        if (amount1 > 0) token1.transfer(msg.sender, amount1);
    }

    /// @dev Callback for Uniswap V3 pool.
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external override {
        require(msg.sender == address(pool));
        // if (amount0Delta > 0) token0.safeTransfer(msg.sender, uint256(amount0Delta));
        // if (amount1Delta > 0) token1.safeTransfer(msg.sender, uint256(amount1Delta));
        if (amount0Delta > 0)
            token0.transfer(msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0)
            token1.transfer(msg.sender, uint256(amount1Delta));
    }

    /// @dev Withdraws share of liquidity in a range from Uniswap pool.
    function _burnLiquidityShare(
        int24 tickLower,
        int24 tickUpper,
        uint256 shares,
        uint256 totalSupply
    ) internal returns (uint256 amount0, uint256 amount1) {
        (uint128 totalLiquidity, , , , ) = _position(tickLower, tickUpper);
        uint256 liquidity =
            uint256(totalLiquidity).mul(shares).div(totalSupply);

        if (liquidity > 0) {
            (uint256 burned0, uint256 burned1, uint256 fees0, uint256 fees1) =
                _burnAndCollect(tickLower, tickUpper, _toUint128(liquidity));

            // Add share of fees
            amount0 = burned0.add(fees0.mul(shares).div(totalSupply));
            amount1 = burned1.add(fees1.mul(shares).div(totalSupply));
        }
    }

    /// @dev Withdraws liquidity from a range and collects all fees in the
    /// process.
    function _burnAndCollect(
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    )
        internal
        returns (
            uint256 burned0,
            uint256 burned1,
            uint256 feesToVault0,
            uint256 feesToVault1
        )
    {
        if (liquidity > 0) {
            (burned0, burned1) = pool.burn(tickLower, tickUpper, liquidity);
        }

        // Collect all owed tokens including earned fees
        (uint256 collect0, uint256 collect1) =
            pool.collect(
                address(this),
                tickLower,
                tickUpper,
                type(uint128).max,
                type(uint128).max
            );

        feesToVault0 = collect0.sub(burned0);
        feesToVault1 = collect1.sub(burned1);
        uint256 feesToProtocol0;
        uint256 feesToProtocol1;

        // Update accrued protocol fees
        uint256 _protocolFee = protocolFee;
        if (_protocolFee > 0) {
            feesToProtocol0 = feesToVault0.mul(_protocolFee).div(1e6);
            feesToProtocol1 = feesToVault1.mul(_protocolFee).div(1e6);
            feesToVault0 = feesToVault0.sub(feesToProtocol0);
            feesToVault1 = feesToVault1.sub(feesToProtocol1);
            accruedProtocolFees0 = accruedProtocolFees0.add(feesToProtocol0);
            accruedProtocolFees1 = accruedProtocolFees1.add(feesToProtocol1);
        }
        emit CollectFees(
            feesToVault0,
            feesToVault1,
            feesToProtocol0,
            feesToProtocol1
        );
    }

    /**
     * @notice Updates vault's positions. Can only be called by the strategy.
     * @dev Two orders are placed - a base order and a limit order. The base
     * order is placed first with as much liquidity as possible. This order
     * should use up all of one token, leaving only the other one. This excess
     * amount is then placed as a single-sided bid or ask order.
     */ /*
    function rebalance(
        int256 swapAmount,
        uint160 sqrtPriceLimitX96,
        int24 _baseLower,
        int24 _baseUpper,
        int24 _bidLower,
        int24 _bidUpper,
        int24 _askLower,
        int24 _askUpper
    ) external nonReentrant {
        require(msg.sender == strategy, "strategy");
        _checkRange(_baseLower, _baseUpper);
        _checkRange(_bidLower, _bidUpper);
        _checkRange(_askLower, _askUpper);

        (, int24 tick, , , , , ) = pool.slot0();
        require(_bidUpper <= tick, "bidUpper");
        require(_askLower > tick, "askLower"); // inequality is strict as tick is rounded down

        // Withdraw all current liquidity from Uniswap pool
        {
            (uint128 baseLiquidity, , , , ) = _position(baseLower, baseUpper);
            (uint128 limitLiquidity, , , , ) = _position(limitLower, limitUpper);
            _burnAndCollect(baseLower, baseUpper, baseLiquidity);
            _burnAndCollect(limitLower, limitUpper, limitLiquidity);
        }

        // Emit snapshot to record balances and supply
        uint256 balance0 = getBalance0();
        uint256 balance1 = getBalance1();
        emit Snapshot(tick, balance0, balance1, totalSupply());

        if (swapAmount != 0) {
            pool.swap(
                address(this),
                swapAmount > 0,
                swapAmount > 0 ? swapAmount : -swapAmount,
                sqrtPriceLimitX96,
                ""
            );
            balance0 = getBalance0();
            balance1 = getBalance1();
        }

        // Place base order on Uniswap
        uint128 liquidity = _liquidityForAmounts(_baseLower, _baseUpper, balance0, balance1);
        _mintLiquidity(_baseLower, _baseUpper, liquidity);
        (baseLower, baseUpper) = (_baseLower, _baseUpper);

        balance0 = getBalance0();
        balance1 = getBalance1();

        // Place bid or ask order on Uniswap depending on which token is left
        uint128 bidLiquidity = _liquidityForAmounts(_bidLower, _bidUpper, balance0, balance1);
        uint128 askLiquidity = _liquidityForAmounts(_askLower, _askUpper, balance0, balance1);
        if (bidLiquidity > askLiquidity) {
            _mintLiquidity(_bidLower, _bidUpper, bidLiquidity);
            (limitLower, limitUpper) = (_bidLower, _bidUpper);
        } else {
            _mintLiquidity(_askLower, _askUpper, askLiquidity);
            (limitLower, limitUpper) = (_askLower, _askUpper);
        }
    }

    function _checkRange(int24 tickLower, int24 tickUpper) internal view {
        int24 _tickSpacing = tickSpacing;
        require(tickLower < tickUpper, "tickLower < tickUpper");
        require(tickLower >= TickMath.MIN_TICK, "tickLower too low");
        require(tickUpper <= TickMath.MAX_TICK, "tickUpper too high");
        require(tickLower % _tickSpacing == 0, "tickLower % tickSpacing");
        require(tickUpper % _tickSpacing == 0, "tickUpper % tickSpacing");
    }

    /// @dev Deposits liquidity in a range on the Uniswap pool.
    function _mintLiquidity(
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) internal {
        if (liquidity > 0) {
            pool.mint(address(this), tickLower, tickUpper, liquidity, "");
        }
    }*/
}
