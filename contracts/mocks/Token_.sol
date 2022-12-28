// SPDX-License-Identifier: MIT
pragma solidity ^0.5.16;

import "openzeppelin-solidity/contracts/token/ERC20/ERC20.sol";


contract Two is ERC20 {
      uint256 constant initialSupply = 100000000 * (10 ** 18);
      constructor() public ERC20() {
          _mint(msg.sender, initialSupply);
      }
}