// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MarketNFT} from "./MarketNFT.sol";
import {VRFConsumerBaseV2Plus} from "../lib/chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "../lib/chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {IERC721} from "../lib/openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {Math} from "../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {UUPSUpgradeable} from "../lib/openzeppelin-contracts/contracts/proxy/utils/UUPSUpgradeable.sol";
import {NFTFactory} from "./FactoryNFT.sol";

contract Marketplace is VRFConsumerBaseV2Plus, ReentrancyGuard, UUPSUpgradeable {
    using Math for uint256;

    struct Listing {
        address seller;
        address nftContract;
        uint256 tokenId;
        string nftType;
    }

    struct Curve {
        uint256 exponent;
        uint256 totalListed;
        uint256 totalMinted;
    }

    struct MintRequest {
        address user;
        string nftType;
        uint256 paidAmount;
    }

    struct RequestStatus {
        bool fulfilled;
        bool exists;
        uint256[] randomWords;
    }

    bytes32 internal keyHash;
    uint256 public randomResult;
    uint256 public s_subscriptionId;
    uint256[] public requestIds;
    uint256 public lastRequestId;
    uint32 internal callbackGasLimit = 500000;
    uint16 internal requestConfirmations = 3;
    uint32 internal numWords = 2;
    mapping(uint256 => MintRequest) public mintRequests;
    mapping(uint256 => RequestStatus) public s_requests;

    NFTFactory public factory;
    mapping(address => Curve) public curves;
    mapping(bytes32 => Listing) public listings;
    mapping(bytes32 => uint256) public listingIndex;
    mapping(string => uint256) public mintprice;
    bytes32[] public allListings;
    uint256 public platformFee = 250;
    uint256 public totalListed = 0;
    uint256 public allTotalMinted = 0;

    event MintStarted(uint256 requestId, address indexed user);
    event NFTMinted(address indexed owner, string nftType, uint256 tokenId);
    event NFTListed(bytes32 listingId, address indexed seller, string nftType, uint256 tokenId, uint256 price);
    event NFTBought(bytes32 listingId, address indexed buyer, uint256 price);
    event NFTReturned(bytes32 listingId, address indexed keeper);

    constructor(address _factory, uint256 subscriptionId)
        VRFConsumerBaseV2Plus(0x9DdfaCa8183c41ad55329BdeeD9F6A8d53168B1B)
    {
        keyHash = 0x787d74caea10b2b357790d5b5247c2f63d1d91572a9846f780606e4d953677ae;
        s_subscriptionId = subscriptionId;
        factory = NFTFactory(_factory);
        _initCurves();
        _initMints();
    }

    function _initCurves() internal {
        for (uint256 i = 0; i < factory.getKeysLen(); i++) {
            address nftAddr = factory.getNftAddr(factory.getNftName(i));
            curves[nftAddr] = Curve(MarketNFT(nftAddr).curveExp(), 0, 0);
        }
    }

    function _initMints() internal {
        for (uint256 i = 0; i < factory.getKeysLen(); i++) {
            string memory nftName = factory.getNftName(i);
            address nftAddr = factory.getNftAddr(nftName);
            mintprice[nftName] = MarketNFT(nftAddr).meanPrice();
        }
    }

    function mintNFT(string memory nftType) external payable nonReentrant {
        require(allTotalMinted <= 10000, "Mint is not available yet!");

        address nftContract = _getContractByType(nftType);
        require(nftContract != address(0), "Invalid NFT type");

        uint256 currentPrice = getMintPrice(nftType);
        require(msg.value >= currentPrice, "Insufficient funds");

        uint256 requestID = requestRandomWords(false);
        mintRequests[requestID] = MintRequest(msg.sender, nftType, msg.value);
        allTotalMinted += 1;
        curves[nftContract].totalMinted += 1;

        if (msg.value > currentPrice) {
            payable(msg.sender).transfer(msg.value - currentPrice);
        }
        payable(owner()).transfer(currentPrice);
        emit MintStarted(requestID, msg.sender);
    }

    function getMintPrice(string memory nftType) public view returns (uint256) {
        require(allTotalMinted <= 10000, "Mint is not available yet!");
        address nftContract = _getContractByType(nftType);
        require(nftContract != address(0), "Invalid NFT type");

        if (allTotalMinted > 1000 && allTotalMinted <= 1445) {
            return mintprice[nftType];
        } else if (allTotalMinted <= 1000) {
            return (mintprice[nftType] / 5) + (mintprice[nftType] / 1250) * allTotalMinted;
        } else {
            return 10 * mintprice[nftType] - (4000 * mintprice[nftType]) / (allTotalMinted - 1000);
        }
    }

    function requestRandomWords(bool enableNativePayment) internal onlyOwner returns (uint256 requestId) {
        requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: keyHash,
                subId: s_subscriptionId,
                requestConfirmations: requestConfirmations,
                callbackGasLimit: callbackGasLimit,
                numWords: numWords,
                extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: enableNativePayment}))
            })
        );
        s_requests[requestId] = RequestStatus({randomWords: new uint256[](0), exists: true, fulfilled: false});
        requestIds.push(requestId);
        lastRequestId = requestId;
        return requestId;
    }

    function fulfillRandomWords(uint256 _requestId, uint256[] calldata _randomWords) internal override {
        require(s_requests[_requestId].exists, "request not found");
        MintRequest memory req = mintRequests[_requestId];
        s_requests[_requestId].fulfilled = true;
        s_requests[_requestId].randomWords = _randomWords;
        uint256 randomness = _randomWords[0] + _randomWords[1];
        uint256 tokenId = factory.createNFT(req.nftType, req.user, randomness);

        delete mintRequests[_requestId];

        emit NFTMinted(req.user, req.nftType, tokenId);
    }

    function listNFT(uint256 tokenId, string memory nftType) external {
        address nftContract = _getContractByType(nftType);
        require(nftContract != address(0), "Unsupported NFT");
        require(IERC721(nftContract).ownerOf(tokenId) == msg.sender, "Not owner");

        bytes32 listingId = keccak256(abi.encodePacked(block.timestamp, nftContract, tokenId));
        listings[listingId] =
            Listing({seller: msg.sender, nftContract: nftContract, tokenId: tokenId, nftType: nftType});

        allListings.push(listingId);
        listingIndex[listingId] = allListings.length - 1;
        curves[nftContract].totalListed += 1;
        totalListed += 1;

        emit NFTListed(listingId, msg.sender, nftType, tokenId, calculatePrice(listingId));
    }

    function buyNFT(bytes32 listingId) external payable nonReentrant {
        require(listings[listingId].seller != address(0), "Listing not found");
        Listing memory listing = listings[listingId];

        uint256 currentPrice = calculatePrice(listingId);
        require(msg.value >= currentPrice, "Insufficient funds");

        curves[listing.nftContract].totalListed -= 1;
        totalListed -= 1;

        uint256 index = listingIndex[listingId];
        bytes32 lastListingId = allListings[allListings.length - 1];
        allListings[index] = lastListingId;
        listingIndex[lastListingId] = index;
        allListings.pop();
        delete listings[listingId];
        delete listingIndex[listingId];

        IERC721(listing.nftContract).transferFrom(listing.seller, msg.sender, listing.tokenId);

        uint256 fee = (currentPrice * platformFee) / 10000;
        payable(owner()).transfer(fee);
        payable(listing.seller).transfer(currentPrice - fee);
        if (msg.value > currentPrice) {
            payable(msg.sender).transfer(msg.value - currentPrice);
        }

        emit NFTBought(listingId, msg.sender, currentPrice);
    }

    function returnNFT(bytes32 listingId) external {
        Listing storage listing = listings[listingId];

        require(msg.sender == address(listing.seller), "Not the owner");

        curves[listing.nftContract].totalListed -= 1;
        totalListed -= 1;

        uint256 index = listingIndex[listingId];
        bytes32 lastListingId = allListings[allListings.length - 1];
        allListings[index] = lastListingId;
        listingIndex[lastListingId] = index;
        allListings.pop();
        delete listings[listingId];
        delete listingIndex[listingId];

        emit NFTReturned(listingId, msg.sender);
    }

    function getActiveListings() external view returns (Listing[] memory) {
        Listing[] memory active = new Listing[](allListings.length);
        uint256 count;

        for (uint256 i = 0; i < allListings.length; i++) {
            active[count] = listings[allListings[i]];
        }

        return active;
    }

    function calculatePrice(bytes32 listingId) public view returns (uint256) {
        Listing memory listing = listings[listingId];
        Curve memory curve = curves[listing.nftContract];
        uint256 basePrice = factory.getBasePrice(listing.nftType, listing.tokenId);
        uint256 tenMill = 100000000;

        if (allTotalMinted <= 10000) {
            uint256 exp = tenMill;
            for (uint256 i = 0; i < curve.totalMinted - curve.totalListed; i++) {
                exp = exp * curve.exponent;
                exp = exp / (curve.exponent - 2);
                if (exp > 10 * tenMill) {
                    exp = 10 * tenMill;
                    break;
                }
            }
            return basePrice * exp / tenMill;
        } else {
            uint256 exp = tenMill;
            for (uint256 i = 0; i < curve.totalListed; i++) {
                exp = exp * curve.exponent;
                exp = exp / (curve.exponent - 2);
            }
            return basePrice * exp / tenMill;
        }
    }

    function getRequestStatus(uint256 _requestId)
        external
        view
        returns (bool fulfilled, uint256[] memory randomWords)
    {
        require(s_requests[_requestId].exists, "request not found");
        RequestStatus memory request = s_requests[_requestId];
        return (request.fulfilled, request.randomWords);
    }

    function _getContractByType(string memory nftType) internal view returns (address) {
        return factory.getNftAddr(nftType);
    }

    function _isSupportedContract(address nftContract) internal view returns (bool) {
        for (uint256 i = 0; i < factory.getKeysLen(); i++) {
            string memory nftName = factory.getNftName(i);
            address nftAddr = factory.getNftAddr(nftName);
            if (nftAddr == nftContract) {
                return true;
            }
        }
        return false;
    }

    function addNewNftToMarket(address newNFT) public onlyOwner {
        factory.addNewNFT(newNFT);
        curves[newNFT] = Curve(MarketNFT(newNFT).curveExp(), 0, 0);
        string memory newNftName = MarketNFT(newNFT).name();
        mintprice[newNftName] = MarketNFT(newNFT).meanPrice();
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
