package com.bmlibrarian.factchecker.domain.transparency

/**
 * Regex patterns for industry detection: COI prose keywords, funder-name stems
 * and whole words, and the government/academic sponsor patterns.
 *
 * Transcribed string-for-string from the Swift `IndustryPatterns` (BioMedLit),
 * which mirrors the canonical Python lists (`FUNDER_NAME_STEMS`,
 * `FUNDER_NAME_WORDS`, `GOVERNMENT_PATTERNS`, `ACADEMIC_PATTERNS`).
 * [governmentPatterns] and [academicPatterns] are pinned by the shared contract
 * `doc/cross_platform/transparency_parity/sponsor_patterns.json`, and the
 * funder lists are measured against `funder_names.json` — see that directory's
 * README before editing any list here.
 *
 * Every regex is matched through [TransparencyRegex], i.e. case-insensitively
 * against lowercased text and compiled with [RegexHelper]'s `(?U)` flag.
 *
 * Declaration order matters: Kotlin initialises `object` properties top to
 * bottom, so [nonIndustryPatterns] must stay below the two halves it joins.
 */
object IndustryPatterns {

    /**
     * Keywords indicating industry affiliation in **COI prose**.
     *
     * Matched against a paper's conflict-of-interest statement — running text,
     * not an organisation name. Deliberately separate from [funderNameStems] /
     * [funderNameWords]: the generic corporate suffixes match far too freely in
     * running text, while these disclosure phrases never occur in a funder name.
     */
    val industryKeywords: List<String> = listOf(
        """\bpharma(?:ceutical)?\b""",
        """\bbiotech(?:nology)?\b""",
        """\bmedical device\b""",
        """\bdrug compan(?:y|ies)\b""",
        """\bmanufacturer\b""",
        """\binc\.?\b""",
        """\bcorp(?:oration)?\.?\b""",
        """\bltd\.?\b""",
        """\bgmbh\b""",
        """\bplc\b""",
        """\bemployee of\b""",
        """\bstock(?:holder)?\b""",
        """\bshareholder\b""",
        """\bconsultant for\b""",
        """\badvisory board\b""",
        """\bspeaker(?:'s)? (?:bureau|fee)\b""",
        """\bhonorari(?:a|um)\b""",
        """\bgrant(?:s)? from\b""",
    )

    /**
     * Substring stems for funder names — matched *inside* a longer word.
     *
     * A stem must reach into a longer word ("pharmaceutic" reaching
     * "Pharmaceuticals"); a whole word must not ("inc" as a substring matches
     * "Lincoln"). Merging this list with [funderNameWords] is a bug. Each stem
     * earned its place on the labelled corpus: `pharmaceutic` 3 TP / 1 FP,
     * `therapeutics` 1 TP / 0 FP, `laboratories` (plural only — "Key
     * Laboratory" is a Chinese state-lab form) 1 TP / 0 FP. Plain lowercase
     * literals, never regex sources: they are compared with `String.contains`.
     */
    val funderNameStems: List<String> = listOf(
        "pharmaceutic",
        "therapeutics",
        "laboratories",
    )

    /**
     * Whole-word terms for funder names — matched with word boundaries.
     *
     * `pharma` and `biotech` are the safe residue of stems the corpus
     * disqualified; the rest are legally reserved incorporation suffixes a public
     * body cannot use. `co`, `corporation`, `pty`, `ag`, `bv`, `nv`, `sa`, `ab`
     * and `labs` are deliberately absent (see the Swift KDoc for the measured
     * reason behind each). Ties go to precision, because `industryFundingDetected`
     * feeds a HIGH-risk rule.
     */
    val funderNameWords: List<String> = listOf(
        """\bpharma\b""",
        """\bbiotech\b""",
        """\bincorporated\b""",
        """\binc\b""",
        """\bcorp\b""",
        """\blimited\b""",
        """\bltd\b""",
        """\bgmbh\b""",
        """\bllc\b""",
        """\bplc\b""",
    )

    /**
     * Industry company names matched as whole words (#394): the brand layer.
     *
     * [funderNameStems] and [funderNameWords] recognise a company *form*; CrossRef and
     * PubMed often return a bare brand instead — "Pfizer", "The Pfizer company" — which no
     * form reaches. These are the companies of [KnownIndustryFunders] plus their most-named
     * subsidiaries (Janssen, Genentech), chosen from that curated list rather than from the
     * corpus. "Eli Lilly" only, never bare "Lilly" (the Lilly Endowment is a charity); UCB
     * is left out (also UC Berkeley). Pinned to `industry_brands.patterns` in
     * `sponsor_patterns.json`.
     */
    val funderBrandPatterns: List<String> = listOf(
        """\bpfizer\b""",
        """\bastra\s?zeneca\b""",
        """\bbayer\b""",
        """\bglaxo\s?smith\s?kline\b""",
        """\bgsk\b""",
        """\bjohnson\s*(?:&|and)\s*johnson\b""",
        """\beli\s+lilly\b""",
        """\bmerck\b""",
        """\bnovartis\b""",
        """\bnovo\s+nordisk\b""",
        """\broche\b""",
        """\bsanofi\b""",
        """\bgilead\b""",
        """\babbvie\b""",
        """\bcelgene\b""",
        """\bamgen\b""",
        """\bbristol[-\s]?myers[-\s]?squibb\b""",
        """\bbiogen\b""",
        """\bboehringer\b""",
        """\btakeda\b""",
        """\bregeneron\b""",
        """\bteva\b""",
        """\ballergan\b""",
        """\bmedtronic\b""",
        """\bboston\s+scientific\b""",
        """\babbott\b""",
        """\bjanssen\b""",
        """\bgenentech\b""",
    )

    /**
     * A brand beside one of these is a charitable foundation, not the company — the Novo
     * Nordisk Foundation, the Boehringer Ingelheim Fonds. Guards the brand layer only.
     * Pinned to `industry_brands.foundation_markers`.
     */
    val foundationMarkerPatterns: List<String> = listOf(
        """\b(?:foundation|fondation|fondazione|fundaci[oó]n|funda[cç][aã]o|stiftung|stiftelse|stichting|fond|fonden|fonds|endowment|charitable)\b""",
    )

    /**
     * Known government/public funder patterns — the "government" half of
     * `sponsor_patterns.json`. Tested before [academicPatterns], so one public
     * agency outranks any number of universities.
     */
    val governmentPatterns: List<String> = listOf(
        """\bnih\b""",
        """\bnational institutes? of health\b""",
        """\bniaid\b""",
        """\bnci\b""",
        """\bnhlbi\b""",
        """\bnimh\b""",
        """\bnsf\b""",
        """\bnational science foundation\b""",
        """\bcdc\b""",
        """\bcenters? for disease control\b""",
        """\bfda\b""",
        """\bfood and drug administration\b""",
        """\bva\b""",
        """\bveterans? (?:affairs|administration)\b""",
        """\bahrq\b""",
        """\bpcori\b""",
        """\bwellcome\b""",
        """\bmedical research council\b""",
    )

    /** Academic/institutional patterns — the "academic" half of `sponsor_patterns.json`. */
    val academicPatterns: List<String> = listOf(
        """\buniversit(?:y|ies)\b""",
        """\bcollege\b""",
        """\bhospital\b""",
        """\bmedical (?:center|school)\b""",
        """\bgovernment\b""",
        """\bfederal\b""",
        """\bstate\b""",
    )

    /** Government then academic patterns, in that order: what "not industry" means to a funder name. */
    val nonIndustryPatterns: List<String> = governmentPatterns + academicPatterns
}
