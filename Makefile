# Fork-mode local stack for the EigenAuction LVR hook.
#
# Flow:
#   make anvil-fork                       # terminal 1: fork mainnet (keeps chainId 1)
#   make fund deploy-fork seed            # terminal 2: fund + deploy + seed pool liquidity
#   docker compose up -d redis
#   make start-server                     # searcher-rpc (keep running)
#   make demo                             # simple one-shot end-to-end (arb + intent)
#
# Full narrated demo (bids -> auction -> winner settles -> LP claims):
#   make fund deploy-fork setup-demo-lp   # (after anvil-fork + redis + start-server)
#   make demo-full
#
# Required in .env: MAINNET_RPC_URL, DEPLOYER_PK, OPERATOR_PK, SETTLER_CALLER_PK, RPC_URL, CHAIN_ID, REDIS_URL
include .env
export

CONTRACTS := src/contracts
# Anvil default account #0 (deployer) and #1 (operator) — override via .env for real keys.
ANVIL_DEPLOYER ?= 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
ANVIL_OPERATOR ?= 0x70997970C51812dc3A010C7d01b50e0d17dc79C8
# Searchers for the full demo (anvil accounts #2-#4; keys hardcoded in full-demo.ts).
SEARCHERS := 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC 0x90F79bf6EB2c4f870365E785982E1f101E93b906 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65
USDC := 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
WETH := 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
# 1,000,000 USDC (6dp) as a 32-byte storage word.
USDC_BAL := 0x000000000000000000000000000000000000000000000000000000e8d4a51000
# 5000 WETH (18dp) as a 32-byte storage word.
WETH_BAL := 0x00000000000000000000000000000000000000000000010f0cf064dd59200000
# 10000 ETH.
ETH_BAL := 0x21e19e0c9bab2400000

.PHONY: anvil-fork fund deploy-fork seed setup-demo-lp start-server start-operator demo demo-full build test

## Start a mainnet fork. --auto-impersonate lets fund targets send from whales without unlocking each.
anvil-fork:
	anvil --fork-url $(MAINNET_RPC_URL) --auto-impersonate --chain-id 1

## Fund deployer + operator with ETH, USDC and WETH. The deployer is the LP + intent user; the
## operator funds the arb swap. ERC20 balances are set directly via anvil_setStorageAt at each
## token's balanceOf slot (WETH: slot 3, USDC implementation: slot 9) — deterministic, no whales.
## Balances: WETH 0x...920000 = 5000e18, USDC 0x...e8d4a51000 = 1,000,000e6.
fund:
	cast rpc anvil_setBalance $(ANVIL_DEPLOYER) 0x21e19e0c9bab2400000 --rpc-url $(RPC_URL)
	cast rpc anvil_setBalance $(ANVIL_OPERATOR) 0x21e19e0c9bab2400000 --rpc-url $(RPC_URL)
	@echo "Funding deployer + operator with WETH (slot 3)..."
	cast rpc anvil_setStorageAt $(WETH) $$(cast index address $(ANVIL_DEPLOYER) 3) \
		0x00000000000000000000000000000000000000000000010f0cf064dd59200000 --rpc-url $(RPC_URL)
	cast rpc anvil_setStorageAt $(WETH) $$(cast index address $(ANVIL_OPERATOR) 3) \
		0x00000000000000000000000000000000000000000000010f0cf064dd59200000 --rpc-url $(RPC_URL)
	@echo "Funding deployer + operator with USDC (slot 9)..."
	cast rpc anvil_setStorageAt $(USDC) $$(cast index address $(ANVIL_DEPLOYER) 9) $(USDC_BAL) --rpc-url $(RPC_URL)
	cast rpc anvil_setStorageAt $(USDC) $$(cast index address $(ANVIL_OPERATOR) 9) $(USDC_BAL) --rpc-url $(RPC_URL)
	@echo "Funding searchers with ETH + USDC..."
	@for a in $(SEARCHERS); do \
		cast rpc anvil_setBalance $$a $(ETH_BAL) --rpc-url $(RPC_URL); \
		cast rpc anvil_setStorageAt $(USDC) $$(cast index address $$a 9) $(USDC_BAL) --rpc-url $(RPC_URL); \
	done

## Deploy our contracts + register operator + init pool; writes deployments/<CHAIN_ID>.json.
deploy-fork:
	forge script $(CONTRACTS)/script/DeployFork.s.sol \
		--root $(CONTRACTS) --rpc-url $(RPC_URL) --broadcast -vvv

## Seed pool liquidity (assumes `fund` has run so the deployer holds USDC + WETH).
seed:
	forge script $(CONTRACTS)/script/SeedLiquidity.s.sol \
		--root $(CONTRACTS) --rpc-url $(RPC_URL) --broadcast -vvv

## Deploy + fund + seed a claimable DemoLP for the full demo; writes deployments/<CHAIN_ID>.demo.json.
setup-demo-lp:
	forge script $(CONTRACTS)/script/SetupDemoLP.s.sol \
		--root $(CONTRACTS) --rpc-url $(RPC_URL) --broadcast -vvv

build:
	forge build --root $(CONTRACTS)

test:
	npm run test

start-server:
	npm run start-server

start-operator:
	npm run start-operator

demo:
	npm run demo

## Full narrated end-to-end demo. Prereqs: deploy-fork + setup-demo-lp done, redis + start-server up.
demo-full:
	npm run demo:full
