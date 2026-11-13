# CSQLite (vendored SQLite amalgamation)

- Version: SQLite 3.50.4
- Source: https://www.sqlite.org/2025/sqlite-amalgamation-3500400.zip
- SHA-256 of the zip: `1d3049dd0f830a025a53105fc79fd2ab9431aea99e137809d064d8ee8356b032`
- Files used unmodified: `sqlite3.c`, `include/sqlite3.h`

SQLite is in the public domain. The authors disclaim copyright to the source code
(see https://www.sqlite.org/copyright.html). This is not a copyrighted asset.

Built only in the Windows / `PTB_SHARED_ONLY=1` branch of `Package.swift`; the Mac app links the system `sqlite3`.
