# Upload InvestSphere source data to Unity Catalog Volumes on the *currently authenticated*
# Databricks workspace.
#
# Prereq:  databricks auth login --host https://<your-workspace>   (point at the RIGHT workspace!)
# Usage :  .\scripts\upload_data_to_volumes.ps1
#
# Uploads:
#   - 14 structured sources (dated/immutable files) -> /Volumes/investsphere/bronze/raw/<source>/
#   - 3 APPROVED PDFs                                -> /Volumes/investsphere/ai/documents/
#     (the restricted private_investment_committee_memo.pdf is intentionally EXCLUDED)

$ErrorActionPreference = "Stop"
$data = Join-Path $PSScriptRoot "..\data" | Resolve-Path

Write-Host "== Structured sources -> bronze/raw ==" -ForegroundColor Cyan
Get-ChildItem "$data\reference_data", "$data\transaction_data", "$data\valuation_data" -File |
  Where-Object { $_.Name -match '_\d{4}_\d{2}_\d{2}\.(csv|json)$' } |   # dated/immutable files only
  ForEach-Object {
    $source = $_.Name -replace '_\d{4}_\d{2}_\d{2}\.(csv|json)$', ''     # e.g. portfolio_master_2026_06_05.csv -> portfolio_master
    Write-Host "  -> bronze/raw/$source"
    databricks fs cp $_.FullName "dbfs:/Volumes/investsphere/bronze/raw/$source/$($_.Name)" --overwrite
  }

Write-Host "== Approved documents -> ai/documents ==" -ForegroundColor Cyan
$approved = 'investment_policy_statement', 'portfolio_risk_guidelines', 'listed_equity_research_note'
Get-ChildItem "$data\documents" -Filter *.pdf |
  Where-Object { ($_.BaseName -replace '_\d{4}_\d{2}_\d{2}$', '') -in $approved } |
  ForEach-Object {
    Write-Host "  -> ai/documents/$($_.Name)"
    databricks fs cp $_.FullName "dbfs:/Volumes/investsphere/ai/documents/$($_.Name)" --overwrite
  }

Write-Host "Done. Verify: databricks fs ls dbfs:/Volumes/investsphere/bronze/raw/" -ForegroundColor Green
