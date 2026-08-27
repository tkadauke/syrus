# MySQL DB Browser

MySQL DB Browser lets admins register external MySQL connections, inspect schemas, browse table contents, and run controlled queries from the Syrus admin UI. Credentials are stored encrypted and connections are explicit per database target.

This plugin is separate from Admin MySQL: Admin MySQL inspects Syrus' own runtime database, while MySQL DB Browser is for operator-managed external databases that Syrus may need to inspect.

## What It Adds

- Admin UI and API endpoints for MySQL connection management.
- Schema browsing for databases, tables, and columns.
- Controlled query execution against configured external connections.

## When To Enable

Enable this plugin when Syrus operators need a lightweight database browser for external MySQL systems. Keep it disabled when all database access should remain outside Syrus.

## Operational Notes

Treat configured credentials as sensitive production access. Use narrowly scoped MySQL users for each connection whenever possible.
