// Layout of the contract file:
// version
// imports
// errors
// interfaces, libraries, contract

// Inside Contract:
// Type declarations (Structs, Enums, etc.)
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

//SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {VRFConsumerBaseV2Plus} from "@chainlink/contracts@1.5.0/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts@1.5.0/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

/**
 * @title  Raffle contract
 * @author Mercy Cherono
 * @notice This contract is for creating a sample Lottery/Raffle smart contract
 * @dev Implements Chainlink VRFV2.5
 */

contract Raffle is VRFConsumerBaseV2Plus {
    /* Errors */
    error Raffle__SendMoreEthToEnterRaffle();
    error Raffle__TransferFailed();
    error Raffle__RaffleNotOpen();
    error Raffle__UpkeepNotNeeded(uint256 currentBalance, uint256 numPlayers, uint256 raffleState);

    /* Type Declarations */
    enum RaffleState {
        OPEN, //0
        CALCULATING //1
        //2 etc...
    }

    /* State Variables */
    uint16 private constant REQUEST_CONFIRMATIONS = 3;
    uint32 private constant NUM_WORDS = 1;
    uint256 private immutable i_entranceFee;
    uint256 private immutable i_interval; //Time between lottery draws/rounds in seconds
    bytes32 private immutable i_keyHash;
    uint256 private immutable i_subscriptionId;
    uint32 private immutable i_callbackGasLimit;
    address payable[] private s_players; //payable so that the contract can send money to the winner
    uint256 private s_lastTimeStamp; //To keep track of the last time a winner was picked
    address private s_recentWinner; //To keep track of the most recent winner
    RaffleState private s_raffleState; //To keep track of the state of the raffle (open or calculating)

    /* Events */
    event RaffleEntered(address indexed player);
    event WinnerPicked(address indexed winner);
    event RequestedRaffleWinner(uint256 indexed requestId);

    constructor(
        uint256 entranceFee,
        uint256 interval,
        address vrfCoordinator,
        bytes32 gasLane,
        uint256 subscriptionId,
        uint32 callbackGasLimit
    ) VRFConsumerBaseV2Plus(vrfCoordinator) {
        i_entranceFee = entranceFee;
        i_interval = interval;
        i_keyHash = gasLane;
        i_subscriptionId = subscriptionId;
        i_callbackGasLimit = callbackGasLimit;

        s_lastTimeStamp = block.timestamp; //Set the last time stamp to the current time
        s_raffleState = RaffleState.OPEN; //Set the default raffle state to open
    }

    //CEI: Checks, Effects, Interactions Pattern

    function enterRaffle() external payable {
        //require(msg.value >= i_entranceFee, "Not enough ETH sent!");
        //require(msg.value >= i_entranceFee, Raffle__SendMoreEthToEnterRaffle());
        if (msg.value < i_entranceFee) {
            revert Raffle__SendMoreEthToEnterRaffle();
        }

        //Check if the raffle is open
        if (s_raffleState != RaffleState.OPEN) {
            revert Raffle__RaffleNotOpen();
        }

        s_players.push(payable(msg.sender)); //Add the player to the list of players
        //Events make migrations easier to track and are cheaper than storing data on-chain
        //Events also make frontend indexing easier, as they can be used to filter and search for specific events in the blockchain.
        emit RaffleEntered(msg.sender);
    }

    //1. Get a random number
    //2. Use that number to pick a winner (index of the array)
    //3. It needs to be automatically triggered, so we will use Chainlink Keepers to do this

    //When should we pick a winner? We should pick a winner when:
    /**
     * @dev This function is called by Chainlink Keepers to check if the contract needs to perform upkeep (pick a winner)
     * The function should return true if the contract needs to perform upkeep, and false otherwise.
     * @param - Ignored
     * @return upkeepNeeded - True if it's time to restart the lottery
     * 1.The time interval has passed since the last time a winner was picked
     * 2. The raffle is open
     * 3. The lottery has ETH in it (the contract balance is greater than 0, meaning that there are players in the raffle)
     * 4. Implicitly, the subscription is funded with LINK (this is handled by Chainlink Keepers)
     * @return  - Ignored
     */
    function checkUpkeep(
        bytes memory /* checkData */
    )
        public
        view
        returns (
            bool upkeepNeeded,
            bytes memory /* performData */
        )
    {
        bool timeHasPassed = ((block.timestamp - s_lastTimeStamp) >= i_interval);
        bool isOpen = s_raffleState == RaffleState.OPEN;
        bool hasBalance = address(this).balance > 0;
        bool hasPlayers = s_players.length > 0;

        upkeepNeeded = (timeHasPassed && isOpen && hasBalance && hasPlayers);
        return (upkeepNeeded, "");
    }

    function performUpkeep(
        bytes calldata /* performData */
    )
        external
    {
        //First check to see if enough time has passed
        (bool upkeepNeeded,) = checkUpkeep("");
        if (!upkeepNeeded) {
            revert Raffle__UpkeepNotNeeded(address(this).balance, s_players.length, uint256(s_raffleState));
        }

        //Set the Raffle State to calculating so that no one can enter the raffle while we are picking a winner
        s_raffleState = RaffleState.CALCULATING;

        VRFV2PlusClient.RandomWordsRequest memory request = VRFV2PlusClient.RandomWordsRequest({
            keyHash: i_keyHash,
            subId: i_subscriptionId,
            requestConfirmations: REQUEST_CONFIRMATIONS,
            callbackGasLimit: i_callbackGasLimit,
            numWords: NUM_WORDS,
            extraArgs: VRFV2PlusClient._argsToBytes(
                // Set nativePayment to true to pay for VRF requests with Sepolia ETH instead of LINK
                VRFV2PlusClient.ExtraArgsV1({nativePayment: false})
            )
        });

        //Get our random number from Chainlink VRF
        uint256 requestId = s_vrfCoordinator.requestRandomWords(request);
        emit RequestedRaffleWinner(requestId); 
    }

    function fulfillRandomWords(
        uint256,
        /* requestId */
        uint256[] calldata randomWords
    )
        internal
        override
    {
        //Pick the winner using the Modulo operator

        //Effects: Update the state of the contract before making any external calls to prevent reentrancy attacks
        uint256 indexOfWinner = randomWords[0] % s_players.length;
        address payable recentWinner = s_players[indexOfWinner];
        s_recentWinner = recentWinner;

        //Set raffle state back to open so that people can enter the raffle again
        s_raffleState = RaffleState.OPEN;

        //Reset the players array so that we can start a new raffle
        s_players = new address payable[](0);

        //Update the last time stamp to the current time so that we can start a new raffle
        s_lastTimeStamp = block.timestamp;

        //Emit a log event to indicate that a winner has been picked
        emit WinnerPicked(recentWinner);

        //Interactions: External calls should be made after all state changes have been made to prevent reentrancy attacks
        //Pay the winner the entire balance of the contract
        (bool success,) = recentWinner.call{value: address(this).balance}("");
        //Make sure the transfer was successful
        if (!success) {
            revert Raffle__TransferFailed();
        }
    }

    /**
     * Getter functions
     */

    function getEntranceFee() external view returns (uint256) {
        return i_entranceFee;
    }

    function getRaffleState() external view returns (RaffleState) {
        return s_raffleState;
    }

    function getPlayer(uint256 indexOfPlayer) external view returns(address) {
        return s_players[indexOfPlayer];
    }

    function getLastTimeStamp() external view returns(uint256) {
        return s_lastTimeStamp;
    }

    function getRecentWinner() external view returns(address) {
        return s_recentWinner;
    }
}

