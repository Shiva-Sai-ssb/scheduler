// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    AutomationCompatibleInterface
} from "@chainlink/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol";
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
    error ScheduleETHTransfer__OnlyPayerCanUpdate();

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
    constructor(address _forwarderAddress) Ownable(msg.sender) {
        if (_forwarderAddress == address(0)) {
            revert ScheduleETHTransfer__ZeroAddressNotAllowed();
        }
        s_nextJobId = 1;
        s_chainlinkAutomationForwarder = _forwarderAddress;
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

        _removeJobFromActiveList(_jobId);

        (bool refundSuccess,) = msg.sender.call{value: refundAmount}("");
        if (!refundSuccess) revert ScheduleETHTransfer__EtherRefundFailed();

        emit TransferJobCancelled(_jobId, msg.sender, refundAmount);
    }

    function updateScheduledTransfer(
        uint256 _jobId, 
        address payable _newRecipientAddress, 
        uint256 _newUnlockTimestamp,
        uint256 _newAmount
    )
        external
        payable
        onlyWhenNotPaused
        nonReentrant
        validAddress(_newRecipientAddress)
    {
        TransferJob storage job = s_jobIdToTransferJob[_jobId];

        if (job.payerAddress == address(0)) revert ScheduleETHTransfer__TransferJobNotFound();
        if (job.isExecuted) revert ScheduleETHTransfer__TransferAlreadyExecuted();
        if (job.isCancelled) revert ScheduleETHTransfer__TransferAlreadyCancelled();
        if (msg.sender != job.payerAddress) revert ScheduleETHTransfer__OnlyPayerCanUpdate();
        if (block.timestamp >= job.unlockTimestamp) revert ScheduleETHTransfer__CannotUpdateAfterUnlockTime();
        if (_newUnlockTimestamp <= block.timestamp) revert ScheduleETHTransfer__UnlockTimeAlreadyPassed();

        uint256 oldAmount = job.transferAmount;
        uint256 finalAmount = oldAmount;

        if (_newAmount > 0 && _newAmount != oldAmount) {
            if (_newAmount > oldAmount) {
                uint256 difference = _newAmount - oldAmount;
                if (msg.value != difference) revert ScheduleETHTransfer__InvalidAmountUpdate();
                finalAmount = _newAmount;
            } else {
                if (msg.value > 0) revert ScheduleETHTransfer__InvalidAmountUpdate();
                uint256 refundAmount = oldAmount - _newAmount;
                finalAmount = _newAmount;
                
                (bool success,) = job.payerAddress.call{value: refundAmount}("");
                if (!success) revert ScheduleETHTransfer__EtherRefundFailed();
            }
        } else {
            if (msg.value > 0) revert ScheduleETHTransfer__InvalidAmountUpdate();
        }

        address oldRecipient = job.recipientAddress;
        uint256 oldUnlockTime = job.unlockTimestamp;

        job.recipientAddress = _newRecipientAddress;
        job.transferAmount = finalAmount;
        job.unlockTimestamp = _newUnlockTimestamp;

        emit TransferJobUpdated(_jobId, oldRecipient, _newRecipientAddress, oldAmount, finalAmount, oldUnlockTime, _newUnlockTimestamp);
    }

    function checkUpkeep(
        bytes calldata /* checkData */
    )
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        if (paused() || s_activeJobIds.length == 0) {
            return (false, bytes(""));
        }

        uint256[] memory readyJobIds = new uint256[](MAX_BATCH_SIZE);
        uint256 readyJobCount = 0;

        for (uint256 i = 0; i < s_activeJobIds.length && readyJobCount < MAX_BATCH_SIZE; i++) {
            uint256 currentJobId = s_activeJobIds[i];
            TransferJob storage currentJob = s_jobIdToTransferJob[currentJobId];

            if (_isJobReadyForExecution(currentJob)) {
                readyJobIds[readyJobCount] = currentJobId;
                readyJobCount++;
            }
        }

        if (readyJobCount == 0) {
            return (false, bytes(""));
        }

        performData = _encodePerformData(readyJobIds, readyJobCount);
        return (true, performData);
    }

    function performUpkeep(bytes calldata performData) external override nonReentrant onlyChainlinkAutomationForwarder {
        if (paused()) revert ScheduleETHTransfer__ContractIsPaused();
        if (performData.length < 1) revert ScheduleETHTransfer__InvalidPerformData();

        uint8 batchSize = uint8(bytes1(performData[0]));
        if (batchSize == 0 || batchSize > MAX_BATCH_SIZE) {
            revert ScheduleETHTransfer__BatchSizeExceedsLimit();
        }

        _executeBatchTransfers(performData, batchSize);
    }

    function pauseContract() external onlyOwner {
        if (s_activeJobIds.length > 0) {
            revert ScheduleETHTransfer__CannotPauseWithActiveJobs();
        }
        _pause();
    }

    function unpauseContract() external onlyOwner {
        _unpause();
    }

    function emergencyWithdrawFunds(address payable _recipientAddress, uint256 _withdrawalAmount)
        external
        onlyOwner
        nonReentrant
        validAddress(_recipientAddress)
    {
        if (_withdrawalAmount > address(this).balance) {
            revert ScheduleETHTransfer__InsufficientBalance();
        }

        (bool withdrawalSuccess,) = _recipientAddress.call{value: _withdrawalAmount}("");
        if (!withdrawalSuccess) revert ScheduleETHTransfer__EtherTransferFailed();

        emit EmergencyFundsWithdrawn(msg.sender, _recipientAddress, _withdrawalAmount);
    }

    // Internal Functions
    function _isJobReadyForExecution(TransferJob storage _job) internal view returns (bool) {
        return !_job.isExecuted && !_job.isCancelled && block.timestamp >= _job.unlockTimestamp;
    }

    function _encodePerformData(uint256[] memory _jobIds, uint256 _count) internal pure returns (bytes memory) {
        bytes memory encodedData = abi.encodePacked(uint8(_count));
        for (uint256 i = 0; i < _count; i++) {
            encodedData = abi.encodePacked(encodedData, _jobIds[i]);
        }
        return encodedData;
    }

    function _executeBatchTransfers(bytes calldata performData, uint8 batchSize) internal {
        uint256 dataOffset = 1;

        for (uint256 i = 0; i < batchSize; i++) {
            uint256 jobId;
            assembly {
                jobId := calldataload(add(performData.offset, dataOffset))
            }
            dataOffset += 32;

            _executeTransferJob(jobId);
        }
    }

    function _executeTransferJob(uint256 _jobId) internal {
        TransferJob storage transferJob = s_jobIdToTransferJob[_jobId];

        if (
            transferJob.payerAddress == address(0) || transferJob.isExecuted || transferJob.isCancelled
                || block.timestamp < transferJob.unlockTimestamp
        ) {
            return;
        }

        transferJob.isExecuted = true;
        uint256 transferAmount = transferJob.transferAmount;
        transferJob.transferAmount = 0;

        _removeJobFromActiveList(_jobId);

        (bool transferSuccess,) = transferJob.recipientAddress.call{value: transferAmount}("");
        if (!transferSuccess) revert ScheduleETHTransfer__EtherTransferFailed();

        emit TransferJobExecuted(_jobId, transferJob.recipientAddress, transferAmount);
    }

    function _removeJobFromActiveList(uint256 _jobId) internal {
        uint256 arrayLength = s_activeJobIds.length;
        if (arrayLength == 0) return;

        uint256 jobIndex = s_jobIdToArrayIndex[_jobId];
        uint256 lastIndex = arrayLength - 1;

        if (jobIndex != lastIndex) {
            uint256 lastJobId = s_activeJobIds[lastIndex];
            s_activeJobIds[jobIndex] = lastJobId;
            s_jobIdToArrayIndex[lastJobId] = jobIndex;
        }

        s_activeJobIds.pop();
        delete s_jobIdToArrayIndex[_jobId];
    }

    // View Functions
    function getNextUnlockTimestamp() external view returns (uint256) {
        if (s_activeJobIds.length == 0) return 0;

        uint256 earliestTimestamp = MAXIMUM_UINT256;

        for (uint256 i = 0; i < s_activeJobIds.length; i++) {
            uint256 currentJobId = s_activeJobIds[i];
            TransferJob storage currentJob = s_jobIdToTransferJob[currentJobId];

            if (!currentJob.isExecuted && !currentJob.isCancelled && currentJob.unlockTimestamp < earliestTimestamp) {
                earliestTimestamp = currentJob.unlockTimestamp;
            }
        }

        return earliestTimestamp == MAXIMUM_UINT256 ? 0 : earliestTimestamp;
    }

    function getTransferJobDetails(uint256 _jobId)
        external
        view
        returns (address payer, address recipient, uint256 amount, uint256 unlockTime, bool executed, bool cancelled)
    {
        TransferJob storage job = s_jobIdToTransferJob[_jobId];
        return (
            job.payerAddress,
            job.recipientAddress,
            job.transferAmount,
            job.unlockTimestamp,
            job.isExecuted,
            job.isCancelled
        );
    }

    function isJobValid(uint256 _jobId) external view returns (bool exists, bool isActive) {
        TransferJob storage job = s_jobIdToTransferJob[_jobId];
        exists = job.payerAddress != address(0);
        isActive = exists && !job.isExecuted && !job.isCancelled;
    }

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
