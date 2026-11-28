# T5-D — Legacy-first execution contract (work in progress)
Baseline ERP `e1bbeb5044d36040f5aabc1a68a586b800e72c7a`; legacy NPP-Platform read-only `f0a2cd20893f4a3dc912bfbe0d020ff6b251bd0e`.
No production changes authorized by owner 28/11/2026. No copying data, secrets or UI assets.

| Source path/lines | Target / decision | Evidence / gap |
|---|---|---|
| npp-core/api/src/services/logistics-driver-delivery.js:475–540 | COPY-ADAPT exact issued-line set, full/partial semantics to delivery_attempt_contract.ts | Pure tests; ERP dispatch key (dispatchId, sourceLine) instead of legacy issue UUID; NUMERIC(24,6) shared inventory helpers instead of legacy (30,12); reject excess precision rather than round |
| Same source:307–365; test/logistics-driver-delivery.test.js:160–199 | COPY-ADAPT result shape, reason, schedule, exact decimals | Server canonical UTC, no client authoritative clock; unit contract requires explicit trusted fractional flag |
| docs/operations/phase-6e4-delivery-attempt-decisions.md:60–84,98–104 | KEEP immutable attempt concept, remaining goods stay in custody | MISSING persistence, DB guard, lifecycle/ownership and receipt integration; pure contract does not authorize or post |
| ERP backend/src/trip_fulfillment.ts:189–271, migration 0025 | KEEP physical OUT as canonical source; no additional OUT when delivering | MISSING trip/stop execution lineage, transaction locking and prohibition of late additional dispatch after terminal attempt |
| ERP backend/src/delivery_trip.ts:248–281; migration 0027 | KEEP locked commercial plan, distinguish actual dispatch/start | MISSING actual departure and reschedule/reassignment lineage |
| ERP backend/src/sales_execution_core.ts:215–310; migration 0026 | CONSOLIDATE existing sales_fulfillment, payment_receipt, payment_allocation, customer_receivable_ledger | Existing mode and triggers MANUAL/PICKUP only; need reviewed additive migration/adaptation, actual received quantity and COD custody/handover; no duplicate ledger |
| legacy logistics-driver-delivery.js:215–245; ERP delivery_employee.ts | MISSING driver actor ownership and least privilege on execution routes | Must resolve canonical active employee identity from server and verify trip assignment, never accept driver identity from browser |
| legacy delivery/web/app/trips/[tripId]/delivery-attempt-panel.tsx:113–161 | ADAPT mobile actions | MISSING Flutter integration, server ACK, retry/read-before-retry, POD, COD |
| legacy phase-6f0-receivable-payment-cod-decisions.md | MISSING COD/AR implementation and reconciliation | Read source implementation/tests before implementing payment and return |

P1 structural gaps (code inspection, not runtime reproduction): planning lock is not departure; actual warehouse dispatch currently reports NOT_DISPATCHED for customer delivery; MANUAL completion guards cannot simply be bypassed for TRIP. These are remaining acceptance blockers. This initial contract must not be exposed as a standalone success endpoint. No DB migration in this commit; later execution persistence likely requires versioned migration after review. Tests in existing CI scripts; no production/UAT claim.
