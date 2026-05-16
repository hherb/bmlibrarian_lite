# Strategy memo (v2) — 2026 TGL Quality Use of Medicines Research Grant

**Applicant:** Dr Horst Herb (Rural Generalist with AST Emergency Medicine; GP background; AHPRA-registered, Australia)
**Grant:** Australian General Practice Research Foundation / Therapeutic Guidelines Ltd
**Cap:** AUD 100,000 (ex GST), 18 months, commencing January 2027
**Submission window:** 11 May – 22 Jun 2026 (9:00 AEST); outcomes 11 Sep 2026

This is v2 of the strategy memo. v1 assumed a multi-co-I team, a university GP-department host, and an audit-and-feedback trial. The user's clarifications have changed all three premises:

- The applicant has spent the last ~9 years primarily in Emergency Medicine and is not received as a "real GP" by university Departments of General Practice; the route to a host institution runs through rural-medicine and rural-clinical-school structures (ACRRM-aligned, JCU rural footprint), not metropolitan GP departments.
- The team will be **two people**: PI (Dr Herb) and one co-investigator (Frithjof Herb, PhD candidate, AI/ML and statistics). The family relationship is a real conflict of interest that will be declared and mitigated openly rather than hidden.
- The study is reduced from an A&F prescribing-behaviour trial to a **validation + usability evaluation** of the two open-source tools (BMLibrarian Lite and BiasBuster), which is honest about scope and avoids over-promising in a $100k pilot.

Each of these changes weakens at least one selection criterion. The memo is upfront about that so the form text can be drafted to compensate where possible and avoid empty claims where it cannot.

---

## 1. Honest assessment of fit before we start drafting

The application is viable but no longer competitive on the academic-track-record axis. It must win on:

1. **Novelty and timeliness** — the foundation explicitly funds work on factors influencing prescribing decisions and on evidence-informed clinical decision-making; AI-assisted, bias-aware appraisal at the point of care is a topic the field is wrestling with right now and has very little Australian evidence on.
2. **Tool maturity** — both tools already exist on four platforms, are AGPL-licensed, and have one prior validation data point (BiasBuster κ=1.000 vs Cochrane RoB 2 on shared domains in a small comparison set). This is unusual for a grant in this band: most applicants propose to *build*; this proposal evaluates *built things*.
3. **Transparency-as-mitigation** — a developer-led, two-person, single-family team cannot win on independence. It can win on radical openness: pre-registered analysis plan, fixed reference standard constructed by external assessors, raw data + analysis code published, negative findings published.
4. **Translation pipeline** — validation + usability is positioned as the necessary precursor to a future cluster-randomised audit-and-feedback trial; the proposal makes this pipeline explicit and credible.

The application **will not** win on:
- Senior academic GP supervision (we don't have it)
- Multi-disciplinary team (we don't have it)
- Independent analytic team (we don't have it)
- Implementation-science track record (we don't have it)

The form will not invent these. We have to be straightforward and lean into what we *do* have.

---

## 2. Eligibility framing (the binding question)

The eligibility page treats "early-mid career researcher" as binary; ticking No ends the application.

**Decision (per user):** tick **Yes**, framed as **research-career** stage rather than clinical-career stage.

**Framing language to use in the leadership section and CV:**
- "Early-mid career *researcher*. Practitioner-led research career commenced with completion of MPH (James Cook University, [year]). Prior clinical career in general practice and emergency medicine provides the practice context for the research programme but is not itself the basis of an academic track record."
- Avoid wording that emphasises decades of clinical seniority. Foreground the MPH, any prior publications (especially recent), and the open-source software work as a practitioner-led research output.
- The CV should lead with research outputs (publications, software releases, validation results) and place clinical positions below. This is unusual for a clinician's CV but matches the framing.

**Risk:** reviewers may push back. The form does not let us pre-empt this — we either tick Yes credibly or we don't. The CV is what decides it.

---

## 3. Administering organisation — revised strategy

University Departments of General Practice are off the realistic list because they have repeatedly indicated they do not consider Dr Herb a current GP. ACRRM-as-administering-body is unlikely to qualify under the grant's "Australian university, hospital, medical research institute, or similar accredited body" requirement (ACRRM is a college, not a research institute). The user has also indicated political friction with ACRRM leadership.

**Realistic tiered targets** (in approximate order of fit):

1. **JCU Australian Institute of Tropical Health and Medicine (AITHM)** — Townsville, rural/remote and tropical medicine focus; receives federal research funding; has a track record of administering grants for clinician-researchers with non-metro footprints. Applicant has an existing alumnus link via the MPH. Approach an AITHM researcher with primary-care or evidence-implementation interests as the in-house sponsor; they would likely need to be named as a co-investigator on the form for the affiliation to stick.
2. **JCU Mount Isa Centre for Rural and Remote Health (MICRRH)** — same university, narrower remit, more sympathetic to rural-generalist + EM profile; smaller but plausible.
3. **Monash School of Rural Health / Monash Rural Health** — strong rural-generalist research culture; not the closest geographic fit but a credible national host.
4. **University of Newcastle School of Medicine and Public Health (Rural & Remote stream)** — has hosted clinician-led practice innovations.
5. **Charles Sturt University / Three Rivers Department of Rural Health** — newer, smaller, but oriented to clinician-led rural research.
6. **Menzies School of Health Research (Darwin)** — long shot; rural/remote-aligned but their portfolio is dominantly Indigenous and chronic disease; would need a strong fit story.

**What we cannot defer:** the host organisation must be a real, locked-in affiliation by submission; the form requires an administering-org signature and a contact. A "we will identify one" placeholder will fail eligibility check.

**Recommendation:** AITHM as the first approach. The email to send opens with: alumnus background, two AGPL tools already in production, $100k validated-tool evaluation study, looking for a JCU co-investigator sponsor and admin host. If AITHM declines, the next move is Monash Rural Health.

**If no host is secured by mid-June:** withdraw from this round and re-target the 2027 round with the host secured first. This is preferable to submitting an ineligible application.

---

## 4. Revised project concept — validation + usability

**Working title (placeholder):** *Validation and clinical usability of open-source AI tools for appraising therapeutic claims in Australian general practice: BMLibrarian Lite and BiasBuster*

**Plain-English version (draft, ~150 words):**

General practitioners and rural generalists encounter a steady flow of therapeutic claims — from pharmaceutical representatives, sponsored education, and selectively cited publications. Independently verifying these claims against the underlying evidence is time-consuming and skills-intensive, and is rarely possible at the point of care. Two open-source tools developed by the applicant — BMLibrarian Lite (an AI-assisted biomedical literature search and synthesis tool) and BiasBuster (an AI-assisted risk-of-bias assessment tool) — aim to make this faster and more reliable. Before recommending their use in Australian general practice, the tools need formal evaluation. This project does two things: (1) measures the tools' accuracy on a curated set of publications used in pharmaceutical promotion, against expert reference standards; and (2) tests whether Australian GPs can use the tools effectively to appraise realistic therapeutic claims, and what changes if they do.

### 4.1 Arm A — Validation against expert reference standard

**Corpus construction (independent of PI):**
- Source publications cited in current pharmaceutical promotional material across **3–4 high-impact drug classes** (candidates: SGLT2 inhibitors, GLP-1 receptor agonists, gabapentinoids, novel anticoagulants, branded statins, biologics in primary care). Sources include rep-left material collected from volunteer practices, sponsored-CPD slide decks, MIMS-listed industry references, and PBS-listed product information.
- Construct a corpus of approximately **80–120 publications**.
- Construction is done by a paid corpus assistant (RA or pharmacist) using a written sourcing protocol; PI does not influence inclusion to avoid skewing toward cases the tools handle well.

**Reference standard:**
- **Two independent assessors** (clinical pharmacist + GP/registrar trained in critical appraisal) score each publication blinded to BiasBuster output, using a domain-by-domain Cochrane RoB 2 (or ROBINS-I for non-randomised) workflow.
- Disagreements resolved by a third senior assessor.
- Assessors are paid contractors, **not** members of the research team or the PI's family. (This is the line we cannot blur — the reference standard must be independent.)

**BiasBuster output:**
- Each publication is processed by BiasBuster in a frozen, version-locked configuration set on day 1 of the project.
- Tool runs are batched and logged; raw outputs are stored.

**Primary metric:**
- Weighted Cohen's κ for risk-of-bias-domain agreement between BiasBuster and the expert reference standard.
- Pre-specified success threshold (e.g. κ ≥ 0.6 overall, ≥ 0.4 per domain) declared in the pre-registration.

**Secondary metrics:**
- Per-domain confusion matrices.
- BMLibrarian Lite's retrieval performance on a subset of claims: precision and recall against a librarian-constructed gold-standard search for ~20 sentinel claims.
- Failure-mode taxonomy: categorisation of disagreements (e.g. tool hallucination, tool conservatism, expert disagreement, ambiguous source material).

### 4.2 Arm B — Clinical usability evaluation

**Participants:**
- **15–20 Australian GPs and rural generalists**, recruited through ACRRM, RACGP, rural workforce agencies, and direct outreach. Stratified for solo/group practice, urban/regional/rural, and self-reported familiarity with AI tools.

**Design:**
- Within-subject counterbalanced design. Each participant appraises **4–6 standardised therapeutic claims** (drawn from the validation corpus): half with the tools, half without, order randomised.
- Realistic time pressure (each appraisal capped at 15 minutes, mirroring a between-patient slot).

**Quantitative measures:**
- Time to appraisal.
- Appraisal accuracy against the same expert reference standard used in Arm A.
- Self-reported confidence (validated short scale, pre/post each appraisal).
- Reported intent to incorporate into practice.

**Qualitative measures:**
- Think-aloud protocol during one of the tool-assisted appraisals per participant (audio-recorded).
- Semi-structured exit interview (~30 min) on workflow fit, trust, perceived risks of AI-assisted appraisal, equity implications, and unmet needs.

**Analysis:**
- Mixed-effects models for accuracy/time/confidence (participant as random effect, condition as fixed effect).
- Reflexive thematic analysis (Braun & Clarke) for interviews.

### 4.3 Translation framing (the load-bearing argument for the 30% Translation criterion)

We cannot claim that this project changes prescribing. Instead we claim:

1. **Validated, freely-licensed tools** become available to every Australian GP and to Therapeutic Guidelines itself as appraisal aids, with documented accuracy bounds and failure modes that practitioners can interpret.
2. **The pre-registered analysis plan and open data** form a template for evaluating future AI appraisal tools entering Australian primary care — a piece of infrastructure currently absent.
3. **The validation results explicitly enable a downstream definitive trial**: a cluster-randomised audit-and-feedback study using the validated tools as the intervention payload. This proposal sketches that follow-on study and identifies the funding paths (MRFF Primary Care, NHMRC Investigator-Initiated) for it. The current grant is positioned as the necessary precursor.
4. **TG dissemination synergy**: validated tools can be integrated into or referenced by TG's editorial workflow; usability findings inform how TG might surface bias-aware appraisal aids to its subscribers.

---

## 5. Team — two people, family COI declared

**Composition:**
- **PI: Dr Horst Herb.** Rural Generalist with AST Emergency Medicine; MPH (JCU); author and copyright holder of BMLibrarian Lite and BiasBuster; software engineering and clinical informatics background.
- **Co-I: Frithjof Herb.** PhD candidate, AI/ML applied to analytical chemistry; statistics major. Role: statistical analysis lead for both arms; corpus randomisation; data pipeline implementation.
- **Paid contractors (not team members, listed separately):** corpus assistant; two blinded expert assessors + one tiebreaker; qualitative researcher for think-aloud / interview coding; transcription services.

**This is unusually small for a $100k grant.** The form's Project Leadership and Capacity Building sections will be the hardest to write convincingly. Drafting strategy:

- **Lean on the paid-contractor independence** rather than pretending the team is larger than it is. Reviewers can see through padded co-I lists.
- **Lean on the JCU/AITHM (or alternative) sponsor co-investigator** once secured — they become the formal academic supervision arrangement and add capacity-building substance.
- **Capacity building**: framed as PI's own formal research-career development (first competitive grant, peer-reviewed validation publications), Frithjof's translation of AI/ML statistical methods into health-services research, and capacity in the participating practices via exposure to structured critical appraisal of industry-cited evidence.

### 5.1 Family-relationship COI — declaration and management

The co-investigator is the PI's son. This must be disclosed as a real personal COI in addition to the developer COI. The form's COI field is the place to defuse it; pretending otherwise will not survive reviewer scrutiny.

**Draft COI declaration (≤250 words target):**

> The principal investigator is the author and copyright holder of both tools under evaluation (BMLibrarian Lite and BiasBuster). Both are released under the AGPL-3.0 open-source licence with no commercial licensing, royalties, or equity arrangements; the PI derives no income from tool use or evaluation. The named co-investigator, Mr Frithjof Herb, is the PI's son; this familial relationship is disclosed as an additional personal COI. He has been engaged because his discipline-specific AI/ML statistical training (PhD candidature in machine learning applied to analytical chemistry, statistics major) is directly applicable to the diagnostic-accuracy and inter-rater agreement methods this study uses, and because the project's budget cannot support a senior independent biostatistician at competitive rates.
>
> Both conflicts are managed by structural design rather than personnel substitution. Specifically: (a) the validation corpus is constructed by a paid independent assistant against a written sourcing protocol that excludes PI influence on selection; (b) the expert reference standard is set by two paid independent blinded assessors with a third tiebreaker, none of whom are members of the research team or related to it; (c) the statistical analysis plan, including success thresholds, is pre-registered on the Open Science Framework before any tool runs; (d) raw data, processed data, and analysis code are published openly on study completion regardless of result direction; (e) a written commitment to publish null or negative findings is registered with the pre-registration; (f) the participant information sheet and recruitment material disclose the PI's developer role and the co-investigator's familial relationship to all GP participants and to the consumer reference group.

This is the strongest position available given the team composition. It is not as strong as having an independent senior co-I would have been.

---

## 6. Consumer involvement and Indigenous engagement

Both are required form fields. With a two-person team they need real handling, not boilerplate:

- **Consumer involvement:** recruit a small (3–4 person) consumer reference panel — patients with lived experience of being prescribed medicines from the sentinel drug classes — via a PHN consumer reference group or the Health Issues Centre (Vic) / Health Consumers Queensland equivalent. Panel sits twice during the project: at design sign-off (corpus criteria, lay-language elements of the usability scenarios) and at results-interpretation. Honoraria budgeted (~$2k total). The panel is not a co-investigator slot, but participation is real and documented.
- **Indigenous engagement:** for a validation + usability study with no Indigenous-specific intervention or recruitment, the honest answer is "not directly applicable to this validation phase". The form should include a short paragraph committing to (a) ensuring usability scenarios include claims relevant to medicines disproportionately prescribed in Aboriginal and Torres Strait Islander populations (e.g. SGLT2i in T2DM), and (b) consulting an Indigenous health representative (NACCHO-affiliated or local AMS) on the downstream cluster trial design, where Indigenous engagement becomes substantive. Do not invent participation that won't happen.

---

## 7. Budget shape (AUD 100,000 ex GST over 18 months)

Reshaped for the validation + usability design. All figures indicative; host org will recalculate with on-costs.

| Category | Item | Approx (AUD) |
|---|---|---|
| **Personnel (~50%)** | PI clinical-session backfill (0.08 FTE × 12 months equivalent) | 22,000 |
| | Co-I statistical analysis (Frithjof Herb) — contracted hours at PhD-candidate rate | 12,000 |
| | Project coordinator / RA (0.2 FTE × 9 months: recruitment, scheduling, logistics) | 16,000 |
| **Reference standard & corpus (~22%)** | Independent corpus assistant (clinical pharmacist or research librarian, ~80 hours) | 7,000 |
| | Two blinded expert assessors (RoB scoring of 80–120 publications, ~60 hours each at academic-contractor rate) | 12,000 |
| | Tiebreaker senior assessor (~10 hours) | 3,000 |
| **Usability arm (~10%)** | GP participant honoraria (20 × $300 — 90 min commitment plus interview) | 6,000 |
| | Independent qualitative researcher (transcription QA + thematic coding lead, ~40 hours) | 4,000 |
| **Consumer involvement (~2%)** | Consumer panel honoraria (4 members × 2 sessions, RACGP-equivalent rates) | 2,000 |
| **Equipment & cloud (~6%)** | Cloud LLM API costs for tool runs across validation corpus and usability sessions | 4,000 |
| | Audio recording + transcription services | 2,000 |
| **Other (~10%)** | HREC submission fees | 1,500 |
| | Travel (PI to in-person usability sessions if not fully remote) | 3,000 |
| | Open-access publication fees (one primary paper) | 3,500 |
| | OSF / pre-registration / data repository (Zenodo DOI fees if any) | 500 |
| | Dissemination (one conference registration for Frithjof — capacity building rationale) | 1,500 |
| **Total** | | **100,000** |

**Notes:**
- The reference-standard contractors are budgeted at independent contractor rates; this is the project's largest non-personnel line and is the budgetary expression of the COI mitigation. It is non-negotiable.
- Frithjof's compensation is at a PhD-candidate hourly rate and is fully transparent in the budget — reviewers will check this.
- No royalties, licence fees, or equity payments anywhere in the budget.
- Salary on-costs (super, payroll tax, leave loading, ~20–28%) will be applied by the host org and will compress the headline figures above; final numbers depend on the host.

---

## 8. Timeline shape (18 months from Jan 2027)

| Months | Phase | Milestones |
|---|---|---|
| 1–2 | Setup | HREC submission; pre-registration on OSF; sourcing protocol finalised; tool version-lock; contractor onboarding |
| 2–3 | HREC approval | Recruitment of usability participants opens |
| 2–6 | Validation corpus construction | Corpus assistant compiles 80–120 publications across 3–4 drug classes |
| 4–9 | Expert reference standard scoring | Two assessors score blinded; tiebreaker resolves disagreements |
| 5–9 | BiasBuster runs | Version-locked tool runs on corpus; outputs logged |
| 8–12 | Usability sessions | 15–20 GP participants complete sessions and interviews |
| 9–13 | Qualitative coding | Independent researcher leads thematic analysis |
| 11–14 | Statistical analysis | Inter-rater agreement, accuracy, time, confidence analyses |
| 13–16 | Write-up | Two papers: validation primary, usability primary |
| 15–17 | Dissemination | Conference abstracts; PHN/college briefings; TG briefing; open data deposit |
| 17–18 | Final reporting | Final grant report; downstream-trial protocol outline |

Milestone-linked payments per grant terms: HREC approval, corpus complete, reference standard complete, BiasBuster runs complete, usability data collection complete, final report.

---

## 9. Risks and mitigations (for the form)

| Risk | Mitigation |
|---|---|
| Host institution not secured by submission | Approach AITHM immediately; if no traction by end May 2026, withdraw and re-target 2027 round with host pre-secured |
| Reviewer concern about developer COI + family-member co-I | Independent corpus construction, independent blinded assessors, pre-registration, open data and code, written commitment to publish null findings, explicit COI disclosure to participants |
| Reviewer concern about ECR framing | CV foregrounds research outputs; supervision/sponsorship arrangement at host institution provides academic anchoring |
| Reference-standard cost overrun | 20% contingency embedded in personnel; assessors paid by-publication, capped |
| GP usability recruitment shortfall | Recruit via multiple channels (ACRRM, RACGP, RWA, rural workforce agencies); offer fully remote option (Zoom-based); over-recruit by 25% |
| Tool changes mid-study | Version-lock both tools on day 1; document SHA/version in pre-registration |
| Cloud LLM cost overrun | Per-batch budget caps already in tools; fallback to local Ollama for validation corpus runs if needed |
| Qualitative coding bias | Independent researcher leads; PI does not interview participants directly |

---

## 10. What is no longer in this version (and why)

For traceability, items removed from v1:

- **Audit & feedback prescribing-behaviour trial** — out of scope for $100k with this team; honesty about scope is a stronger story than overpromising.
- **Multi-co-I team (academic GP, biostatistician, HSR researcher, clinical pharmacist, PHN site lead, qualitative researcher)** — replaced by paid independent contractors for specific roles; only the host-institution sponsor (TBD) joins as a named co-I.
- **PHN as administering organisation** — PHNs are unlikely to satisfy the grant's "university / hospital / MRI / accredited body" requirement and would not provide academic sponsorship for the ECR-as-research framing.
- **University Department of General Practice as host** — not realistic given the EM-pivot reality described by the user.
- **Sentinel-prescribing outcome** — replaced by tool accuracy and tool usability outcomes; prescribing-behaviour change is the *next* grant.

---

## 11. Decisions still needed from you before drafting form text

1. **Host institution outreach**: do you want me to draft the AITHM outreach email now, or do you have a contact there already? Same question for Monash Rural Health as backup.
2. **Drug-class shortlist**: pick 3–4 from {SGLT2i, GLP-1 RAs, gabapentinoids, novel oral anticoagulants, branded vs generic statins, biologics for psoriasis/atopic dermatitis} or substitute your own.
3. **Co-investigator naming**: is "Frithjof Herb" the name and role for the form, or do you want a different role title (e.g. "Statistical Analysis Lead" vs "Co-investigator")?
4. **Independent assessors**: do you have any candidates in mind (clinical pharmacist, GP/registrar trained in critical appraisal) we should name in the application as "to be contracted", or leave generic?
5. **Consumer panel**: do you have a route to Health Consumers Queensland / NSW / Vic, or should we plan for a PHN consumer reference group route?
6. **AGPRF same-round overlap**: are you submitting any other 2026 AGPRF application?
7. **Submission go/no-go gate**: agree that **no host institution secured by mid-June = withdraw and re-target 2027**? This needs to be your call now, not a panic-call on 20 June.

---

## 12. Once you sign off

I'll draft, sized to the word limits on the form:

- Project title; plain-English summary (≤250); literature review × 3 fields (≤250 each); research question (≤250); participants; design & methodology (≤750); Indigenous engagement (≤250); consumer involvement; ethics + HREC plan (≤250); beneficiaries; dissemination & translation (≤500); anticipated impact (≤250); project leadership & support (≤250); GP-grounding (≤150); capacity-building (≤200); co-investigator description (≤250); detailed timeline (≤250); budget table + salary justification (≤250); other funding; COI declaration (≤250); CV skeleton for PI and co-I.
