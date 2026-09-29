# Run one read-only SQL statement against the TraceForce lakehouse on BigQuery (GCP) and
# print the result as CSV. PowerShell twin of bq_query.sh, for Windows without bash: same
# checks, same output. Needs the gcloud CLI signed in for the project that holds the
# lakehouse dataset. GoogleSQL dialect. Runs on Windows PowerShell 5.1 and PowerShell 7.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File bq_query.ps1 -f query.sql
#   powershell -NoProfile -ExecutionPolicy Bypass -File bq_query.ps1 "SELECT count(*) FROM traceforce_lakehouse.agent_events"
#
# Prefer -f: PowerShell can alter double quotes in SQL passed inline.
# Env: TRACEFORCE_LAKEHOUSE_PROJECT (optional) the GCP project holding the dataset; defaults
#      to the gcloud config project when unset. TRACEFORCE_LAKEHOUSE_MAX_ROWS (default 200;
#      0 = all); TRACEFORCE_LAKEHOUSE_MAX_GB per-query scan cap (default 50).
# Output: CSV on stdout, "-- 0 rows" on stderr when the result is empty; exit 1 with
#         BigQuery's reason on failure.
param(
  [Parameter(Position = 0)][string]$Sql = '',
  [Alias('f')][string]$File = ''
)

# Every deliberate exit goes through Quit, so the finally block can tell an interrupt (Ctrl-C)
# from a normal end.
$script:done = $false
function Quit([int]$Code) {
  $script:done = $true
  exit $Code
}
function Fail([string]$Message, [int]$Code) {
  [Console]::Error.WriteLine($Message)
  Quit $Code
}
# An unexpected error ends the run with exit 1 instead of carrying on to a misleading exit 0.
trap { [Console]::Error.WriteLine($_); Quit 1 }

$project = $env:TRACEFORCE_LAKEHOUSE_PROJECT
$maxRows = [long]200
if ($env:TRACEFORCE_LAKEHOUSE_MAX_ROWS) { $maxRows = [long]$env:TRACEFORCE_LAKEHOUSE_MAX_ROWS }
$maxGb = [long]50
if ($env:TRACEFORCE_LAKEHOUSE_MAX_GB) { $maxGb = [long]$env:TRACEFORCE_LAKEHOUSE_MAX_GB }
# 0 = all rows, as in the bash twin: bq has no "all" setting, so use the largest value it accepts.
if ($maxRows -eq 0) { $maxRows = 2147483647 }

if (-not $project) { $project = "$(& gcloud config get-value project 2>$null)".Trim() }
if (-not $project -or $project -eq '(unset)') {
  Fail "no GCP project: set TRACEFORCE_LAKEHOUSE_PROJECT or run 'gcloud config set project <id>'" 2
}
# -f files: UTF-8 with or without a BOM, else the system code page (what Windows PowerShell's
# Set-Content writes by default).
function Read-SqlFile([string]$Path) {
  $full = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
  try { return (New-Object Text.UTF8Encoding($false, $true)).GetString([IO.File]::ReadAllBytes($full)).TrimStart([char]0xFEFF) }
  catch { return [IO.File]::ReadAllText($full, [Text.Encoding]::GetEncoding(0)) }
}

if ($File) { $Sql = Read-SqlFile $File }
if (-not $Sql) { Fail 'usage: bq_query.ps1 "SQL" | -f file.sql' 2 }

# First-keyword allowlist: a fast fail for an obvious DML/DDL statement, NOT the read-only
# guarantee. bq runs multi-statement scripts, so read-only is enforced by IAM: run as an
# identity holding only bigquery.dataViewer (+ jobUser). See bq_query.sh. A lone CR also ends
# a line.
$first = ''
foreach ($line in ($Sql -split "`r`n|`r|`n")) {
  $t = $line.Trim()
  if ($t -eq '' -or $t.StartsWith('--')) { continue }
  $first = ($t -split '\s+')[0].ToUpperInvariant()
  break
}
if (@('SELECT', 'WITH') -notcontains $first) {
  Fail "refusing to run a non-read statement (first keyword: $first)" 2
}

$sqlFile = [IO.Path]::GetTempFileName()
$outFile = [IO.Path]::GetTempFileName()
try {
  # The SQL goes to bq on stdin, not as an argument: on Windows bq is bq.cmd, and cmd.exe
  # rewrites %, ^, & and quotes in arguments. bq writes its failure reason to stdout, so
  # capture stdout to a file and print it on both paths.
  [IO.File]::WriteAllText($sqlFile, $Sql, (New-Object Text.UTF8Encoding $false))
  $env:PYTHONIOENCODING = 'utf-8'
  $bq = (Get-Command bq -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
  $flags = @('query', "--project_id=$project", '--use_legacy_sql=false', '--format=csv',
    "--maximum_bytes_billed=$($maxGb * 1073741824)", "--max_rows=$maxRows")
  $p = Start-Process -FilePath $bq -ArgumentList $flags -RedirectStandardInput $sqlFile `
    -RedirectStandardOutput $outFile -NoNewWindow -Wait -PassThru
  $bytes = [IO.File]::ReadAllBytes($outFile)
  $stdout = [Console]::OpenStandardOutput()
  $stdout.Write($bytes, 0, $bytes.Length)
  $stdout.Flush()
  if ($p.ExitCode -ne 0) { Quit 1 }
  # An empty result prints nothing at all (no header either), which reads as "the script broke".
  if ($bytes.Length -eq 0) { [Console]::Error.WriteLine('-- 0 rows') }
  $script:done = $true
} catch {
  [Console]::Error.WriteLine($_)
  Quit 1
} finally {
  Remove-Item -LiteralPath $sqlFile, $outFile -Force -ErrorAction SilentlyContinue
  # Interrupted (Ctrl-C): don't let the run read as success.
  if (-not $script:done) {
    [Console]::Error.WriteLine('-- interrupted')
    [Environment]::Exit(130)
  }
}
