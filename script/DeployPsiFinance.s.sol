// SPDX-License-Identifier: BSL-1.1
pragma solidity 0.8.31;

import { Script } from 'forge-std/Script.sol';
import { console2 } from 'forge-std/console2.sol';
import { ERC1967Proxy } from '@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol';

import { PsiTimeLockController } from '../src/PsiTimeLockController.sol';
import { PsiTwapOracle } from '../src/PsiTwapOracle.sol';
import { PsiStakingVault } from '../src/PsiStakingVault.sol';
import { PsiStakingVaultExtension } from '../src/PsiStakingVaultExtension.sol';
import { PsiLens } from '../src/PsiLens.sol';
import { IPsiStakingVault } from '../src/interfaces/IPsiStakingVault.sol';
import { DataTypes } from '../src/types/DataTypes.sol';

/// @title DeployPsiFinance
/// @notice One-shot deployer for the PSI Finance contract suite on Polygon.
/// @dev    Reads all addresses from env (see .env.example). Requires the
///         broadcaster (DEPLOYER_PRIVATE_KEY's address) to equal PSI_OWNER for
///         this initial deploy, because the post-init `grantRole(VAULT_ROLE,
///         vaultProxy)` on the oracle needs DEFAULT_ADMIN_ROLE — which
///         `PsiTwapOracle.initialize` grants only to `initialOwner`.
///
///         After deploy, the owner may transfer admin to a multisig as a
///         separate, ideally timelocked, operation. See docs/POLYGON_DEPS.md
///         for the broader context (V1 vs V2 Polymarket contracts, USDC.e vs
///         pUSD collateral, audit assumptions).
contract DeployPsiFinance is Script {
    // Default URI baked into PsiStakingVault.sol. If PSI_METADATA_URI differs
    // from this, the script will call setUri() post-deploy.
    string internal constant DEFAULT_METADATA_URI = 'https://api.psi.finance/v1/shares/{id}';

    struct Deployment {
        address timelock;
        address oracleImpl;
        address oracleProxy;
        address extension;
        address vaultImpl;
        address vaultProxy;
        address lens;
    }

    struct Dependencies {
        address ctf;
        address negRiskAdapter;
        address negRiskCtfExchange;
        address ctfExchange;
        address underlyingUsdc;
        address polymarketWcol;
    }

    function run() external {
        // ---- 1. Read + validate env -----------------------------------------
        uint256 deployerKey = vm.envUint('DEPLOYER_PRIVATE_KEY');
        address deployer = vm.addr(deployerKey);

        address owner = vm.envAddress('PSI_OWNER');
        require(owner != address(0), 'PSI_OWNER unset');
        require(
            deployer == owner,
            'For initial deploy DEPLOYER_PRIVATE_KEY address must equal PSI_OWNER'
        );

        address twapSigner = vm.envAddress('PSI_TWAP_SIGNER');
        require(twapSigner != address(0), 'PSI_TWAP_SIGNER unset');

        uint256 timelockMinDelay = vm.envUint('PSI_TIMELOCK_MIN_DELAY');
        uint256 protocolFeeBps = vm.envUint('PSI_PROTOCOL_FEE_BPS');

        Dependencies memory deps = Dependencies({
            ctf: vm.envAddress('POLYMARKET_CTF'),
            negRiskAdapter: vm.envAddress('POLYMARKET_NEG_RISK_ADAPTER'),
            negRiskCtfExchange: vm.envAddress('POLYMARKET_NEG_RISK_CTF_EXCHANGE'),
            ctfExchange: vm.envAddress('POLYMARKET_CTF_EXCHANGE'),
            underlyingUsdc: vm.envAddress('POLYMARKET_COLLATERAL'),
            polymarketWcol: vm.envAddress('POLYMARKET_WCOL')
        });
        _requireNonZero(deps);

        string memory metadataUri = vm.envOr('PSI_METADATA_URI', DEFAULT_METADATA_URI);

        // ---- 2. Deploy -------------------------------------------------------
        vm.startBroadcast(deployerKey);

        Deployment memory d;

        // Step 1: timelock
        address[] memory proposers = new address[](1);
        proposers[0] = owner;
        address[] memory executors = new address[](1);
        executors[0] = owner;
        d.timelock = address(new PsiTimeLockController(timelockMinDelay, proposers, executors));

        // Step 2 + 3: TWAP oracle implementation + proxy
        d.oracleImpl = address(new PsiTwapOracle());
        bytes memory oracleInit = abi.encodeCall(
            PsiTwapOracle.initialize,
            (owner, d.timelock, 'PsiTwapOracle', '1', twapSigner)
        );
        d.oracleProxy = address(new ERC1967Proxy(d.oracleImpl, oracleInit));

        // Step 4: vault extension
        d.extension = address(new PsiStakingVaultExtension());

        // Step 5 + 6: vault implementation + proxy
        d.vaultImpl = address(new PsiStakingVault());

        DataTypes.InitParams memory params = DataTypes.InitParams({
            owner: owner,
            timelockController: d.timelock,
            protocolFeeBps: protocolFeeBps,
            ctf: deps.ctf,
            negRiskAdapter: deps.negRiskAdapter,
            negRiskCtfExchange: deps.negRiskCtfExchange,
            ctfExchange: deps.ctfExchange,
            underlyingUsdc: deps.underlyingUsdc,
            polymarketWcol: deps.polymarketWcol,
            twapOracle: d.oracleProxy,
            extension: d.extension
        });
        bytes memory vaultInit = abi.encodeCall(PsiStakingVault.initialize, (params));
        d.vaultProxy = address(new ERC1967Proxy(d.vaultImpl, vaultInit));

        // Step 7: lens
        d.lens = address(new PsiLens(d.vaultProxy));

        // Step 8: grant VAULT_ROLE on oracle to vault proxy
        bytes32 vaultRole = PsiTwapOracle(d.oracleProxy).VAULT_ROLE();
        PsiTwapOracle(d.oracleProxy).grantRole(vaultRole, d.vaultProxy);

        // Step 9 (conditional): override metadata URI if env differs from baked default
        if (keccak256(bytes(metadataUri)) != keccak256(bytes(DEFAULT_METADATA_URI))) {
            IPsiStakingVault(d.vaultProxy).setUri(metadataUri);
        }

        vm.stopBroadcast();

        // ---- 3. Log + persist deployment manifest ---------------------------
        _logDeployment(d, deps);
        _writeDeploymentJson(d, deps, metadataUri);
    }

    // ============ Validation =================================================

    function _requireNonZero(Dependencies memory deps) internal pure {
        require(deps.ctf != address(0), 'POLYMARKET_CTF unset');
        require(deps.negRiskAdapter != address(0), 'POLYMARKET_NEG_RISK_ADAPTER unset');
        require(deps.negRiskCtfExchange != address(0), 'POLYMARKET_NEG_RISK_CTF_EXCHANGE unset');
        require(deps.ctfExchange != address(0), 'POLYMARKET_CTF_EXCHANGE unset');
        require(deps.underlyingUsdc != address(0), 'POLYMARKET_COLLATERAL unset');
        require(deps.polymarketWcol != address(0), 'POLYMARKET_WCOL unset');
    }

    // ============ Output =====================================================

    function _logDeployment(Deployment memory d, Dependencies memory deps) internal pure {
        console2.log('=== PSI Finance Deployment ===');
        console2.log('PsiTimeLockController            ', d.timelock);
        console2.log('PsiTwapOracleImplementation      ', d.oracleImpl);
        console2.log('PsiTwapOracleProxy               ', d.oracleProxy);
        console2.log('PsiStakingVaultExtension         ', d.extension);
        console2.log('PsiStakingVaultImplementation    ', d.vaultImpl);
        console2.log('PsiStakingVaultProxy             ', d.vaultProxy);
        console2.log('PsiLens                          ', d.lens);
        console2.log('--- Dependencies ---');
        console2.log('ctf                              ', deps.ctf);
        console2.log('negRiskAdapter                   ', deps.negRiskAdapter);
        console2.log('negRiskCtfExchange               ', deps.negRiskCtfExchange);
        console2.log('ctfExchange                      ', deps.ctfExchange);
        console2.log('underlyingUsdc (collateral)      ', deps.underlyingUsdc);
        console2.log('polymarketWcol                   ', deps.polymarketWcol);
    }

    function _writeDeploymentJson(
        Deployment memory d,
        Dependencies memory deps,
        string memory metadataUri
    ) internal {
        string memory contractsKey = 'psi.contracts';
        vm.serializeAddress(contractsKey, 'PsiTimeLockController', d.timelock);
        vm.serializeAddress(contractsKey, 'PsiTwapOracleImplementation', d.oracleImpl);
        vm.serializeAddress(contractsKey, 'PsiTwapOracleProxy', d.oracleProxy);
        vm.serializeAddress(contractsKey, 'PsiStakingVaultExtension', d.extension);
        vm.serializeAddress(contractsKey, 'PsiStakingVaultImplementation', d.vaultImpl);
        vm.serializeAddress(contractsKey, 'PsiStakingVaultProxy', d.vaultProxy);
        string memory contractsJson = vm.serializeAddress(contractsKey, 'PsiLens', d.lens);

        string memory depsKey = 'psi.dependencies';
        vm.serializeAddress(depsKey, 'ctf', deps.ctf);
        vm.serializeAddress(depsKey, 'negRiskAdapter', deps.negRiskAdapter);
        vm.serializeAddress(depsKey, 'negRiskCtfExchange', deps.negRiskCtfExchange);
        vm.serializeAddress(depsKey, 'ctfExchange', deps.ctfExchange);
        vm.serializeAddress(depsKey, 'collateral', deps.underlyingUsdc);
        string memory depsJson = vm.serializeAddress(depsKey, 'wcol', deps.polymarketWcol);

        string memory rootKey = 'psi.root';
        vm.serializeUint(rootKey, 'chainId', block.chainid);
        vm.serializeString(rootKey, 'network', _networkName(block.chainid));
        vm.serializeUint(rootKey, 'deployedAt', block.timestamp);
        vm.serializeString(rootKey, 'metadataUri', metadataUri);
        vm.serializeString(rootKey, 'contracts', contractsJson);
        string memory rootJson = vm.serializeString(rootKey, 'dependencies', depsJson);

        string memory path = string.concat('./deployments/', _networkName(block.chainid), '/psi-finance.json');
        vm.writeJson(rootJson, path);
        console2.log('Wrote deployment manifest:', path);
    }

    function _networkName(uint256 chainId) internal pure returns (string memory) {
        if (chainId == 137) return 'polygon';
        if (chainId == 80001) return 'mumbai';
        if (chainId == 80002) return 'amoy';
        if (chainId == 31337) return 'localhost';
        return 'unknown';
    }
}
