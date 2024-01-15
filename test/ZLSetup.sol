// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {BonusPool} from "src/BonusPool.sol";
import {Epoch} from "src/Epoch.sol";
import {FeeDistributor} from "src/FeeDistributor.sol";
import {StakingEmissions} from "src/StakingEmissions.sol";
import {StreamedVesting} from "src/StreamedVesting.sol";
import {VestedZeroLend} from "src/VestedZeroLend.sol";
import {ZeroLend} from "src/ZeroLend.sol";
import {ZeroLocker} from "src/ZeroLocker.sol";
import {ZeroLockerTimelock} from "src/ZeroLockerTimelock.sol";
import {ZLRewardsController} from "src/ZLRewardsController.sol";
import {MockAggregator} from "src/tests/MockAggregator.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Burnable} from "src/interfaces/IERC20Burnable.sol";
import {IZeroLocker} from "src/interfaces/IZeroLocker.sol";
import {IBonusPool} from "src/interfaces/IBonusPool.sol";

contract ZLSetup {
    uint256 constant veSupply = 100_000_000_000 ether;
    address public vault = address(0x1234);
    ZeroLend token;
    VestedZeroLend vestedToken;
    BonusPool bonusPool;
    ZeroLocker locker;
    FeeDistributor feeDistributor;
    StakingEmissions stakingEmissions;
    StreamedVesting vesting;

    function deploy() internal virtual {
        //Deploying Contracts
        token = new ZeroLend(address(0));
        vestedToken = new VestedZeroLend();
        locker = new ZeroLocker();
        feeDistributor = new FeeDistributor();
        stakingEmissions = new StakingEmissions();
        vesting = new StreamedVesting();
        bonusPool = new BonusPool(IERC20(address(token)), address(vesting));

        //Inititalizing
        vesting.initialize(
            IERC20(token), IERC20Burnable(address(vestedToken)), IZeroLocker(locker), IBonusPool(bonusPool)
        );

        feeDistributor.initialize(address(locker), address(vestedToken));
        locker.initialize(address(token));

        stakingEmissions.initialize(feeDistributor, vestedToken, 4807692e18);

        // fund 5% unvested to staking bonus
        token.transfer(address(bonusPool), (5 * veSupply) / 100);

        // send 10% to liquidity
        token.transfer(address(token), (10 * veSupply) / 100);

        // send 10% vested tokens to the staking contract
        token.transfer(address(vesting), (10 * veSupply) / 100);
        vestedToken.transfer(address(stakingEmissions), (10 * veSupply) / 100);

        // send 47% for emissions
        token.transfer(address(vesting), (47 * veSupply) / 100);
        vestedToken.transfer(address(vault), (47 * veSupply) / 100);

        // whitelist the bonding sale contract
        vestedToken.addwhitelist(address(stakingEmissions), true);
        vestedToken.addwhitelist(address(feeDistributor), true);

        // start vesting and staking emissions (for test)
        vesting.start();
        stakingEmissions.start();
    }
}
