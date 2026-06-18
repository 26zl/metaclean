# Security Policy

metaclean is a privacy tool: its worst-case failure is reporting a file as
"clean" when removable metadata actually survived, or mishandling a file it
overwrites. Reports of either — or of any vulnerability in metaclean itself —
are welcome.

## Reporting a vulnerability

**Please do not open a public issue for security reports.**

Use GitHub's [private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
for this repository (the **Security** tab → **Report a vulnerability**). If that
is unavailable, contact the maintainer privately via their GitHub profile
([@26zl](https://github.com/26zl)).

Please include:

- the file type and a minimal way to reproduce (use `--dry-run` if you can't
  share the file);
- the metaclean version and the detected exiftool/mat2/qpdf versions
  (`metaclean --version`);
- your OS and Ruby version.

We aim to acknowledge reports within a few days.

## Scope

metaclean shells out to **ExifTool**, **mat2**, and **qpdf**, which parse hostile
binary formats and have had CVEs of their own. Vulnerabilities in those tools
should be reported to their respective projects — keep them updated. metaclean's
own scope is the wrapper logic: path handling and argument-injection guards, the
strip/verify pipeline, the "never write a file we can't verify is clean"
guarantee, and the atomic in-place write/backup.

## Supported versions

metaclean follows [Semantic Versioning](https://semver.org). Only the latest
released version receives fixes.
