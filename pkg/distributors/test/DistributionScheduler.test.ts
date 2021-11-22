import { ethers } from 'hardhat';
import { Contract, BigNumber, BigNumberish } from 'ethers';
import { expect } from 'chai';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/dist/src/signer-with-address';

import Token from '@balancer-labs/v2-helpers/src/models/tokens/Token';
import TokenList from '@balancer-labs/v2-helpers/src/models/tokens/TokenList';

import { fp } from '@balancer-labs/v2-helpers/src/numbers';

import { deploy } from '@balancer-labs/v2-helpers/src/contract';
import { expectBalanceChange } from '@balancer-labs/v2-helpers/src/test/tokenBalance';
import * as expectEvent from '@balancer-labs/v2-helpers/src/test/expectEvent';
import { advanceTime, currentTimestamp } from '@balancer-labs/v2-helpers/src/time';
import { ZERO_BYTES32 } from '@balancer-labs/v2-helpers/src/constants';
import { MultiDistributor } from './helpers/MultiDistributor';
import TypesConverter from '@balancer-labs/v2-helpers/src/models/types/TypesConverter';
import { solidityKeccak256 } from 'ethers/lib/utils';
import { Account } from '@balancer-labs/v2-helpers/src/models/types/types';

describe('Distribution Scheduler', () => {
  let vault: Contract;
  let distributor: MultiDistributor;
  let scheduler: Contract;

  let stakingToken: Token, stakingTokens: TokenList;
  let distributionToken: Token, distributionTokens: TokenList;

  let distributionOwner: SignerWithAddress, poker: SignerWithAddress;

  before('setup signers', async () => {
    [, distributionOwner, poker] = await ethers.getSigners();
  });

  sharedBeforeEach('deploy distributor', async () => {
    distributor = await MultiDistributor.create();
    scheduler = await deploy('DistributionScheduler', { args: [distributor.address] });
    vault = distributor.vault;
  });

  sharedBeforeEach('deploy tokens', async () => {
    stakingTokens = await TokenList.create(1);
    stakingToken = stakingTokens.first;

    distributionTokens = await TokenList.create(1);
    distributionToken = distributionTokens.first;

    await distributionTokens.mint({ to: distributionOwner });
    await distributionTokens.approve({ to: scheduler, from: distributionOwner });
  });

  const calcScheduleId = (stakingToken: Token, distributionToken: Token, owner: Account, time: BigNumberish) => {
    const addresses = TypesConverter.toAddresses([stakingToken, distributionToken, owner]);
    return solidityKeccak256(['address', 'address', 'address', 'uint256'], [...addresses, time]);
  };

  describe('scheduleDistribution', () => {
    const amount = fp(1);

    it('creates a scheduled distribution', async () => {
      const time = (await currentTimestamp()).add(3600 * 24);
      await scheduler
        .connect(distributionOwner)
        .scheduleDistribution(ZERO_BYTES32, stakingToken.address, distributionToken.address, amount, time);

      const scheduleId = calcScheduleId(stakingToken, distributionToken, distributionOwner, time);

      const response = await scheduler.getScheduledDistributionInfo(scheduleId);

      expect(response.stakingToken).to.equal(stakingToken.address);
      expect(response.distributionToken).to.equal(distributionToken.address);
      expect(response.startTime).to.equal(time);
      expect(response.owner).to.equal(distributionOwner.address);
      expect(response.amount).to.equal(amount);
      expect(response.status).to.equal(1);
    });

    it('transfers distributionTokens to the scheduler', async () => {
      const time = (await currentTimestamp()).add(3600 * 24);

      await expectBalanceChange(
        () =>
          scheduler
            .connect(distributionOwner)
            .scheduleDistribution(ZERO_BYTES32, stakingToken.address, distributionToken.address, amount, time),
        distributionTokens,
        [
          { account: scheduler.address, changes: { [distributionToken.symbol]: amount } },
          { account: distributionOwner.address, changes: { [distributionToken.symbol]: amount.mul(-1) } },
        ]
      );
    });

    it('emits a DistributionScheduled event', async () => {
      const time = (await currentTimestamp()).add(3600 * 24);

      const receipt = await (
        await scheduler
          .connect(distributionOwner)
          .scheduleDistribution(ZERO_BYTES32, stakingToken.address, distributionToken.address, amount, time)
      ).wait();

      const scheduleId = calcScheduleId(stakingToken, distributionToken, distributionOwner, time);

      expectEvent.inReceipt(receipt, 'DistributionScheduled', {
        scheduleId,
        owner: distributionOwner.address,
        distributionToken: distributionToken.address,
        startTime: time,
        amount: amount,
      });
    });
  });

  describe('startDistributions', () => {
    const amount = fp(1);

    context('when distribution is pending', () => {
      let scheduleId: string;
      let time: BigNumber;
      sharedBeforeEach(async () => {
        // reward duration is important.  These tests assume a very short duration
        time = (await currentTimestamp()).add(3600 * 24);
        await scheduler
          .connect(distributionOwner)
          .scheduleDistribution(ZERO_BYTES32, stakingToken.address, distributionToken.address, amount, time);

        scheduleId = calcScheduleId(stakingToken, distributionToken, distributionOwner, time);
      });

      // Skip tests pending support for paying into a distribution owned by another address
      context.skip('when start time has passed', () => {
        sharedBeforeEach(async () => {
          await advanceTime(3600 * 25);
        });

        it('allows anyone to poke the contract to notify the staking contract and transfer rewards', async () => {
          await expectBalanceChange(
            () => scheduler.connect(poker).startDistributions([scheduleId]),
            distributionTokens,
            [{ account: distributor.address, changes: { DAI: ['very-near', amount] } }],
            vault
          );
        });

        it('emits DistributionStarted', async () => {
          const receipt = await (await scheduler.connect(poker).startDistributions([scheduleId])).wait();

          expectEvent.inReceipt(receipt, 'DistributionStarted', {
            scheduleId,
            owner: distributionOwner.address,
            stakingToken: stakingToken.address,
            distributionToken: distributionToken.address,
            startTime: time,
            amount: amount,
          });
        });

        it('emits RewardAdded in MultiDistributor', async () => {
          const receipt = await (await scheduler.connect(poker).startDistributions([scheduleId])).wait();

          expectEvent.inIndirectReceipt(receipt, distributor.instance.interface, 'RewardAdded', {
            distributionToken: distributionToken.address,
            amount: amount,
          });
        });

        it('marks scheduled distribution as STARTED', async () => {
          await scheduler.connect(poker).startDistributions([scheduleId]);

          const response = await scheduler.getScheduledDistributionInfo(scheduleId);
          expect(response.status).to.equal(2);
        });
      });

      context('when start time has not passed', () => {
        it('reverts', async () => {
          await expect(scheduler.connect(poker).startDistributions([scheduleId])).to.be.revertedWith(
            'Distribution start time is in the future'
          );
        });
      });
    });

    // Skip tests pending support for paying into a distribution owned by another address
    context.skip('when distribution has been started', () => {
      let scheduleId: string;
      let time: BigNumber;
      sharedBeforeEach(async () => {
        // reward duration is important.  These tests assume a very short duration
        time = (await currentTimestamp()).add(3600 * 24);
        await scheduler
          .connect(distributionOwner)
          .scheduleDistribution(ZERO_BYTES32, stakingToken.address, distributionToken.address, amount, time);

        scheduleId = calcScheduleId(stakingToken, distributionToken, distributionOwner, time);
        await advanceTime(3600 * 25);
        await scheduler.connect(poker).startDistributions([scheduleId]);
      });

      it('reverts', async () => {
        await expect(scheduler.connect(poker).startDistributions([scheduleId])).to.be.revertedWith(
          'Reward cannot be started'
        );
      });
    });
  });
});
