-- ============================================================
-- Feature Store Schema
-- ============================================================

-- -----------------------------
-- Companies
-- -----------------------------
-- Identified by public IDs (RSSD, EIN, etc.)
-- No internal-only companies; every company has at least one public identifier.

CREATE TABLE companies (
    id          SERIAL PRIMARY KEY,
    name        TEXT NOT NULL UNIQUE,
    rssd_id     VARCHAR(50)  UNIQUE,       -- NCUA/FDIC identifier
    ein         VARCHAR(20)  UNIQUE,       -- IRS employer ID
    lei         VARCHAR(25)  UNIQUE,       -- Legal Entity Identifier
    metadata    JSONB        DEFAULT '{}', -- flexible attrs (address, state, type, etc.)
    created_at  TIMESTAMPTZ  DEFAULT NOW(),
    updated_at  TIMESTAMPTZ  DEFAULT NOW(),
    CONSTRAINT at_least_one_identifier CHECK (
        rssd_id IS NOT NULL OR ein IS NOT NULL OR lei IS NOT NULL
    )
);



-- -----------------------------
-- Datasources
-- -----------------------------
-- Each datasource is a distinct reporting origin.
-- Different sources for the same metric = different features.

CREATE TABLE datasources (
    id               SERIAL PRIMARY KEY,
    name             TEXT NOT NULL UNIQUE,            -- e.g. "NCUA Call Reports"
    description      TEXT,
    provider         TEXT,                           -- e.g. "NCUA", "FDIC", "SEC"
    url              TEXT,                           -- link to source
    created_at       TIMESTAMPTZ DEFAULT NOW()
);


-- -----------------------------
-- Features (definitions)
-- -----------------------------
-- A feature is a named metric/attribute with a fixed data type,
-- tied to exactly one datasource.

CREATE TYPE feature_data_type AS ENUM ('int', 'float', 'bool', 'text');

CREATE TABLE features (
    id               SERIAL PRIMARY KEY,
    name             TEXT NOT NULL UNIQUE,
    description      TEXT,
    data_type        feature_data_type NOT NULL,
    unit_of_measure  TEXT,                           -- e.g. "USD", "count", "percent"
    category         TEXT,                           -- grouping label, e.g. "deposits", "loans"
    datasource_id    INTEGER NOT NULL REFERENCES datasources(id),
    update_frequency TEXT,                            -- how often this feature gets new values
    mapping_metadata JSONB        DEFAULT '{}',     -- source field name, transformations, notes
    created_at       TIMESTAMPTZ  DEFAULT NOW(),
    updated_at       TIMESTAMPTZ  DEFAULT NOW()
);

CREATE INDEX idx_features_category    ON features (category);
CREATE INDEX idx_features_datasource  ON features (datasource_id);


-- -----------------------------
-- Feature values (observations)
-- -----------------------------
-- One row per (company, feature, report_date).
-- Numeric features (int, float, bool) stored in `value`.
-- Text features (enums like charter_type) stored in `value_text`.
-- Only one of value/value_text should be populated per row.
--
-- Versioning: when a value is corrected, the old row gets is_current = FALSE
-- and a new row is inserted. Query with is_current = TRUE for latest known values.

CREATE TABLE feature_values (
    id           BIGSERIAL    PRIMARY KEY,
    company_id   INTEGER      NOT NULL REFERENCES companies(id),
    feature_id   INTEGER      NOT NULL REFERENCES features(id),
    report_date  DATE         NOT NULL,     -- date the value was reported for (e.g. 2025-03-31)
    value        DOUBLE PRECISION,          -- numeric features (int, float, bool as 1/0)
    value_text   TEXT,                       -- text/enum features (e.g. "Federal", "Active")
    is_current   BOOLEAN      DEFAULT TRUE,
    reported_at  TIMESTAMPTZ  DEFAULT NOW(),-- when this version was recorded
    created_at   TIMESTAMPTZ  DEFAULT NOW()
);

-- Main query path: latest value of feature X for company Y at report_date D
CREATE UNIQUE INDEX idx_fv_current
    ON feature_values (company_id, feature_id, report_date)
    WHERE is_current = TRUE;

-- Analytical: top companies by value for a given feature + report_date
CREATE INDEX idx_fv_feature_date_value
    ON feature_values (feature_id, report_date, value)
    WHERE is_current = TRUE;

-- Historical: all values for a company-feature pair over time
CREATE INDEX idx_fv_company_feature_time
    ON feature_values (company_id, feature_id, report_date DESC)
    WHERE is_current = TRUE;


-- -----------------------------
-- Snapshots
-- -----------------------------
-- A manually triggered point-in-time capture of aggregate statistics.
-- Each snapshot computes aggregates for all numeric features across all report_dates.

CREATE TABLE snapshots (
    id          SERIAL PRIMARY KEY,
    description TEXT,
    metadata    JSONB        DEFAULT '{}',
    created_at  TIMESTAMPTZ  DEFAULT NOW()
);


-- -----------------------------
-- Snapshot aggregates
-- -----------------------------
-- Precomputed statistics per (feature, report_date) within a snapshot.
-- Only numeric features (int, float, bool) are aggregated.
--
-- NOTE: text features are excluded from aggregates. When a common strategy
-- for text/enum aggregation is defined (e.g., value counts, mode), this
-- can be extended with a separate table or additional columns.

CREATE TABLE snapshot_aggregates (
    id              BIGSERIAL PRIMARY KEY,
    snapshot_id     INTEGER NOT NULL REFERENCES snapshots(id) ON DELETE CASCADE,
    feature_id      INTEGER NOT NULL REFERENCES features(id),
    report_date     DATE    NOT NULL,
    company_count   INTEGER,                    -- number of companies with a value
    min_val         DOUBLE PRECISION,
    max_val         DOUBLE PRECISION,
    avg_val         DOUBLE PRECISION,
    p10             DOUBLE PRECISION,
    p20             DOUBLE PRECISION,
    p25             DOUBLE PRECISION,
    p30             DOUBLE PRECISION,
    p40             DOUBLE PRECISION,
    p50             DOUBLE PRECISION,           -- median
    p60             DOUBLE PRECISION,
    p70             DOUBLE PRECISION,
    p75             DOUBLE PRECISION,
    p80             DOUBLE PRECISION,
    p90             DOUBLE PRECISION,
    UNIQUE (snapshot_id, feature_id, report_date)
);

CREATE INDEX idx_sa_feature    ON snapshot_aggregates (feature_id, report_date);


-- ============================================================
-- Example queries
-- ============================================================

-- 1. Top companies where feature X increased more than 2x since last year
--
-- WITH latest AS (
--     SELECT company_id, value
--     FROM   feature_values
--     WHERE  feature_id = :feature_id
--       AND  report_date = :current_date     -- e.g. '2026-03-31'
--       AND  is_current = TRUE
-- ),
-- previous AS (
--     SELECT company_id, value
--     FROM   feature_values
--     WHERE  feature_id = :feature_id
--       AND  report_date = :year_ago_date     -- e.g. '2025-03-31'
--       AND  is_current = TRUE
-- )
-- SELECT c.name, p.value AS prev_value, l.value AS curr_value,
--        l.value / NULLIF(p.value, 0) AS growth_ratio
-- FROM   latest l
-- JOIN   previous p USING (company_id)
-- JOIN   companies c ON c.id = l.company_id
-- WHERE  p.value > 0
--   AND  l.value / p.value > 2.0
-- ORDER  BY growth_ratio DESC
-- LIMIT  20;


-- 2. Populate snapshot_aggregates for a given snapshot
--    (only numeric features: int, float, bool)
--
-- INSERT INTO snapshot_aggregates (
--     snapshot_id, feature_id, report_date, company_count,
--     min_val, max_val, avg_val,
--     p10, p20, p25, p30, p40, p50, p60, p70, p75, p80, p90
-- )
-- SELECT
--     :snapshot_id,
--     fv.feature_id,
--     fv.report_date,
--     count(*)                                                     AS company_count,
--     min(fv.value)                                                AS min_val,
--     max(fv.value)                                                AS max_val,
--     avg(fv.value)                                                AS avg_val,
--     percentile_cont(0.10) WITHIN GROUP (ORDER BY fv.value)       AS p10,
--     percentile_cont(0.20) WITHIN GROUP (ORDER BY fv.value)       AS p20,
--     percentile_cont(0.25) WITHIN GROUP (ORDER BY fv.value)       AS p25,
--     percentile_cont(0.30) WITHIN GROUP (ORDER BY fv.value)       AS p30,
--     percentile_cont(0.40) WITHIN GROUP (ORDER BY fv.value)       AS p40,
--     percentile_cont(0.50) WITHIN GROUP (ORDER BY fv.value)       AS p50,
--     percentile_cont(0.60) WITHIN GROUP (ORDER BY fv.value)       AS p60,
--     percentile_cont(0.70) WITHIN GROUP (ORDER BY fv.value)       AS p70,
--     percentile_cont(0.75) WITHIN GROUP (ORDER BY fv.value)       AS p75,
--     percentile_cont(0.80) WITHIN GROUP (ORDER BY fv.value)       AS p80,
--     percentile_cont(0.90) WITHIN GROUP (ORDER BY fv.value)       AS p90
-- FROM   feature_values fv
-- JOIN   features f ON f.id = fv.feature_id
-- WHERE  fv.is_current = TRUE
--   AND  f.data_type IN ('int', 'float', 'bool')
-- GROUP  BY fv.feature_id, fv.report_date;


-- 3. Top companies where feature Y is between $2B and $5B
--
-- SELECT c.name, fv.value, fv.report_date
-- FROM   feature_values fv
-- JOIN   companies c ON c.id = fv.company_id
-- WHERE  fv.feature_id = :feature_id
--   AND  fv.report_date = :period
--   AND  fv.is_current = TRUE
--   AND  fv.value BETWEEN 2000000000 AND 5000000000
-- ORDER  BY fv.value DESC;
