# Security Policy

## Reporting a Vulnerability

Please do NOT open a public GitHub issue for security vulnerabilities.

Use GitHub's private vulnerability reporting instead:
https://github.com/duplantier/hushboard/security/advisories/new

You will receive a response within 72 hours.

## Scope

Hushboard requests two system permissions:

- **Accessibility** (keyboard monitoring via CGEvent tap): used solely to detect keystrokes and trigger mute. Keystrokes are never logged, stored, or transmitted.
- **Microphone** (CoreAudio mute/unmute): used solely to set the hardware mute flag on the default input device.

Reports related to either of these permission scopes are treated as high priority.

## Out of Scope

- Issues requiring physical access to the machine
- Bugs without a credible security impact
