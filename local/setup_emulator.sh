flow deploy
flow transactions send ./cadence/transactions/mocks/oracle/set_price.cdc 'A.0ae53cb6e3f42a79.FlowToken.Vault' 0.5
flow transactions send ./cadence/transactions/mocks/oracle/set_price.cdc 'A.f8d6e0586b0a20c7.YieldToken.Vault' 1.0
flow transactions send ./cadence/transactions/mocks/swapper/set_liquidity_connector.cdc /storage/flowTokenVault
flow transactions send ./cadence/transactions/mocks/swapper/set_liquidity_connector.cdc /storage/usdaTokenVault_0xf8d6e0586b0a20c7
flow transactions send ./cadence/transactions/mocks/swapper/set_liquidity_connector.cdc /storage/yieldTokenVault_0xf8d6e0586b0a20c7