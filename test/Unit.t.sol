// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ZLSetup} from "./ZLSetup.sol";
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

contract Unit is Test, ZLSetup {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        deploy();
        token.transfer(alice, 10000e18);
        token.transfer(bob, 10000e18);
    }

    function test_createLock() public {
        vm.startPrank(alice);

        token.approve(address(locker), 50e18);
        locker.createLock(50e18, 2 weeks);

        console.log("Voting Power: %s", locker.balanceOfNFT(1));

        vm.stopPrank();
    }
}
