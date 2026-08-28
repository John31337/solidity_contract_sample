// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title TaskMarketplace
 * @notice A simple freelance task marketplace with ETH escrow.
 *
 * Workflow:
 * 1. Client creates a task and deposits ETH.
 * 2. Freelancer accepts the task.
 * 3. Freelancer submits the completed work.
 * 4. Client approves the work.
 * 5. Escrowed ETH is released to the freelancer.
 *
 * The client can cancel a task before a freelancer accepts it.
 */

contract TaskMarketplace {
    enum TaskStatus {
        Open,
        InProgress,
        Submitted,
        Completed,
        Cancelled
    }

    struct Task {
        uint256 id;
        address payable client;
        address payable freelancer;
        uint256 payment;
        string title;
        string description;
        string workSubmission;
        TaskStatus status;
        uint256 createdAt;
        uint256 acceptedAt;
        uint256 submittedAt;
        uint256 completedAt;
    }

    uint256 private nextTaskId = 1;

    mapping(uint256 => Task) private tasks;

    uint256 public platformFees;
    uint256 public constant PLATFORM_FEE_BPS = 100; // 1%
    uint256 public constant BPS_DENOMINATOR = 10_000;

    address public immutable owner;

    bool private locked;

    event TaskCreated(
        uint256 indexed taskId,
        address indexed client,
        uint256 payment,
        string title
    );

    event TaskAccepted(
        uint256 indexed taskId,
        address indexed freelancer
    );

    event WorkSubmitted(
        uint256 indexed taskId,
        string workSubmission
    );

    event TaskCompleted(
        uint256 indexed taskId,
        address indexed client,
        address indexed freelancer,
        uint256 freelancerPayment,
        uint256 platformFee
    );

    event TaskCancelled(
        uint256 indexed taskId,
        address indexed client,
        uint256 refundedAmount
    );

    event PlatformFeesWithdrawn(
        address indexed owner,
        uint256 amount
    );

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    modifier nonReentrant() {
        require(!locked, "Reentrancy detected");

        locked = true;
        _;

        locked = false;
    }

    modifier taskExists(uint256 taskId) {
        require(tasks[taskId].id != 0, "Task does not exist");
        _;
    }

    modifier onlyClient(uint256 taskId) {
        require(
            msg.sender == tasks[taskId].client,
            "Only task client"
        );
        _;
    }

    modifier onlyFreelancer(uint256 taskId) {
        require(
            msg.sender == tasks[taskId].freelancer,
            "Only task freelancer"
        );
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    /**
     * @notice Create a new task and deposit ETH into escrow.
     */
    function createTask(
        string calldata title,
        string calldata description
    )
        external
        payable
        returns (uint256 taskId)
    {
        require(bytes(title).length > 0, "Title is required");
        require(msg.value > 0, "Payment must be greater than zero");

        taskId = nextTaskId;

        tasks[taskId] = Task({
            id: taskId,
            client: payable(msg.sender),
            freelancer: payable(address(0)),
            payment: msg.value,
            title: title,
            description: description,
            workSubmission: "",
            status: TaskStatus.Open,
            createdAt: block.timestamp,
            acceptedAt: 0,
            submittedAt: 0,
            completedAt: 0
        });

        nextTaskId++;

        emit TaskCreated(
            taskId,
            msg.sender,
            msg.value,
            title
        );
    }

    /**
     * @notice Accept an open task.
     */
    function acceptTask(
        uint256 taskId
    )
        external
        taskExists(taskId)
    {
        Task storage task = tasks[taskId];

        require(
            task.status == TaskStatus.Open,
            "Task is not open"
        );

        require(
            msg.sender != task.client,
            "Client cannot accept own task"
        );

        task.freelancer = payable(msg.sender);
        task.status = TaskStatus.InProgress;
        task.acceptedAt = block.timestamp;

        emit TaskAccepted(
            taskId,
            msg.sender
        );
    }

    /**
     * @notice Freelancer submits completed work.
     *
     * workSubmission can contain:
     * - IPFS CID
     * - GitHub URL
     * - Deliverable hash
     * - Any off-chain reference
     */
    function submitWork(
        uint256 taskId,
        string calldata workSubmission
    )
        external
        taskExists(taskId)
        onlyFreelancer(taskId)
    {
        Task storage task = tasks[taskId];

        require(
            task.status == TaskStatus.InProgress,
            "Task is not in progress"
        );

        require(
            bytes(workSubmission).length > 0,
            "Submission is required"
        );

        task.workSubmission = workSubmission;
        task.status = TaskStatus.Submitted;
        task.submittedAt = block.timestamp;

        emit WorkSubmitted(
            taskId,
            workSubmission
        );
    }

    /**
     * @notice Client approves the submitted work.
     *
     * ETH is released to the freelancer.
     */
    function approveWork(
        uint256 taskId
    )
        external
        nonReentrant
        taskExists(taskId)
        onlyClient(taskId)
    {
        Task storage task = tasks[taskId];

        require(
            task.status == TaskStatus.Submitted,
            "Work has not been submitted"
        );

        uint256 fee =
            (task.payment * PLATFORM_FEE_BPS)
            / BPS_DENOMINATOR;

        uint256 freelancerPayment =
            task.payment - fee;

        task.status = TaskStatus.Completed;
        task.completedAt = block.timestamp;

        platformFees += fee;

        (bool success, ) =
            task.freelancer.call{
                value: freelancerPayment
            }("");

        require(
            success,
            "Payment transfer failed"
        );

        emit TaskCompleted(
            taskId,
            task.client,
            task.freelancer,
            freelancerPayment,
            fee
        );
    }

    /**
     * @notice Client cancels a task before anyone accepts it.
     *
     * The full escrow amount is returned.
     */
    function cancelTask(
        uint256 taskId
    )
        external
        nonReentrant
        taskExists(taskId)
        onlyClient(taskId)
    {
        Task storage task = tasks[taskId];

        require(
            task.status == TaskStatus.Open,
            "Cannot cancel this task"
        );

        uint256 refundAmount = task.payment;

        task.status = TaskStatus.Cancelled;

        (bool success, ) =
            task.client.call{
                value: refundAmount
            }("");

        require(
            success,
            "Refund failed"
        );

        emit TaskCancelled(
            taskId,
            task.client,
            refundAmount
        );
    }

    /**
     * @notice Contract owner withdraws accumulated platform fees.
     */
    function withdrawPlatformFees()
        external
        onlyOwner
        nonReentrant
    {
        uint256 amount = platformFees;

        require(
            amount > 0,
            "No fees available"
        );

        platformFees = 0;

        (bool success, ) =
            payable(owner).call{
                value: amount
            }("");

        require(
            success,
            "Fee withdrawal failed"
        );

        emit PlatformFeesWithdrawn(
            owner,
            amount
        );
    }

    /**
     * @notice Get a task.
     */
    function getTask(
        uint256 taskId
    )
        external
        view
        taskExists(taskId)
        returns (
            uint256 id,
            address client,
            address freelancer,
            uint256 payment,
            string memory title,
            string memory description,
            string memory workSubmission,
            TaskStatus status,
            uint256 createdAt,
            uint256 acceptedAt,
            uint256 submittedAt,
            uint256 completedAt
        )
    {
        Task storage task = tasks[taskId];

        return (
            task.id,
            task.client,
            task.freelancer,
            task.payment,
            task.title,
            task.description,
            task.workSubmission,
            task.status,
            task.createdAt,
            task.acceptedAt,
            task.submittedAt,
            task.completedAt
        );
    }

    /**
     * @notice Get total number of created tasks.
     */
    function getTaskCount()
        external
        view
        returns (uint256)
    {
        return nextTaskId - 1;
    }

    /**
     * @notice Prevent accidental ETH transfers.
     */
    receive() external payable {
        revert(
            "Use createTask to deposit ETH"
        );
    }

    fallback() external payable {
        revert(
            "Invalid function call"
        );
    }
}