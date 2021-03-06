pragma solidity ^0.5.0;

import "../DOSOnChainSDK.sol";

// A user contract asks anything from off-chain world through a url.
contract AskMeAnything is DOSOnChainSDK {
    string public response;
    uint public random;
    // query_id -> valid_status
    mapping(uint => bool) private _valid;
    bool public repeatedCall = false;
    // Default timeout in seconds: Two blocks.
    uint public timeout = 14 * 2;
    string public lastQueriedUrl;
    string public lastQueriedSelector;
    uint public lastRequestedRandom;
    uint8 public lastQueryInternalSerial;

    event SetTimeout(uint previousTimeout, uint newTimeout);
    event QueryResponseReady(uint queryId, string result);
    event RequestSent(address indexed msgSender, uint8 internalSerial, bool succ, uint requestId);
    event RandomReady(uint requestId, uint generatedRandom);

    constructor() public {
        // @dev: setup and then transfer DOS tokens into deployed contract
        // as oracle fees.
        // Unused fees can be reclaimed by calling DOSRefund() in the SDK.
        super.DOSSetup();
    }

    function setQueryMode(bool newMode) public onlyOwner {
        repeatedCall = newMode;
    }

    function setTimeout(uint newTimeout) public onlyOwner {
        emit SetTimeout(timeout, newTimeout);
        timeout = newTimeout;
    }

    // Ask me anything (AMA) off-chain through an api/url.
    function AMA(uint8 internalSerial, string memory url, string memory selector) public {
        lastQueriedUrl = url;
        lastQueriedSelector = selector;
        lastQueryInternalSerial = internalSerial;
        uint id = DOSQuery(timeout, url, selector);
        if (id != 0x0) {
            _valid[id] = true;
            emit RequestSent(msg.sender, internalSerial, true, id);
        } else {
            revert("Invalid query id.");
        }
    }

    // User-defined callback function handling query response.
    function __callback__(uint queryId, bytes calldata result) external auth {
        require(_valid[queryId], "Response with invalid request id!");
        response = string(result);
        emit QueryResponseReady(queryId, response);
        delete _valid[queryId];

        if (repeatedCall) {
            AMA(lastQueryInternalSerial, lastQueriedUrl, lastQueriedSelector);
        }
    }

    function requestSafeRandom(uint8 internalSerial) public {
        lastRequestedRandom = random;
        uint requestId = DOSRandom(now);
        _valid[requestId] = true;
        emit RequestSent(msg.sender, internalSerial, true, requestId);
    }

    // User-defined callback function handling newly generated secure
    // random number.
    function __callback__(uint requestId, uint generatedRandom) external auth {
        require(_valid[requestId], "Response with invalid request id!");
        random = generatedRandom;
        emit RandomReady(requestId, generatedRandom);
        delete _valid[requestId];
    }
}
