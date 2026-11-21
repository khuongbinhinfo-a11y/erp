# ERP Identity / Session POC — Issue #6

- Passwords are salted Node scrypt hashes; client credentials are never stored or logged in plaintext.
- Session tokens are cryptographically random, delivered to the caller only, and stored in PostgreSQL exclusively as SHA-256 hashes.
- Sessions are scoped to one installation, expire after eight hours, and are invalid immediately after logout or user disable.
- Authentication audit is append-only and contains request ID, installation, optional actor ID, event code and timestamp, with no login name, password, IP or raw session token.
- Failed logins use the same externally visible AuthDenied result as nonexistent users. The service invokes a KDF even when no account exists to reduce account enumeration differences.
- This is internal server-only code with regression tests. HTTP endpoints, credential throttling, trusted installation routing, session cookie protections, admin bootstrap, user management and privileges remain unimplemented: DO NOT claim #6 ready or enable external sign-in until those gates are met.
- No real Prisma demo database migration has been performed. SQL version 0004 runs only on ephemeral CI PostgreSQL for now.
