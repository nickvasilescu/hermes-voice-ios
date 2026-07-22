# Security policy

## Reporting a vulnerability

Use a private GitHub security advisory:

<https://github.com/nickvasilescu/hermes-voice-ios/security/advisories/new>

Do not include secrets in a public issue, discussion, screenshot, or pull
request. Include the affected component, impact, reproduction steps, and a
minimal redacted proof. If a live credential may have been exposed, revoke or
rotate it immediately; deleting it from the latest commit is not sufficient.

## Supported versions

This project is a public alpha. Security fixes target the current `main`
branch; there are no supported release branches yet.

## Scope notes

The repository demonstrates a secure boundary for short-lived OpenAI Realtime
credentials, but it is not a complete production identity or storage system.
Review [`docs/SECURITY.md`](docs/SECURITY.md) and
[`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md) before internet exposure.
