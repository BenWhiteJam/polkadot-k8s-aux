/* A simple one-shot payout script for Polkadot
 * Copyright 2021 MIDL.dev
 *
 * This script requires a payout account with dust money to pay for transaction fees to call the payout extrinsic.
 *
 *  ########################################################
 *  ##                                                    ##
 *  ##  Want a simpler solution ?                         ##
 *  ##                                                    ##
 *  ##    https://MIDL.dev/polkadot-automated-payouts     ##
 *  ##                                                    ##
 *  ##  Kusama automated payouts for US$9.99 / month      ##
 *  ##  Polkadot automated payouts for US$19.99 / month   ##
 *  ##                                                    ##
 *  ########################################################
 *
 * All inputs come from environment variables:
 * 
 *  * NODE_ENDPOINT : the polkadot/kusama node rpc (localhost)
 *  * PAYOUT_ACOUNT_MNEMONIC: 12 words of the payout account (should have little balance, just for fees)
 *  * STASH_ACCOUNT_ADDRESS: the address of the validator's stash
 *
 * The script queries the current era. It then verifies that:
 *
 *  * the previous era has not been paid yet
 *  * the validator was active in the previous era
 *
 *  When these conditions are met, it sends the payout extrinsic and exits.
 *
 *  This script does not:
 *   * support multiple validators. To support multiple validator, run several cronjobs.
 *   * support older eras than the one before the current one. This script should run often.
 *
 *  To run once:
 *    export NODE_ENDPOINT=localhost
 *    export PAYOUT_ACCOUNT_MNEMONIC="your twelve key words..."
 *    export STASH_ACCOUNT_ADDRESS="GyrcqNwF87LFc4BRxhxakq8GZRVNzhGn3NLfSQhVHQxqYYx"
 *    node index.js
 *
 *  To run continously, put the following script in a cronjob.
 *  See for reference: https://opensource.com/article/17/11/how-use-cron-linux
 * */

// Import the API
const { ApiPromise, WsProvider } = require('@polkadot/api');
const { Keyring } = require('@polkadot/keyring');

async function main () {
  const provider = new WsProvider(`ws://${process.env.NODE_ENDPOINT}:9944`);
  // Create our API
  const api = await ApiPromise.create({ provider });

  // Constuct the keying
  const keyring = new Keyring({ type: 'sr25519' });

  // Add the payout account to our keyring
  const payoutKey = keyring.addFromUri(process.env.PAYOUT_ACCOUNT_MNEMONIC);

  const [currentEra] = await Promise.all([
    api.query.staking.currentEra()
  ]);


  const stash_account = process.env.STASH_ACCOUNT_ADDRESS;
  var controller_address = await api.query.staking.bonded(stash_account);
  var controller_ledger = await api.query.staking.ledger(controller_address.toString());
  claimed_eras = controller_ledger.toHuman().claimedRewards.map(x => parseInt(x.replace(',','')));
  console.log(`Payout for validator stash ${stash_account} has been claimed for eras: ${claimed_eras}`);

  if (claimed_eras.includes(currentEra - 1)) {
    console.log(`Payout for validator stash ${stash_account} for era ${currentEra - 1} has already been issued, exiting`);
    process.exit(0);
  }

  var exposure_for_era = await api.query.staking.erasStakers(currentEra - 1, stash_account);
  if (exposure_for_era.total == 0) {
    console.log(`Stash ${stash_account} was not in the active validator set for era ${currentEra - 1}, no payout can be made, exiting`);
    process.exit(0);
  }

  console.log(`Issuing payoutStakers extrinsic from address ${payoutKey.address} for validator stash ${stash_account} for era ${currentEra - 1}`);

  // Create, sign and send the payoutStakers extrinsic
  var unsub = await api.tx.staking.payoutStakers(stash_account, currentEra - 1).signAndSend(payoutKey, ({ events = [], status }) => {
    console.log('Transaction status:', status.type);

    if (status.isInBlock) {
      console.log('Included at block hash', status.asInBlock.toHex());
      console.log('Events:');

      events.forEach(({ event: { data, method, section }, phase }) => {
        console.log('\t', phase.toString(), `: ${section}.${method}`, data.toString());
      });
    } else if (status.isFinalized) {
      console.log('Finalized block hash', status.asFinalized.toHex());
    } else if (status.isError) {
      console.error('Errored out in block hash', status.asFinalized.toHex());
      process.exit(1);
    }
  });
  console.log("Exiting");
  process.exit(0);
}

main().catch(console.error);
