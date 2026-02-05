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
        Settings["Settings"]
    end

    subgraph QueryGeneration["Step 1: Query Generation"]
        QC["LiteQueryConverter - LLM"]
        QC -->|Extract concepts| Concepts["Key Concepts"]
        Concepts --> PubMedQ["PubMed Query String"]
        PubMedQ --> Fallback{Query valid?}
        Fallback -->|No| FallbackQ["Fallback Query"]
        Fallback -->|Yes| ValidQ["Valid Query"]
    end

    subgraph Search["Step 2: Literature Search"]
        SearchService["SearchService"]
        SearchService --> PubMed["PubMed API"]
        SearchService --> EPMC["Europe PMC API"]
        PubMed --> Results1["Results Set 1"]
        EPMC --> Results2["Results Set 2"]
        Results1 --> Dedup["Deduplication"]
        Results2 --> Dedup
        Dedup --> Documents["LiteDocuments + Embeddings"]
    end

    subgraph OptionalIncremental["Optional: Iterative Fetching"]
        IncrSearch["IncrementalSearchWorker"]
        IncrSearch -->|Batch fetch| MoreResults["Fetch More Results"]
        MoreResults --> FilterScored["Filter Already Scored"]
        FilterScored -->|Target not met| IncrSearch
        FilterScored -->|Done| NewDocs["New Documents"]
    end

    subgraph QualityFilter["Step 3: Quality Filtering"]
        QM["QualityManager"]
        QM --> Tier1["Tier 1: Metadata"]
        Tier1 -->|Inconclusive| Tier2["Tier 2: LLM Haiku"]
        Tier2 -->|Need detail| Tier3["Tier 3: LLM Sonnet"]
        Tier1 --> Filtered["Filtered Documents"]
        Tier2 --> Filtered
        Tier3 --> Filtered
    end

    subgraph Scoring["Step 4: Document Scoring"]
        SA["LiteScoringAgent - LLM"]
        SA -->|Per document| Score["Score 1-5 + Explanation"]
        Score --> Persist1[("Save to DB")]
        Score --> FilterMin{Score >= threshold?}
        FilterMin -->|Yes| Relevant["Relevant Documents"]
        FilterMin -->|No| Rejected["Rejected"]
    end

    subgraph Citation["Step 5: Citation Extraction"]
        CA["LiteCitationAgent - LLM"]
        CA -->|Per document| Extract["Extract Key Passages"]
        Extract --> Citations["Citations with context"]
        Citations --> Persist2[("Save to DB")]
    end

    subgraph Transparency["Step 6: Transparency Analysis"]
        TM["TransparencyManager"]
        TM --> Industry["Industry Sponsorship"]
        TM --> DataDisc["Data Disclosure"]
        TM --> TrialReg["Trial Registration"]
        TM --> Outcome["Outcome Reporting"]
        TM --> COI["COI Analysis"]
        Industry --> Risk["Risk Assessment"]
        DataDisc --> Risk
        TrialReg --> Risk
        Outcome --> Risk
        COI --> Risk
    end

    subgraph Report["Step 7: Report Generation"]
        RA["LiteReportingAgent - LLM"]
        RA --> Narrative["Synthesized Narrative"]
        Narrative --> Refs["References Section"]
        Refs --> Method["Methodology Section"]
        Method --> FinalReport["Final Markdown Report"]
    end

    subgraph Output["Output"]
        Display["Report Tab Display"]
        Checkpoint[("Checkpoint + Metadata")]
        AuditTrail["Audit Trail"]
    end

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
    Risk -.->|Enriches| FinalReport
    FinalReport --> Display
    FinalReport --> Checkpoint

    QC -.->|query_generated| AuditTrail
    Documents -.->|documents_found| AuditTrail
    Score -.->|document_scored| AuditTrail
    Citations -.->|citation_extracted| AuditTrail
    Risk -.->|analysis_complete| AuditTrail

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
        SelectQ["Select Past Question"]
        Target["Set Target New Docs"]
    end

    subgraph IncrementalSearch["IncrementalSearchWorker"]
        Init["Initialize with query and scored IDs"]

        Loop{New docs < target AND offset < max?}

        Fetch["Fetch Batch"]

        Filter["Filter Already Scored"]

        Emit["Emit batch_complete signal"]

        Offset["Increment offset"]

        Done["Emit finished with new docs"]
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
            CTGov["ClinicalTrials.gov Sponsor"]
            FunderMatch["Pharma Database Match"]
        end

        subgraph Data["Data Disclosure"]
            DAS["Availability Statement Parser"]
            Categories["Categories"]
        end

        subgraph Trial["Trial Registration"]
            NCT["NCT ID Extraction"]
            Results["Results Posted Check"]
            FDAAA["FDAAA 2007 Compliance"]
        end

        subgraph Outcomes["Outcome Analysis"]
            RegOutcomes["Registered Outcomes"]
            PubOutcomes["Published Outcomes"]
            Compare["Compare for Switching"]
        end

        subgraph COI["COI Detection"]
            Statement["COI Statement Parser"]
            Industry["Industry Relationships"]
            Financial["Financial Ties"]
        end
    end

    subgraph Output["TransparencyResult"]
        Risk["Risk: LOW/MODERATE/HIGH"]
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
        Query["PubMed Query with timestamp"]
        Session["SearchSession"]
    end

    subgraph Documents["2. Document Registry"]
        Doc["LiteDocument"]
        DocID["Unique ID: pmid-12345678"]
        DocMeta["Immutable Metadata"]
        Doc --> DocID
        Doc --> DocMeta
    end

    subgraph Scoring["3. Relevance Assessment"]
        ScoredDoc["ScoredDocument"]
        ScoreData["Score Record"]
        ScoredDoc --> ScoreData
    end

    subgraph Citations["4. Evidence Extraction"]
        Citation["Citation"]
        CitationData["Citation Record"]
        Citation --> CitationData
    end

    subgraph Report["5. Final Report"]
        Narrative["Report Narrative"]
        InlineCite["Inline Citation Links"]
        RefSection["References Section"]
        MethodSection["Methodology Section"]
    end

    subgraph Checkpoint["6. Checkpoint"]
        CP["Checkpoint Record"]
        CPData["Full Metadata JSON"]
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

    InlineCite -.->|Click to trace| DocMeta
    RefSection -.->|Links to| DocID

    classDef trace fill:#e3f2fd,stroke:#1565c0,stroke-width:2px
    classDef storage fill:#fff8e1,stroke:#f57f17
    class DocID,InlineCite,RefSection trace
    class Session,ScoreData,CitationData,CPData storage
```

**Provenance Data at Each Stage:**

| Stage | Key Fields |
|-------|------------|
| **SearchSession** | query_string, search_date, provider, total_available, duplicates_removed |
| **Document** | PMID, DOI, PMC ID, Title, Authors, Year, Journal |
| **ScoreData** | document_id, score (1-5), explanation, checkpoint_id, timestamp |
| **CitationData** | document_id, passage_text, relevance_score, context, checkpoint_id |
| **Checkpoint** | research_question, pubmed_query, created_at, completed_at, report_text, metadata |

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

    DOCUMENT ||--o{ SCORED_DOCUMENT : scores
    DOCUMENT ||--o{ CITATION : cites
    DOCUMENT {
        string id PK
        string pmid UK
        string doi UK
        string pmc_id UK
        string title
        text abstract
        json authors
        int year
        string journal
        string source
        datetime added_at
    }

    SCORED_DOCUMENT {
        string id PK
        string document_id FK
        string checkpoint_id FK
        int score
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
