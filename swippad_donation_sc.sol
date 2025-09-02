// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/// @title DonationPool - A decentralized crowdfunding platform
/// @author ottodevs
/// @notice This contract allows users to create and manage donation campaigns with different funding models
/// @dev Implements crowdfunding functionality with ALL_OR_NOTHING and KEEP_WHAT_YOU_RAISE models
/// @custom:security-contact 5030059+ottodevs@users.noreply.github.com

// --- Interfaces ---
// Note: You'll need to create these locally in Remix or import from a repo
// For now, we'll assume they are in the same directory
import "./interface/IDonationPool.sol";
import "./interface/IERC20.sol";

// --- Libraries ---
import "./library/DonationConstantsLib.sol";
import "./library/DonationEventsLib.sol";
import "./library/DonationErrorsLib.sol";
import "./library/DonationPoolAdminLib.sol";
import "./library/DonationPoolDetailLib.sol";
import "./library/DonationPoolBalanceLib.sol";
import "./library/DonorDetailLib.sol";
import "./library/UtilsLib.sol";
import "./library/SafeTransferLib.sol";

// --- Dependencies ---
import "./dependency/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/// @notice Main contract for managing donation campaigns
/// @dev Inherits from Ownable2Step, AccessControl, and Pausable for security and control
contract DonationPool is IDonationPool, Ownable2Step, AccessControl, Pausable {
    using SafeTransferLib for IERC20;
    using DonationPoolAdminLib for IDonationPool.PoolAdmin;
    using DonationPoolDetailLib for IDonationPool.PoolDetail;
    using DonationPoolBalanceLib for IDonationPool.PoolBalance;
    using DonorDetailLib for IDonationPool.DonorDetail;

    /// @notice Role identifier for admin privileges
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Latest campaign ID
    uint256 public latestPoolId;
    
    /// @notice Platform fee rate in basis points
    uint16 public platformFeeRate;

    // Mappings
    mapping(uint256 => PoolAdmin) public poolAdmin;
    mapping(uint256 => PoolDetail) public poolDetail;
    mapping(uint256 => IERC20) public poolToken;
    mapping(uint256 => PoolBalance) public poolBalance;
    mapping(uint256 => POOLSTATUS) public poolStatus;
    mapping(uint256 => address[]) public donors;

    mapping(address => uint256[]) public createdCampaigns;
    mapping(address => mapping(uint256 => bool)) public isCreator;

    mapping(address => uint256[]) public donatedCampaigns;
    mapping(address => mapping(uint256 => bool)) public isDonor;
    mapping(address => mapping(uint256 => DonorDetail)) public donorDetail;

    mapping(address => uint256) public platformFeesCollected;

    /// @notice Ensures only the campaign creator can call the function
    modifier onlyCreator(uint256 poolId) {
        if (msg.sender != poolAdmin[poolId].getCreator()) {
            revert DonationErrorsLib.OnlyCreator(msg.sender, poolAdmin[poolId].getCreator());
        }
        _;
    }

    /// @notice Ensures the campaign is not in disputed state
    modifier notDisputed(uint256 poolId) {
        if (poolAdmin[poolId].isDisputed()) {
            revert DonationErrorsLib.CampaignDisputed(poolId);
        }
        _;
    }

    /// @notice Initializes the contract with default settings
    constructor() Ownable2Step(msg.sender) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        platformFeeRate = DEFAULT_PLATFORM_FEE;
    }

    // ----------------------------------------------------------------------------
    // Donor Functions
    // ----------------------------------------------------------------------------

    function donate(
        uint256 poolId,
        uint256 amount
    ) external whenNotPaused notDisputed(poolId) returns (bool) {
        if (amount == 0) revert DonationErrorsLib.InvalidAmount(amount);
        if (poolStatus[poolId] != POOLSTATUS.ACTIVE) revert DonationErrorsLib.CampaignNotActive(poolId);

        uint256 feeAmount = (amount * platformFeeRate) / FEES_PRECISION;
        poolBalance[poolId].addDonation(amount, feeAmount);

        if (!isDonor[msg.sender][poolId]) {
            donors[poolId].push(msg.sender);
            donatedCampaigns[msg.sender].push(poolId);
            isDonor[msg.sender][poolId] = true;
        }

        DonorDetailLib.addDonation(donorDetail, msg.sender, poolId, amount);
        poolToken[poolId].safeTransferFrom(msg.sender, address(this), amount);

        if (poolBalance[poolId].getTotalDonations() >= poolDetail[poolId].getFundingGoal() && poolStatus[poolId] == POOLSTATUS.ACTIVE) {
            poolStatus[poolId] = POOLSTATUS.SUCCESSFUL;
            emit DonationEventsLib.CampaignStatusChanged(poolId, POOLSTATUS.SUCCESSFUL);
            emit DonationEventsLib.FundingGoalReached(poolId, poolBalance[poolId].getTotalDonations());
        }

        emit DonationEventsLib.DonationReceived(poolId, msg.sender, amount);
        return true;
    }

    function claimRefund(uint256 poolId) external whenNotPaused {
        if (poolStatus[poolId] != POOLSTATUS.FAILED) {
            if (poolDetail[poolId].hasFundingModel(FUNDINGMODEL.ALL_OR_NOTHING) &&
                poolDetail[poolId].hasEnded() &&
                poolBalance[poolId].getTotalDonations() < poolDetail[poolId].getFundingGoal()) {
                poolStatus[poolId] = POOLSTATUS.FAILED;
                emit DonationEventsLib.CampaignStatusChanged(poolId, POOLSTATUS.FAILED);
                emit DonationEventsLib.FundingFailed(poolId, poolBalance[poolId].getTotalDonations(), poolDetail[poolId].getFundingGoal());
            } else {
                revert DonationErrorsLib.NoRefundAvailable(poolId, msg.sender);
            }
        }

        if (!poolDetail[poolId].hasFundingModel(FUNDINGMODEL.ALL_OR_NOTHING)) {
            revert DonationErrorsLib.NoRefundAvailable(poolId, msg.sender);
        }

        if (!DonorDetailLib.hasDonated(donorDetail, msg.sender, poolId) ||
            DonorDetailLib.hasRefunded(donorDetail, msg.sender, poolId)) {
            revert DonationErrorsLib.NoRefundAvailable(poolId, msg.sender);
        }

        uint40 endTime = poolDetail[poolId].getEndTime();
        if (block.timestamp > endTime && (block.timestamp - endTime) > REFUND_GRACE_PERIOD) {
            revert DonationErrorsLib.RefundPeriodExpired(poolId, endTime + REFUND_GRACE_PERIOD);
        }

        uint256 totalDonated = donorDetail[msg.sender][poolId].totalDonated;
        uint256 refundClaimed = donorDetail[msg.sender][poolId].refundClaimed;
        uint16 feeRate = poolAdmin[poolId].getPlatformFeeRate();
        uint256 feeAmount = (totalDonated * feeRate) / FEES_PRECISION;
        uint256 refundAmount = totalDonated - feeAmount - refundClaimed;

        if (refundAmount == 0) revert DonationErrorsLib.NoRefundAvailable(poolId, msg.sender);

        DonorDetailLib.markAsRefunded(donorDetail, msg.sender, poolId, refundAmount);
        poolBalance[poolId].deductFromBalance(refundAmount);
        poolToken[poolId].safeTransfer(msg.sender, refundAmount);

        emit DonationEventsLib.RefundClaimed(poolId, msg.sender, refundAmount);
    }

    // ----------------------------------------------------------------------------
    // Creator Functions
    // ----------------------------------------------------------------------------

    function createCampaign(
        uint40 startTime,
        uint40 endTime,
        string calldata campaignName,
        string calldata campaignDescription,
        string calldata campaignUrl,
        string calldata imageUrl,
        uint256 fundingGoal,
        FUNDINGMODEL fundingModel,
        address token
    ) external whenNotPaused returns (uint256) {
        if (startTime >= endTime) revert DonationErrorsLib.InvalidTimeframe(startTime, endTime);
        if (endTime - startTime < MIN_FUNDING_PERIOD || endTime - startTime > MAX_FUNDING_PERIOD) revert DonationErrorsLib.InvalidTimeframe(startTime, endTime);
        if (fundingGoal < MIN_FUNDING_GOAL) revert DonationErrorsLib.InvalidFundingGoal(fundingGoal);
        if (!UtilsLib.isContract(token)) revert DonationErrorsLib.InvalidToken(token);

        latestPoolId++;

        poolDetail[latestPoolId].setStartTime(startTime);
        poolDetail[latestPoolId].setEndTime(endTime);
        poolDetail[latestPoolId].setCampaignName(campaignName);
        poolDetail[latestPoolId].setCampaignDescription(campaignDescription);
        poolDetail[latestPoolId].setCampaignUrl(campaignUrl);
        poolDetail[latestPoolId].setImageUrl(imageUrl);
        poolDetail[latestPoolId].fundingGoal = fundingGoal;
        poolDetail[latestPoolId].fundingModel = fundingModel;

        poolAdmin[latestPoolId].setCreator(msg.sender);
        poolAdmin[latestPoolId].setPlatformFeeRate(platformFeeRate);
        isCreator[msg.sender][latestPoolId] = true;
        createdCampaigns[msg.sender].push(latestPoolId);

        poolToken[latestPoolId] = IERC20(token);
        poolStatus[latestPoolId] = POOLSTATUS.ACTIVE;

        emit DonationEventsLib.CampaignCreated(latestPoolId, msg.sender, campaignName, fundingGoal, token, fundingModel);
        emit DonationEventsLib.CampaignStatusChanged(latestPoolId, POOLSTATUS.ACTIVE);

        return latestPoolId;
    }

    function updateCampaignDetails(
        uint256 poolId,
        string calldata campaignName,
        string calldata campaignDescription,
        string calldata campaignUrl,
        string calldata imageUrl
    ) external whenNotPaused onlyCreator(poolId) notDisputed(poolId) {
        if (poolStatus[poolId] != POOLSTATUS.ACTIVE) revert DonationErrorsLib.CampaignNotActive(poolId);

        poolDetail[poolId].setCampaignName(campaignName);
        poolDetail[poolId].setCampaignDescription(campaignDescription);
        poolDetail[poolId].setCampaignUrl(campaignUrl);
        poolDetail[poolId].setImageUrl(imageUrl);

        emit DonationEventsLib.CampaignDetailsUpdated(poolId, campaignName, campaignDescription, campaignUrl, imageUrl);
    }

    function changeEndTime(
        uint256 poolId,
        uint40 endTime
    ) external whenNotPaused onlyCreator(poolId) notDisputed(poolId) {
        if (poolStatus[poolId] != POOLSTATUS.ACTIVE) revert DonationErrorsLib.CampaignNotActive(poolId);

        uint40 startTime = poolDetail[poolId].getStartTime();
        if (endTime <= block.timestamp) revert DonationErrorsLib.InvalidTimeframe(startTime, endTime);
        if (endTime - startTime < MIN_FUNDING_PERIOD || endTime - startTime > MAX_FUNDING_PERIOD) revert DonationErrorsLib.InvalidTimeframe(startTime, endTime);

        poolDetail[poolId].setEndTime(endTime);
        emit DonationEventsLib.CampaignEndTimeChanged(poolId, endTime);
    }

    function withdrawFunds(uint256 poolId) external whenNotPaused onlyCreator(poolId) notDisputed(poolId) {
        bool canWithdraw = false;
        if (poolStatus[poolId] == POOLSTATUS.SUCCESSFUL) {
            canWithdraw = true;
        } else if (poolDetail[poolId].hasFundingModel(FUNDINGMODEL.KEEP_WHAT_YOU_RAISE) && poolDetail[poolId].hasEnded()) {
            canWithdraw = true;
        }

        if (!canWithdraw) {
            if (!poolDetail[poolId].hasEnded()) {
                revert DonationErrorsLib.DeadlineNotReached(poolId, poolDetail[poolId].getEndTime());
            } else if (poolDetail[poolId].hasFundingModel(FUNDINGMODEL.ALL_OR_NOTHING) &&
                       poolBalance[poolId].getTotalDonations() < poolDetail[poolId].getFundingGoal()) {
                revert DonationErrorsLib.FundingGoalNotReached(poolId, poolBalance[poolId].getTotalDonations(), poolDetail[poolId].getFundingGoal());
            }
        }

        uint256 amount = poolBalance[poolId].getBalance();
        if (amount == 0) revert DonationErrorsLib.NoFundsToWithdraw(poolId);

        poolBalance[poolId].deductFromBalance(amount);
        poolToken[poolId].safeTransfer(msg.sender, amount);

        emit DonationEventsLib.FundsWithdrawn(poolId, msg.sender, amount);
    }

    function cancelCampaign(uint256 poolId) external whenNotPaused onlyCreator(poolId) {
        if (poolStatus[poolId] != POOLSTATUS.ACTIVE) revert DonationErrorsLib.CampaignNotActive(poolId);
        if (poolBalance[poolId].getTotalDonations() > 0) revert DonationErrorsLib.CampaignHasDonations(poolId, poolBalance[poolId].getTotalDonations());

        poolStatus[poolId] = POOLSTATUS.DELETED;
        emit DonationEventsLib.CampaignCancelled(poolId, msg.sender);
        emit DonationEventsLib.CampaignStatusChanged(poolId, POOLSTATUS.DELETED);
    }

    // ----------------------------------------------------------------------------
    // View Functions
    // ----------------------------------------------------------------------------

    function getCampaignCreator(uint256 poolId) external view returns (address) {
        return poolAdmin[poolId].getCreator();
    }

    function getCampaignDetails(uint256 poolId) external view returns (PoolDetail memory) {
        return poolDetail[poolId];
    }

    function getCampaignBalance(uint256 poolId) external view returns (uint256) {
        return poolBalance[poolId].getBalance();
    }

    function getFundingProgress(uint256 poolId) external view returns (uint256) {
        uint256 goal = poolDetail[poolId].getFundingGoal();
        if (goal == 0) return 0;
        return (poolBalance[poolId].getTotalDonations() * 100) / goal;
    }

    function getCampaignsCreatedBy(address creator) external view returns (uint256[] memory) {
        return createdCampaigns[creator];
    }

    function getCampaignsDonatedToBy(address donor) external view returns (uint256[] memory) {
        return donatedCampaigns[donor];
    }

    function getDonationDetails(uint256 poolId, address donor) external view returns (DonorDetail memory) {
        return donorDetail[donor][poolId];
    }

    function getCampaignDonors(uint256 poolId) external view returns (address[] memory) {
        return donors[poolId];
    }

    function isCampaignSuccessful(uint256 poolId) external view returns (bool) {
        return poolStatus[poolId] == POOLSTATUS.SUCCESSFUL ||
               (poolBalance[poolId].getTotalDonations() >= poolDetail[poolId].getFundingGoal());
    }

    function hasCampaignFailed(uint256 poolId) external view returns (bool) {
        return poolStatus[poolId] == POOLSTATUS.FAILED ||
               (poolDetail[poolId].hasEnded() &&
                poolDetail[poolId].hasFundingModel(FUNDINGMODEL.ALL_OR_NOTHING) &&
                poolBalance[poolId].getTotalDonations() < poolDetail[poolId].getFundingGoal());
    }

    function getAllCampaignInfo(uint256 poolId)
        external
        view
        returns (
            IDonationPool.PoolAdmin memory _poolAdmin,
            IDonationPool.PoolDetail memory _poolDetail,
            IDonationPool.PoolBalance memory _poolBalance,
            IDonationPool.POOLSTATUS _poolStatus,
            address _poolToken,
            address[] memory _donors
        )
    {
        return (
            poolAdmin[poolId],
            poolDetail[poolId],
            poolBalance[poolId],
            poolStatus[poolId],
            address(poolToken[poolId]),
            donors[poolId]
        );
    }

    // ----------------------------------------------------------------------------
    // Admin Functions
    // ----------------------------------------------------------------------------

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    function flagCampaignAsDisputed(uint256 poolId) external onlyRole(ADMIN_ROLE) {
        if (poolAdmin[poolId].isDisputed()) return;
        poolAdmin[poolId].setDisputed(true);
        emit DonationEventsLib.CampaignDisputed(poolId, msg.sender);
    }

    function resolveDispute(uint256 poolId, bool resolveInFavorOfCreator) external onlyRole(ADMIN_ROLE) {
        if (!poolAdmin[poolId].isDisputed()) return;
        poolAdmin[poolId].setDisputed(false);
        if (!resolveInFavorOfCreator) {
            poolStatus[poolId] = POOLSTATUS.FAILED;
            emit DonationEventsLib.CampaignStatusChanged(poolId, POOLSTATUS.FAILED);
        }
        emit DonationEventsLib.DisputeResolved(poolId, resolveInFavorOfCreator);
    }

    function setPlatformFeeRate(uint16 newFeeRate) external onlyRole(ADMIN_ROLE) {
        if (newFeeRate > FEES_PRECISION) revert DonationErrorsLib.InvalidFeeRate(newFeeRate);
        uint16 oldRate = platformFeeRate;
        platformFeeRate = newFeeRate;
        emit DonationEventsLib.PlatformFeeRateChanged(oldRate, newFeeRate);
    }

    function collectPlatformFees(IERC20 token) external onlyRole(ADMIN_ROLE) {
        uint256 feesToCollect = 0;
        for (uint256 i = 1; i <= latestPoolId; i++) {
            if (address(poolToken[i]) == address(token)) {
                uint256 poolFeesToCollect = poolBalance[i].getFeesToCollect();
                if (poolFeesToCollect > 0) {
                    poolBalance[i].collectFees(poolFeesToCollect);
                    feesToCollect += poolFeesToCollect;
                }
            }
        }
        if (feesToCollect == 0) return;
        platformFeesCollected[address(token)] += feesToCollect;
        token.safeTransfer(msg.sender, feesToCollect);
        emit DonationEventsLib.PlatformFeeCollected(address(token), feesToCollect);
    }

    function emergencyWithdraw(IERC20 token, uint256 amount) external onlyRole(ADMIN_ROLE) whenPaused {
        token.safeTransfer(msg.sender, amount);
        emit DonationEventsLib.EmergencyWithdraw(address(token), amount);
    }

    // ----------------------------------------------------------------------------
    // Access Control Functions
    // ----------------------------------------------------------------------------

    function addAdmin(address account) external onlyOwner {
        _grantRole(ADMIN_ROLE, account);
    }

    function removeAdmin(address account) external onlyOwner {
        _revokeRole(ADMIN_ROLE, account);
    }
}
