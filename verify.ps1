Get-Content .env | ForEach-Object {
    if ($_ -match '^([^#][^=]*)=(.*)$') {
        [System.Environment]::SetEnvironmentVariable($matches[1].Trim(), $matches[2].Trim())
    }
}
$env:PATH = "$env:USERPROFILE\.foundry\bin;$env:PATH"

$CA   = "0000000000000000000000001804c8ab1f12e6bbf3894d4083f33e07309d1f38" +
        "000000000000000000000000d799cd2b5258edc2157bec7e2cd069f31f2678c2"
$KEY  = $env:ETHERSCAN_API_KEY
$OPT  = "https://api.etherscan.io/v2/api?chainid=11155420"
$BASE = "https://api.etherscan.io/v2/api?chainid=84532"

Write-Host "[1/4] OPT Sepolia: MarketplaceEscrow"
forge verify-contract 0x331B47D295D328B25059632E7077bd0Fa17c9522 src/MarketplaceEscrow.sol:MarketplaceEscrow --verifier-url $OPT --etherscan-api-key $KEY --constructor-args $CA

Write-Host "[2/4] OPT Sepolia: QnAEscrow"
forge verify-contract 0xd4c53597Fe13B10EB3EcAD560381c4eb900d43b9 src/QnAEscrow.sol:QnAEscrow --verifier-url $OPT --etherscan-api-key $KEY --constructor-args $CA

Write-Host "[3/4] Base Sepolia: MarketplaceEscrow"
forge verify-contract 0x70a7ADDbED004646350c4760C10e6B1119F86193 src/MarketplaceEscrow.sol:MarketplaceEscrow --verifier-url $BASE --etherscan-api-key $KEY --constructor-args $CA

Write-Host "[4/4] Base Sepolia: QnAEscrow"
forge verify-contract 0x1C23Ba255A8Bc5173721033b8a537176F196c2Ab src/QnAEscrow.sol:QnAEscrow --verifier-url $BASE --etherscan-api-key $KEY --constructor-args $CA

Write-Host "Done."
