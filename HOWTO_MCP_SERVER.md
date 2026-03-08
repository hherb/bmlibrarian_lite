# BMLibrarian Lite MCP Server

BMLibrarian Lite exposes its biomedical literature research capabilities as an
[MCP (Model Context Protocol)](https://modelcontextprotocol.io/) server. Any
MCP-compatible client — Claude Desktop, Claude Code, custom agents, or your own
application — can use it as an expert medical fact-checker backed by PubMed and
Europe PMC.

## Prerequisites

- Python 3.12+
- [uv](https://docs.astral.sh/uv/) (recommended) or pip
- An Anthropic API key (or a running Ollama instance)

## Installation

### System-wide install (recommended)

Install as a uv tool so `bmlibrarian-lite-mcp` is available globally without
activating a virtual environment:

```bash
uv tool install bmlibrarian-lite            # from PyPI (when published)
uv tool install /path/to/bmlibrarian_lite   # from local checkout
```

This places the `bmlibrarian-lite-mcp` command in `~/.local/bin/`, which uv
automatically adds to your PATH. No venv activation or path juggling required.

To update later:

```bash
uv tool upgrade bmlibrarian-lite
```

### Development install

If you are working on the source code:

```bash
# From the repository root
uv venv && source .venv/bin/activate
uv pip install -e ".[dev]"
```

In this case, `bmlibrarian-lite-mcp` is only available while the venv is
active (or via its full path at `.venv/bin/bmlibrarian-lite-mcp`).

## Configuration

The MCP server reuses BMLibrarian Lite's existing configuration at
`~/.bmlibrarian_lite/config.json`. If you have already used the desktop app,
no extra setup is needed.

At minimum, set the `ANTHROPIC_API_KEY` environment variable:

```bash
export ANTHROPIC_API_KEY="sk-ant-..."
```

Optional environment variables:

| Variable | Purpose |
|----------|---------|
| `ANTHROPIC_API_KEY` | Claude API key (required for Anthropic provider) |
| `OLLAMA_HOST` | Ollama URL (default: `localhost:11434`) |
| `NCBI_EMAIL` | Your email for PubMed API (recommended, improves rate limits) |

## Starting the Server

```bash
bmlibrarian-lite-mcp
```

This launches the MCP server on **stdio transport** (stdin/stdout). It is
designed to be started by an MCP client, not run interactively.

## Connecting from MCP Clients

### Claude Desktop

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`
(macOS) or the equivalent on your platform:

```json
{
  "mcpServers": {
    "bmlibrarian": {
      "command": "bmlibrarian-lite-mcp"
    }
  }
}
```

If you used `uv tool install`, this just works. If you installed in a venv
instead, use the full path: `.venv/bin/bmlibrarian-lite-mcp`.

Restart Claude Desktop. You will see the BMLibrarian tools in the tools menu.

### Claude Code

Add to your project's `.mcp.json` or global `~/.claude/mcp.json`:

```json
{
  "mcpServers": {
    "bmlibrarian": {
      "command": "bmlibrarian-lite-mcp"
    }
  }
}
```

### Custom Python Client

Use the MCP Python SDK to connect programmatically:

```python
import asyncio
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

async def main():
    server_params = StdioServerParameters(
        command="bmlibrarian-lite-mcp",
    )

    async with stdio_client(server_params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()

            # List available tools
            tools = await session.list_tools()
            for tool in tools.tools:
                print(f"  {tool.name}: {tool.description[:60]}...")

            # Fact-check a medical claim
            result = await session.call_tool(
                "fact_check_claim",
                arguments={"claim": "Metformin reduces mortality in CKD patients"},
            )
            print(result.content[0].text)

asyncio.run(main())
```

## Available Tools

### `fact_check_claim`

The primary tool. Runs the full evidence pipeline: literature search, relevance
scoring, citation extraction, and report generation.

**Parameters:**

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `claim` | string | *(required)* | Medical claim or research question |
| `max_results` | integer | 20 | Maximum articles to retrieve (5-100) |
| `min_score` | integer | 3 | Minimum relevance score 1-5 to include |
| `search_provider` | string | `"pubmed"` | `"pubmed"`, `"europepmc"`, or `"both"` |
| `include_preprints` | boolean | false | Include preprints (Europe PMC only) |

**Response:**

```json
{
  "report": "# Evidence Report\n\nA 2024 randomised trial by Smith et al. ...",
  "search_query": "(metformin) AND (chronic kidney disease OR CKD) AND (mortality)",
  "documents_found": 20,
  "documents_relevant": 8,
  "citations_extracted": 15,
  "sources": [
    {
      "title": "Metformin and Kidney Outcomes...",
      "authors": "Smith J, Doe A",
      "year": 2024,
      "journal": "NEJM",
      "doi": "10.1056/NEJMoa2401234",
      "pmid": "39521399",
      "pmc_id": "PMC12101959",
      "score": 5,
      "explanation": "Directly answers the question with RCT evidence.",
      "document_id": "pmid-39521399"
    }
  ]
}
```

**Note:** This is a long-running operation (1-5 minutes) because it makes
multiple LLM calls to score each document and extract citations.

---

### `search_literature`

Searches PubMed and/or Europe PMC for articles matching a research question.
Returns metadata only — no scoring or analysis. Fast (a few seconds).

**Parameters:**

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `query` | string | *(required)* | Research question or search terms |
| `max_results` | integer | 20 | Maximum results (5-100) |
| `search_provider` | string | `"pubmed"` | `"pubmed"`, `"europepmc"`, or `"both"` |
| `include_preprints` | boolean | false | Include preprints (Europe PMC only) |

**Response:**

```json
{
  "search_query": "(metformin) AND (CKD OR chronic kidney disease)",
  "total_results": 20,
  "documents": [
    {
      "id": "pmid-39521399",
      "title": "Stopping Versus Continuing Metformin...",
      "abstract": "Despite a lack of supporting evidence...",
      "authors": ["Lambourg EJ", "Fu EL"],
      "year": 2025,
      "journal": "American Journal of Kidney Diseases",
      "doi": "10.1053/j.ajkd.2024.08.012",
      "pmid": "39521399",
      "pmc_id": "PMC12101959",
      "source": "pubmed",
      "is_preprint": false
    }
  ]
}
```

---

### `get_document_fulltext`

Retrieves the full text of an article. Tries multiple sources in order:
Europe PMC XML (best quality) → cached PDFs → PDF download via Unpaywall.
Returns markdown-formatted content.

Also automatically loads the document for subsequent `ask_document` calls.

**Parameters** (at least one required):

| Name | Type | Description |
|------|------|-------------|
| `pmid` | string | PubMed ID, e.g. `"39521399"` |
| `doi` | string | DOI, e.g. `"10.1053/j.ajkd.2024.08.012"` |
| `pmc_id` | string | PubMed Central ID, e.g. `"PMC12101959"` |

**Response (success):**

```json
{
  "success": true,
  "source": "europepmc_xml",
  "document_id": "pmid-39521399",
  "content_length": 45230,
  "content": "# Stopping Versus Continuing Metformin...\n\n## Abstract\n..."
}
```

**Response (not available):**

```json
{
  "success": false,
  "source": "not_found",
  "error": "Full text not available for this article."
}
```

---

### `ask_document`

Ask a question about a specific article using retrieval-augmented generation
(RAG). The document must first be loaded via `get_document_fulltext`.

The agent chunks the document, retrieves the most relevant passages via
semantic search, and generates an answer grounded in the actual text.

**Parameters:**

| Name | Type | Description |
|------|------|-------------|
| `question` | string | Question about the document |
| `document_id` | string | Document ID from `get_document_fulltext` or `fact_check_claim` |

**Response:**

```json
{
  "answer": "The study found that discontinuing metformin in patients with...",
  "document_id": "pmid-39521399",
  "source_passages": [
    "In the intention-to-treat analysis, discontinuation of metformin...",
    "The primary endpoint of all-cause mortality occurred in 12.3%..."
  ]
}
```

## Typical Workflows

### Workflow 1: Quick Fact-Check

Use `fact_check_claim` for a one-shot evidence report:

```
User → "Is ivermectin effective against COVID-19?"
LLM  → calls fact_check_claim(claim="Is ivermectin effective against COVID-19?")
LLM  ← receives report with cited evidence from RCTs and meta-analyses
LLM  → presents synthesised answer to user
```

### Workflow 2: Explore, Then Deep-Dive

Use `search_literature` to find articles, then `get_document_fulltext` +
`ask_document` to interrogate specific papers:

```
1. search_literature(query="SGLT2 inhibitors heart failure outcomes")
   → browse results, pick interesting articles

2. get_document_fulltext(pmid="38992869")
   → loads full text, returns markdown

3. ask_document(question="What was the primary endpoint?", document_id="pmid-38992869")
   → grounded answer from the paper

4. ask_document(question="Were there any safety concerns?", document_id="pmid-38992869")
   → follow-up question on same paper
```

### Workflow 3: Comparative Analysis

Search both databases and include preprints for maximum coverage:

```
fact_check_claim(
    claim="What is the current evidence for GLP-1 agonists in NASH/MAFLD?",
    search_provider="both",
    include_preprints=true,
    max_results=50
)
```

## Error Handling

All errors are returned as JSON — the server never crashes. Error responses
have this shape:

```json
{
  "error": "Description of what went wrong",
  "error_type": "NetworkError"
}
```

Common error types:

| Error Type | Meaning |
|------------|---------|
| `NetworkError` | PubMed/Europe PMC API unreachable |
| `LLMError` | LLM provider returned an error |
| `ConfigurationError` | Missing API key or invalid config |
| `LiteStorageError` | Database issue |

## Performance Considerations

| Tool | Typical Duration | LLM Calls |
|------|-----------------|-----------|
| `search_literature` | 2-10 seconds | 1 (query conversion) |
| `get_document_fulltext` | 1-15 seconds | 0 |
| `ask_document` | 5-15 seconds | 1-2 (query expansion + answer) |
| `fact_check_claim` (20 docs) | 1-5 minutes | ~45 (1 query + 20 score + 20 cite + 1 report) |

To reduce `fact_check_claim` duration:
- Lower `max_results` (e.g. 10 instead of 20)
- Raise `min_score` (e.g. 4 instead of 3) to skip marginal articles
- Use Ollama with a fast local model for scoring tasks

## LLM Provider Configuration

The server uses the same LLM configuration as the desktop app. Edit
`~/.bmlibrarian_lite/config.json` to change providers or models:

```json
{
  "models": {
    "default_provider": "anthropic",
    "default_model": "claude-sonnet-4-20250514",
    "task_overrides": {
      "document_scoring": {
        "provider": "anthropic",
        "model": "claude-haiku-4-5-20251001"
      },
      "citation_extraction": {
        "provider": "anthropic",
        "model": "claude-haiku-4-5-20251001"
      }
    }
  }
}
```

Using a faster/cheaper model (like Haiku) for scoring and citation extraction
significantly reduces cost and latency for `fact_check_claim`, since those
steps run once per document.

## Troubleshooting

**Server won't start:**
If you used `uv tool install`, run `uv tool list` to confirm it's installed.
If you installed in a venv instead, either activate it first or use the full
path (e.g. `.venv/bin/bmlibrarian-lite-mcp`).

**"ConfigurationError: Missing API key":**
Set `ANTHROPIC_API_KEY` in the environment where the MCP client launches the
server. For Claude Desktop, use the `env` key in config:

```json
{
  "mcpServers": {
    "bmlibrarian": {
      "command": "bmlibrarian-lite-mcp",
      "env": {
        "ANTHROPIC_API_KEY": "sk-ant-..."
      }
    }
  }
}
```

**Tools are slow:**
See [Performance Considerations](#performance-considerations) above. The
`fact_check_claim` tool makes many LLM calls. Consider using cheaper models
for scoring/citation tasks.

**"Full text not available":**
Not all articles have open-access full text. The tool tries Europe PMC XML,
PDFs, and Unpaywall in order. For paywalled articles, only the abstract is
available via `search_literature`.

## License

BMLibrarian Lite is licensed under the
[GNU Affero General Public License v3](https://www.gnu.org/licenses/agpl-3.0.html).
