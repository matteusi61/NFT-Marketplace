pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import {Marketplace} from "../src/Marketplace.sol";
import {NFTFactory} from "../src/FactoryNFT.sol";
import {CardNFT} from "../src/CardNFT.sol";
import {ColorNFT} from "../src/ColorNFT.sol";
import {StarNFT} from "../src/StarNFT.sol";
import {ERC1967Proxy} from "../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployerAddress = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        CardNFT cardNFT = new CardNFT(deployerAddress);
        ColorNFT colorNFT = new ColorNFT(deployerAddress);
        StarNFT starNFT = new StarNFT(deployerAddress);

        NFTFactory factory = new NFTFactory(address(cardNFT), address(colorNFT), address(starNFT), deployerAddress);

        Marketplace marketplace = new Marketplace(payable(address(factory)));
        factory.transferOwnership(address(marketplace));
        cardNFT.transferOwnership(address(factory));
        colorNFT.transferOwnership(address(factory));
        starNFT.transferOwnership(address(factory));

        ERC1967Proxy proxy = new ERC1967Proxy(address(marketplace), "");

        vm.stopBroadcast();

        console.log("CardNFT address is ", address(cardNFT));
        console.log("StarNFT address is ", address(starNFT));
        console.log("ColorNFT address is ", address(colorNFT));
        console.log("Marketplace address is ", address(marketplace));
        console.log("FactoryNFT address is ", address(factory));
        console.log("Proxy address is ", address(proxy));
    }
}
