include .env
export

deploy-op:
	@forge script script/MyERC20.s.sol:DeployMyERC20 \
		--rpc-url $(OPT_SEPOLIA_RPC_URL) \
		--account my_deployer \
		--sender $$(cast wallet address --account my_deployer) \
		--broadcast \
		--verify \
		--verifier-url https://api-sepolia-optimistic.etherscan.io/api/v2
		--etherscan-api-key $(ETHERSCAN_API_KEY) \
		-vvvv