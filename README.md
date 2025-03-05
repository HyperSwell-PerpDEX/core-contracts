# Controller

Smart contracts for HyperSwell

## Features

BridgeSwapController support 2 flow of bridge (via layer zero) + swap
 - receive token bridged (from other chain) and swap to user address, then deposit to HyperLiquid
 - swap token and bridge to user address (to other chain)

### BridgeSwapController

- lzCompose: Handles incoming composed messages from LayerZero
    - this function will triggered when bridge usde have compose compose data
    - the compose data include the data of swap from usde to usdc and deposit to HyperLiquid

- swapAndBridge:
    - this function support user swap from usde to usdc, then bridge usde to other chain
    - the order data include the swap data and bridge data

