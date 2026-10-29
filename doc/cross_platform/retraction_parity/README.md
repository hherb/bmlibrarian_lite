# Retraction status parity

`retraction_status.json` is bmlib's shared contract for a paper's retraction
status (bmlib#504): 47 rule cases, 24 Crossref parse cases, 5 request cases.

It is copied verbatim from bmlib `tests/fixtures/retraction_status.json` at
commit `f76721545a76eceb683d9c460fb1f47e5c925cdb` (unchanged at `83cd2b3`, the
apps' FFI pin). It is never edited here; a bmlib change arrives by a ledger
sync (`doc/cross_platform/bmlib_sync/`).

Five readers assert against it:

1. bmlib Python (`tests/test_retraction_status.py`)
2. bmlib Rust (`rust/bmlib/tests/retraction_status.rs`)
3. lite desktop (`tests/test_retraction_contract.py`, through bmlib's API)
4. lite Swift (`Packages/BioMedLit/Tests/BioMedLitTests/RetractionContractTests.swift`,
   through bmlib's Rust over UniFFI)
5. lite Kotlin (`android/…/util/retraction/BmlibRetractionContractTest.kt`, the
   same; it skips without a bmlib checkout, and `android-tests.yml` fails a
   skipped run)
