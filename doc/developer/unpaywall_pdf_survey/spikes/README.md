# Getting past the walls: three spikes (2026-10-04)

The survey in `../README.md` found that 81% of the Unpaywall PDFs our clients
cannot download sit behind bot walls. These spikes asked what would recover
them. Each worked from the survey's committed rows: the desktop's 290
failures, or a 41-address sample of them. The code was throwaway and is not
kept; the result rows are, beside this file.

**Decision taken (maintainer, 2026-10-04):**
1. Add unattended machine channels first.
2. Then fetch through a real embedded browser engine: hidden, then a briefly
   shown window, then a "needs your browser" review queue for what is left
   (mostly ScienceDirect, which needs one person's tick).
3. Do not use obscura or any other stealth client.

## 1. Unattended channels (`2026-10-04-channels.jsonl`)

For each of the 290 failures, every channel below was asked once. Requests
were paced per host as in the survey; CORE was additionally paced to its
personal-key limit of 25 a minute.

- **Europe PMC `fullTextXML`**, by the PMCID a Europe PMC search for the DOI
  returns.
- **PMC's AWS open-data bucket** (`pmc-oa-opendata`). `metadata/PMCxxxx.N.json`
  gives `pdf_url`, `text_url`, `is_pmc_openaccess` and `is_manuscript`. NCBI's
  old `oa.fcgi` service now answers 404.
- **Every other Unpaywall location's `url_for_pdf`**, with the desktop's
  headers.
- **Every OpenAlex location `pdf_url`** not already tried.
- **CORE v3 search by DOI**, with the maintainer's personal key: its
  `downloadUrl`, and the extracted `fullText` (counted when over 5,000
  characters).

| Stratum | Failures | Recovered | By |
|---|---|---|---|
| Europe PMC `OPEN_ACCESS:Y` | 141 | 141 | Europe PMC XML 137, AWS PDF 138, others a handful |
| Europe PMC `OPEN_ACCESS:N` | 149 | **47 (32%)** | AWS author-manuscript text 28, CORE text 14, other Unpaywall locations 9, OpenAlex 4 (overlapping) |

The first stratum barely matters: the chain already asks Europe PMC first and
gets those articles there. In the second, 102 stay unrecovered: 83 walls, 16
addresses with no PDF, and 3 refusals of our client. The 83 walls are PMC
"free to read" articles absent from the bucket (24), ScienceDirect (16), and
a long tail.

- **CORE is under-measured.** It answered 429 to 136 of 290 searches, 73 of
  them among the 102 unrecovered, although requests were paced at 25 a
  minute; a search evidently costs more than one token. Its downloads, the
  `api.core.ac.uk/v3/outputs/{id}/download` route included, sit behind
  Cloudflare even with the key. Its search `fullText` is usable.
- **Elsevier is blocked from outside the institution.** The maintainer's key
  works for the Abstract Retrieval API. The ScienceDirect Article Retrieval
  API answers `AUTHENTICATION_ERROR` ("Requestor configuration settings
  insufficient") for every request, by DOI or PII, as PDF, XML or JSON. It
  needs the institution's network or an institutional token. Untested from
  there.

## 2. A real embedded browser: QtWebEngine (`2026-10-04-qtwebengine-*.jsonl`)

The browser was PySide6's QtWebEngine 6.10.1 (Chromium 134), which the
desktop already ships. It used its default User-Agent, a persistent profile
for the run (so cookies carry over within a publisher), and the PDF viewer
turned off, so that a PDF arrives as a download and is checked for `%PDF`.
There was no automation protocol. The sample was 41 failures: 12 PMC, 10
ScienceDirect, 14 other walls, and 5 controls with no PDF behind them.

| | PMC | ScienceDirect | Other walls | Controls (no PDF) |
|---|---|---|---|---|
| Hidden (no window, 25 s) | **12/12** | 0/10 | 5/14 | 0/5, as expected |
| Window shown (60 s, nobody ticking), hidden failures only | | 0/10 | **9/9** | |

- **Everything but ScienceDirect arrived, with no person involved.**
  Showing the window was enough for the Cloudflare publishers (RSC, BMJ,
  Cell, OUP, Thieme, AK Journals and others).
- **ScienceDirect stays on "Just a moment…".** In the maintainer's Safari the
  same addresses needed one tick-box, and that tick covered the next
  ScienceDirect PDF too.
- **Playwright did worse.** In the survey, Playwright's Chromium, headless or
  headed with the automation flag off, was stopped by PMC's reCAPTCHA and by
  ScienceDirect. A wall that blocks Playwright says nothing about a real
  embedded engine.
- **Caveats.** The sample came mostly from the 2019–21 rows. The Apple apps
  would use WebKit, untested here, although Safari passing PMC suggests the
  same.

## 3. obscura, a stealth headless browser (`2026-10-04-obscura-stealth.jsonl`)

[obscura](https://github.com/h4ckf0r0day/obscura) is a Rust headless browser
with its own engine (a Rust DOM with V8), not Chromium. Its stealth build
adds a BoringSSL transport that presents Chrome's TLS handshake, plus
per-session fingerprint randomisation and tracker blocking. It was built from
source, release **v0.2.3** (commit `1a3169d`), with `cargo build --release -p
obscura-cli --bins --features render,stealth`, and run with `--stealth`. The
repository's main branch at the time (`765af54`) did not compile
(`obscura-cdp`, an undefined `ctx` in `server.rs`). The source was read
before building: the build scripts only stamp a version and build a V8
snapshot, and nothing phones home.

It was given the same 41 addresses, one `obscura fetch` per address and
mode, paced per host:

- **A, stealth transport only:** `--stealth fetch URL --dump original` (raw
  body, no JavaScript).
- **B, with JavaScript:** `--stealth fetch URL --dump html --wait-until
  networkidle0`.
- **C, cookies kept:** B, then A again with the same `--storage-dir`, so any
  clearance cookie from B is reused (3 addresses).

| | PMC | ScienceDirect | Other walls | Time per address |
|---|---|---|---|---|
| A | 0/12 | 0/10 | 0/14 | median 2.2 s |
| B | 0/12 | 0/10 | 0/14 | 3–14 s |
| C | 0/2 | | 0/1 | |

- **Mode A** got the challenge pages themselves: Cloudflare's "Just a
  moment…", PMC's "Preparing to download" or reCAPTCHA, and ScienceDirect's
  403. The TLS impersonation alone does not pass these walls.
- **Mode B** stayed on the challenge. Cloudflare showed a captcha, and
  ScienceDirect stayed on "Just a moment…". On PMC, seven ended on a blank
  page and five on reCAPTCHA.
- **Mode C** shows the walls are not passed at all. PMC issued its
  proof-of-work cookie (`cloudpmc-viewer-pow`) and still answered the next
  request with HTML: its reCAPTCHA second stage. OUP set only `__cf_bm`, never
  the clearance cookie.

**obscura recovered none of the walled PDFs, where QtWebEngine recovered
every one but ScienceDirect's.** Its speed is real but buys nothing when
every answer is a challenge page; the embedded engine's time goes on waiting
out the challenges. A stealth client would also mean impersonating a browser
to get past a host's defence, the opposite of the identification
`doc/cross_platform/polite_request_pacing.md` asks of us. The real-engine
route needs no impersonation.

**When to look again:** if a later obscura release claims to pass Cloudflare
Turnstile or PMC's reCAPTCHA. Re-running is cheap: build the release as
above, then for each address in the 41-row sample (the hidden QtWebEngine
rows list their DOIs) run mode A, falling back to B, and compare with these
rows.
