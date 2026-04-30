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
def prepare_query(filters: list[dict], limit: int = 20) -> str:
    """
    Find companies matching per-feature criteria. Intersects results across all filters.
    filters: list of filter objects, each with:
        - feature_id (int, required)
        - min_value (float, optional)
        - max_value (float, optional)
      Example: [{"feature_id": 1, "min_value": 50000000, "max_value": 210000000},
                {"feature_id": 5, "min_value": 1.4}]
    limit: max companies to return (default 20)
    """
    with httpx.Client() as client:
        company_sets = []
        feature_data = {}

        for f in filters:
            fid = f["feature_id"]
            params = (
                f"?feature_id=eq.{fid}"
                f"&is_current=eq.true"
                f"&select=company_id,value,companies(name),features(name)"
            )
            if "min_value" in f:
                params += f"&value=gte.{f['min_value']}"
            if "max_value" in f:
                params += f"&value=lte.{f['max_value']}"
            rows = client.get(f"{POSTGREST_URL}/feature_values{params}").json()
            if not isinstance(rows, list):
                return json.dumps(
                    {"error": f"Query failed for feature_id={fid}", "response": rows},
                    indent=2,
                )

            cids = {r["company_id"] for r in rows}
            company_sets.append(cids)
            for r in rows:
                feature_data.setdefault(
                    r["company_id"], {"company": r["companies"]["name"], "features": {}}
                )
                feature_data[r["company_id"]]["features"][r["features"]["name"]] = r[
                    "value"
                ]

        if not company_sets:
            return json.dumps({"data": [], "count": 0}, indent=2)

        matched_ids = company_sets[0]
        for s in company_sets[1:]:
            matched_ids &= s

        results = [feature_data[cid] for cid in matched_ids if cid in feature_data]
        results.sort(key=lambda r: list(r["features"].values())[0], reverse=True)
        results = results[:limit]

    return json.dumps({"data": results, "count": len(results)}, indent=2)


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
    app.run(transport="sse", host="0.0.0.0", port=6726)
