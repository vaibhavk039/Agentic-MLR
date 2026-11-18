# Agentic MLR — AI-Powered Medical-Legal-Regulatory Review on Salesforce

An autonomous pre-screening system that evaluates promotional materials through three sequential AI agents — Medical, Legal, and Regulatory — before human review. Built on Salesforce with Groq-powered LLM inference, it delivers structured confidence scores and flagged issues directly on the submission record.

---

## Problem

MLR review committees face a bottleneck: every piece of promotional content (brochures, claims, digital ads) must be reviewed by Medical, Legal, and Regulatory experts before approval. This sequential, manual process is slow, inconsistent, and expensive. Low-quality submissions waste reviewers' time on obvious issues that an automated check could catch first.

---

## Solution

Agentic MLR automates the first pass. When a document is uploaded to a submission record, three AI agents run sequentially:

1. **Medical Agent** — checks clinical accuracy, balanced presentation of benefits and risks, and fair scientific characterization
2. **Legal Agent** — evaluates regulatory compliance language, disclaimer completeness, and liability exposure
3. **Regulatory Agent** — validates against label claims, substantiation requirements, and applicable regulatory guidelines

Each agent returns a **confidence score** (High / Medium / Low) with detailed flags and rationale. If any agent scores Low, downstream agents are halted — the submission is returned for revision before full review. Only High-confidence submissions advance to the human MLR committee.

---

## Architecture

```
Document Upload
      │
      ▼
┌─────────────────────────────────┐
│        MLR Submission Record     │
│    (mlrPreScreenButton LWC)     │
└──────────────┬──────────────────┘
               │
               ▼
     ┌─────────────────────┐
     │   Medical Agent     │  ← Groq LLM (openai/gpt-oss-120b)
     │   Confidence score  │    Knowledge: Medical guidelines KB
     └──────────┬──────────┘
                │ Low → HALT
                ▼ High/Medium
     ┌─────────────────────┐
     │    Legal Agent      │  ← Groq LLM (openai/gpt-oss-120b)
     │   Confidence score  │    Knowledge: Legal reference KB
     └──────────┬──────────┘
                │ Low → HALT
                ▼ High/Medium
     ┌─────────────────────┐
     │  Regulatory Agent   │  ← Groq LLM (openai/gpt-oss-120b)
     │   Confidence score  │    Knowledge: Regulatory reference KB
     └──────────┬──────────┘
                │
                ▼
     Agent Results displayed on
     Submission Record (LWC)
```

**Key design principles:**
- **Sequential gating**: each agent runs only if the previous passed — saves LLM calls and surfaces issues early
- **Async execution**: all LLM callouts run in an asynchronous Queueable job, keeping the UI responsive
- **Keyword fallback**: if the LLM is unavailable, a rules-based keyword engine provides a degraded-mode result
- **Retry logic**: for PDF/DOCX files that need text indexing time, the system automatically retries up to 3× before marking as failed

---

## Tech Stack

| Layer | Technology |
|---|---|
| Platform | Salesforce (Lightning Experience) |
| AI Agents | Salesforce Agentforce |
| LLM | Groq — `openai/gpt-oss-120b` (500 tokens/sec, 131K context) |
| Backend | Apex (Queueable, Schedulable, InvocableMethod) |
| Frontend | Lightning Web Components (LWC) |
| Knowledge grounding | Salesforce Knowledge / Custom Object KB |
| Integration | Salesforce Named Credential → Groq API |

---

## Salesforce Components

### Custom Objects

| Object | Purpose |
|---|---|
| `MLR_Submission__c` | The promotional material record — links to uploaded document, tracks overall status |
| `MLR_Agent_Result__c` | One result record per agent run — stores confidence, flags, and rationale |
| `MLR_Config__c` | Org-level configuration — LLM API key, model endpoint, retry settings |
| `MLR_Regulatory_Reference__c` | Knowledge base of regulatory guidelines used to ground agent prompts |

### Lightning Web Components

| Component | Purpose |
|---|---|
| `mlrPreScreenButton` | Main interaction component on the submission record — file upload, trigger scan, polling display |
| `mlrAgentResults` | Displays agent results with confidence badges, flags, and rationale |
| `mlrDashboard` | Portfolio view across all submissions — status breakdown, pipeline metrics |
| `mlrFileUpload` | Reusable file upload component with format validation |

---

## Setup & Deployment

### Prerequisites

- Salesforce org with **Files** and **Knowledge** enabled
- Salesforce CLI installed (`sf` v2+)
- A [Groq API key](https://console.groq.com) (free tier available)

### 1. Deploy Metadata

```bash
# Authenticate to your org
sf org login web --alias mlr-org

# Deploy all metadata
sf project deploy start --target-org mlr-org
```

### 2. Configure the Named Credential

After deployment, update the Named Credential in Setup:

1. Go to **Setup → Named Credentials → MLR_LLM_Service**
2. Confirm the endpoint is `https://api.groq.com`
3. No authentication is set at the Named Credential level — the API key is passed via the custom setting below

### 3. Set the API Key

Create a **MLR_Config__c** custom setting record (Manage → New) with:

| Field | Value |
|---|---|
| Name | `Default` |
| LLM_API_Key__c | Your Groq API key |
| LLM_Model__c | `openai/gpt-oss-120b` |

### 4. Seed Regulatory References

Populate `MLR_Regulatory_Reference__c` with the guidelines your agents should reference. At minimum, seed one record per agent type (Medical, Legal, Regulatory). These records ground the LLM prompts with org-specific compliance context.

### 5. Add the LWC to the Submission Page Layout

1. Open the **MLR_Submission__c** Lightning record page in App Builder
2. Drag `mlrPreScreenButton` and `mlrAgentResults` onto the page
3. Save and activate

---

## Demo Flow

1. Open an **MLR Submission** record
2. Use the **File Upload** area to attach a PDF, DOCX, or TXT promotional document
3. For the first upload, the scan starts automatically. For re-runs, click **Run Pre-Screener**
4. A progress indicator shows `Medical → Legal → Regulatory running…`
   - TXT files: ~30 seconds
   - PDF / DOCX: 2–4 minutes (text extraction + LLM processing)
5. Results appear below automatically — each agent card shows:
   - Confidence level (High / Medium / Low)
   - Flagged issues with descriptions
   - Rationale for the confidence score
6. If all three agents return High or Medium, the submission is ready for human MLR review

---

## Switching LLM Provider (Groq → Gemini)

The system uses an OpenAI-compatible API format, so switching providers requires only two changes:

**1. Update the Named Credential endpoint:**

| Provider | Endpoint |
|---|---|
| Groq (current) | `https://api.groq.com` |
| Gemini | `https://generativelanguage.googleapis.com` |

**2. Update the model and path in MLR_Config__c:**

| Provider | Callout Path | Model Name |
|---|---|---|
| Groq | `/openai/v1/chat/completions` | `openai/gpt-oss-120b` |
| Gemini | `/v1beta/openai/chat/completions` | `gemini-2.0-flash` or `gemini-2.5-pro` |

**Cost comparison:**

| Provider | Model | Input | Output |
|---|---|---|---|
| Groq | openai/gpt-oss-120b | $0.15 / 1M tokens | $0.60 / 1M tokens |
| Gemini | gemini-2.0-flash | $0.075 / 1M tokens | $0.30 / 1M tokens |
| Gemini | gemini-2.5-pro | $1.25 / 1M tokens | $10.00 / 1M tokens |

No code changes are required — only Named Credential and config updates.

---

## Known Limitations

- **Double-scan on first upload**: a Salesforce platform trigger and the LWC auto-start both fire simultaneously on the initial file attachment. This is transient — if the submission briefly shows `Failed`, refreshing the page and clicking **Run Pre-Screener** manually resolves it.
- **PDF text extraction delay**: large PDFs (>10 pages) may need 60–90 seconds for Salesforce to index the text before the agents can read it. The retry mechanism handles this automatically.
- **Org permissions**: the pre-screener runs in the context of the logged-in user. If submission records are owned by an integration user, running as a user without edit access will fail. Grant the running user at least Edit on `MLR_Agent_Result__c`.

---

## Repository Structure

```
force-app/main/default/
├── classes/           # Apex — orchestration, agents, confidence rollup, retry
├── lwc/               # Lightning Web Components — UI layer
├── objects/           # Custom object definitions
├── namedCredentials/  # MLR_LLM_Service (Groq endpoint)
├── customMetadata/    # (if applicable) reference data
└── triggers/          # ContentDocumentLink trigger for file-event handling
```

---

## License

Internal hackathon project — Deloitte NGT Hackathon 2026.
