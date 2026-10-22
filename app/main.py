"""
Safe Deployments Lab — Demo FastAPI Application
================================================
This app intentionally contains the same patterns found in real production audits:

  Scenario A: Hardcoded value + env var never read (Issue #1, #13 pattern)
  Scenario B: Config that looks correct but breaks at runtime (Issue #12, #23 pattern)
  Scenario C: Errors swallowed silently, no test coverage (Issue #18, #30 pattern)

The pipeline is green. The secrets are set. The app is broken.
The AI audit gate catches what the pipeline cannot.
"""

import os
import httpx
from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse
from contextlib import asynccontextmanager


# ── Scenario A: Config with silent hardcoded fallbacks ───────────────────────
# These values are read from env vars — but fall back to hardcoded values
# if the env var is missing. The app never fails. It silently uses wrong config.
# Maps to: Issue #13 (default DB credentials) + Issue #1 (hardcoded API key)

DB_HOST     = os.getenv("DB_HOST", "192.168.1.100")       # ← hardcoded fallback
DB_NAME     = os.getenv("DB_NAME", "strapi")               # ← default credential
DB_USER     = os.getenv("DB_USER", "strapi")               # ← default credential
DB_PASSWORD = os.getenv("DB_PASSWORD", "strapi")           # ← default credential
APP_ENV     = os.getenv("APP_ENV", "production")
STORAGE_BUCKET = os.getenv("STORAGE_BUCKET", "")

# ── Scenario A (security): Hardcoded API key ──────────────────────────────────
# Workflow sets COMMODITIES_API_KEY as a secret. App never reads it.
# Key is hardcoded here — committed to source control.
# Maps to: Issue #1
COMMODITIES_API_KEY = "jxy6ipfgpa4cwx8rrh8lp4eyicrjm3h3haew0i7ohopnqic3xjrzx9emnku8"

# ── Scenario B: HOST defaults to localhost ────────────────────────────────────
# Cloud Run and Azure App Service cannot health-check an app bound to localhost.
# The load balancer probes /health → connection refused → container restarts.
# Maps to: Issue #12
HOST = os.getenv("HOST", "localhost")   # ← should default to "0.0.0.0"


def audit_warnings() -> list[str]:
    """
    Returns a list of configuration warnings detectable at startup.
    The AI audit gate catches these before deploy.
    """
    warnings = []
    if DB_HOST == "192.168.1.100":
        warnings.append("DB_HOST is using hardcoded fallback '192.168.1.100'")
    if DB_PASSWORD == "strapi":
        warnings.append("DB_PASSWORD is using default credential 'strapi'")
    if HOST == "localhost":
        warnings.append("HOST is 'localhost' — health probes will fail on Cloud Run")
    if not STORAGE_BUCKET:
        warnings.append("STORAGE_BUCKET is not set — file operations will fail")
    return warnings


@asynccontextmanager
async def lifespan(app: FastAPI):
    print(f"[STARTUP] env={APP_ENV} host={HOST} db={DB_HOST}")
    for w in audit_warnings():
        print(f"[WARNING] {w}")
    # Scenario B: app starts even with broken config
    # No startup check fails. Process appears healthy.
    yield


app = FastAPI(
    title="Safe Deployments Lab",
    description="Demo app replicating real production audit findings",
    version="1.0.0",
    lifespan=lifespan,
)


# ── Routes ────────────────────────────────────────────────────────────────────

@app.get("/")
async def root():
    return {
        "app": "safe-deployments-lab",
        "env": APP_ENV,
        "host": HOST,
    }


# ── Scenario B: No /health route ──────────────────────────────────────────────
# deploy-broken.yml declares:
#   health_check_path: /health
# But this route does not exist.
# Cloud Run / Azure pings /health → 404 → restarts container.
# Silent restart loop. Pipeline never knows.
# Maps to: Issue #23
#
# Fix: uncomment the route below
#
# @app.get("/health")
# async def health():
#     return {"status": "ok", "env": APP_ENV}


@app.get("/api/records")
async def get_records():
    """
    Scenario A: App reads DB_HOST (hardcoded fallback).
    Workflow sets DATABASE_URL. They never connect.
    The variable names don't match — the secret is irrelevant.
    """
    return {
        "records": [{"id": 1, "source": f"db@{DB_HOST}/{DB_NAME}"}],
        "connected_to": DB_HOST,
        "audit_warning": "DB_HOST is hardcoded — DATABASE_URL secret is never read",
    }


@app.get("/api/prices")
async def get_prices():
    """
    Scenario A (security): Hardcoded API key in source code.
    Workflow sets COMMODITIES_API_KEY as a secret.
    App never calls os.getenv('COMMODITIES_API_KEY').
    Key is committed to Git. Visible to anyone with repo access.
    """
    try:
        async with httpx.AsyncClient() as client:
            response = await client.get(
                "https://commodities-api.com/api/latest",
                params={"access_key": COMMODITIES_API_KEY},
                timeout=5.0,
            )
            return response.json()
    except Exception:
        # ── Scenario C: Error swallowed ───────────────────────────────────────
        # Maps to: Issue #18 (Axios onError returns Promise.resolve(false))
        # Route returns 200 with False — pipeline curl sees success
        # Real error is invisible to monitoring and post-deploy verification
        return False


@app.get("/api/files")
async def get_files():
    """
    Scenario C: Error swallowed silently.
    Storage fails → route returns 200 with empty result.
    Post-deploy verification passes. Users see broken UI.
    """
    try:
        if not STORAGE_BUCKET or STORAGE_BUCKET == "UNREACHABLE":
            raise ConnectionError(f"Cannot reach bucket: {STORAGE_BUCKET}")
        return {"files": ["document.pdf", "image.png"], "bucket": STORAGE_BUCKET}
    except Exception:
        # ⚠️ Swallowed — same pattern as Issue #18
        return {"files": [], "bucket": None, "ok": False}


@app.get("/api/config/check")
async def config_check():
    """
    Reveals what the app actually reads vs what the workflow set.
    The AI audit cross-references these two sides.
    """
    return {
        "active_config": {
            "DB_HOST": DB_HOST,
            "DB_NAME": DB_NAME,
            "DB_USER": DB_USER,
            "APP_ENV": APP_ENV,
            "HOST": HOST,
            "STORAGE_BUCKET": STORAGE_BUCKET or "NOT SET",
        },
        "workflow_sets": [
            "DATABASE_URL",
            "APP_ENV",
            "STORAGE_BUCKET",
            "COMMODITIES_API_KEY",
        ],
        "app_reads": [
            "DB_HOST",
            "DB_NAME",
            "DB_USER",
            "DB_PASSWORD",
            "APP_ENV",
            "HOST",
            "STORAGE_BUCKET",
        ],
        "mismatches": [
            "Workflow sets DATABASE_URL — app reads DB_HOST, DB_NAME, DB_USER, DB_PASSWORD",
            "Workflow sets COMMODITIES_API_KEY — app uses hardcoded key, never reads env var",
        ],
        "audit_warnings": audit_warnings(),
    }
