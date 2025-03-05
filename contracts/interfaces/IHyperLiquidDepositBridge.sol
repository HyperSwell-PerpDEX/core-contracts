pragma solidity >=0.8.0;

interface IHyperLiquidDepositBridge {
    struct Signature {
        uint256 r;
        uint256 s;
        uint8 v;
    }

    struct DepositWithPermit {
        address user;
        uint64 usd;
        uint64 deadline;
        Signature signature;
    }

    function batchedDepositWithPermit(
        DepositWithPermit[] memory deposits
    ) external;
}
