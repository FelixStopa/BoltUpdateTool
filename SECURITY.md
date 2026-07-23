# Security policy

## Supported version

Security fixes currently target the latest revision on the `main` branch. There is not yet a
stable release support matrix.

## Reporting a vulnerability

Please do not publish an immediately exploitable vulnerability, a malicious firmware sample,
private device information, or proprietary firmware in a public issue.

Contact the maintainer through [felix.stopa.net](https://felix.stopa.net) with:

- the affected commit or app version
- the macOS and hardware version
- a concise description of the impact
- reproducible steps that do not include copyrighted firmware
- relevant logs with personal information removed

Allow a reasonable amount of time for investigation before public disclosure.

## Firmware safety

BoltUpdateTool does not provide or download firmware. Users are responsible for selecting a
lawfully obtained, compatible, signed package. File-format validation cannot guarantee hardware
compatibility or prevent every possible device failure.
