include .env
export

COMMON_ARGS := --rpc-url $(OPT_SEPOLIA_RPC_URL) \
               --account my_deployer \
               --sender $$(cast wallet address --account my_deployer) \
               --broadcast \
               --verify \
               --verifier-url https://api.etherscan.io/v2/api \
               --etherscan-api-key $(ETHERSCAN_API_KEY) \
               --chain-id 11155420 \
               -vvvv

deploy-token:
	@forge script script/MyERC20.s.sol:DeployMyERC20 $(COMMON_ARGS)

deploy-wallet:
	@forge script script/SimpleWallet.s.sol:DeploySimpleWallet $(COMMON_ARGS)

deploy-voucher:
	@forge script script/Voucher.s.sol:DeployVoucher $(COMMON_ARGS)

deploy-all: deploy-token deploy-wallet