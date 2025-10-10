// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AutomationCompatibleInterface} from
    "@chainlink/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract ScheduleETHTransfer is AutomationCompatibleInterface, Ownable, ReentrancyGuard, Pausable {
    // Errors
    error ScheduleETHTransfer__ContractIsPaused();
    error ScheduleETHTransfer__NoEtherSent();
    error ScheduleETHTransfer__InvalidRecipientAddress();
    error ScheduleETHTransfer__UnlockTimeAlreadyPassed();
    error ScheduleETHTransfer__TransferJobNotFound();
    error ScheduleETHTransfer__TransferAlreadyExecuted();
    error ScheduleETHTransfer__TransferAlreadyCancelled();
    error ScheduleETHTransfer__OnlyPayerCanCancel();
    error ScheduleETHTransfer__CancellationPeriodEnded();
    error ScheduleETHTransfer__EtherRefundFailed();
    error ScheduleETHTransfer__EtherTransferFailed();
    error ScheduleETHTransfer__InvalidPerformData();
    error ScheduleETHTransfer__BatchSizeExceedsLimit();
    error ScheduleETHTransfer__ZeroAddressNotAllowed();
    error ScheduleETHTransfer__InsufficientBalance();
    error ScheduleETHTransfer__UnauthorizedAutomationCall();
    error ScheduleETHTransfer__CannotPauseWithActiveJobs();
    error ScheduleETHTransfer__CannotUpdateAfterUnlockTime();
    error ScheduleETHTransfer__InvalidAmountUpdate();

    // Structs
    struct TransferJob {
        address payerAddress;
        address payable recipientAddress;
        uint256 transferAmount;
        uint256 unlockTimestamp;
        bool isExecuted;
        bool isCancelled;
    }

    // Constants
    uint256 public constant MAX_BATCH_SIZE = 20;
    uint256 private constant MAXIMUM_UINT256 = type(uint256).max;

    // State variables
    uint256 public s_nextJobId;
    uint256[] private s_activeJobIds;
    mapping(uint256 => TransferJob) public s_jobIdToTransferJob;
    mapping(uint256 => uint256) private s_jobIdToArrayIndex;
    address public s_chainlinkAutomationForwarder;

    // Events
    event TransferJobScheduled(
        uint256 indexed jobId, address indexed payer, address indexed recipient, uint256 amount, uint256 unlockTimestamp
    );
    event TransferJobExecuted(uint256 indexed jobId, address indexed recipient, uint256 amount);
    event TransferJobCancelled(uint256 indexed jobId, address indexed payer, uint256 refundAmount);
    event TransferJobUpdated(
        uint256 indexed jobId,
        address indexed oldRecipient,
        address indexed newRecipient,
        uint256 oldAmount,
        uint256 newAmount,
        uint256 oldUnlockTimestamp,
        uint256 newUnlockTimestamp
    );
    event EmergencyFundsWithdrawn(address indexed owner, address indexed recipient, uint256 amount);
    event ChainlinkAutomationForwarderUpdated(address indexed oldForwarder, address indexed newForwarder);

    // Modifiers
    modifier onlyWhenNotPaused() {
        if (paused()) {
            revert ScheduleETHTransfer__ContractIsPaused();
        }
        _;
    }

    modifier onlyChainlinkAutomationForwarder() {
        if (msg.sender != s_chainlinkAutomationForwarder) {
            revert ScheduleETHTransfer__UnauthorizedAutomationCall();
        }
        _;
    }

    modifier onlyPayer(uint256 jobId) {
        if (msg.sender != s_jobIdToTransferJob[jobId].payerAddress) {
            revert ScheduleETHTransfer__OnlyPayerCanCancel();
        }
        _;
    }

    modifier validAddress(address addressToCheck) {
        if (addressToCheck == address(0)) {
            revert ScheduleETHTransfer__ZeroAddressNotAllowed();
        }
        _;
    }

    // Constructor
    constructor() Ownable(msg.sender) {
        s_nextJobId = 1;
    }

    // External Functions
    function setChainlinkAutomationForwarder(address _newforwarderAddress)
        external
        onlyOwner
        validAddress(_newforwarderAddress)
    {
        address oldForwarder = s_chainlinkAutomationForwarder;
        s_chainlinkAutomationForwarder = _newforwarderAddress;
        emit ChainlinkAutomationForwarderUpdated(oldForwarder, _newforwarderAddress);
    }

    function scheduleEthTransfer(address payable _recipientAddress, uint256 _unlockTimestamp)
        external
        payable
        onlyWhenNotPaused
        validAddress(_recipientAddress)
        returns (uint256 jobId)
    {
        if (msg.value == 0) revert ScheduleETHTransfer__NoEtherSent();
        if (_unlockTimestamp <= block.timestamp) revert ScheduleETHTransfer__UnlockTimeAlreadyPassed();

        jobId = s_nextJobId++;

        TransferJob memory newJob = TransferJob({
            payerAddress: msg.sender,
            recipientAddress: _recipientAddress,
            transferAmount: msg.value,
            unlockTimestamp: _unlockTimestamp,
            isExecuted: false,
            isCancelled: false
        });

        s_jobIdToTransferJob[jobId] = newJob;
        s_activeJobIds.push(jobId);
        s_jobIdToArrayIndex[jobId] = s_activeJobIds.length - 1;

        emit TransferJobScheduled(jobId, msg.sender, _recipientAddress, msg.value, _unlockTimestamp);
    }

    function cancelScheduledTransfer(uint256 _jobId) external nonReentrant onlyPayer(_jobId) {
        TransferJob storage job = s_jobIdToTransferJob[_jobId];

        if (job.payerAddress == address(0)) revert ScheduleETHTransfer__TransferJobNotFound();
        if (job.isExecuted) revert ScheduleETHTransfer__TransferAlreadyExecuted();
        if (job.isCancelled) revert ScheduleETHTransfer__TransferAlreadyCancelled();
        if (msg.sender != job.payerAddress) revert ScheduleETHTransfer__OnlyPayerCanCancel();
        if (block.timestamp >= job.unlockTimestamp) revert ScheduleETHTransfer__CancellationPeriodEnded();

        job.isCancelled = true;
        uint256 refundAmount = job.transferAmount;
        job.transferAmount = 0;

        // Remove job from active jobs array
        uint256 index = s_jobIdToArrayIndex[_jobId];
        uint256 lastIndex = s_activeJobIds.length - 1;
        if (index != lastIndex) {
            s_activeJobIds[index] = s_activeJobIds[lastIndex];
            s_jobIdToArrayIndex[s_activeJobIds[index]] = index;
        }
        s_activeJobIds.pop();
        delete s_jobIdToArrayIndex[_jobId];

        // Refund the payer
        (bool refundSuccess,) = msg.sender.call{value: refundAmount}("");
        if (!refundSuccess) revert ScheduleETHTransfer__EtherRefundFailed();

        emit TransferJobCancelled(_jobId, msg.sender, refundAmount);
    }

    function checkUpkeep(bytes calldata /* checkData */ )
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {}

    function performUpkeep(bytes calldata performData) external override nonReentrant whenNotPaused {}

    function pauseContract() external onlyOwner {
        if (s_activeJobIds.length > 0) {
            revert ScheduleETHTransfer__CannotPauseWithActiveJobs();
        }
        _pause();
    }

    function unpauseContract() external onlyOwner {
        _unpause();
    }

    // Public Functions
    // Internal Functions
    // Private Functions
    // View Functions

    function getActiveJobIds() external view returns (uint256[] memory) {
        return s_activeJobIds;
    }

    function getAutomationForwarder() external view returns (address) {
        return s_chainlinkAutomationForwarder;
    }

    function getActiveJobCount() external view returns (uint256) {
        return s_activeJobIds.length;
    }

    function getContractBalance() external view returns (uint256) {
        return address(this).balance;
    }
}
