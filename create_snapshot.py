#!/usr/bin/env python3
"""Create a feature store snapshot with precomputed aggregates."""

import json
from typing import Annotated, Optional

import psycopg
import typer

app = typer.Typer(help="Feature store snapshot CLI.")

AGGREGATE_SQL = """
INSERT INTO snapshot_aggregates (
    snapshot_id, feature_id, report_date, company_count,
    min_val, max_val, avg_val,
    p10, p20, p25, p30, p40, p50, p60, p70, p75, p80, p90
)
SELECT
    %(snapshot_id)s,
    fv.feature_id,
    fv.report_date,
    count(*)                                                     AS company_count,
    min(fv.value)                                                AS min_val,
    max(fv.value)                                                AS max_val,
    avg(fv.value)                                                AS avg_val,
    percentile_cont(0.10) WITHIN GROUP (ORDER BY fv.value)       AS p10,
    percentile_cont(0.20) WITHIN GROUP (ORDER BY fv.value)       AS p20,
    percentile_cont(0.25) WITHIN GROUP (ORDER BY fv.value)       AS p25,
    percentile_cont(0.30) WITHIN GROUP (ORDER BY fv.value)       AS p30,
    percentile_cont(0.40) WITHIN GROUP (ORDER BY fv.value)       AS p40,
    percentile_cont(0.50) WITHIN GROUP (ORDER BY fv.value)       AS p50,
    percentile_cont(0.60) WITHIN GROUP (ORDER BY fv.value)       AS p60,
    percentile_cont(0.70) WITHIN GROUP (ORDER BY fv.value)       AS p70,
    percentile_cont(0.75) WITHIN GROUP (ORDER BY fv.value)       AS p75,
    percentile_cont(0.80) WITHIN GROUP (ORDER BY fv.value)       AS p80,
    percentile_cont(0.90) WITHIN GROUP (ORDER BY fv.value)       AS p90
FROM   feature_values fv
JOIN   features f ON f.id = fv.feature_id
WHERE  fv.is_current = TRUE
  AND  f.data_type IN ('int', 'float', 'bool')
GROUP  BY fv.feature_id, fv.report_date
"""


@app.command()
def create(
    description: Annotated[
        Optional[str],
        typer.Option("--description", "-d", help="Snapshot description"),
    ] = None,
    metadata: Annotated[
        Optional[str],
        typer.Option("--metadata", "-m", help="JSON metadata string"),
    ] = None,
    db_url: Annotated[
        str,
        typer.Option(
            "--db-url",
            envvar="DATABASE_URL",
            help="PostgreSQL connection string",
        ),
    ] = "postgresql://sharp_funnel:@localhost:5432/sharp_funnel",
    dry_run: Annotated[
        bool,
        typer.Option("--dry-run", help="Show what would be done without executing"),
    ] = False,
):
    """Create a new snapshot and compute aggregates for all numeric features."""
    meta = {}
    if metadata:
        try:
            meta = json.loads(metadata)
        except json.JSONDecodeError:
            typer.echo("Error: --metadata must be valid JSON", err=True)
            raise typer.Exit(1)

    if dry_run:
        typer.echo("Dry run — would create snapshot:")
        typer.echo(f"  description: {description}")
        typer.echo(f"  metadata:    {meta}")
        typer.echo(f"  db_url:      {db_url}")
        typer.echo("  Then populate snapshot_aggregates for all numeric features.")
        raise typer.Exit(0)

    try:
        with psycopg.connect(db_url) as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "INSERT INTO snapshots (description, metadata) "
                    "VALUES (%(description)s, %(metadata)s) "
                    "RETURNING id, created_at",
                    {"description": description, "metadata": json.dumps(meta)},
                )
                row = cur.fetchone()
                snapshot_id, created_at = row[0], row[1]
                typer.echo(f"Created snapshot #{snapshot_id} at {created_at}")

                cur.execute(AGGREGATE_SQL, {"snapshot_id": snapshot_id})
                agg_count = cur.rowcount
                typer.echo(f"Computed {agg_count} aggregate rows")

    except psycopg.Error as e:
        typer.echo(f"Database error: {e}", err=True)
        raise typer.Exit(1)

    typer.echo(f"Snapshot #{snapshot_id} complete.")


if __name__ == "__main__":
    app()
