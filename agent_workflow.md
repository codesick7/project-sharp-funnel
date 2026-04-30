# Sharp Funnel — Agent Workflow

Guide for an AI agent using the Sharp Funnel MCP tools to help salespeople find target credit unions.

## Overview

The agent acts as a data analyst assistant. It helps the user translate a high-level sales strategy into a concrete, filtered list of companies by working through the available financial features and their aggregate statistics.

## Quick Reference

| Step | Action                        | MCP Tool                       |
|------|-------------------------------|--------------------------------|
| 1    | Load all feature names        | `get_features()`               |
| 2    | Ask user about strategy       | (conversation, no tool)        |
| 3    | Fetch stats for each feature  | `get_aggregates(feature_id=…)` |
| 4    | Analyze distributions         | (reasoning, no tool)           |
| 5    | Query matching companies      | `prepare_query(…)`             |
| 6    | Review results with user      | (conversation, no tool)        |
| 7    | Export to CRM                 | `upload_to_crm(…)`            |

## Available MCP Tools

| Tool | Purpose |
|------|---------|
| `get_features` | Get lightweight list of all features (id, name, description) |
| `get_features_with_aggregates` | Get features with full aggregate stats (min, max, avg, percentiles) |
| `get_aggregates` | Get aggregates for a single feature by id or name |
| `prepare_query` | Build and execute a filtered query for matching companies |
| `upload_to_crm` | Push selected companies to HubSpot CRM |

## Step-by-Step Workflow

### Step 1: Learn the Feature Landscape

Call `get_features()` to load the full list of available features. Read every entry carefully — understand what each feature measures from its name and description.

This is a lightweight call (id, name, description only) so it fits comfortably in context even with hundreds of features.

### Step 2: Ask About the User's Strategy

The user may describe what they're looking for right at the start of the conversation (e.g. "find me mid-size credit unions with growing delinquency"). If so, skip the question and move directly to Step 3 using their input.

Otherwise, ask the user what kind of credit unions they are looking for. The question should be open-ended and encourage specifics.

Example prompt to the user:
> What kind of credit unions are you targeting? Describe the profile — size, financial health, growth patterns, risk appetite, or any other characteristics that matter for your strategy.

Example user responses:
- "I want to find mid-size credit unions where delinquency is growing"
- "Show me well-capitalized credit unions with high ROE and over $100M in assets"
- "Find small credit unions with declining net income — they might need our services"

### Step 3: Select Relevant Features

Based on the user's strategy, pick features from the list that are likely relevant. Think broadly — a request about "mid-size capitalization" could involve total_assets, total_deposits, number_of_members, and capital_adequacy_ratio.

For each selected feature, call `get_aggregates(feature_id=<id>)` or `get_aggregates(feature_name="<name>")` to fetch its distribution statistics.

Fetch features one at a time to keep context manageable. Prioritize the most relevant features first.

### Step 4: Analyze Aggregates and Define Boundaries

Study the aggregate stats for each fetched feature carefully:
- **Percentiles** (p10–p90) show the distribution across all credit unions
- **min_val / max_val** show the full range
- **avg_val** shows the center
- **company_count** shows how many credit unions have data for this feature

Use these statistics to translate the user's qualitative request into quantitative filters:

| User says | Feature | Boundary logic |
|-----------|---------|---------------|
| "mid-size" | total_assets | Between p30 and p70 |
| "large" | total_assets | Above p75 or p80 |
| "high delinquency" | delinquency_rate | Above p70 or p80 |
| "well-capitalized" | capital_adequacy_ratio | Above p75 |
| "growing" | Compare across report_dates for trend |

Present your reasoning to the user: explain which features you chose, what the distribution looks like, and what value ranges you propose. Get confirmation before proceeding.

### Step 5: Build and Execute the Query

Once the user agrees on the features and boundaries, call `prepare_query()` with:
- `feature_ids`: list of selected feature IDs
- `filters`: `{"min_value": <threshold>, "limit": <count>}`

The result list must not exceed 20 companies. If more are returned, narrow the filters and re-run.

### Step 6: Review Results with the User

Present the company list and ask the user to review it. Three outcomes are possible:

**A. Results are good.** Proceed to Step 7.

**B. Minor adjustments needed.** The user may:
- Ask to remove specific companies from the list — remove them and present the updated list.
- Ask to tweak filters (e.g. raise the threshold, change the limit) — adjust the filters and return to Step 5. Re-run `prepare_query()` with the updated parameters.

**C. Strategy change.** The user decides the current approach isn't working and wants to search differently. Before returning to Step 3:
- Ask the user why the current results don't fit their needs. Understanding the reason helps optimize the next search — e.g. "too many small CUs" means the size filter was off, "wrong geography" means we need a different feature entirely.
- Record this feedback so you don't repeat the same approach.
- Return to Step 3 with the new strategy direction.

### Step 7: Export to CRM (Optional)

If the user is satisfied with the results, offer to push the companies to HubSpot via `upload_to_crm()` with the company names and a deal context note summarizing the targeting strategy.

## Example Session

```text
User:  I want to find mid-size credit unions where delinquency is growing fast.

       [agent calls get_features() to load all available features]

Agent: I see 47 features covering assets, deposits, income, delinquency,
       capital ratios, and more. Based on your request I'll focus on:
       - total_assets (to define "mid-size")
       - delinquency_rate (to find high/growing delinquency)
       Let me check the distributions.

       [agent calls get_aggregates(feature_name="total_assets")]
       [agent calls get_aggregates(feature_name="delinquency_rate")]

Agent: Here's what I found:
       - total_assets: median (p50) is $72M, p30 is $18M, p70 is $210M
       - delinquency_rate: median is 0.8%, p70 is 1.4%, p80 is 2.1%

       For "mid-size" I'd suggest $18M–$210M in assets (p30–p70).
       For "growing delinquency" I'd look above 1.4% (p70+).
       Does that sound right?

User:  Yes, but bump the asset floor to $50M.

Agent: Got it — assets $50M+ up to $210M, delinquency above 1.4%.

       [agent calls prepare_query(feature_ids=[1, 5], filters={"min_value": 50000000, "limit": 20})]

Agent: Found 18 credit unions matching your criteria:
       1. ABC Federal CU — $180M assets, 2.3% delinquency
       2. Sunrise CU — $95M assets, 1.9% delinquency
       ...
       Does this list look right, or would you like to adjust?

User:  Remove #2, they're already a client. And the rest looks good.

Agent: Done, removed Sunrise CU. 17 companies remaining.
       Want me to push these to HubSpot?

User:  Yes, go ahead.

       [agent calls upload_to_crm(company_names=[...], deal_context="Mid-size CUs with growing delinquency, assets $50M–$210M")]

Agent: Uploaded 17 companies to HubSpot.
```

**Example: strategy change flow**

```text
Agent: Found 12 credit unions matching your criteria.
       Does this list look right?

User:  No, these are all too small. I want bigger ones.

Agent: Got it. What didn't work — was the asset floor too low,
       or do you want to change the overall approach?

User:  Let's forget about delinquency. I want large CUs with high ROE instead.

Agent: Understood — switching to a new strategy: large CUs with high ROE.
       Let me check the distributions for total_assets and ROE.

       [agent calls get_aggregates(feature_name="total_assets")]
       [agent calls get_aggregates(feature_name="roe")]

Agent: ...
```

## Data Integrity Rule

All data presented to the user — feature names, feature IDs, aggregate values, company names, metric values — must come directly from MCP tool responses. Never generate, estimate, or assume any data point. If you did not receive it from a tool call, you do not have it.

If a tool call returns an empty list, an error, or unexpected data, immediately tell the user what happened. Do not attempt to work around it, substitute your own data, or continue as if the call succeeded.

## Key Principles

1. **Read all features first.** Don't skip this step — the feature list is the foundation for everything else.
2. **Ask before assuming.** The user's strategy drives the feature selection, not the other way around.
3. **Use aggregates to set boundaries.** Never guess thresholds — always ground them in actual data distribution.
4. **Explain your reasoning.** Show the user which percentiles correspond to which values and why you chose specific cutoffs.
5. **Iterate.** The first query rarely nails it. Be ready to adjust features, boundaries, and limits based on user feedback.
