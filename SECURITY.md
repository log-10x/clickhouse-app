# Security Policy

## Supported versions

The latest released version of `tenx-for-clickhouse` is supported with security fixes. Older versions may receive fixes for high-severity issues at the maintainers' discretion.

## Reporting a vulnerability

Please report vulnerabilities privately to **security@log10x.com**.

Do not file public GitHub issues for suspected vulnerabilities.

Expect an initial acknowledgement within 3 business days. We will work with you on a remediation timeline and coordinate disclosure.

## Scope

In scope:

- SQL injection or unintended privilege escalation through `tenx_inflate*` functions
- Data exposure through the expansion view (`tenx.events`, `tenx.events_iso`)
- Authentication or authorization bypasses related to the templates dictionary
- Issues with the `install.sql` schema that could create insecure defaults

Out of scope:

- Vulnerabilities in ClickHouse itself (report to [ClickHouse Security](https://github.com/ClickHouse/ClickHouse/security))
- Vulnerabilities in the Log10x Receiver (report to security@log10x.com)
- Misconfigurations of the customer's ClickHouse deployment
- Performance regressions that do not have a security impact

## Defensive guidance for operators

The templates table is critical infrastructure: compact events cannot be expanded without it. Treat its availability and integrity at least as carefully as you treat authentication data. See the [User Guide](USER-GUIDE.md#operating-the-templates-dictionary) for backup and replication guidance.
