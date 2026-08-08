# Security and privacy boundary

## Threat model

The package is a set of agent instructions and offline setup helpers. The primary assets are customer credentials, customer data, production systems and the integrity of approval decisions.

Trust boundaries:

- repository content -> customer agent runtime
- customer runtime -> customer-selected MCP servers
- MCP server -> customer account, tenant and production data
- draft or test result -> explicitly approved external action

Primary risks are committed credentials, inherited publisher or customer data, active connection configuration, cross-tenant actions, prompt-driven external effects and false claims that a draft or test is already live.

## Controls in this package

- No active MCP connection file is included.
- Credentials and runtime state are excluded by repository policy and `.gitignore`.
- Every agent requires customer-owned authentication and reports missing access as `blocked_missing_access`.
- External and irreversible actions remain approval-gated.
- The installer refuses to overwrite existing agent files unless the operator supplies `--force`.
- `scripts/validate_package.py` checks the agent count, names, connection filenames, local user paths, e-mail addresses, common credential formats, binary files and symlinks.

## Export validation

The initial export was checked across every delivered file with:

- the package validator
- shell syntax validation for the installer
- a dedicated source-identity and source-organization term scan
- URL, e-mail, local-path, tenant/channel identifier and infrastructure-reference scans
- Gitleaks directory scan with redaction enabled
- an isolated installer test, including refusal and explicit overwrite paths

No reportable credential, active-connection or source-identity finding survived validation.

## Customer responsibility

This result applies only to the repository as delivered. It does not certify MCP servers, customer configuration, customer data, runtime permissions or later commits. Before production use, the customer must review every selected MCP, authenticate with its own accounts, verify the exact target tenant and begin with read-only permissions.

Security issues should be reported through the private commercial support channel defined in the applicable customer agreement. Do not include credentials or personal data in reports.
