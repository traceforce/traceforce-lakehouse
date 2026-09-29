# Run one SQL statement against the TraceForce lakehouse through Athena and print the
# result as CSV. PowerShell twin of athena_query.sh, for Windows without bash: same checks,
# same output. Needs the AWS CLI v2 with credentials that carry the module's
# query_policy_json policy (or broader). Runs on Windows PowerShell 5.1 and PowerShell 7.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File athena_query.ps1 -f query.sql
#   powershell -NoProfile -ExecutionPolicy Bypass -File athena_query.ps1 "SELECT count(*) FROM agent_events"
#
# Prefer -f: PowerShell can alter double quotes in SQL passed inline. Names are fixed by the
# module (workgroup traceforce-lakehouse, catalog s3tablescatalog/traceforce-lakehouse,
# namespace traceforce). Optional: TRACEFORCE_LAKEHOUSE_MAX_ROWS rows to print (default 200;
# 0 = all).
#
# Output: CSV on stdout; "-- query <id> ok, scanned N MB" and any truncation note on stderr;
# exit 1 with Athena's failure reason when the query fails.
param(
  [Parameter(Position = 0)][string]$Sql = '',
  [Alias('f')][string]$File = ''
)

$WG = 'traceforce-lakehouse'
$Catalog = 's3tablescatalog/traceforce-lakehouse'
$NS = 'traceforce'
$MaxRows = 200
if ($env:TRACEFORCE_LAKEHOUSE_MAX_ROWS) { $MaxRows = [long]$env:TRACEFORCE_LAKEHOUSE_MAX_ROWS }

function Fail([string]$Message, [int]$Code) {
  [Console]::Error.WriteLine($Message)
  exit $Code
}

# -f files: UTF-8 with or without a BOM, else the system code page (what Windows PowerShell's
# Set-Content writes by default).
function Read-SqlFile([string]$Path) {
  $full = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
  try { return (New-Object Text.UTF8Encoding($false, $true)).GetString([IO.File]::ReadAllBytes($full)).TrimStart([char]0xFEFF) }
  catch { return [IO.File]::ReadAllText($full, [Text.Encoding]::Default) }
}

if ($File) { $Sql = Read-SqlFile $File }
if (-not $Sql) { Fail 'usage: athena_query.ps1 "SQL" | -f file.sql' 2 }

# Read-only by construction: the policy forbids writes anyway, this just fails faster.
# A lone CR also ends a line, as it does for the engine.
$first = ''
foreach ($line in ($Sql -split "`r`n|`r|`n")) {
  $t = $line.Trim()
  if ($t -eq '' -or $t.StartsWith('--')) { continue }
  $first = ($t -split '\s+')[0].ToUpperInvariant()
  break
}
if (@('SELECT', 'WITH', 'SHOW', 'DESCRIBE', 'DESC', 'EXPLAIN') -notcontains $first) {
  Fail "refusing to run a non-read statement (first keyword: $first)" 2
}
if (-not (Get-Command aws -CommandType Application -ErrorAction SilentlyContinue)) {
  Fail 'aws: command not found (install the AWS CLI v2)' 127
}

$sqlFile = [IO.Path]::GetTempFileName()
$csvFile = [IO.Path]::GetTempFileName()
$qid = ''
$finished = $false
try {
  # The SQL goes to aws as a file, so no shell or PowerShell quoting can alter it.
  [IO.File]::WriteAllText($sqlFile, $Sql, (New-Object Text.UTF8Encoding $false))
  $env:AWS_CLI_FILE_ENCODING = 'UTF-8'

  # The workgroup pins the result location and encryption, so none is passed here.
  $start = @('athena', 'start-query-execution', '--work-group', $WG,
    '--query-execution-context', "Catalog=$Catalog,Database=$NS",
    '--query-string', "file://$sqlFile", '--query', 'QueryExecutionId', '--output', 'text')
  $qid = "$(& aws @start)".Trim()
  if ($LASTEXITCODE -ne 0) { $finished = $true; exit $LASTEXITCODE }

  $poll = @('athena', 'get-query-execution', '--query-execution-id', $qid, '--query',
    '[QueryExecution.Status.State, QueryExecution.Status.StateChangeReason, QueryExecution.ResultConfiguration.OutputLocation]',
    '--output', 'text')
  $out = ''
  while ($true) {
    # A transient CLI failure (throttle, expired token) must not stop the poll loop.
    $status = "$(& aws @poll)".Trim()
    if ($LASTEXITCODE -ne 0) { Start-Sleep -Seconds 2; continue }
    $state, $reason, $out = $status -split "`t"
    if ($state -eq 'SUCCEEDED') { break }
    if ($state -eq 'FAILED' -or $state -eq 'CANCELLED') {
      $finished = $true
      Fail "Athena $state ($qid): $reason" 1
    }
    Start-Sleep -Seconds 1
  }
  $finished = $true

  $scanned = [long]0
  $raw = "$(& aws athena get-query-execution --query-execution-id $qid --query 'QueryExecution.Statistics.DataScannedInBytes' --output text)".Trim()
  $null = [long]::TryParse($raw, [ref]$scanned)
  [Console]::Error.WriteLine("-- query $qid ok, scanned $([math]::Floor($scanned / 1048576)) MB")

  # Download to a file first, then print from it.
  & aws s3 cp --only-show-errors $out $csvFile
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  $bytes = [IO.File]::ReadAllBytes($csvFile)
  $stdout = [Console]::OpenStandardOutput()
  if ($MaxRows -eq 0) {
    $stdout.Write($bytes, 0, $bytes.Length)
    $stdout.Flush()
    exit 0
  }
  # Header plus MaxRows lines, as the bash twin's head does; the rest is counted, not printed.
  $lines = 0
  $end = $bytes.Length
  $pos = 0
  while ($pos -lt $bytes.Length) {
    $nl = [Array]::IndexOf($bytes, [byte]10, $pos)
    if ($nl -lt 0) { break }
    $lines++
    if ($lines -eq $MaxRows + 1) { $end = $nl + 1 }
    $pos = $nl + 1
  }
  $stdout.Write($bytes, 0, $end)
  $stdout.Flush()
  $total = $lines - 1
  if ($total -gt $MaxRows) {
    [Console]::Error.WriteLine("-- showing $MaxRows of $total result lines; set TRACEFORCE_LAKEHOUSE_MAX_ROWS=0 for all (lines, not rows: quoted content can span lines)")
  }
} finally {
  Remove-Item -LiteralPath $sqlFile, $csvFile -Force -ErrorAction SilentlyContinue
  # Ctrl-C cancels the scan instead of leaving it running, and must not read as success.
  if ($qid -and -not $finished) {
    & aws athena stop-query-execution --query-execution-id $qid *> $null
    [Console]::Error.WriteLine("-- interrupted; cancelled query $qid")
    [Environment]::Exit(130)
  }
}
