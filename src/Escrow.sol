// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@chainlink/contracts/src/v0.8/ChainlinkClient.sol";
import "@chainlink/contracts/src/v0.8/ConfirmedOwner.sol";

contract InfluencerEscrow is ChainlinkClient, ConfirmedOwner {
    using Chainlink for Chainlink.Request;

    struct EscrowContract {
        address brand;
        address influencer;
        uint256 amount;
        uint256 minimumEngagement;
        uint256 createdAt;
        uint256 expiredAt;
        uint256 acceptedAt;
        uint256 duration;
        bool fundsDeposited;
        bool engagementChecked;
        ContractStatus status;
    }

    enum ContractStatus {
        Pending,
        Active,
        Completed,
        Refunded,
        Rejected,
        Expired
    }

    mapping(string => EscrowContract) public contracts;
    mapping(bytes32 => string) private requestIdToOfferId;

    bytes32 private jobId;
    uint256 private fee;

    event ContractCreated(
        string indexed offerId,
        address indexed brand,
        address indexed influencer,
        uint256 amount
    );
    event PaymentDeposited(
        string indexed offerId,
        address indexed brand,
        uint256 amount
    );
    event PaymentReleased(
        string indexed offerId,
        address indexed influencer,
        uint256 amount
    );
    event PaymentRefunded(
        string indexed offerId,
        address indexed brand,
        uint256 amount
    );
    event EngagementChecked(string indexed offerId, uint256 engagement);
    event ContractAccepted(string indexed offerId);
    event ContractRejected(string indexed offerId);
    event ContractExpired(string indexed offerId);
    event RequestEngagement(bytes32 indexed requestId, uint256 engagement);

    error OnlyBrand(string offerId);
    error OnlyInfluencer(string offerId);
    error ContractNotActive(string offerId);
    error IncorrectAmountSent();
    error ContractAlreadyExists(string offerId);
    error ContractNotPending(string offerId);
    error ContractNotExpired(string offerId);
    error DurationNotPassed(string offerId);
    error EngagementAlreadyChecked(string offerId);

    modifier onlyBrand(string memory offerId) {
        if (msg.sender != contracts[offerId].brand) {
            revert OnlyBrand(offerId);
        }
        _;
    }

    modifier onlyInfluencer(string memory offerId) {
        if (msg.sender != contracts[offerId].influencer) {
            revert OnlyInfluencer(offerId);
        }
        _;
    }

    modifier onlyActive(string memory offerId) {
        if (contracts[offerId].status != ContractStatus.Active) {
            revert ContractNotActive(offerId);
        }
        _;
    }

    constructor() ConfirmedOwner(msg.sender) {
        setChainlinkToken(0x779877A7B0D9E8603169DdbD7836e478b4624789); //sepolia
        setChainlinkOracle(0x6090149792dAAeE9D1D568c9f9a6F6B46AA29eFD); //sepolia
        jobId = "ca98366cc7314957b8c012c72f05aeeb";
        fee = (1 * LINK_DIVISIBILITY) / 10; // 0.1 * 10**18 (0.1 LINK)
    }

    function depositFunds(
        string memory offerId,
        address _influencer,
        uint256 _amount,
        uint256 _minimumEngagement,
        uint256 _expiredAt,
        uint256 _duration
    ) external payable {
        if (msg.value != _amount) {
            revert IncorrectAmountSent();
        }
        if (contracts[offerId].amount != 0) {
            revert ContractAlreadyExists(offerId);
        }

        createContract(
            offerId,
            _influencer,
            _amount,
            _minimumEngagement,
            _expiredAt,
            _duration
        );

        EscrowContract storage esc = contracts[offerId];
        esc.fundsDeposited = true;
        esc.createdAt = block.timestamp;

        emit PaymentDeposited(offerId, esc.brand, esc.amount);
    }

    function createContract(
        string memory offerId,
        address _influencer,
        uint256 _amount,
        uint256 _minimumEngagement,
        uint256 _expiredAt,
        uint256 _duration
    ) internal {
        contracts[offerId] = EscrowContract({
            brand: msg.sender,
            influencer: _influencer,
            amount: _amount,
            minimumEngagement: _minimumEngagement,
            createdAt: 0,
            expiredAt: _expiredAt,
            acceptedAt: 0,
            duration: _duration,
            fundsDeposited: false,
            engagementChecked: false,
            status: ContractStatus.Pending
        });

        emit ContractCreated(offerId, msg.sender, _influencer, _amount);
    }

    function acceptContract(
        string memory offerId
    ) external onlyInfluencer(offerId) {
        EscrowContract storage esc = contracts[offerId];
        if (esc.status != ContractStatus.Pending) {
            revert ContractNotPending(offerId);
        }
        esc.status = ContractStatus.Active;
        esc.acceptedAt = block.timestamp;

        emit ContractAccepted(offerId);
    }

    function rejectContract(
        string memory offerId
    ) external onlyInfluencer(offerId) {
        EscrowContract storage esc = contracts[offerId];
        if (esc.status != ContractStatus.Pending) {
            revert ContractNotPending(offerId);
        }
        esc.status = ContractStatus.Rejected;
        payable(esc.brand).transfer(esc.amount);

        emit ContractRejected(offerId);
        emit PaymentRefunded(offerId, esc.brand, esc.amount);
    }

    function checkExpired(string memory offerId) external {
        EscrowContract storage esc = contracts[offerId];
        if (esc.status != ContractStatus.Pending) {
            revert ContractNotPending(offerId);
        }
        if (block.timestamp < esc.expiredAt) {
            revert ContractNotExpired(offerId);
        }

        esc.status = ContractStatus.Expired;
        payable(esc.brand).transfer(esc.amount);

        emit ContractExpired(offerId);
        emit PaymentRefunded(offerId, esc.brand, esc.amount);
    }

    function requestEngagementData(
        string memory offerId
    ) public onlyActive(offerId) returns (bytes32 requestId) {
        EscrowContract storage esc = contracts[offerId];
        if (block.timestamp < esc.acceptedAt + esc.duration) {
            revert DurationNotPassed(offerId);
        }

        Chainlink.Request memory req = buildChainlinkRequest(
            jobId,
            address(this),
            this.fulfill.selector
        );

        // Set the URL to perform the GET request on
        req.add("get", "https://payfi-influencer.vercel.app/api/engagement");

        // Set the path to find the desired data in the API response
        req.add("path", "msg,engagement");

        // Multiply the result by 10^18 to remove decimals
        int256 timesAmount = 10 ** 18;
        req.addInt("times", timesAmount);

        // Sends the request
        requestId = sendChainlinkRequest(req, fee);
        requestIdToOfferId[requestId] = offerId;

        return requestId;
    }

    function fulfill(
        bytes32 _requestId,
        uint256 _engagement
    ) public recordChainlinkFulfillment(_requestId) {
        string memory offerId = requestIdToOfferId[_requestId];
        EscrowContract storage esc = contracts[offerId];

        emit RequestEngagement(_requestId, _engagement);

        if (_engagement >= esc.minimumEngagement) {
            releasePayment(offerId);
        } else {
            refundPayment(offerId);
        }
    }

    function releasePayment(string memory offerId) internal {
        EscrowContract storage esc = contracts[offerId];
        esc.status = ContractStatus.Completed;
        payable(esc.influencer).transfer(esc.amount);

        emit PaymentReleased(offerId, esc.influencer, esc.amount);
    }

    function refundPayment(string memory offerId) internal {
        EscrowContract storage esc = contracts[offerId];
        esc.status = ContractStatus.Refunded;
        payable(esc.brand).transfer(esc.amount);

        emit PaymentRefunded(offerId, esc.brand, esc.amount);
    }

    /**
     * Allow withdraw of Link tokens from the contract
     */
    function withdrawLink() public onlyOwner {
        LinkTokenInterface link = LinkTokenInterface(chainlinkTokenAddress());
        require(
            link.transfer(msg.sender, link.balanceOf(address(this))),
            "Unable to transfer"
        );
    }

    receive() external payable {}

    fallback() external payable {}
}
