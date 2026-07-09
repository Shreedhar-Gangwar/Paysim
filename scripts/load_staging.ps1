# =============================================================================
# load_staging.ps1 — Stage A loader
#
# What it does:
#   1. Reads DB credentials from .env (never hardcoded here).
#   2. Creates the project database if it doesn't exist.
#   3. Creates the staging table (sql/01_create_staging.sql).
#   4. Bulk-loads the PaySim CSV via psql \copy (client-side COPY —
#      streams the file in one pass; never row-by-row INSERTs).
#
# Run from the project root:  powershell -File scripts\load_staging.ps1
# =============================================================================

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot

# --- 1. Load .env into process environment -----------------------------------
Get-Content (Join-Path $projectRoot ".env") | ForEach-Object {
    if ($_ -match '^\s*([^#][^=]*)=(.*)$') {
        [System.Environment]::SetEnvironmentVariable($Matches[1].Trim(), $Matches[2].Trim())
    }
}
$db = $env:PGDATABASE

# --- 2. Create the database if missing (connect via maintenance DB) ----------
$exists = psql -h $env:PGHOST -p $env:PGPORT -U $env:PGUSER -d postgres -w -tAc `
    "SELECT 1 FROM pg_database WHERE datname = '$db';"
if ($exists -ne "1") {
    psql -h $env:PGHOST -p $env:PGPORT -U $env:PGUSER -d postgres -w -c "CREATE DATABASE $db;"
    Write-Host "Created database '$db'."
} else {
    Write-Host "Database '$db' already exists."
}

# --- 3. Create staging table --------------------------------------------------
psql -h $env:PGHOST -p $env:PGPORT -U $env:PGUSER -d $db -w -v ON_ERROR_STOP=1 `
    -f (Join-Path $projectRoot "sql\01_create_staging.sql")

# --- 4. Bulk-load the CSV via \copy -------------------------------------------
$csv = Join-Path $projectRoot "data\raw\paysim dataset.csv"
$copyCmd = "\copy stg_transactions FROM '$csv' WITH (FORMAT csv, HEADER true)"
psql -h $env:PGHOST -p $env:PGPORT -U $env:PGUSER -d $db -w -v ON_ERROR_STOP=1 -c $copyCmd

Write-Host "Load complete."
