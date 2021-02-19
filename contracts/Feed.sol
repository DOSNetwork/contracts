pragma solidity ^0.5.0;

import "./SafeMath.sol";
import "./DOSOnChainSDK.sol";

contract IParser {
    function parse(string memory raw, uint decimal) public view returns(uint);
}

contract Feed is DOSOnChainSDK {
    using SafeMath for uint;

    uint private constant ONEHOUR = 1 hours;
    uint private constant ONEDAY = 1 days;
    // overflow flag
    uint private constant UINT_MAX = uint(-1);
    uint public windowSize = 1200;     // 20 minutes
    string public source;
    string public selector;
    // Absolute price deviation percentage * 1000, i.e. 1 represents 1/1000 price change.
    uint public deviation;
    // Number of decimals the reported price data use.
    uint public decimal;
    // Data parser, may be configured along with data source change
    address public parser;
    // Reader whitelist
    mapping(address => bool) private whitelist;
    // Feed data is either updated once per windowSize or the deviation requirement is met, whichever comes first.
    // Anyone can trigger an update on windowSize expiration, but only governance approved ones can be deviation updater to get rid of sybil attacks.
    mapping(address => bool) private deviationGuardian;
    mapping(uint => bool) private _valid;

    struct Observation {
        uint timestamp;
        uint price;
    }
    Observation[] private observations;
    
    event QueryUpdated(string oldSource, string newSource, string oldSelector, string newSelector, uint oldDecmial, uint newDecimal);
    event WindowUpdated(uint oldWindow, uint newWindow);
    event DeviationUpdated(uint oldDeviation, uint newDeviation);
    event ParserUpdated(address oldParser, address newParser);
    event DataUpdated(uint timestamp, uint price);
    event PulledTrigger(address trigger, uint qId);
    event BulletCaught(uint qId);
    event AddAccess(address reader);
    event RemoveAccess(address reader);
    event AddGuardian(address guardian);
    event RemoveGuardian(address guardian);
    
    modifier accessible {
        require(whitelist[msg.sender] || msg.sender == tx.origin, "not-accessible");
        _;
    }

    modifier isContract(address addr) {
        uint codeSize = 0;
        assembly {
            codeSize := extcodesize(addr)
        }
        require(codeSize > 0, "not-smart-contract");
        _;
    }

    constructor(string memory _source, string memory _selector, uint _decimal) public {
        // @dev: setup and then transfer DOS tokens into deployed contract
        // as oracle fees.
        // Unused fees can be reclaimed by calling DOSRefund() function of SDK contract.
        super.DOSSetup();
        source = _source;
        selector = _selector;
        decimal = _decimal;
        emit QueryUpdated("", _source, "", _selector, 0, _decimal);
    }
    
    function updateQuery(string memory _source, string memory _selector, uint _decimal) public onlyOwner {
        emit QueryUpdated(source, _source, selector, _selector, decimal, _decimal);
        source = _source;
        selector = _selector;
        decimal = _decimal;
    }
    // This will erase all observed data!
    function updateWindowSize(uint newWindow) public onlyOwner {
        emit WindowUpdated(windowSize, newWindow);
        windowSize = newWindow;
        delete observations;
    }
    function updateDeviation(uint newDeviation) public onlyOwner {
        require(newDeviation >= 0 && newDeviation <= 1000, "should-be-in-0-1000");
        emit DeviationUpdated(deviation, newDeviation);
        deviation = newDeviation;
    }
    function updateParser(address newParser) public onlyOwner isContract(newParser) {
        emit ParserUpdated(parser, newParser);
        parser = newParser;
    }
    function addReader(address reader) public onlyOwner {
        if (!whitelist[reader]) {
            whitelist[reader] = true;
            emit AddAccess(reader);
        }
    }
    function removeReader(address reader) public onlyOwner {
        if (whitelist[reader]) {
            delete whitelist[reader];
            emit RemoveAccess(reader);
        }
    }
    function addGuardian(address guardian) public onlyOwner {
        if (!deviationGuardian[guardian]) {
            deviationGuardian[guardian] = true;
            emit AddGuardian(guardian);
        }
    }
    function removeGuardian(address guardian) public onlyOwner {
        if (deviationGuardian[guardian]) {
            delete deviationGuardian[guardian];
            emit RemoveGuardian(guardian);
        }
    }

    function stale(uint age) public view returns(bool) {
        uint lastTime = observations.length > 0 ? observations[observations.length - 1].timestamp : 0;
        return block.timestamp > lastTime.add(age);
    }

    function pullTrigger() public {
        if(!stale(windowSize) && !deviationGuardian[msg.sender]) return;

        uint id = DOSQuery(30, source, selector);
        if (id != 0) {
            _valid[id] = true;
            emit PulledTrigger(msg.sender, id);
        }
    }

    function __callback__(uint id, bytes calldata result) external auth {
        require(_valid[id], "invalid-request-id");
        uint priceData = IParser(parser).parse(string(result), decimal);
        if (update(priceData)) emit BulletCaught(id);
        delete _valid[id];
    }

    function update(uint price) private returns (bool) {
        uint lastPrice = observations.length > 0 ? observations[observations.length - 1].price : 0;
        uint delta = price > lastPrice ? (price - lastPrice) : (lastPrice - price);
        if (stale(windowSize) || (deviation > 0 && delta >= lastPrice.mul(deviation).div(1000))) {
            observations.push(Observation(block.timestamp, price));
            emit DataUpdated(block.timestamp, price);
            return true;
        }
        return false;
    }
    
    // Return latest reported price & timestamp data.
    function latestResult() public view accessible returns (uint _lastPrice, uint _lastUpdatedTime) {
        require(observations.length > 0);
        Observation storage last = observations[observations.length - 1];
        return (last.price, last.timestamp);
    }
    
    // Given sample size return time-weighted average price (TWAP) of (observations[start] : observations[end])
    function twapResult(uint start) public view accessible returns (uint) {
        require(start < observations.length, "index-overflow");
        
        uint end = observations.length - 1;
        uint cumulativePrice = 0;
        for (uint i = start; i < end; i++) {
            cumulativePrice = cumulativePrice.add(observations[i].price.mul(observations[i+1].timestamp.sub(observations[i].timestamp)));
        }
        uint timeElapsed = observations[end].timestamp.sub(observations[start].timestamp);
        return cumulativePrice.div(timeElapsed);
    }
    
    // Observation[] is sorted by timestamp in ascending order. Return the maximum index {i}, satisfying that: observations[i].timestamp <= observations[end].timestamp.sub(timedelta)
    // Return UINT_MAX if not enough data points.
    function binarySearch(uint timedelta) public view returns (uint) {
        int index = -1;
        int l = 0;
        int r = int(observations.length.sub(1));
        uint key = observations[uint(r)].timestamp.sub(timedelta);
        while (l <= r) {
            int m = (l + r) / 2;
            uint m_val = observations[uint(m)].timestamp;
            if (m_val <= key) {
                index = m;
                l = m + 1;
            } else {
                r = m - 1;
            }
        }
        return uint(index);
    }
    
    function TWAP1Hour() public view accessible returns (uint) {
        require(!stale(ONEHOUR), "1h-outdated-data");
        uint idx = binarySearch(ONEHOUR);
        require(idx != UINT_MAX, "not-enough-observation-data-for-1h");
        return twapResult(idx);
    }
    
    function TWAP2Hour() public view accessible returns (uint) {
        require(!stale(ONEHOUR * 2), "2h-outdated-data");
        uint idx = binarySearch(ONEHOUR * 2);
        require(idx != UINT_MAX, "not-enough-observation-data-for-2h");
        return twapResult(idx);
    }
    
    function TWAP4Hour() public view accessible returns (uint) {
        require(!stale(ONEHOUR * 4), "4h-outdated-data");
        uint idx = binarySearch(ONEHOUR * 4);
        require(idx != UINT_MAX, "not-enough-observation-data-for-4h");
        return twapResult(idx);
    }

    function TWAP6Hour() public view accessible returns (uint) {
        require(!stale(ONEHOUR * 6), "6h-outdated-data");
        uint idx = binarySearch(ONEHOUR * 6);
        require(idx != UINT_MAX, "not-enough-observation-data-for-6h");
        return twapResult(idx);
    }

    function TWAP8Hour() public view accessible returns (uint) {
        require(!stale(ONEHOUR * 8), "8h-outdated-data");
        uint idx = binarySearch(ONEHOUR * 8);
        require(idx != UINT_MAX, "not-enough-observation-data-for-8h");
        return twapResult(idx);
    }
    
    function TWAP12Hour() public view accessible returns (uint) {
        require(!stale(ONEHOUR * 12), "12h-outdated-data");
        uint idx = binarySearch(ONEHOUR * 12);
        require(idx != UINT_MAX, "not-enough-observation-data-for-12h");
        return twapResult(idx);
    }
    
    function TWAP1Day() public view accessible returns (uint) {
        require(!stale(ONEDAY), "1d-outdated-data");
        uint idx = binarySearch(ONEDAY);
        require(idx != UINT_MAX, "not-enough-observation-data-for-1d");
        return twapResult(idx);
    }
    
    function TWAP1Week() public view accessible returns (uint) {
        require(!stale(ONEDAY * 7), "1w-outdated-data");
        uint idx = binarySearch(ONEDAY * 7);
        require(idx != UINT_MAX, "not-enough-observation-data-for-1week");
        return twapResult(idx);
    }
}
