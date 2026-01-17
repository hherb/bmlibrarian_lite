# Hybrid Search: PubMed + Europe PMC

This document describes the cross-platform algorithm for searching both PubMed and Europe PMC, handling pagination, and merging/deduplicating results.

## Overview

BMLibrarian searches two complementary biomedical literature databases:

1. **PubMed** (via NCBI E-utilities): The authoritative source for biomedical literature
2. **Europe PMC**: Aggregates PubMed plus additional sources, provides full-text XML

Searching both provides better coverage and enables full-text retrieval via Europe PMC.

## API Differences

| Aspect | PubMed | Europe PMC |
|--------|--------|------------|
| Base URL | `https://eutils.ncbi.nlm.nih.gov/entrez/eutils/` | `https://www.ebi.ac.uk/europepmc/webservices/rest/` |
| Pagination | Offset-based (`retstart`) | Cursor-based (`cursorMark`) |
| Max offset | 9999 | ~10,000 via cursor |
| Rate limit | 3/sec (10/sec with API key) | No official limit |
| API key | Optional but recommended | Not required |
| Full text | Not available | JATS XML for PMC articles |

## Query Translation

PubMed and Europe PMC use different query syntaxes. We need to translate queries between them.

### PubMed Query Syntax

```
# Field tags
covid-19[Title]
cancer[Title/Abstract]
"Smith J"[Author]
Nature[Journal]

# Boolean
diabetes AND treatment
cancer OR tumor
heart NOT failure

# Filters
humans[MeSH]
review[pt]  (publication type)
2020:2024[dp]  (date published)
```

### Europe PMC Query Syntax

```
# Field prefixes
TITLE:"covid-19"
TITLE_ABS:"cancer"
AUTH:"Smith J"
JOURNAL:"Nature"

# Boolean (uppercase)
diabetes AND treatment
cancer OR tumor
heart NOT failure

# Filters
HAS_ABSTRACT:Y
SRC:MED  (PubMed source)
SRC:PPR  (preprints)
NOT SRC:PPR  (exclude preprints)
FIRST_PDATE:[2020 TO 2024]
```

### Translation Algorithm

```pseudocode
function translate_pubmed_to_europepmc(pubmed_query: string) -> string:
    result = pubmed_query

    # Field tag translations
    replacements = {
        "[Title]": " AND TITLE:",
        "[Title/Abstract]": " AND TITLE_ABS:",
        "[Author]": " AND AUTH:",
        "[Journal]": " AND JOURNAL:",
        "[MeSH Terms]": " AND MESH:",
        "[pt]": " AND PUB_TYPE:",
    }

    for pattern, replacement in replacements:
        result = result.replace(pattern, replacement)

    # Date range translation
    # 2020:2024[dp] -> FIRST_PDATE:[2020 TO 2024]
    date_pattern = r'(\d{4}):(\d{4})\[dp\]'
    result = regex_replace(result, date_pattern,
                          'FIRST_PDATE:[$1 TO $2]')

    # Add standard filters
    if "HAS_ABSTRACT" not in result.upper():
        result += " AND HAS_ABSTRACT:Y"

    # Exclude preprints unless explicitly included
    if "SRC:PPR" not in result.upper():
        result += " NOT SRC:PPR"

    return result
```

**Important:** Quote terms containing spaces in Europe PMC queries:

```pseudocode
function quote_if_needed(term: string) -> string:
    if " " in term and not term.startswith('"'):
        return f'"{term}"'
    return term
```

## Pagination Strategies

### PubMed: Offset-Based

```pseudocode
class PubMedPagination:
    total_count: int = 0
    current_offset: int = 0
    batch_size: int = 100

    function has_more() -> bool:
        return current_offset < min(total_count, MAX_OFFSET)

    function next_batch() -> (offset: int, count: int):
        offset = current_offset
        count = min(batch_size, total_count - current_offset)
        current_offset += count
        return (offset, count)

# Usage
pagination = PubMedPagination()

# First request: get count
response = esearch(query, retmax=0, rettype="count")
pagination.total_count = response.count

# Fetch batches
while pagination.has_more():
    offset, count = pagination.next_batch()
    ids = esearch(query, retstart=offset, retmax=count)
    articles = efetch(ids)
    yield articles
```

**Constraint:** PubMed offset cannot exceed 9999. For result sets >10,000, use date windowing.

### Europe PMC: Cursor-Based

```pseudocode
class EuropePMCPagination:
    total_count: int = 0
    current_cursor: string = "*"
    next_cursor: string | null = null
    batch_size: int = 100

    function has_more() -> bool:
        return next_cursor is not null and next_cursor != current_cursor

    function advance(new_cursor: string):
        current_cursor = next_cursor
        next_cursor = new_cursor

# Usage
pagination = EuropePMCPagination()

# First request
response = search(query, cursorMark="*", pageSize=100)
pagination.total_count = response.hitCount
pagination.next_cursor = response.nextCursorMark

yield response.articles

# Subsequent requests
while pagination.has_more():
    response = search(query,
                     cursorMark=pagination.current_cursor,
                     pageSize=100)
    pagination.advance(response.nextCursorMark)
    yield response.articles
```

**Cursor termination:** The cursor is exhausted when `nextCursorMark` equals `cursorMark` or is null.

## Parallel Search Strategy

For best user experience, search both providers in parallel:

```pseudocode
async function hybrid_search(query: string, max_results: int) -> list[Article]:
    # Translate query for Europe PMC
    epmc_query = translate_pubmed_to_europepmc(query)

    # Launch parallel searches
    pubmed_task = async_search_pubmed(query, max_results)
    epmc_task = async_search_europepmc(epmc_query, max_results)

    # Wait for both (or use timeouts)
    pubmed_results, epmc_results = await gather(pubmed_task, epmc_task)

    # Merge and deduplicate
    merged = merge_results(pubmed_results, epmc_results)

    return merged
```

### Progressive Loading

For UI responsiveness, emit results as they arrive:

```pseudocode
async function hybrid_search_progressive(
    query: string,
    on_results: callback(list[Article]),
    on_complete: callback()
):
    seen_ids = set()

    async def process_pubmed():
        for batch in search_pubmed_batches(query):
            new_articles = dedupe_batch(batch, seen_ids)
            update_seen_ids(seen_ids, new_articles)
            on_results(new_articles)

    async def process_epmc():
        epmc_query = translate_pubmed_to_europepmc(query)
        for batch in search_europepmc_batches(epmc_query):
            new_articles = dedupe_batch(batch, seen_ids)
            update_seen_ids(seen_ids, new_articles)
            on_results(new_articles)

    await gather(process_pubmed(), process_epmc())
    on_complete()
```

## Deduplication Algorithm

Articles may appear in both result sets. Deduplicate using a priority chain:

### Deduplication Priority

1. **PMID match** - Most reliable identifier for PubMed articles
2. **DOI match** - Cross-provider identifier (case-insensitive)
3. **PMC ID match** - Reliable for open access articles
4. **Title similarity** - Fallback using Jaccard similarity

### Implementation

```pseudocode
const TITLE_SIMILARITY_THRESHOLD = 0.8

class SearchResultMerger:
    seen_pmids: set[string]
    seen_dois: set[string]  # lowercase
    seen_pmcids: set[string]
    seen_titles: list[string]  # lowercase, for fuzzy matching

    function is_duplicate(article: Article) -> (bool, index | null):
        # Check PMID
        if article.pmid and article.pmid in seen_pmids:
            return (true, find_by_pmid(article.pmid))

        # Check DOI (case-insensitive)
        if article.doi:
            doi_lower = article.doi.lower()
            if doi_lower in seen_dois:
                return (true, find_by_doi(doi_lower))

        # Check PMC ID
        if article.pmcid and article.pmcid in seen_pmcids:
            return (true, find_by_pmcid(article.pmcid))

        # Check title similarity
        if article.title:
            title_lower = article.title.lower()
            for i, seen_title in enumerate(seen_titles):
                if jaccard_similarity(title_lower, seen_title) >= TITLE_SIMILARITY_THRESHOLD:
                    return (true, i)

        return (false, null)

    function add_article(article: Article):
        if article.pmid:
            seen_pmids.add(article.pmid)
        if article.doi:
            seen_dois.add(article.doi.lower())
        if article.pmcid:
            seen_pmcids.add(article.pmcid)
        if article.title:
            seen_titles.append(article.title.lower())
```

### Title Similarity (Jaccard Index)

```pseudocode
const STOP_WORDS = {"a", "an", "the", "of", "in", "on", "for", "to",
                    "and", "or", "is", "are", "with"}
const MIN_WORD_LENGTH = 2

function jaccard_similarity(title1: string, title2: string) -> float:
    # Tokenize
    words1 = tokenize(title1)
    words2 = tokenize(title2)

    # Filter stop words and short words
    words1 = {w for w in words1 if w not in STOP_WORDS and len(w) > MIN_WORD_LENGTH}
    words2 = {w for w in words2 if w not in STOP_WORDS and len(w) > MIN_WORD_LENGTH}

    if not words1 or not words2:
        return 0.0

    intersection = words1 & words2
    union = words1 | words2

    return len(intersection) / len(union)

function tokenize(text: string) -> set[string]:
    # Simple whitespace tokenization
    # Could be enhanced with regex for punctuation handling
    return set(text.lower().split())
```

## Metadata Merging

When the same article is found in both sources, merge metadata to get the best of both:

```pseudocode
function merge_metadata(existing: Article, new: Article):
    # Add source
    existing.sources.add(new.source)

    # Fill missing identifiers
    if not existing.pmid and new.pmid:
        existing.pmid = new.pmid
    if not existing.pmcid and new.pmcid:
        existing.pmcid = new.pmcid
    if not existing.doi and new.doi:
        existing.doi = new.doi

    # Fill missing metadata
    if not existing.abstract and new.abstract:
        existing.abstract = new.abstract
    if not existing.authors and new.authors:
        existing.authors = new.authors
    if not existing.journal and new.journal:
        existing.journal = new.journal
    if not existing.year and new.year:
        existing.year = new.year

    # Merge MeSH terms (PubMed-only, but valuable)
    if new.mesh_terms:
        existing.mesh_terms = unique(existing.mesh_terms + new.mesh_terms)

    # Update flags
    existing.has_fulltext_xml = existing.has_fulltext_xml or new.has_fulltext_xml
```

## Error Handling

Both APIs can fail. Handle errors gracefully:

```pseudocode
async function resilient_hybrid_search(query: string) -> list[Article]:
    results = []
    errors = []

    try:
        pubmed_results = await search_pubmed(query)
        results.extend(pubmed_results)
    except PubMedError as e:
        errors.append(("PubMed", e))
        log.warning(f"PubMed search failed: {e}")

    try:
        epmc_results = await search_europepmc(query)
        results.extend(epmc_results)
    except EuropePMCError as e:
        errors.append(("Europe PMC", e))
        log.warning(f"Europe PMC search failed: {e}")

    if not results and errors:
        raise SearchError("All search providers failed", errors)

    return deduplicate(results)
```

### Retryable Errors

Implement exponential backoff for transient errors:

```pseudocode
const RETRYABLE_STATUS_CODES = {429, 500, 502, 503, 504}

function should_retry(error: Error) -> bool:
    if error is HTTPError:
        return error.status_code in RETRYABLE_STATUS_CODES
    if error is NetworkError:
        return true  # Connection errors are retryable
    return false

async function with_retry(operation: async func, max_retries: int = 3) -> Result:
    for attempt in range(max_retries):
        try:
            return await operation()
        except Error as e:
            if not should_retry(e) or attempt == max_retries - 1:
                raise
            delay = (2 ** attempt) * (1 + random() * 0.2)  # Exponential + jitter
            await sleep(delay)
```

## Configuration Constants

Define these constants in your platform's configuration:

```pseudocode
# API URLs
const PUBMED_SEARCH_URL = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi"
const PUBMED_FETCH_URL = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi"
const EUROPEPMC_SEARCH_URL = "https://www.ebi.ac.uk/europepmc/webservices/rest/search"

# Pagination
const PUBMED_BATCH_SIZE = 100
const EUROPEPMC_BATCH_SIZE = 100
const EUROPEPMC_INITIAL_CURSOR = "*"
const MAX_PUBMED_OFFSET = 9999

# Deduplication
const TITLE_SIMILARITY_THRESHOLD = 0.8
const MIN_WORD_LENGTH = 2

# Timeouts
const SEARCH_REQUEST_TIMEOUT_SECONDS = 30
const MAX_RETRIES = 3

# Europe PMC filters
const EUROPEPMC_DEFAULT_FILTERS = "HAS_ABSTRACT:Y NOT SRC:PPR"
```

## Platform-Specific Notes

### Python (Desktop)

- Use `requests` with `HTTPAdapter` for retry logic
- Use `concurrent.futures` for parallel searches
- See `src/bmlibrarian_lite/europepmc.py` and `search_merger.py`

### Swift (iOS/macOS)

- Use `async/await` with `TaskGroup` for parallel searches
- See `Packages/BioMedLit/Sources/BioMedLit/Services/EuropePMCService.swift`
- Use `SearchResultMerger` from the iOS/macOS utilities

### Kotlin (Android)

- Use Kotlin coroutines with `async`/`await` for parallel searches
- Use Retrofit for HTTP requests
- See `android/.../data/remote/europepmc/EuropePMCService.kt`

## Testing Considerations

1. **Mock both APIs** for unit tests
2. **Test deduplication** with articles having partial identifier overlap
3. **Test pagination** including edge cases (empty results, single page, cursor exhaustion)
4. **Test error recovery** when one provider fails
5. **Test query translation** with complex queries including dates and filters
