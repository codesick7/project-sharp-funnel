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


-- 2. Top companies where feature Y is between $2B and $5B
--
-- SELECT c.name, fv.value, fv.report_date
-- FROM   feature_values fv
-- JOIN   companies c ON c.id = fv.company_id
-- WHERE  fv.feature_id = :feature_id
--   AND  fv.report_date = :period
--   AND  fv.is_current = TRUE
--   AND  fv.value BETWEEN 2000000000 AND 5000000000
-- ORDER  BY fv.value DESC;
