# Vendored dependencies

All dependency sources are ordinary files in `lib/`; no submodules, package manager, remote imports or network access are required during verification. Upstream source comments are retained as provenance, not project instructions. Only the Solidity import closure needed by this project and the corresponding license files are retained.

| Directory | Upstream revision | Archive SHA-256 | Use |
| --- | --- | --- | --- |
| `lib/openzeppelin` | [OpenZeppelin Contracts v5.1.0](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/v5.1.0) | `8a3b08cfc756437ba3343901565b18182adb42ec1e621960240a19da5d738686` | ERC-20, ownership, safe token calls, arithmetic, reentrancy protection |
| `lib/forge-std` | [forge-std v1.9.4](https://github.com/foundry-rs/forge-std/tree/v1.9.4) | `9bf191808ba79584a69ee4f288bfb9f217d1187c43d46f59780d86cab9196a15` | Tests only |
| `lib/v4-core` | [Uniswap v4 core `46c6834698c48bc4a463a86d8420f4eb1d7f3b75`](https://github.com/Uniswap/v4-core/tree/46c6834698c48bc4a463a86d8420f4eb1d7f3b75) | `669c7c7903378bfd327072982008c447517c55b03d6ff1cb7bd9a7f04b6e47eb` | Actual PoolManager integration tests only |
| `lib/solmate` | [Solmate `4b47a19038b798b4a33d9749d25e570443520647`](https://github.com/transmissions11/solmate/tree/4b47a19038b798b4a33d9749d25e570443520647) | `9aa78449f8bc10931520500ec24734f089af9ac875a3334d8b512f8727241667` | v4 PoolManager's ownership dependency, tests only |

Hashes identify the downloaded GitHub codeload `.tar.gz` archives, before selecting source files. No vendored Solidity source has been modified. OpenZeppelin and Solmate use MIT licensing; forge-std includes MIT/Apache notices. v4 sources retain their individual SPDX identifiers and upstream license. See the license files within each package for their terms. v4 and Solmate are not linked into the delivered token or vault.
