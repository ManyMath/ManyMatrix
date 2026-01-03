# Tuwunel 1.4.9

December 30, 2025

All federating deployments must upgrade for follow-up mitigations similar to those patched by 1.4.8 now uncovered as a wider class of vulnerabilities in additional locations. This is an off-schedule coordinated security release. Full release notes will be included with the next scheduled release.

### Security Fixes

- Federation responses processed from a remote server assisting in membership state transitions lacked input validation: trusting, signing, and disseminating an event crafted by the remote server. These vulnerabilities were uncovered in a classic follow-up to the initial forgery attack pattern described in patch 1.4.8 also present in additional locations.
