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
- the metaclean version and the detected exiftool/mat2/qpdf/ffmpeg versions
  (`metaclean --version`);
- your OS and Ruby version.

We aim to acknowledge reports within a few days.

## Scope

metaclean shells out to **ExifTool**, **mat2**, **qpdf**, and **ffmpeg**, which
parse hostile binary formats and have had CVEs of their own. Vulnerabilities in
those tools should be reported to their respective projects — keep them updated. metaclean's
own scope is the wrapper logic: path handling and argument-injection guards,
private temporary workspaces, the strip/verify pipeline, and the guarantee that
failed, unsupported or unverified candidates are never committed as clean.

Tool output is created in a mode-0700 directory (on the destination filesystem
for real commits, in system temp for dry-run) and validated with `lstat` before commit. Reports that bypass this boundary,
cause a symlink to be committed, or overwrite an unrelated file are in scope.
User-controlled symlinks in parent path components are rejected and path
component identities are pinned from discovery through commit.

Embedded payloads are treated as a separate verification boundary. PDFs and
Matroska files containing attachments or cover-art streams are rejected because
their nested metadata cannot yet be independently verified. A file reported
clean while such metadata survives is a security issue.

A non-standard ICC profile (one whose description is not a recognized standard
color space) blocks commit unless the user explicitly accepts its identifying
fields with `--allow-icc-metadata`; standard color spaces clean without it.

## Supported versions

metaclean follows [Semantic Versioning](https://semver.org). Only the latest
released version receives fixes.

The external parsers are supplied by the operating system rather than the gem.
CI records their versions and capability-checks the features metaclean uses, but
users must keep ExifTool, mat2, qpdf and ffmpeg patched through their package
manager.
