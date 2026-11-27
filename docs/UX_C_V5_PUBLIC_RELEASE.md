# UX-C v5 public OTA 27/11/2026

Staged signed binary: releases/5/erp-5.apk; 64605474 bytes; SHA256 d050f77e19fa1ce4ba4ac4011442ed7955f7342252f2805ad9db61ddfe0616cf; original signer; source d97e58e9ea437420285cb9a563bf7bb4005f14f4. Signed CI 45931727261; R2 stage 45932205481. Download Worker pins hash, size and source, retains v1-v4 and Range support. Gate: reviewed PR CI/Codex, aux merge/primary tree parity, Worker deployment and public full-download SHA, then immutable history manifest + latest pointer v5 readback. Device authenticated UAT still unverified; no false PASS.

## V5 public download smoke workflow

After Worker deploy, pushing the workflow on aux main verifies complete v5 public bytes/hash, resume, v4 compatibility while latest remains v4. After v5 activation, owner-authenticated issue #46 comment `/erp-android-v5-public-smoke` triggers the same smoke with expected latest=5; only exact owner + issue are permitted; no secrets and no writes. Report real Android device UAT separately.
