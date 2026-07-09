# CLAUDE.md — PaySim FinTech Transaction Analytics

> This file gives you (Claude Code) persistent context for this project. Read it fully at the start of every session before doing anything.

---

## 1. What this project is

Build a **portfolio-quality analytics project** on the PaySim mobile-money transaction dataset. The deliverable is a PostgreSQL **star schema** plus a set of clean, well-documented analytical SQL queries answering business questions about growth, fraud risk, and profitability — feeding a **Power BI dashboard** (built manually, see Section 3).

This project is aimed at **Data Analyst / Data Science roles**. That shapes the priorities: the **star-schema design and the quality/readability of the SQL are the things interviewers will actually inspect and ask me to walk through**. Clean, explainable data modeling and queries matter more here than clever tricks or model accuracy.

### Business framing
A mobile-money provider wants to understand three things from its transaction stream:
- **Growth** — how transaction activity and active accounts evolve over the period.
- **Risk** — where fraud concentrates (by transaction type, amount, balance behavior) and the exposure it represents.
- **Profitability** — simulated fee-based net profitability by segment, to find loss-making vs profitable activity.

---

## 2. Dataset — PaySim

I am placing the PaySim CSV in `data/raw/`.

- **Source:** Kaggle — "Synthetic Financial Datasets For Fraud Detection" (PaySim). I download and place it myself; you cannot fetch it.
- **Size:** ~6.3M rows (~470 MB). Load it **efficiently** — use PostgreSQL `COPY` (or `\copy`), never row-by-row `INSERT`s.
- **Columns:** `step` (1 unit = 1 hour of simulation, ~30 days total), `type` (CASH_IN, CASH_OUT, DEBIT, PAYMENT, TRANSFER), `amount`, `nameOrig`, `oldbalanceOrg`, `newbalanceOrig`, `nameDest`, `oldbalanceDest`, `newbalanceDest`, `isFraud`, `isFlaggedFraud`.

### IMPORTANT — honest scoping, verify before building
PaySim is **synthetic** and spans only ~30 simulated days, with `step` as an hour counter (there is no real calendar date, and no signup/onboarding event). This limits some classic metrics, so **inspect the data first and confirm what it genuinely supports** before committing to metric definitions:
- Derive a date/time dimension from `step` (e.g. day = `step // 24`, hour = `step % 24`). There is no real calendar; document the synthetic mapping.
- Check how often originating accounts (`nameOrig`) recur. If repeat activity is sparse, **"MAU / cohort retention" may not be honestly supportable** — prefer daily-active-accounts and activity-over-time framings, or define cohorts carefully against what the data actually shows. Report back what's feasible; do not force metrics the data can't defend.
- Fraud is known to concentrate in `TRANSFER` and `CASH_OUT`. Confirm this in the data.

Do not assume — inspect `data/raw/`, report the real distributions, and confirm the metric definitions with me before building the analysis.

---

## 3. Division of work — you build the data layer, I build the dashboard

- **You (Claude Code) build:** the Postgres schema, ETL/load, the star schema, and all analytical SQL, exposing clean summary **views/tables** that a BI tool can sit on directly.
- **I build the Power BI dashboard manually.** Power BI is a GUI desktop app you cannot operate. In **Stage D**, your job is to (a) produce dashboard-ready views and (b) give me a build guide: the DAX measures to create and which visual goes where. You are **not** expected to build the visuals.

---

## 4. How I want you to work (same method as my last project)

- **Plan before building.** Propose your approach; let me approve it before you write code.
- **Work in stages, one at a time** (see Section 6). Stop after each stage so I can review before continuing.
- **Explain the rationale** for non-obvious choices (schema decisions, how a metric is defined, indexing).
- **Ask when the data is ambiguous** rather than guessing.
- Push back if I ask for something the data can't honestly support (see the MAU/cohort caveat).

---

## 5. SQL and modeling standards (this is the graded part)

Because analyst interviewers will read this SQL and may ask me to walk through it live:
- **Write for readability, not cleverness.** Use CTEs to break logic into named steps; avoid dense nested subqueries and one-liner tricks.
- **Comment every non-trivial query** — a short header explaining what business question it answers, and inline notes on any non-obvious step.
- **Clear, consistent naming** — descriptive table/column/CTE names (`monthly_active_accounts`, not `t1`).
- **Proper star-schema discipline** — a clean fact table with foreign keys to conformed dimensions; no mixing of grain.
- Add sensible **indexes / primary keys** and explain why.
- Keep each analytical query **self-contained and runnable**, so any one can be demonstrated on its own.

---

## 6. Star schema (confirm grain during Stage B)

- **`fact_transactions`** — one row per transaction (the natural grain). Measures: `amount`, balance deltas, `isFraud`, `isFlaggedFraud`; foreign keys to the dimensions.
- **`dim_date`** — derived from `step` (day, hour, and any period buckets); document the synthetic mapping.
- **`dim_users`** (or account dimension) — distinct accounts and any attributes derivable from the data (e.g. account role as originator/destination, type behavior). Confirm what's meaningfully populatable given PaySim's structure.

Confirm the final dimension list with me — only build dimensions the data can actually support.

---

## 7. Stage-by-stage build order (one increment per review)

**Stage A — Scaffold + DB connection + load**
Project structure, config (DB connection params, paths, seed), `requirements.txt`, `.gitignore` (ignore `data/raw/`, local env). Establish the Postgres connection. Bulk-load the CSV via `COPY` into a raw/staging table. Inspect and report: row count, `type` distribution, fraud rate overall and by type, `step` range, and how often `nameOrig`/`nameDest` recur. **Stop for review.**

**Stage B — Star schema**
DDL for `fact_transactions` + confirmed dimensions, plus the transformation SQL that populates them from staging. Keys, indexes, grain documented. Validate row counts reconcile with staging. **Stop for review.**

**Stage C — Analytical SQL (Growth / Risk / Profitability)**
Clean, CTE-based, commented queries producing summary views:
- **Growth:** activity over time (daily transaction volume/value, active accounts per day), by `type`.
- **Risk:** fraud exposure by `type` and amount band; value at risk; flagged-vs-actual fraud.
- **Profitability:** a documented fee model (assign a fee rule per `type`) -> simulated net profitability by segment, surfacing loss-making segments.
Each query header states the business question it answers. **Stop for review.**

**Stage D — Dashboard handoff (I build Power BI)**
Finalize dashboard-ready views/tables. Provide a **Power BI build guide**: the DAX measures to create (with the DAX written out), the recommended visuals (KPI cards, activity-over-time, fraud-by-type, cohort/heatmap *if the data supports it*, profitability breakdown), and which view feeds each visual. **Stop for review.**

**Stage E — Repo polish + reproducibility**
`README.md` (setup on a clean machine: install Postgres, obtain PaySim from Kaggle into `data/raw/`, run the load + schema + analysis scripts in order), a single runner or documented run order, and a short data-dictionary of the schema. **Stop — project complete.**

---

## 8. Deliverables

- PostgreSQL star schema (DDL + populate scripts)
- Clean, commented, CTE-based analytical SQL (Growth / Risk / Profitability), as reusable views
- Dashboard-ready summary views + a Power BI build guide (DAX + visual layout)
- `README.md`, `requirements.txt`, `.gitignore`, schema data-dictionary
- (Built by me: the Power BI dashboard itself)

---

## 9. Tech stack

- **PostgreSQL** (schema, ETL via `COPY`, all analytical SQL) — the core of the project.
- **Python** (`psycopg2` or `sqlalchemy`) only as needed for orchestration/loading; the analysis lives in SQL, not pandas.
- **Power BI** for the dashboard layer (manual, my part).
- Config-driven DB connection; never hardcode credentials in scripts — read from config/env and keep them out of git.

---

## 10. Success criteria

A clean, reproducible, interview-defensible analytics project: a well-modeled star schema, readable well-commented SQL I can walk through line by line, honest metrics that match what the synthetic data actually supports, and a clear path from raw CSV to a dashboard. The value is the clarity and correctness of the data modeling and SQL — not visual flash.
