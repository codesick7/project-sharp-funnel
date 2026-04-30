import httpx
import json
from mcp.server.fastmcp import FastMCP

POSTGREST_URL = "http://host.wordguess.lol:3000"

app = FastMCP("funnel")


@app.tool()
def get_features(after_id: int = 0, limit: int = 500) -> str:
    """
    Get a lightweight paginated list of features (id, name, description only).
    after_id: ID of the last fetched feature (0 for the first page)
    limit: number of features per page (default 500)
    """
    with httpx.Client() as client:
        params = (
            f"?select=id,name,description&id=gt.{after_id}&order=id.asc&limit={limit}"
        )
        features = client.get(f"{POSTGREST_URL}/features{params}").json()
        has_more = len(features) == limit
        return json.dumps(
            {
                "data": features,
                "has_more": has_more,
                "next_after_id": features[-1]["id"] if features else None,
            },
            indent=2,
        )


@app.tool()
def get_features_with_aggregates(after_id: int = 0, limit: int = 50) -> str:
    """
    Get a paginated list of features with their snapshot aggregates.
    after_id: ID of the last fetched feature (0 for the first page)
    limit: number of features per page (default 50)
    """
    with httpx.Client() as client:
        params = (
            f"?select=*,snapshot_aggregates(*)"
            f"&snapshot_aggregates.snapshot_id=eq.2"
            f"&id=gt.{after_id}"
            f"&order=id.asc"
            f"&limit={limit}"
        )
        features = client.get(f"{POSTGREST_URL}/features{params}").json()
        has_more = len(features) == limit
        return json.dumps(
            {
                "data": features,
                "has_more": has_more,
                "next_after_id": features[-1]["id"] if features else None,
            },
            indent=2,
        )


@app.tool()
def get_aggregates(
    feature_id: int | None = None, feature_name: str | None = None
) -> str:
    """
    Get snapshot aggregates for a specific feature by ID or name.
    feature_id: feature ID to look up
    feature_name: feature name to look up (used if feature_id is not provided)
    """
    with httpx.Client() as client:
        if feature_id is not None:
            params = (
                f"?feature_id=eq.{feature_id}&snapshot_id=eq.2&select=*,features(name)"
            )
        elif feature_name is not None:
            params = f"?features.name=eq.{feature_name}&snapshot_id=eq.2&select=*,features!inner(name)"
        else:
            return json.dumps(
                {"error": "Provide either feature_id or feature_name"}, indent=2
            )
        aggregates = client.get(f"{POSTGREST_URL}/snapshot_aggregates{params}").json()
        return json.dumps({"data": aggregates}, indent=2)


@app.tool()
def prepare_query(feature_ids: list[int], filters: dict) -> str:
    """
    Prepare a final SQL query and pitch for the salesperson.
    feature_ids: list of feature IDs
    filters: e.g. {"min_value": 1000000, "limit": 20}
    """
    min_val = filters.get("min_value", 0)
    limit = filters.get("limit", 200)
    ids_str = ",".join(str(i) for i in feature_ids)

    sql = f"""
SELECT
    c.name AS company,
    f.name AS feature,
    fv.value,
    fv.report_date
FROM feature_values fv
JOIN companies c ON c.id = fv.company_id
JOIN features f ON f.id = fv.feature_id
WHERE fv.feature_id IN ({ids_str})
  AND fv.is_current = TRUE
  AND fv.value > {min_val}
ORDER BY fv.value DESC
LIMIT {limit};
"""

    with httpx.Client() as client:
        params = (
            f"?feature_id=in.({ids_str})"
            f"&is_current=eq.true"
            f"&value=gt.{min_val}"
            f"&order=value.desc"
            f"&limit={limit}"
            f"&select=*,companies(name),features(name)"
        )
        data = client.get(f"{POSTGREST_URL}/feature_values{params}").json()

    return json.dumps(
        {
            "sql": sql.strip(),
            "results": data,
            "count": len(data) if isinstance(data, list) else 0,
        },
        indent=2,
    )


@app.tool()
def upload_to_crm(company_names: list[str], deal_context: str) -> str:
    """
    Upload companies to HubSpot CRM.
    company_names: list of company names
    deal_context: deal context for notes
    """
    return json.dumps(
        {
            "status": "ready",
            "companies": company_names,
            "context": deal_context,
            "message": "Use HubSpot MCP to create companies",
        },
        indent=2,
    )


if __name__ == "__main__":
    app.run()
