<!-- PR optional; owner chose direct-main CI on 18/11/2026 -->
## Scope
Issues: #
Baseline main SHA:
Head SHA:

## Invariants and security
- [ ] No token, PII, database URL, customer assets
- [ ] No cross-installation access, ledger mutation without server ACK
- [ ] No production migration, deploy or provider change without owner authorization

## Evidence
- [ ] Backend typecheck/test
- [ ] Flutter analyze/widget test
- [ ] Migration + concurrency/RBAC tests (or marked NOT RUN with reason)
- [ ] UI responsive/keyboard/accessibility evidence if UI changed

## Release gate
CI: NOT VERIFIED
Smoke: NOT RUN
UAT: NOT RUN
Merge approval: OWNER DECISION FOR THIS PR
Production deployment: NOT AUTHORIZED
