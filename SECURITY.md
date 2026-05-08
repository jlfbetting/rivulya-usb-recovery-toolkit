# Security Policy

Rivulya USB Recovery Toolkit is experimental software for controlled offline recovery workflows.

Report security issues privately by opening a GitHub security advisory if available, or by contacting the maintainer through the repository owner profile. Do not publish exploit details before there is time to investigate.

## Trust Model

The toolkit does not make arbitrary USB devices safe. It trusts one enrolled USB stick identity and signed job manifests. Enrolled servers execute accepted jobs as root, so protect the operator signing key and the dedicated USB stick.

## Supported Versions

Only the current `main` branch is maintained during the experimental phase.
