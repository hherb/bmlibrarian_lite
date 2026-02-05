# Systematic Review Workflow

This document describes the complete workflow from user question input to final report generation, with emphasis on the **audit trail and reference provenance tracking** that ensures every claim in the final report can be traced back to its source.

## Key Design Principle: Full Provenance Chain

Every piece of evidence in the final report maintains a complete audit trail:

```
Research Question → PubMed Query → Document (PMID/DOI) → Score + Explanation → Extracted Passage → Report Citation
```

This chain is preserved in the database and exposed through real-time signals for transparency.

## Overview Diagram

```mermaid
flowchart TD
    subgraph UserInput["User Input"]
        Q[/"Research Question"/]
        Settings["Settings<br/>• Max results<br/>• Min score threshold<br/>• Quality filters<br/>• Transparency analysis"]
    end

    subgraph QueryGeneration["Step 1: Query Generation"]
        QC["LiteQueryConverter<br/>(LLM)"]
        QC -->|"Extract concepts"| Concepts["2-4 Key Concepts<br/>• MeSH terms<br/>• Keywords"]
        Concepts --> PubMedQ["PubMed Query String"]
        PubMedQ --> Fallback{Query valid?}
        Fallback -->|No| FallbackQ["Fallback Query<br/>(keyword extraction)"]
        Fallback -->|Yes| ValidQ["Valid Query"]
    end

    subgraph Search["Step 2: Literature Search"]
        SearchService["SearchService"]
        SearchService --> PubMed["PubMed API<br/>(E-utilities)"]
        SearchService --> EPMC["Europe PMC API<br/>(REST)"]
        PubMed --> Results1["Results Set 1"]
        EPMC --> Results2["Results Set 2"]
        Results1 --> Dedup["Deduplication<br/>(PMID/DOI/PMC/Title)"]
        Results2 --> Dedup
        Dedup --> Documents["LiteDocument[]<br/>+ Embeddings"]
    end

    subgraph OptionalIncremental["Optional: Iterative Result Fetching"]
        IncrSearch["IncrementalSearchWorker"]
        IncrSearch -->|"Batch fetch"| MoreResults["Fetch More Results<br/>(offset pagination)"]
        MoreResults --> FilterScored["Filter Already Scored"]
        FilterScored -->|"Target not met"| IncrSearch
        FilterScored -->|"Target met or exhausted"| NewDocs["New Documents"]
    end

    subgraph QualityFilter["Step 3: Quality Filtering (Optional)"]
        QM["QualityManager"]
        QM --> Tier1["Tier 1: Metadata Filter<br/>(free, instant)"]
        Tier1 -->|"Inconclusive"| Tier2["Tier 2: LLM Classification<br/>(Haiku - fast)"]
        Tier2 -->|"Need detail"| Tier3["Tier 3: Detailed Assessment<br/>(Sonnet)"]
        Tier1 --> Filtered["Filtered Documents"]
        Tier2 --> Filtered
        Tier3 --> Filtered
    end

    subgraph Scoring["Step 4: Document Scoring"]
        SA["LiteScoringAgent<br/>(LLM)"]
        SA -->|"Per document"| Score["Score 1-5<br/>+ Explanation"]
        Score --> Persist1[("Save to DB<br/>(crash-safe)")]
        Score --> FilterMin{"Score ≥<br/>threshold?"}
        FilterMin -->|Yes| Relevant["Relevant Documents"]
        FilterMin -->|No| Rejected["Rejected"]
    end

    subgraph Citation["Step 5: Citation Extraction"]
        CA["LiteCitationAgent<br/>(LLM)"]
        CA -->|"Per document"| Extract["Extract 1-3<br/>Key Passages"]
        Extract --> Citations["Citations[]<br/>• passage text<br/>• relevance score<br/>• context"]
        Citations --> Persist2[("Save to DB")]
    end

    subgraph Transparency["Step 6: Transparency Analysis (Background)"]
        TM["TransparencyManager"]
        TM --> Industry["Industry Sponsorship<br/>(CrossRef, ClinicalTrials.gov)"]
        TM --> DataDisc["Data Disclosure<br/>(availability statements)"]
        TM --> TrialReg["Trial Registration<br/>(FDAAA compliance)"]
        TM --> Outcome["Outcome Reporting<br/>(switching detection)"]
        TM --> COI["COI Analysis<br/>(financial ties)"]
        Industry --> Risk["Risk Assessment<br/>LOW/MODERATE/HIGH"]
        DataDisc --> Risk
        TrialReg --> Risk
        Outcome --> Risk
        COI --> Risk
    end

    subgraph Report["Step 7: Report Generation"]
        RA["LiteReportingAgent<br/>(LLM)"]
        RA --> Narrative["Synthesized Narrative<br/>• Thematic organization<br/>• Inline citations<br/>• Conflicting evidence"]
        Narrative --> Refs["References Section<br/>(numbered bibliography)"]
        Refs --> Method["Methodology Section<br/>• Search parameters<br/>• Score distribution<br/>• Models used<br/>• Timestamps"]
        Method --> FinalReport["Final Markdown Report"]
    end

    subgraph Output["Output"]
        Display["Report Tab Display"]
        Checkpoint[("Checkpoint<br/>+ Reproducibility<br/>Metadata")]
        AuditTrail["Audit Trail<br/>(real-time signals)"]
    end

    %% Main flow connections
    Q --> QC
    Settings --> SearchService
    ValidQ --> SearchService
    FallbackQ --> SearchService
    Documents --> QM
    Documents --> SA
    NewDocs --> SA
    Filtered --> SA
    Relevant --> CA
    Citations --> RA
    Risk -.->|"Enriches"| FinalReport
    FinalReport --> Display
    FinalReport --> Checkpoint

    %% Signal flow (dashed)
    QC -.->|"query_generated"| AuditTrail
    Documents -.->|"documents_found"| AuditTrail
    Score -.->|"document_scored"| AuditTrail
    Citations -.->|"citation_extracted"| AuditTrail
    Risk -.->|"analysis_complete"| AuditTrail

    %% Styling
    classDef llm fill:#e1f5fe,stroke:#01579b
    classDef storage fill:#fff3e0,stroke:#e65100
    classDef optional fill:#f3e5f5,stroke:#7b1fa2
    classDef input fill:#e8f5e9,stroke:#2e7d32
    classDef output fill:#fce4ec,stroke:#c2185b

    class QC,SA,CA,RA,Tier2,Tier3 llm
    class Persist1,Persist2,Checkpoint storage
    class OptionalIncremental,QualityFilter,Transparency optional
    class Q,Settings input
    class Display,FinalReport,AuditTrail output
```

## Detailed Component Interactions

```mermaid
sequenceDiagram
    participant U as User
    participant GUI as SystematicReviewTab
    participant WW as WorkflowWorker
    participant QC as QueryConverter
    participant SS as SearchService
    participant QM as QualityManager
    participant SA as ScoringAgent
    participant CA as CitationAgent
    participant TM as TransparencyManager
    participant RA as ReportingAgent
    participant DB as Storage

    U->>GUI: Enter question + settings
    GUI->>WW: Start workflow (background thread)

    Note over WW: Step 1: Query Generation
    WW->>QC: convert(question)
    QC->>QC: LLM extracts concepts
    QC-->>WW: PubMedQuery
    WW-->>GUI: query_generated signal

    Note over WW: Step 2: Search
    WW->>SS: search(query, max_results)
    SS->>SS: Search PubMed + Europe PMC
    SS->>SS: Deduplicate results
    SS-->>WW: SearchSession + Documents[]
    WW->>DB: add_documents(docs, embeddings)
    WW-->>GUI: documents_found signal

    Note over WW: Step 3: Quality Filter (optional)
    opt Quality filtering enabled
        WW->>QM: filter_documents(docs, filter)
        loop Each document
            QM->>QM: Tier 1: Metadata
            opt Inconclusive
                QM->>QM: Tier 2: LLM (Haiku)
            end
            QM-->>WW: QualityAssessment
            WW-->>GUI: quality_assessed signal
        end
        QM-->>WW: Filtered documents
    end

    Note over WW: Step 4: Scoring
    WW->>DB: create_checkpoint()
    loop Each document
        WW->>SA: score_document(question, doc)
        SA->>SA: LLM scores relevance 1-5
        SA-->>WW: ScoredDocument
        WW->>DB: save_scored_document()
        WW-->>GUI: document_scored signal
    end

    Note over WW: Step 5: Citation Extraction
    loop Each relevant document
        WW->>CA: extract_citations(question, doc)
        CA->>CA: LLM extracts passages
        CA-->>WW: Citations[]
        WW->>DB: save_citation()
        WW-->>GUI: citation_extracted signal
    end

    Note over WW: Step 6: Report Generation
    WW->>RA: generate_report(question, citations, metadata)
    RA->>RA: LLM synthesizes narrative
    RA-->>WW: Markdown report
    WW->>DB: update_checkpoint(report)

    Note over GUI: Background: Transparency Analysis
    par Transparency runs in parallel
        GUI->>TM: analyze_documents(docs)
        loop Each document (concurrent)
            TM->>TM: Check industry funding
            TM->>TM: Assess data disclosure
            TM->>TM: Verify trial registration
            TM->>TM: Detect outcome switching
            TM->>TM: Parse COI statements
            TM-->>GUI: analysis_complete signal
        end
    end

    WW-->>GUI: finished(report, metadata)
    GUI-->>U: Display report + audit trail
```

## Iterative Result Fetching Flow

```mermaid
flowchart TD
    subgraph Trigger["Trigger: Re-run Search"]
        SelectQ["Select Past Question<br/>(ResearchQuestionsTab)"]
        Target["Set Target:<br/>New Documents to Find"]
    end

    subgraph IncrementalSearch["IncrementalSearchWorker"]
        Init["Initialize<br/>• Existing PubMed query<br/>• Already scored IDs<br/>• Target count"]

        Loop{"New docs < target<br/>AND offset < max?"}

        Fetch["Fetch Batch<br/>(INCREMENTAL_SEARCH_BATCH_SIZE)"]

        Filter["Filter Out<br/>Already Scored"]

        Emit["Emit batch_complete<br/>signal"]

        Offset["Increment offset"]

        Done["Emit finished<br/>with all new docs"]
    end

    subgraph Processing["Continue Workflow"]
        Score["Score New Documents"]
        Extract["Extract Citations"]
        Update["Update Report"]
    end

    SelectQ --> Init
    Target --> Init
    Init --> Loop
    Loop -->|Yes| Fetch
    Fetch --> Filter
    Filter --> Emit
    Emit --> Offset
    Offset --> Loop
    Loop -->|No| Done
    Done --> Score
    Score --> Extract
    Extract --> Update
```

## Quality Filter Decision Tree

```mermaid
flowchart TD
    Start["Document"] --> Check{"Quality<br/>filter<br/>enabled?"}

    Check -->|No| Pass["Pass to Scoring"]
    Check -->|Yes| Tier1["Tier 1: Metadata Analysis"]

    Tier1 --> Meta{"Publication type<br/>Journal rank<br/>Study indicators"}

    Meta -->|"Clear result"| T1Decision{"Meets<br/>minimum<br/>tier?"}
    Meta -->|"Inconclusive"| Tier2["Tier 2: LLM Classification<br/>(Haiku)"]

    Tier2 --> LLM1{"Study design<br/>classification"}

    LLM1 -->|"Clear result"| T2Decision{"Meets<br/>criteria?"}
    LLM1 -->|"Need detail"| Tier3["Tier 3: Detailed Assessment<br/>(Sonnet)"]

    Tier3 --> LLM2{"Comprehensive<br/>evaluation"}

    LLM2 --> T3Decision{"Meets all<br/>requirements?"}

    T1Decision -->|Yes| Pass
    T1Decision -->|No| Reject["Reject Document"]

    T2Decision -->|Yes| Pass
    T2Decision -->|No| Reject

    T3Decision -->|Yes| Pass
    T3Decision -->|No| Reject

    subgraph Criteria["Filter Criteria"]
        C1["minimum_tier"]
        C2["require_randomization"]
        C3["require_blinding"]
        C4["minimum_sample_size"]
    end
```

## Transparency Analysis Components

```mermaid
flowchart LR
    subgraph Input["Document Metadata"]
        DOI["DOI"]
        PMID["PMID"]
        Title["Title/Abstract"]
    end

    subgraph Analysis["StudyTransparencyAnalyzer"]
        subgraph Funding["Industry Sponsorship"]
            CrossRef["CrossRef Funder API"]
            CTGov["ClinicalTrials.gov<br/>Sponsor Class"]
            FunderMatch["Match against<br/>pharma database"]
        end

        subgraph Data["Data Disclosure"]
            DAS["Data Availability<br/>Statement Parser"]
            Categories["Categories:<br/>• full_open<br/>• on_request<br/>• restricted<br/>• not_available<br/>• not_stated"]
        end

        subgraph Trial["Trial Registration"]
            NCT["NCT ID Extraction"]
            Results["Results Posted<br/>Check"]
            FDAAA["FDAAA 2007<br/>Compliance"]
        end

        subgraph Outcomes["Outcome Analysis"]
            RegOutcomes["Registered<br/>Outcomes"]
            PubOutcomes["Published<br/>Outcomes"]
            Compare["Compare for<br/>Switching"]
        end

        subgraph COI["COI Detection"]
            Statement["COI Statement<br/>Parser"]
            Industry["Industry<br/>Relationships"]
            Financial["Financial<br/>Ties"]
        end
    end

    subgraph Output["TransparencyResult"]
        Risk["Overall Risk<br/>LOW/MODERATE/HIGH"]
        Details["Detailed Findings"]
        Confidence["Confidence Score"]
    end

    DOI --> CrossRef
    DOI --> DAS
    PMID --> NCT
    PMID --> Statement
    Title --> FunderMatch

    CrossRef --> Risk
    Categories --> Risk
    FDAAA --> Risk
    Compare --> Risk
    Financial --> Risk
```

## Audit Trail & Reference Provenance

The system maintains complete traceability from every claim in the final report back to its original source document. This is critical for scientific reproducibility and verification.

### Provenance Chain Diagram

```mermaid
flowchart TB
    subgraph Sources["1. Source Identification"]
        Query["PubMed Query<br/><i>Stored with timestamp</i>"]
        Session["SearchSession<br/>• query_string<br/>• search_date<br/>• provider<br/>• total_available<br/>• duplicates_removed"]
    end

    subgraph Documents["2. Document Registry"]
        Doc["LiteDocument"]
        DocID["Unique ID<br/><code>pmid-12345678</code>"]
        DocMeta["Immutable Metadata<br/>• PMID<br/>• DOI<br/>• PMC ID<br/>• Title<br/>• Authors<br/>• Year<br/>• Journal"]
        Doc --> DocID
        Doc --> DocMeta
    end

    subgraph Scoring["3. Relevance Assessment"]
        ScoredDoc["ScoredDocument"]
        ScoreData["Score Record<br/>• document_id → Doc<br/>• score (1-5)<br/>• explanation<br/>• checkpoint_id<br/>• timestamp"]
        ScoredDoc --> ScoreData
    end

    subgraph Citations["4. Evidence Extraction"]
        Citation["Citation"]
        CitationData["Citation Record<br/>• document_id → Doc<br/>• passage_text<br/>• relevance_score<br/>• context<br/>• checkpoint_id"]
        Citation --> CitationData
    end

    subgraph Report["5. Final Report"]
        Narrative["Report Narrative"]
        InlineCite["Inline Citation<br/><code>[Author, Year](docid:pmid-12345678)</code>"]
        RefSection["References Section<br/>1. Author et al. (Year). Title.<br/>   Journal. DOI: xxx PMID: yyy"]
        MethodSection["Methodology Section<br/>• Original question<br/>• Exact PubMed query<br/>• Search date<br/>• Scoring parameters<br/>• Model versions"]
    end

    subgraph Checkpoint["6. Checkpoint (Reproducibility)"]
        CP["Checkpoint Record"]
        CPData["• research_question<br/>• pubmed_query<br/>• created_at<br/>• completed_at<br/>• step (complete)<br/>• report_text<br/>• metadata JSON"]
    end

    Query --> Session
    Session --> Doc
    Doc --> ScoredDoc
    ScoredDoc --> Citation
    Citation --> Narrative
    Narrative --> InlineCite
    InlineCite --> RefSection
    RefSection --> MethodSection
    MethodSection --> CP
    CP --> CPData

    %% Bidirectional trace
    InlineCite -.->|"Click to trace"| DocMeta
    RefSection -.->|"Links to"| DocID

    classDef trace fill:#e3f2fd,stroke:#1565c0,stroke-width:2px
    classDef storage fill:#fff8e1,stroke:#f57f17
    class DocID,InlineCite,RefSection trace
    class Session,ScoreData,CitationData,CPData storage
```

### Citation Format in Reports

The report uses a special citation format that preserves document traceability:

```markdown
According to Smith et al., the treatment showed significant improvement
in patient outcomes [Smith, 2023](docid:pmid-12345678), which was
corroborated by a larger trial [Jones, 2024](docid:pmid-87654321).
```

The `docid:` prefix creates clickable links that navigate to the source document, allowing readers to:
1. View the original abstract
2. See the relevance score and explanation
3. Access the extracted passages
4. Link to PubMed/DOI for full text

### Audit Trail Signals

Real-time signals provide visibility into every step:

```mermaid
sequenceDiagram
    participant WW as WorkflowWorker
    participant DB as Storage
    participant AT as AuditTrailTab
    participant User as User Interface

    Note over WW,User: Every action is logged with full context

    WW->>DB: create_checkpoint(question)
    DB-->>WW: checkpoint_id
    WW-->>AT: workflow_started

    WW->>DB: save_query(pubmed_query)
    WW-->>AT: query_generated(pubmed_query, nl_query)
    AT-->>User: Display: "Query: optic nerve[MeSH]..."

    loop Each document found
        WW->>DB: add_document(doc, embedding)
        WW-->>AT: document_found(doc_id, title, source)
    end
    AT-->>User: Display: "Found 47 documents"

    loop Each document scored
        WW->>DB: save_scored_document(doc, score, explanation, checkpoint_id)
        WW-->>AT: document_scored(doc_id, score, explanation)
        AT-->>User: Display: "Scored pmid-123: 4/5 - Directly relevant..."
    end

    loop Each citation extracted
        WW->>DB: save_citation(citation, checkpoint_id)
        WW-->>AT: citation_extracted(doc_id, passage)
        AT-->>User: Display: "Extracted from pmid-123: 'The mean diameter...'"
    end

    WW->>DB: update_checkpoint(report, metadata)
    WW-->>AT: workflow_finished
    AT-->>User: Display: Complete audit log with timestamps
```

### Database Schema for Provenance

```mermaid
erDiagram
    CHECKPOINT ||--o{ SCORED_DOCUMENT : contains
    CHECKPOINT ||--o{ CITATION : contains
    CHECKPOINT {
        string id PK
        string research_question
        string pubmed_query
        datetime created_at
        datetime completed_at
        string step
        text report
        json metadata
    }

    DOCUMENT ||--o{ SCORED_DOCUMENT : "scored as"
    DOCUMENT ||--o{ CITATION : "cited in"
    DOCUMENT {
        string id PK "pmid-xxxxx"
        string pmid UK
        string doi UK
        string pmc_id UK
        string title
        text abstract
        json authors
        int year
        string journal
        string source "PUBMED|EUROPEPMC"
        datetime added_at
    }

    SCORED_DOCUMENT {
        string id PK
        string document_id FK
        string checkpoint_id FK
        int score "1-5"
        text explanation
        datetime scored_at
    }

    CITATION {
        string id PK
        string document_id FK
        string checkpoint_id FK
        text passage
        float relevance_score
        text context
        datetime extracted_at
    }

    SEARCH_SESSION ||--o{ DOCUMENT : discovers
    SEARCH_SESSION {
        string id PK
        string query_string
        datetime search_date
        string provider
        int total_available
        int retrieved
        int duplicates_removed
    }
```

### Methodology Section Auto-Generation

The final report includes a comprehensive methodology section that documents exactly how the review was conducted:

```markdown
## Methodology

### Search Strategy
- **Research Question:** What is the efficacy of drug X for condition Y?
- **PubMed Query:** `"drug X"[MeSH] AND "condition Y"[MeSH] AND hasabstract`
- **Search Date:** 2024-01-15 14:32:07 UTC
- **Databases:** PubMed, Europe PMC (deduplicated)

### Results
- **Total Available:** 1,247 articles
- **Retrieved:** 100 articles
- **After Deduplication:** 98 unique articles
- **Quality Filtered:** 72 articles (RCTs and systematic reviews only)

### Relevance Scoring
- **Scoring Threshold:** ≥ 3/5
- **Accepted:** 34 articles
- **Rejected:** 64 articles

| Score | Count | Percentage |
|-------|-------|------------|
| 5     | 8     | 8.2%       |
| 4     | 12    | 12.2%      |
| 3     | 14    | 14.3%      |
| 2     | 28    | 28.6%      |
| 1     | 36    | 36.7%      |

### AI Models Used
| Task | Provider | Model | Temperature |
|------|----------|-------|-------------|
| Query Conversion | Anthropic | claude-3-haiku | 0.1 |
| Document Scoring | Anthropic | claude-3-haiku | 0.1 |
| Citation Extraction | Anthropic | claude-3-haiku | 0.1 |
| Report Generation | Anthropic | claude-3-sonnet | 0.3 |

### Citations
- **Total Passages Extracted:** 87
- **From Unique Documents:** 34

---
*Generated: 2024-01-15 14:45:23 UTC*
*BMLibrarian Lite v1.2.0*
```

### Traceability Features

| Feature | Purpose | Implementation |
|---------|---------|----------------|
| **Document IDs** | Unique identification | `pmid-{pmid}` or `doi-{doi}` format |
| **Inline Citations** | Click-to-source in report | `[Author, Year](docid:ID)` markdown links |
| **Checkpoint System** | Reproducibility | Full state saved at each workflow completion |
| **Real-time Signals** | Live audit trail | Qt signals to AuditTrailTab |
| **Methodology Section** | Search documentation | Auto-generated with exact parameters |
| **Score Explanations** | Decision transparency | LLM explains each relevance judgment |
| **Crash Recovery** | No lost work | Per-document persistence to SQLite |
