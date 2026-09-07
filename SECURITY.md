# Security Policy

## Reporting a vulnerability

Please **do not** open a public issue for security problems. Use GitHub's
[private vulnerability reporting](../../security/advisories/new) on this
repository instead. Reports are looked at on a best-effort basis - this is a
community tool maintained in spare time.

## Scope & threat model

EXO Mailbox Forward Manager is an **operator tool**: it runs with the
permissions of the signed-in administrator, and performs only the actions
the operator confirms. Relevant notes:

- **No credential handling.** Authentication is delegated entirely to
  `ExchangeOnlineManagement` (MSAL under the hood) in interactive
  delegated mode. The tool never sees, stores, or logs passwords, tokens,
  or client secrets.
- **No telemetry.** The only network traffic is to Exchange Online
  endpoints, initiated explicitly by the operator via Refresh or Apply.
- **Local artifacts may be sensitive.** `cache.json` and
  `changelog-yyyyMMdd-HHmmss.csv` contain directory data: user principal
  names and forwarding addresses. They are written next to the script,
  are `.gitignore`d, and should be treated like any other directory
  export - do not commit them, do not share them unredacted.
- **Config contains no secrets.** `config.json` holds the target
  forwarding domain, the service-account UPN, and UI defaults. It is not
  sensitive on its own, but is `.gitignore`d by default to avoid
  accidental commits of tenant-specific values.
- **No undo on Apply.** Once a forwarding change is applied, the previous
  value is preserved only in the changelog CSV. Keep the changelogs.
- **Module supply chain.** The tool requires `ExchangeOnlineManagement`
  from the PowerShell Gallery. If your organization requires
  pinned/internal module sources, install the module yourself beforehand -
  the tool uses whatever is already available.

## Supported versions

The latest release is the only supported version. Older releases do not
receive security fixes.
