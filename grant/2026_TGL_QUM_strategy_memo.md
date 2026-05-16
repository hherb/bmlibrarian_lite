# Strategy memo — 2026 TGL Quality Use of Medicines Research Grant

**Applicant:** Dr Horst Herb (GP, AHPRA-registered, Australia)
**Grant:** Australian General Practice Research Foundation / Therapeutic Guidelines Ltd
**Cap:** AUD 100,000 (ex GST), 18 months, commencing January 2027
**Submission window:** 11 May – 22 Jun 2026 (9:00 AEST); outcomes 11 Sep 2026

This memo locks in the study design, team shape, COI management, budget shape, and timeline before I draft the form responses. Once you sign off (or amend), I'll write the word-limited field-by-field text.

---

## 1. Refined project concept

**Working title (placeholder):** *Augmenting audit and feedback with AI-assisted evidence appraisal: a pilot evaluation in Australian general practice*

**One-paragraph plain-English version:**
General practitioners face a constant stream of therapeutic claims — from pharmaceutical representatives, sponsored education, and selectively cited publications — but rarely have time at the point of care to verify them against the underlying evidence or against Therapeutic Guidelines. This pilot tests whether equipping GPs with open-source AI tools that retrieve, summarise and assess the risk of bias of biomedical evidence in seconds, delivered alongside a structured audit-and-feedback intervention, can narrow evidence-practice gaps in prescribing for a small set of high-impact, guideline-discordant medicines.

**Why this framing works for this grant:**
- Audit & feedback is a Cochrane-evidenced QUM intervention class (Ivers et al., Cochrane Database Syst Rev 2012; updated 2024) — reviewers will recognise it immediately as legitimate QUM research, not a tech demonstration.
- The intervention is the *tools + the feedback session*; the outcome is *prescribing behaviour*. The tools are means, not ends.
- It directly addresses the foundation's listed focus areas: "factors that influence prescribing decisions", "strategies to support evidence-informed clinical decision-making", "reduce evidence-practice gaps", "translation of guideline-informed care".
- TG resources are usable inside the intervention (and the grant explicitly offers TG access to successful applicants) — natural fit.

---

## 2. Mapping to selection criteria

| Criterion | Weight | How this design scores well |
|---|---|---|
| Scientific quality | 30% | Pre-registered mixed-methods pilot; sentinel-drug audit with TG concordance as primary outcome; pre/post design with qualitative interviews; biostatistician on team |
| Translation & impact | 30% | Tools are open-source (AGPL), already production on 4 platforms; finding informs both GP education and TG dissemination strategy; PHN host enables scale-out |
| Innovation | 15% | First Australian evaluation of LLM-based, bias-aware, point-of-care evidence appraisal in primary care; AI-augmented audit & feedback is novel |
| Feasibility | 15% | Tools already exist and are validated (BiasBuster κ=1.000 vs Cochrane RoB 2 on shared domains); PI is the developer; PHN partnership for recruitment |
| Capacity building | 10% | Practice-based research training for participating GPs; supervision arrangement builds PI's formal research credentials; methods workshop with PHN |

---

## 3. Proposed study design

**Design:** Single-arm pre/post mixed-methods pilot, with embedded qualitative process evaluation.
(A stepped-wedge cluster trial is more rigorous but unaffordable at $100k and likely fails the feasibility test. A pilot is honest, achievable, and generates the effect-size data needed for a later definitive trial — which the application can flag as a follow-on.)

**Setting:** 6–10 general practices recruited through one or two partnering PHNs.

**Participants:** ~30–50 GPs (full-time-equivalent) across recruited practices; consenting individual GPs are the unit of analysis for prescribing outcomes.

**Sentinel prescribing targets (3–4):** Selected with TG and clinical-pharmacy input. Candidates:
- Long-term proton pump inhibitor prescribing without ongoing indication
- Gabapentinoids for non-neuropathic pain
- Antibiotics for acute respiratory infections in adults
- Branded-vs-generic statin / antihypertensive choice
- Early SGLT2i / GLP-1 RA prescribing concordance with TG sequencing

These map to areas where industry-promoted claims commonly diverge from TG and from best evidence.

**Intervention:**
1. **Baseline practice-level audit** (months 1–3): consented extraction of de-identified prescribing data for sentinel classes over the prior 12 months from clinical software (Best Practice / Medical Director via PHN-supported extraction tooling, e.g. POLAR or Pen CS).
2. **Structured feedback session** (months 4–6): in-practice small-group session with each practice. GPs receive their practice-level audit. Facilitated workshop demonstrates BMLibrarian Lite + BiasBuster on real claims circulating about the sentinel drug classes (e.g. recent rep material, sponsored CPD content). GPs use the tools hands-on.
3. **Ongoing access** (months 4–12): free access to both tools (already AGPL open source); periodic email prompts with new bias-aware evidence summaries for the sentinel classes.
4. **Re-audit** (months 12–15): same data extraction; calculate change in prescribing concordance with TG.
5. **Qualitative interviews** (months 6–14): semi-structured interviews with ~15–20 participating GPs on tool usability, perceived impact, barriers, and how the tools changed their interpretation of industry-sourced claims.

**Outcomes:**
- **Primary:** change in proportion of sentinel-class prescriptions concordant with TG recommendations, pre vs post.
- **Secondary (quantitative):** GP-reported confidence in appraising therapeutic claims (validated scale, pre/post); tool usage logs (anonymised); time-to-evidence-summary at point of care.
- **Secondary (qualitative):** thematic analysis of interviews — perceived value, COI awareness, integration into workflow, equity considerations, willingness to adopt.

**Pre-registration:** OSF or ANZCTR before recruitment begins.

**Statistical approach:** Mixed-effects logistic regression clustered by practice and GP for concordance outcome; descriptive statistics for usage logs; reflexive thematic analysis (Braun & Clarke) for interviews.

---

## 4. Team composition (critical for eligibility & scoring)

The eligibility text explicitly requires "an appropriate supervision and support team". A solo PI will fail Feasibility and Capacity Building. You need to name co-investigators on the form.

**Essential roles to fill before submission:**

| Role | Why needed | What to look for |
|---|---|---|
| **Academic GP supervisor** | Eligibility + Capacity Building (10%) | Senior academic GP with audit-and-feedback or implementation-science track record; ideally at a University Dept of General Practice |
| **Biostatistician** | Scientific Quality (30%) | Experience with clustered data and primary-care prescribing outcomes; could be from host institution |
| **Health services / implementation researcher** | Translation & Impact (30%) | Familiar with audit-and-feedback theory; can co-design feedback session |
| **Clinical pharmacist** | QUM credibility | NPS MedicineWise or PHN-based; helps select sentinel targets and design concordance measures |
| **PHN site lead** | Recruitment & data extraction | Senior GP or practice-support manager at partnering PHN |
| **Consumer representative** | Consumer-involvement section is mandatory | PHN consumer reference group or Health Issues Centre |
| **Independent qualitative researcher** | COI mitigation (does the analysis you cannot) | Could be at academic GP host |

You can list ~3–5 of these as named co-investigators on the form; the others can be named in supervision/support arrangements.

**Suggested next step:** I can draft a short outreach email template you can send to potential co-investigators once you've identified candidates.

---

## 5. Conflict of interest — declaration & management plan

You are the developer and copyright holder of both BMLibrarian Lite (AGPL-3.0) and BiasBuster. This is a real COI that **must be declared and actively managed**. Reviewers will look for a credible management plan.

**Declaration (mandatory field):** Yes — actual COI. PI is the author and copyright holder of the two open-source tools being evaluated.

**Management plan to include in the form:**
1. Both tools are AGPL-licensed open source with no commercial licensing; no royalties, equity, or income to PI from tool use.
2. **Independent outcome assessment**: prescribing data extraction, cleaning, and statistical analysis are performed by an independent team member who is not the PI.
3. **Qualitative analysis** of GP interviews is led and coded by an independent researcher; PI does not interview participants directly.
4. **Pre-registration** of analysis plan on OSF before any outcome data are unblinded.
5. **Publication commitment**: negative or null findings will be published; protocol and statistical code published openly.
6. **Participant disclosure**: PI's developer role is explicitly disclosed in the Participant Information Sheet for both GPs and the consumer reference group.
7. **Steering committee oversight**: an independent academic GP and a TG representative review interim findings.

This turns the COI from a weakness into a demonstration of methodological rigour.

---

## 6. Budget shape (AUD 100,000 ex GST over 18 months)

This is indicative — exact figures depend on host org on-costs and NHMRC scale alignment.

| Category | Item | Approx (AUD) |
|---|---|---|
| **Personnel (~65%)** | PI clinical-session backfill (0.1 FTE × 12 months equivalent) | 30,000 |
| | Research assistant / project coordinator (0.3 FTE × 12 months for recruitment, data extraction coordination, interview scheduling, transcription QA) | 25,000 |
| | Biostatistician (~80 hours across analysis phases) | 10,000 |
| **Practice & participant costs (~20%)** | Practice participation payments (8 practices × $1,500) | 12,000 |
| | GP interview honoraria (20 GPs × $200) | 4,000 |
| | Consumer rep honoraria (per RACGP rates) | 2,000 |
| **Equipment & materials (~7%)** | Cloud LLM API costs for tool use during study (Anthropic / OpenAI) | 3,500 |
| | Audit data extraction support (PHN POLAR/Pen CS fees if applicable) | 2,500 |
| | Interview transcription | 1,500 |
| **Other (~8%)** | HREC submission fees | 1,500 |
| | Travel to participating practices | 3,000 |
| | Dissemination (open-access fees, conference travel for one GP early-career attendee — capacity building) | 4,000 |
| | Open Science Framework / pre-registration administration | 500 |
| **Total** | | **100,000** |

**Notes:**
- Personnel salaries must align with NHMRC scales (form requirement).
- On-costs (payroll tax, leave loading, super, workers' comp) must be included — typical loading is 20–28%. The above figures are inclusive; the host org's finance team will need to recalculate.
- No equipment purchase needed — the tools already exist.
- No grant funds go to PI as tool licensing revenue (tools are AGPL; this fact strengthens the COI case).

---

## 7. Timeline shape (18 months from Jan 2027)

| Months | Phase | Milestones |
|---|---|---|
| 1–2 | Setup | HREC submission; co-design feedback session with team & consumer rep; tool refinement for sentinel-class workflows; pre-registration |
| 3 | HREC approval; site agreements | Practice recruitment opens |
| 3–6 | Baseline audit | Data extraction across practices; sentinel-class concordance baseline calculated |
| 5–7 | Intervention delivery | Structured feedback + workshop sessions in each practice; ongoing tool access enabled |
| 7–14 | Maintenance & monitoring | Anonymised tool usage logs; quarterly check-ins; ongoing evidence summaries to GPs |
| 10–14 | Qualitative interviews | Interview, transcribe, code (independent researcher leads) |
| 13–15 | Re-audit | Post-intervention data extraction & analysis |
| 15–17 | Analysis & write-up | Statistical analysis; thematic analysis; integration of findings |
| 17–18 | Dissemination | Manuscript submission; conference abstract; PHN report; TG briefing |

Payments are milestone-linked per grant terms — natural milestones are HREC approval, baseline audit complete, intervention delivered, re-audit complete, final report.

---

## 8. Risks and mitigations (good to flag in the form)

| Risk | Mitigation |
|---|---|
| Practice recruitment shortfall | PHN partnership; smaller practice count acceptable for a pilot; over-recruit by 20% |
| Data extraction technical issues | Use established PHN tooling (POLAR/Pen CS); pre-pilot at one practice |
| Reviewer concern about developer COI | Independent analysis pipeline; pre-registration; open data |
| Tool changes mid-study | Version-lock both tools at study start; document version used |
| Cloud LLM cost overrun | Per-GP budget caps already implemented in tools; fall back to local Ollama if needed |
| Low GP engagement post-workshop | Email prompts with evidence summaries; sentinel-class targeting chosen for clinical relevance |

---

## 9. Critical decisions I need from you before drafting

1. **Co-investigators**: Who can you realistically recruit as academic GP supervisor, biostatistician, pharmacist, PHN site lead, and consumer rep? Even 1–2 confirmed names dramatically strengthen the application. If you don't have anyone yet, are you willing to do outreach now (May → Jun 2026 closing date gives you time)?
2. **Host PHN / practice network**: Which one(s) are realistic — your local PHN, a research-active practice network (e.g., one of the practice-based research networks attached to a university Dept of General Practice), or a specific TG / RACGP-aligned body? They become the administering organisation.
3. **Sentinel drug classes**: Are you happy with the 3–4 candidates I've listed (PPIs / gabapentinoids / antibiotics-for-URTI / SGLT2i-GLP-1 sequencing), or do you have stronger candidates from your own practice experience that we should swap in?
4. **Project title**: My working title is a placeholder — do you want something punchier, or stay neutral until co-Is weigh in?
5. **"Early-mid career researcher" status**: Do you fit this label comfortably given your CV? If your publication track record is substantial, we may need to address this proactively in the leadership section.
6. **AGPRF same-round overlap**: The form asks whether you're submitting a similar project to another 2026 AGPRF grant. Are you?

---

## 10. Once you sign off

I'll draft, sized to the word limits on the form:
- Project title
- Plain-English summary (≤250 words)
- Literature review × 3 fields (≤250 words each) + references
- Research question / hypothesis (≤250 words)
- Participants
- Design & methodology (≤750 words) — the biggest single field
- Indigenous engagement (≤250 words, if relevant — likely "not applicable" with a brief note on equity)
- Consumer involvement
- Ethics (≤250 words) + HREC plan
- Beneficiaries
- Dissemination & translation (≤500 words)
- Anticipated impact (≤250 words)
- Project leadership & support (≤250 words)
- GP-grounding (≤150 words)
- Capacity-building (≤200 words)
- Co-investigator descriptions (≤250 words each)
- Detailed timeline (≤250 words)
- Budget table + salary justification (≤250 words)
- Other funding details
- COI declaration (≤250 words)
- A skeleton CV outline you can complete

That is the core of a submittable application minus signatures, ABN lookup, ethics committee selection, and the CV PDF.
