# Contract Versioning Strategy

> ⚠️ This document was initially generated with the assistance of a Large Language Model (LLM) and has been reviewed by the engineering team.

---

## Overview

This document defines the versioning strategy used across:
- Flow Yield Vaults (FYV)
- Flow ALP
- DeFiActions

The goals are to:

- Safely manage **non-upgradable smart contract changes**
- Maintain **mainnet stability**
- Enable **parallel development**
- Ensure **cross-repository consistency**

---

## Core Model

### Version Boundaries

A **new version** is required when a change:

- Breaks backward compatibility
- Modifies resource/storage layout (e.g., adding fields)
- Requires redeployment to a new name or address

These changes are **non-upgradable** and define version boundaries.

### Within a Version

All changes must be:

- Backward-compatible  
- Deployable to the same contract address **with the same name**  
- Safe for existing integrations  

---

## Branching Model

Each version is represented by a Git branch.

| Branch | Purpose                           |
|--------|----------------------------------|
| `main` | Active development (not deployed) |
| `v0`   | Current deployed mainnet version  |

- `main` is free to introduce breaking changes  
- `v0` is stable and represents the exact deployed contract set  

All repositories (FYV, Flow ALP, DeFiActions) must maintain aligned version branches.

---

## Deployment Model

### Development

The `main` branch is **never deployed to a persistent network**.

It is validated using:

- Forked environments  
- Local emulator  
- Temporary/test deployments  

This enables rapid iteration without mainnet constraints.

### Mainnet

Persistent deployments must come from a **version branch** (e.g., `v0`).

The FYV repository acts as the **deployment source of truth**:

- Pins dependency commits (submodules or equivalent)  
- Defines the full contract set  
- Ensures reproducibility  

---

## Workflow

### Feature Development

- Develop on `main`  
- Breaking changes are allowed  

### Creating a New Version

When a non-upgradable change is introduced:

1. Continue development on `main`  
2. Introduce new contracts (new names/addresses if required)  
3. Create/update a version branch (e.g., `v1`)  
4. Align all repositories to compatible commits  

### Maintaining Current Version (`v0`)

- Maintenance mode only  
- Allowed changes:  
  - Bug fixes  
  - Backward-compatible improvements  

### Backporting

- Apply fixes to `main`  
- Backport to `v0` only if compatible  

### Deployment Steps

1. Checkout version branch (e.g., `v0`)  
2. Use pinned dependencies  
3. Deploy to network  

---

## Contract Naming Conventions

Clear and consistent contract naming is required to reinforce version boundaries and avoid ambiguity.

### Within a Version

- Contract names must remain **stable**  
- Contracts must be deployable to the **same address with the same name**  
- Renaming or adding suffixes (e.g., `V2`, `New`) is **not allowed**  

### Across Versions

When introducing a new version due to non-upgradeable changes:

- Contracts must be **redeployed under new names or addresses**  
- Naming must clearly indicate version differences  

#### Recommended Patterns

- **Suffix-based versioning:**  
  - `FlowVault` → `FlowVaultV1`  
  - `AutoBalancer` → `AutoBalancerV1`  

### Guidelines

- Use explicit version identifiers (`V1`, `V2`, ...)  
- Avoid ambiguous names such as:  
  - `New`  
  - `Updated`  
- Keep naming consistent across FYV, Flow ALP, and DeFiActions  

### Important

Once a version is deployed and superseded:

- Contracts should be treated as **immutable**  
- No further modifications should be made  

---

## Designing for Extendability

### Extension State Pattern (Use with Caution)

An optional pattern is to include a contract-level `AnyStruct` field that can act as an extensible container for **temporary, upgrade-compatible patches** to already deployed versions.

> ⚠️ This pattern introduces **globally mutable, non-type-safe state**. It should be used sparingly and only when strictly necessary.

### Intended Use

- Primarily for **version branches** (e.g., `v0`) to ship missing behavior without breaking upgradeability  
- As an **escape hatch** when a deployed contract cannot be changed safely otherwise  

### Usage Rules

- The container **may exist on `main`**, but should be:
  - **Empty**
  - **Not referenced in logic**
- Do **not** rely on this pattern for normal feature development on `main`  
- Prefer introducing properly typed state in the **next version** (e.g., `v1`)  

### Implementation Guidance

If used:

- Store a structured value inside the `AnyStruct`  
- Use mapping-style substructures for scoped additions  
- Isolate it from core storage and public interfaces  
- Clearly document any data written to it  

### Risks

- Reduced type safety  
- Harder reasoning about state and invariants  
- Increased likelihood of bugs  

### Recommendation

- Treat this as a **temporary compatibility mechanism**, not a design default  
- When creating a new version, replace usages with **properly typed fields and resources**  

---

## Summary

- Versions are defined by **non-upgradable changes**  
- Branches represent versions (`v0`, `v1`, ...)  
- `main` is development-only and not deployed  
- Version branches are the only deployment source  
- All repositories must stay aligned per version  

This model enables safe contract evolution while maintaining mainnet stability.
