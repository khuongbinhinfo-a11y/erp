# ERP — Server-side RBAC scope contract

POC for Issue #6. Deny-by-default, no client-trusted grants.

| Scope | Permission codes |
| --- | --- |
| Installation | identity.users.read, identity.users.manage, identity.roles.manage |
| Branch | catalog.read, catalog.write, orders.read, orders.create, finance.receivables.read, finance.payments.record, delivery.read, delivery.update |
| Branch + explicit warehouse | inventory.read, inventory.post |

- Installation grants require an installation-only user_role (branch_id NULL).
- Branch grants require a matching branch_id, never a global wildcard.
- Warehouse grants require a branch role AND a matching user_role_warehouse record.
- Composite foreign keys prohibit cross-installation or cross-branch warehouse assignments.
- Disabled users, missing roles, revoked permissions, unknown permission codes and invalid scopes are rejected.
- Delegation requires BOTH identity.roles.manage on the installation and the exact permission/scope granted to the delegating actor.
- Authorization must be evaluated server-side inside the same PostgreSQL transaction as mutation. Public business mutation API remains disabled until identity/session and administrative permission management are implemented and tested.
- Current user_role primary key limits a given (user,role) to one branch; use distinct roles per branch or add a reviewed migration before full multibranch role management. This is a POC subset, not completed Issue #6.
