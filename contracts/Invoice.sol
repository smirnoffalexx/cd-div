// SPDX-License-Identifier: MIT

pragma solidity 0.8.17;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "./utils/CustomContext.sol";

import "./libraries/ExceptionsLibrary.sol";
import "./interfaces/registry/IRegistry.sol";
import "./interfaces/IPool.sol";
import "./interfaces/IInvoice.sol";
import "./interfaces/IPausable.sol";

/**
 * @title Invoice Contract
 * @notice This contract is designed for managing invoices issued by pools for payment.
 * @dev It supports both trusted (payment confirmation off-chain by an authorized address) and trustless (on-chain payment) modes of operation.
 *Regardless of the presence of Governance tokens in delegation or balance, and regardless of the owner/creator pool status, any address can act as an invoice payer. The following conditions must be met:
 *
 * - The structure Invoice.sol:invoices for the selected invoice number stores either an empty InvoiceInfo.core.whitelist[] (public invoice), or it contains the payer's address
 * - The structure Invoice.sol:invoices for the selected invoice number has the values false in the fields InvoiceInfo.isPaid and InvoiceInfo.isCanceled (the invoice has not been canceled or paid by anyone yet)
 * - The current network block is less than the InvoiceInfo.core.expirationBlock stored in the structure Invoice.sol:invoices for the selected invoice number
 *
 * When paying the invoice, the amount specified by the invoice creator is debited in the units they have chosen (ERC20 tokens or ETH).
 *
 *@dev _Note. All the above is valid for on-chain invoice payments. For off-chain invoice payments, a 3rd party backend solution is used to verify the payment of the specified invoice and has its mechanisms for allowing or disallowing the user to pay, including KYC. There is no such blockchain payer in this approach; the invoice is marked as paid by the address assigned the role of SERVICE_MANAGER in the Service contract._
 */
contract Invoice is
    Initializable,
    ReentrancyGuardUpgradeable,
    IInvoice,
    ERC2771Context
{
    using AddressUpgradeable for address payable;
    using SafeERC20Upgradeable for IERC20Upgradeable;

    // STORAGE

    /// @notice Адрес контракта Registry
    IRegistry public registry;

    /// @notice Последние созданные пулами инвойсы
    /// @dev Маппинг, содержащий последний (максимальный) номер инвойса для каждого пула
    mapping(address => uint256) public lastInvoiceIdForPool;

    /// @notice Invoice data (including their state)
    /// @dev Mapping that stores nested mappings of invoice structures for each pool (pool address is used as the key)
    mapping(address => mapping(uint256 => InvoiceInfo)) public invoices;

    /// @notice Global enumeration of invoices
    /// @dev For each pool and for each invoice issued by the pool, the mapping contains global event IDs under which the invoices were registered in the Registry contract.
    mapping(address => mapping(uint256 => uint256)) public eventIndex;

    // EVENTS

    /**
     * @dev Event emitted on invoice creating
     * @param pool Pool address
     * @param invoiceId InvoiceId for Pool
     */
    event InvoiceCreated(address pool, uint256 invoiceId);

    /**
     * @dev Event emitted when invoice is canceled
     * @param pool Pool address
     * @param invoiceId InvoiceId for Pool
     */
    event InvoiceCanceled(address pool, uint256 invoiceId);

    /**
     * @dev Event emitted when invoice is paid
     * @param pool Pool address
     * @param invoiceId InvoiceId for Pool
     */
    event InvoicePaid(address pool, uint256 invoiceId);

    // MODIFIERS
    /**
     * @notice Modifier that allows creating and canceling invoices for a given pool.
     * @dev The logic of the modifier is described in the isValidInvoiceManager method. The modifier forwards the arguments to this method and uses its boolean output.
     */
    modifier onlyValidInvoiceManager(address pool) {
        require(
            isValidInvoiceManager(pool, _msgSender()),
            ExceptionsLibrary.NOT_INVOICE_MANAGER
        );
        _;
    }

    /**
     * @dev Modifier to allow only the service manager to call a function.
     */
    modifier onlyManager() {
        require(
            registry.service().hasRole(
                registry.service().SERVICE_MANAGER_ROLE(),
                _msgSender()
            ),
            ExceptionsLibrary.INVALID_USER
        );
        _;
    }

    /**
     * @dev Modifier to check if the pool is not paused.
     */
    modifier whenPoolNotPaused(address pool) {
        require(!IPausable(pool).paused(), ExceptionsLibrary.POOL_PAUSED);

        _;
    }

    /**
     *@notice Modifier that allows manipulation with an existing invoice only if it has the "Active" status.
     */
    modifier onlyActive(address pool, uint256 invoiceId) {
        require(
            invoiceState(pool, invoiceId) == InvoiceState.Active,
            ExceptionsLibrary.WRONG_STATE
        );
        _;
    }

    // INITIALIZER AND CONSTRUCTOR

    /**
     * @notice Contract constructor.
     * @dev This contract uses OpenZeppelin upgrades and has no need for a constructor function.
     * The constructor is replaced with an initializer function.
     * This method disables the initializer feature of the OpenZeppelin upgrades plugin, preventing the initializer methods from being misused.
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Contract initializer
     * @dev This method replaces the constructor for upgradeable contracts. It also sets the registry contract address in the contract's storage.
     * @param registry_ Protocol registry address
     */
    function initialize(IRegistry registry_) external initializer {
        registry = registry_;
    }

    // PUBLIC FUNCTIONS

    /**
     * @notice On-chain payment of an invoice (trustless scenario)
     * @dev In addition to the specified modifiers, there is also a check for the payer's wallet to be included in the whitelist of invoice payers.
     * @dev To allow the invoice to be paid by any wallet, the whitelist field should be left empty when creating the invoice.
     * @dev After successful payment, the invoice receives an irreversible "Paid" status.
     * @param pool Address of the pool contract that issued the invoice
     * @param invoiceId Identifier of the invoice being paid
     */
    function payInvoice(
        address pool,
        uint256 invoiceId
    ) external payable nonReentrant whenPoolNotPaused(pool) {
        InvoiceInfo memory invoice = invoices[pool][invoiceId];

        require(
            invoiceState(pool, invoiceId) == InvoiceState.Active,
            ExceptionsLibrary.WRONG_STATE
        );

        //check if payer is whitelisted
        if (invoice.core.whitelist.length > 0) {
            bool isWhitelisted = false;
            for (uint256 i = 0; i < invoice.core.whitelist.length; i++) {
                if (invoice.core.whitelist[i] == _msgSender())
                    isWhitelisted = true;
            }
            require(isWhitelisted, ExceptionsLibrary.NOT_WHITELISTED);
        }

        //if unitOfAccount is ETH
        if (invoice.core.unitOfAccount == address(0)) {
            require(
                msg.value == invoice.core.amount,
                ExceptionsLibrary.WRONG_AMOUNT
            );

            (bool success, ) = payable(pool).call{value: invoice.core.amount}(
                ""
            );
            require(success, ExceptionsLibrary.WRONG_AMOUNT);
        } else {
            IERC20Upgradeable(invoice.core.unitOfAccount).safeTransferFrom(
                _msgSender(),
                pool,
                invoice.core.amount
            );
        }

        _setInvoicePaid(pool, invoiceId);
        registry.log(
            _msgSender(),
            address(this),
            msg.value,
            abi.encodeWithSelector(
                IInvoice.payInvoice.selector,
                pool,
                invoiceId
            )
        );
    }

    /**
     * @notice Create an invoice by a specified pool
     * @dev The onlyValidInvoiceManager modifier determines which accounts can create an invoice for the specified pool.
     * @dev After creation, the invoice receives an "Active" status.
     * @param pool Address of the pool contract that issues the invoice
     * @param core Invoice payment data (described in the interface)
     */
    function createInvoice(
        address pool,
        InvoiceCore memory core
    ) external onlyValidInvoiceManager(pool) {
        //check if pool registry record exists
        require(
            registry.typeOf(pool) == IRecordsRegistry.ContractType.Pool,
            ExceptionsLibrary.NOT_POOL
        );

        //validation
        validateInvoiceCore(core);

        InvoiceInfo memory info;
        info.createdBy = _msgSender();
        info.core = core;

        //set invoiceId
        uint256 invoiceId = lastInvoiceIdForPool[pool];
        info.invoiceId = invoiceId;

        //add invoice
        invoices[pool][invoiceId] = info;
        lastInvoiceIdForPool[pool]++;

        uint256 index = registry.service().addInvoiceEvent(pool, invoiceId);
        eventIndex[pool][invoiceId] = index;

        emit InvoiceCreated(pool, invoiceId);

        registry.log(
            _msgSender(),
            address(this),
            0,
            abi.encodeWithSelector(IInvoice.createInvoice.selector, pool, core)
        );
    }

    /**
     * @notice Cancel an invoice
     * @dev To cancel an invoice, the request must pass the onlyValidInvoiceManager modifier, which regulates who can manipulate the pool's invoices on behalf of the pool.
     * @dev After cancellation, the invoice receives an irreversible "Canceled" status.
     * @param pool Address of the pool contract that issued the invoice
     * @param invoiceId Invoice identifier
     */
    function cancelInvoice(
        address pool,
        uint256 invoiceId
    ) external onlyValidInvoiceManager(pool) {
        _setInvoiceCanceled(pool, invoiceId);

        registry.log(
            _msgSender(),
            address(this),
            0,
            abi.encodeWithSelector(
                IInvoice.cancelInvoice.selector,
                pool,
                invoiceId
            )
        );
    }

    /**
     * @notice Off-chain payment of an invoice (trusted scenario)
     * @dev Addresses that have the "SERVICE_MANAGER" role in the Service contract can change the status of any active invoice of any pool to "Paid", indicating a successful payment of the invoice through an off-chain payment method.
     * @dev After successful payment, the invoice receives an irreversible "Paid" status.
     * @param pool Address of the pool contract that issued the invoice
     * @param invoiceId Invoice identifier
     */

    function setInvoicePaid(
        address pool,
        uint256 invoiceId
    ) external onlyManager {
        _setInvoicePaid(pool, invoiceId);
    }

    /**
     * @notice Canceling an invoice by the manager
     * @dev Addresses that have the "SERVICE_MANAGER" role in the Service contract can cancel any active invoice of any pool.
     * @dev After cancellation, the invoice receives an irreversible "Canceled" status.
     * @param pool Address of the pool contract that issued the invoice
     * @param invoiceId Invoice identifier
     */
    function setInvoiceCanceled(
        address pool,
        uint256 invoiceId
    ) external onlyManager {
        _setInvoiceCanceled(pool, invoiceId);

        registry.log(
            _msgSender(),
            address(this),
            0,
            abi.encodeWithSelector(
                IInvoice.setInvoiceCanceled.selector,
                pool,
                invoiceId
            )
        );
    }

    // PUBLIC VIEW FUNCTIONS

    /**
    * @notice This method checks the validity of invoice data during its creation
    * @dev An invoice is considered valid if it meets the following criteria:
    - Non-zero payment amount (in any token, including the native network coin)
    - The expiration block has not yet been reached
    - The specified token for payment is a valid ERC20 contract
    * @param core Invoice data represented by the structure described in the InvoiceCore interface
    * @return True if the parameters are valid (reverts otherwise)
    */
    function validateInvoiceCore(
        InvoiceCore memory core
    ) public view returns (bool) {
        require(core.amount > 0, ExceptionsLibrary.WRONG_AMOUNT);

        require(
            core.expirationBlock > block.number,
            ExceptionsLibrary.WRONG_BLOCK_NUMBER
        );

        require(
            core.unitOfAccount == address(0) ||
                IERC20Upgradeable(core.unitOfAccount).totalSupply() > 0,
            ExceptionsLibrary.WRONG_TOKEN_ADDRESS
        );
        return true;
    }

    /**
     * @dev This method returns the state of an invoice
     * @param pool The address of the pool contract that issued the invoice
     * @param invoiceId The identifier of the invoice
     */
    function invoiceState(
        address pool,
        uint256 invoiceId
    ) public view returns (InvoiceState) {
        InvoiceInfo memory invoice = invoices[pool][invoiceId];

        if (invoice.isPaid) return InvoiceState.Paid;

        if (invoice.isCanceled) return InvoiceState.Canceled;

        if (invoice.core.expirationBlock < block.number)
            return InvoiceState.Expired;

        return InvoiceState.Active;
    }

    /**

    * @notice This method checks the account's authority to manipulate pool invoices
    * @dev In order to create and cancel pool invoices, the account address must:
    - be listed in the pool's secretaries OR
    - have the "SERVICE_MANAGER" role in the Service contract OR
    - be the owner of the pool if the pool has not yet obtained DAO status
    *@param pool The address of the pool contract
    *@param account The account address
    */
    function isValidInvoiceManager(
        address pool,
        address account
    ) public view returns (bool) {
        if (!IPool(pool).isDAO()) {
            if (account == IPool(pool).owner()) return true;
        } else {
            if (IPool(pool).isValidProposer(account)) return true;
        }

        if (
            registry.service().hasRole(
                registry.service().SERVICE_MANAGER_ROLE(),
                account
            )
        ) return true;

        return false;
    }

    //PRIVATE

    /// @dev Implementation of the function that changes the status of an active invoice to "Paid"
    function _setInvoicePaid(
        address pool,
        uint256 invoiceId
    ) private onlyActive(pool, invoiceId) {
        invoices[pool][invoiceId].isPaid = true;
        emit InvoicePaid(pool, invoiceId);
    }

    /// @dev Implementation of the function that cancels an active invoice and sets its status to "Canceled"
    function _setInvoiceCanceled(
        address pool,
        uint256 invoiceId
    ) private onlyActive(pool, invoiceId) {
        invoices[pool][invoiceId].isCanceled = true;
        emit InvoiceCanceled(pool, invoiceId);
    }

    function getTrustedForwarder() public view override returns (address) {
        return registry.service().getTrustedForwarder();
    }

    
}
