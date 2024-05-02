# AlfaFrens Contracts

## Prerequisites

- `pnpm`
- `forge`
- `.env` (see `.env.example`)
- `lcov` (for coverage)
- `nix` OR `echidna` (for stateful fuzzing tests)

## Installing Dependencies

Run `pnpm install` and `forge install` to install all necessary dependencies for AlfaFrens contracts.

## Building

To build the contracts, run `pnpm build`.

## Testing

### Foundry Tests

To run the foundry test suite, run `pnpm test`.

### Echidna Tests (Stateful Fuzzing)

> NOTE: You will either need to have nix installed and you can run `nix develop .` in the root OR you will need `echidna` and all other dependencies installed ot run the stateful fuzzing tests.

To run the stateful fuzzing tests, we use echidna, run `lib/protocol-monorepo/packages/hot-fuzz/hot-fuzz src/echidna/FullHotFuzz.yaml`.

See [`this`](packages/contracts/src/echidna/FullHotFuzz.sol) file to see the different actions being run and the different invariants being checked.

There is coverage output generated in the `corpus` folder which can be used to generate a html coverage report.

### Coverage

To generate a lcov coverage report and generate an HTML file based on the generated `lcov.info` file, run `pnpm coverage`.

## Watch Mode

To run the tests in watch mode, run `pnpm dev`.

To run compilation in watch mode, run `forge build -w`.

## Deployment & Upgrades

> NOTE: Remember to run `source .env` first to load environment variables in `.env` into your shell.

Note that for deployment and upgrades you will need the following variables in a `.env` file or exported to the shell environment you are running the script in:

- `PRIVATE_KEY`: The private key of the deployer
- `HOST_ADDRESS`: The Superfluid Host address
- `SUBSCRIPTION_SUPER_TOKEN_ADDRESS`: The Native Asset Token address
- `PROTOCOL_FEE_DEST`: The address that will be the recipient of the protocol fees
- `OWNER_ADDRESS`: The address of the FAN token owner
- `RPC_URL`: The RPC endpoint which will be used to broadcast the transactions

To deploy the contracts, run `source .env && pnpm deploy`.

### Upgrades

#### Channel Logic

Note that for upgrading the channel logic, you will additionally need the following variables in a `.env` file:

- `REWARD_TOKEN_PROXY_ADDRESS`: The address of the Reward Token proxy contract
- `CHANNEL_FACTORY_ADDRESS`: The address of the Channel Factory contract

See [`script/UpgradeChannelBeaconLogic.s.sol`](script/UpgradeChannelBeaconLogic.s.sol) for the command to execute the upgrade and for a more granular view of the upgrade script.


#### Alfa Token Logic

Note that for upgrading you will additionally need the following variables in a `.env` file:

- `REWARD_TOKEN_PROXY_ADDRESS`: The address of the Reward Token proxy contract

See [`script/UpgradeRewardTokenLogic.s.sol`](script/UpgradeRewardTokenLogic.s.sol) for the command to execute the upgrade and for a more granular view of the upgrade script.
