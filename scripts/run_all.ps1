# =============================================================================
# run_all.ps1 — build the entire project from a clean database.
#
# What this step is: the single entry point. It creates the database, loads the
# CSV, builds the star schema, validates it, and creates every analytical and
# dashboard view -- in the only order that works.
#
# Usage, from the project root:
#     powershell -ExecutionPolicy Bypass -File scripts\run_all.ps1
#
# Prerequisites:
#   * PostgreSQL installed and running, with psql on PATH.
#   * .env present (copy .env.example and fill in your password).
#   * The PaySim CSV at data/raw/paysim dataset.csv (see README).
#
# Safe to re-run: script 03 drops with CASCADE, removing the dependent views, and
# scripts 06-10 recreate them.
#
# Runtime from scratch on a cold cache: roughly 25-30 minutes. Most of it is the
# fact_transactions insert (6.36M rows joined twice into a 9M-row account
# dimension) and the six indexes built afterwards. The CSV load is only ~2 min.
# =============================================================================

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$sqlDir      = Join-Path $projectRoot "sql"

# --- Load .env into the process environment ----------------------------------
# Credentials never live in a script or a .sql file. psql reads PGHOST/PGUSER/
# PGPASSWORD/PGDATABASE straight from the environment.
$envFile = Join-Path $projectRoot ".env"
if (-not (Test-Path $envFile)) {
    throw ".env not found. Copy .env.example to .env and fill in your PostgreSQL password."
}
Get-Content $envFile | ForEach-Object {
    if ($_ -match '^\s*([^#][^=]*)=(.*)$') {
        [System.Environment]::SetEnvironmentVariable($Matches[1].Trim(), $Matches[2].Trim())
    }
}
$db = $env:PGDATABASE

# --- Check the CSV is present before doing anything expensive ----------------
$csv = Join-Path $projectRoot "data\raw\paysim dataset.csv"
if (-not (Test-Path $csv)) {
    throw "PaySim CSV not found at '$csv'. Download it from Kaggle -- see README section 2."
}

function Invoke-Sql {
    param([string]$File, [string]$Label)
    Write-Host ""
    Write-Host "==> $Label" -ForegroundColor Cyan
    psql -h $env:PGHOST -p $env:PGPORT -U $env:PGUSER -d $db -w -v ON_ERROR_STOP=1 `
         -f (Join-Path $sqlDir $File)
    if ($LASTEXITCODE -ne 0) { throw "FAILED: $File" }
}

$started = Get-Date

# --- 1. Create the database if it does not exist ------------------------------
# Connect via the maintenance database 'postgres'; CREATE DATABASE cannot run
# inside the database it is creating.
$exists = psql -h $env:PGHOST -p $env:PGPORT -U $env:PGUSER -d postgres -w -tAc `
    "SELECT 1 FROM pg_database WHERE datname = '$db';"
if ($exists -ne "1") {
    psql -h $env:PGHOST -p $env:PGPORT -U $env:PGUSER -d postgres -w -c "CREATE DATABASE $db;" | Out-Null
    Write-Host "Created database '$db'." -ForegroundColor Green
} else {
    Write-Host "Database '$db' already exists -- reusing it." -ForegroundColor Yellow
}

# --- 2. Staging: schema, then bulk load --------------------------------------
Invoke-Sql "01_create_staging.sql" "Stage A: create staging table"

Write-Host ""
Write-Host "==> Stage A: bulk-load CSV via \copy (this is the slow step)" -ForegroundColor Cyan
psql -h $env:PGHOST -p $env:PGPORT -U $env:PGUSER -d $db -w -v ON_ERROR_STOP=1 `
     -c "\copy stg_transactions FROM '$csv' WITH (FORMAT csv, HEADER true)"
if ($LASTEXITCODE -ne 0) { throw "FAILED: CSV load" }

# 02 is a read-only profile of the raw data. It prints the distributions that
# justified every modelling decision. Skipped by default because it is slow and
# purely informational; run it yourself with -f sql\02_inspect_staging.sql.

# --- 3. Star schema -----------------------------------------------------------
Invoke-Sql "03_create_star_schema.sql"   "Stage B: create star schema"
Invoke-Sql "04_populate_star_schema.sql" "Stage B: populate star schema + indexes"
Invoke-Sql "05_validate_star_schema.sql" "Stage B: validate (all checks must PASS)"

# --- 4. Analysis --------------------------------------------------------------
# 06 must precede 09: the profitability views call fn_transaction_fee.
# 07 must precede 09: it creates mv_duplicate_cashout_legs, which the
#    profitability views anti-join against to deduplicate fraud loss.
Invoke-Sql "06_fee_model.sql"              "Stage C: fee model (assumptions)"
Invoke-Sql "07_analysis_risk.sql"          "Stage C: risk views + duplicate-leg matview"
Invoke-Sql "08_analysis_growth.sql"        "Stage C: growth views"
Invoke-Sql "09_analysis_profitability.sql" "Stage C: profitability views"

# --- 5. Dashboard layer -------------------------------------------------------
Invoke-Sql "10_dashboard_views.sql" "Stage D: dashboard views"

# --- 6. Refresh the materialized view ----------------------------------------
# 07 creates it fresh, so this is redundant on a full run. It is here because
# this is the command you must remember after ANY rebuild of fact_transactions.
# Skip it and every fraud figure silently drifts back toward the naive 12,056M.
Write-Host ""
Write-Host "==> Refresh mv_duplicate_cashout_legs" -ForegroundColor Cyan
psql -h $env:PGHOST -p $env:PGPORT -U $env:PGUSER -d $db -w -v ON_ERROR_STOP=1 `
     -c "REFRESH MATERIALIZED VIEW mv_duplicate_cashout_legs;"
if ($LASTEXITCODE -ne 0) { throw "FAILED: matview refresh" }

# --- 7. Show the headline numbers so a successful run is self-evidencing -----
Write-Host ""
Write-Host "==> Headline figures" -ForegroundColor Cyan
psql -h $env:PGHOST -p $env:PGPORT -U $env:PGUSER -d $db -w -c @"
SELECT total_txns,
       total_value_billions,
       net_profit_millions,
       fraud_loss_millions        AS fraud_loss_deduplicated,
       fraud_loss_naive_millions  AS fraud_loss_naive
FROM vw_dashboard_kpi;
"@

$elapsed = (Get-Date) - $started
Write-Host ""
Write-Host ("Build complete in {0:mm}m {0:ss}s. Connect Power BI to database '{1}'." -f $elapsed, $db) -ForegroundColor Green
Write-Host "See docs/powerbi_build_guide.md for the dashboard build." -ForegroundColor Green
