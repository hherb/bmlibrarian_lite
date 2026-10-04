# Why Unpaywall's PDFs cannot be downloaded (#480)

Since #478 every platform refuses a PDF Unpaywall named that it could not
obtain: no link is offered, and the open-access copy is recorded as unsettled
(`doc/cross_platform/fulltext_retrieval.md`). This survey measured why those
downloads fail. The three possible causes #480 names are: the address itself,
a bot wall, or our own client.

**In short:** our clients obtain 28% of the PDFs Unpaywall names. Of the rest,
**81% are bot walls**, 12% are addresses that serve no PDF, 4% are our client,
and 4% are unclassified. The app can tell the difference on its own: **89% of
the failures where our client was shown a challenge page are walls**, and 73%
of the failures where it was not shown one serve no PDF.

## Method

`scripts/unpaywall_pdf_survey.py` (its docstring has the details). In outline:

- **Sample.** PubMed records from random publication days. Each sample has
  two strata of 100 articles whose Unpaywall answer names a `url_for_pdf`: one
  where Europe PMC's record says `OPEN_ACCESS:Y`, and one where it says
  `OPEN_ACCESS:N`. The second stratum is where the Unpaywall PDF matters,
  because the chain serves an open-access PMC article from Europe PMC before it
  reaches Unpaywall. A dev sample (2019–21, seed 1) and a held-out sample
  (2023–25, seed 2) were each fetched on 2026-10-04. The rules were refined on
  the dev sample and checked on the held-out one.
- **Probe.** The PDF `choose_unpaywall_url` picks (the one the apps try) is
  asked for once, with no retries, by five clients:
  - `desktop`: the shipped session's headers;
  - `android`: its User-Agent;
  - `apple`: URLSession's default headers;
  - `browser-headers`: Chrome's navigation headers over the same `requests`
    client;
  - a headless Chromium with a current Chrome User-Agent, which downloads PDFs
    rather than displaying them and waits 8 s for a challenge to clear.

  Every request is paced by the app's own per-host limiter.
- **Classify.** `classify()` sorts each failure into a family. The browser is
  the arbiter: a PDF it obtained is not unfetchable. Its control holds: no
  address was served to one of our clients and refused to the browser.

The rows are `2026-10-04-dev.jsonl` and `2026-10-04-heldout.jsonl`. **Re-analyse
them rather than re-fetch**, because hosts change their defences:

```bash
python scripts/unpaywall_pdf_survey.py analyse doc/developer/unpaywall_pdf_survey/*.jsonl
```

`tests/test_unpaywall_pdf_survey.py` pins the figures below to these rows.

## Results (400 addresses)

Unpaywall was asked about 901 DOIs. 400 of its answers named a PDF, 203 named
only a landing page, 298 named no open-access location, and 4 DOIs were
unknown to it.

| Client | Served |
|---|---|
| desktop | 110 (28%) |
| android | 111 (28%) |
| apple | 116 (29%) |
| browser headers over `requests` | 88 (22%) |
| headless Chromium | 223 of 399 (56%) |

One address (IEEE) stalled the browser's download past the 120 s bound. It is
recorded as a harness failure, not as an answer.

### The desktop's 290 failures, by family

| Family | Reason | Count |
|---|---|---|
| **bot-wall** 234 (81%) | `challenge-in-browser`: a challenge every automated browser was still shown | 115 |
| | `js-challenge`: our client was challenged, and a headless browser was served | 103 |
| | `challenge-unresolved`: the browser's page stayed blank | 16 |
| **unfetchable** 34 (12%) | `not-a-pdf`: every client, browser included, got something else | 18 |
| | `no-free-pdf-behind-wall`: past the challenge, the publisher sends the browser to the abstract | 14 |
| | `gone`, `gone-behind-wall`: a 404 | 2 |
| **our-client** 11 (4%) | `user-agent`: another of our clients was served | 7 |
| | `headers`: Chrome's headers over the same client were served | 4 |
| **unclassified** 11 (4%) | `browser-stopped-mid-redirect`: RSC's sign-on bounce | 7 |
| | `refused-everywhere`, `host-error`, a 500 | 4 |

In the stratum that matters (`OPEN_ACCESS:N` in Europe PMC, 200 articles), the
desktop failed on 149: 118 walls (79%), 24 unfetchable, 6 our client and 1
unclassified. Android's failures are the desktop's less one, and Apple's
less six: MDPI serves its User-Agent.

**Where the walls are.** PMC alone accounts for 83 failures: a reCAPTCHA
"Checking your browser" page, or a "Preparing to download" proof of work. 44 of
them are in the `OPEN_ACCESS:N` stratum, the closed-access PMC articles whose
`fullTextXML` answers 500 (#432), so this PDF is their only copy. Next come
ScienceDirect with 35 (Cloudflare) and Wiley, RSC and OUP with 14–15 each.
MDPI's Akamai rule refuses the `BMLibrarian/1.0` User-Agent that the desktop
and Android send, and serves Apple's CFNetwork one. eScholarship's CloudFront
serves only Chrome's headers.

**What is genuinely unfetchable.** Springer redirects every client to the
article's page. `ars.els-cdn.com` "PDFs" are JPEG graphical abstracts that
Unpaywall lists as PDFs. Behind a cleared challenge, Wiley, Elsevier society
journals, Karger and SAGE send an anonymous reader to the abstract. Also a
parked domain, and a 404.

**A visible browser does no better.** Five `challenge-in-browser` addresses
(two PMC, two ScienceDirect, one Wiley) were retried in a *headed*
Playwright Chromium. PMC and ScienceDirect still showed their challenge, and
Wiley still sent it to the abstract. Every automated browser is stopped by
these walls.

**A person's browser passes them.** As a spot check, the maintainer opened
four of these addresses in Safari on 2026-10-04: two PMC and two
ScienceDirect. All four were PDFs. Both PMC PDFs downloaded straight away.
The first ScienceDirect PDF asked for a tick-box captcha, and the second
then downloaded straight away (same publisher, with the challenge already
solved). Four addresses are not a measurement, but these two hosts account
for 119 of the 131 walls no automated browser passed
(`challenge-in-browser` and `challenge-unresolved`), and a reader clears
them in one click or none.

### What the app can see

The app cannot run a browser to decide. What it has is its own answer:
whether that answer was a challenge page (`probe_markers`: a known challenge in
the page, or a 403/503 served by Cloudflare itself).

| The desktop's failure | Walls | Our client | No free PDF / gone | Unclassified |
|---|---|---|---|---|
| challenged (264) | 234 (89%) | 7 | 15 (6%) | 8 |
| not challenged (26) | 0 | 4 | 19 (73%) | 3 |

The share of challenged failures that are walls is 86% in the dev sample and
94% in the held-out one.

## What it decides

#480 asked three questions. Each answer below is the evidence; the decision is
the maintainer's.

1. **Should a bot-walled PDF be offered as a link to open in the browser?**
   The evidence supports it, for a challenged failure only. 89% of those are
   walls. A headless browser opened 103 of the 264 outright, and the walls
   that stop every automated browser (mostly PMC and ScienceDirect) let a
   person through in the spot check above, at most after a tick-box
   captcha. About 6% would send the reader to an abstract or a 404 rather
   than the PDF. A
   failure that was not challenged is mostly an address with no PDF (73%), and
   refusing it, as now, is right.
2. **Does a challenge deserve its own failure kind and sentence?** Today a
   challenge reaches the reader as "did not serve it (HTTP 403)", an answer
   about the article. Behind 110 of the 264 challenges a PDF was confirmed
   (a browser or another of our clients got it), and 115 more are walls a
   browser is stopped by too. Only 15 had no free PDF behind them. A
   `challenged` kind would be detectable by every platform from the status,
   the `server` header and the page. It would need its own sentence in
   `open_access_unsettled_notice.json` and a new failure kind in all three
   ports.
3. **Do client changes recover a meaningful share?** No. Chrome's headers over
   our client recover 4 of 290 (eScholarship). A different User-Agent recovers
   7, all but one MDPI's rule against ours. Either change means sending a
   browser's identity in place of our own to get past a host's defence.
   That is the opposite of the identification that
   `doc/cross_platform/polite_request_pacing.md` asks of us. TLS
   fingerprinting was not separated out. Only a browser gets past these
   walls, so no HTTP client change would recover them either.

**Found on the way:** the desktop already has a browser fallback for an
open-access 401/403 (`pdf_discovery.BrowserSession`). It never works:
Playwright is not a dependency, and once installed, the code reads Chrome's
"Download is starting" as a failure and discards the download it had just got
past the wall for. Lodged as #483.

## What came next

Three spikes asked what recovers the walled PDFs: unattended machine
channels, a real embedded browser (QtWebEngine), and a stealth headless
browser (obscura). Their findings, and the decision taken, are in
`spikes/README.md`.
