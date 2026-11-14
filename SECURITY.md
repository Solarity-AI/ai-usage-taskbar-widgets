# Security policy

The widgets read your Claude Code and Codex sign-in on your own PC and send it only to the vendor's own usage endpoint. If you find a way they could leak a token, read files they shouldn't, or run something unexpected, please report it privately.

## Reporting a vulnerability

- Use **[Report a vulnerability](https://github.com/Solarity-AI/ai-usage-taskbar-widgets/security/advisories/new)** (GitHub private vulnerability reporting). Please don't open a public issue for security problems.
- Include the widget (Claude or Codex), its version (right-click the pill → *About*), your Windows version and the steps to reproduce.
- Never include a real token, `.credentials.json` or `auth.json` contents. Describe what was exposed and where instead.

We aim to reply within 7 days and to publish a fixed release as soon as one is ready.

## Supported versions

Only the [latest release](https://github.com/Solarity-AI/ai-usage-taskbar-widgets/releases/latest) gets security fixes.
