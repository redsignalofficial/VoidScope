# VoidScope

VoidScope is a specialized Luau sandbox, analysis engine, and turnkey deobfuscator designed for inspecting and devirtualizing protected Luau scripts and Roblox payloads.

## Features

- **VM Introspection & Bytecode Disassembly**: Intercepts virtual machine dispatchers, lifts bytecode, and maps virtual opcodes into instruction traces.
- **One-Shot Prototype Splitting**: Automatically extracts and isolates all nested prototypes into modular files.
- **Roblox Service Sandbox**: Safely mocks `HttpService`, `DataStoreService`, `RunService`, `Players`, and core engine services.
- **Dynamic C2 Stub & IOC Extraction**: Intercepts outbound beaconing and analyzes network payloads in an isolated local harness.

## Quick Start

### 1. One-Shot Deobfuscation
```bash
./deobf.sh <path_to_sample>
```
Splits all nested prototypes, decodes constant pools, disassembles bytecode, and generates clean modular files.

### 2. Run Test Suite
```bash
lune run tests/run.luau
```

## Architecture

- `src/sandbox.luau` — Core Luau execution sandbox and environment protection.
- `src/mocks/` — Roblox engine service proxies and mocks.
- `src/c2/` — Local C2 beacon interceptor and stub responder.
- `src/iocs/` — Network and filesystem IOC extractors.
- `deobf.luau` — Standalone one-shot devirtualizer and prototype splitter.
