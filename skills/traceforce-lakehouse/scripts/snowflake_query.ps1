# Run one read-only SQL statement against the TraceForce lakehouse on Snowflake (Azure) and
# print the result as CSV. PowerShell twin of snowflake_query.sh, for Windows without bash:
# both are thin launchers for snowflake_query.py (same folder), which holds every check and
# runs the query. Needs Python 3 with snowflake-connector-python installed. Runs on Windows
# PowerShell 5.1 and PowerShell 7.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File snowflake_query.ps1 -f query.sql
#   powershell -NoProfile -ExecutionPolicy Bypass -File snowflake_query.ps1 'SELECT count(*) FROM "agent_events"'
#
# Prefer -f: PowerShell can alter double quotes in SQL passed inline, and Snowflake's lowercase
# identifiers need them; inline SQL that begins with "-" (a leading -- comment) is read as a
# parameter name by PowerShell and fails before this script runs (exit 1, a binder message).
# Save -f files as UTF-8: Windows PowerShell's > and Out-File write UTF-16 by default, which
# is refused with a message saying so. Python is found as py -3, python, python3; the py
# launcher of the newer python.org install manager may offer to install Python when none is.
# Env: authentication is either all five of SNOWFLAKE_ORGANIZATION_NAME, SNOWFLAKE_ACCOUNT_NAME,
#      SNOWFLAKE_USER, SNOWFLAKE_AUTHENTICATOR (= SNOWFLAKE_JWT) and SNOWFLAKE_PRIVATE_KEY
#      (key-pair auth), or none of them (the connector's default connections.toml connection);
#      a partial set is an error. TRACEFORCE_LAKEHOUSE_MAX_ROWS rows to print (default 200;
#      0 = all); TRACEFORCE_LAKEHOUSE_STATEMENT_TIMEOUT seconds before Snowflake cancels the
#      query (default 300; 0 = 7 days, Snowflake's maximum).
# Output: CSV on stdout (UTF-8, LF line endings, exactly as snowflake_query.py writes it);
#         "-- 0 rows" or a truncation note on stderr; exit 2 for usage, validation or a refused
#         statement, exit 1 with Snowflake's reason on stderr when the query fails.
# Read-only: every query runs as the traceforce_lakehouse_reader role, and the statement is
#         checked before it is sent; the rules live in snowflake_query.py. This file only finds
#         Python and hands the SQL over by file.
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

if (-not $File -and -not $Sql) { Fail 'usage: snowflake_query.ps1 "SQL" | -f file.sql' 2 }

# Python 3, by the names Windows installs use: the py launcher, python (the python.org
# installer's name), python3 (the Microsoft Store name). Each candidate must answer --version
# with "Python 3": that skips Python 2 and the Store's placeholder python.exe, which only prints
# an install hint.
function Test-Python3([string]$Exe, [string[]]$Pre) {
  # The probe's stderr is folded into the output; keep that from becoming a terminating error
  # under a caller's $ErrorActionPreference = 'Stop'.
  $ErrorActionPreference = 'Continue'
  try { return ("$(& $Exe @Pre --version 2>&1)" -match '^Python 3\.') } catch { return $false }
}
$python = ''
$pythonPre = @()
foreach ($c in @(@('py', '-3'), @('python'), @('python3'))) {
  $name = $c[0]
  $pre = @($c | Select-Object -Skip 1)
  $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $cmd) { continue }
  if (Test-Python3 $cmd.Source $pre) { $python = $cmd.Source; $pythonPre = $pre; break }
}
if (-not $python) {
  Fail 'Python 3 is required (tried py -3, python, python3): install it from python.org, then open a new shell' 2
}

$impl = Join-Path $PSScriptRoot 'snowflake_query.py'
$sqlFile = ''
$p = $null
try {
  # Inline SQL goes to Python as a UTF-8 file, so no shell or PowerShell quoting can alter it.
  # A user's own -f path is passed through as given.
  $sqlPath = $File
  if (-not $File) {
    $sqlFile = [IO.Path]::GetTempFileName()
    [IO.File]::WriteAllText($sqlFile, $Sql, (New-Object Text.UTF8Encoding $false))
    $sqlPath = $sqlFile
  }

  # Python is started directly, not through PowerShell's pipeline: PowerShell would decode its
  # stdout as text and rewrite it with CRLF line endings and the console code page. Its stdout
  # is copied here byte for byte; stderr is inherited and reaches the console untouched.
  $env:PYTHONIOENCODING = 'utf-8'
  $env:SNOWFLAKE_QUERY_PROG = 'snowflake_query.ps1'
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = $python
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  # One argument string, quoted the way both the Windows C runtime and .NET on Unix split it.
  $argv = @()
  foreach ($a in $pythonPre) { $argv += $a }
  foreach ($a in @($impl, '-f', $sqlPath)) { $argv += ('"' + $a.Replace('"', '\"') + '"') }
  $psi.Arguments = $argv -join ' '
  # A relative -f path must resolve against PowerShell's current location, which can differ
  # from the process's.
  $loc = Get-Location
  if ($loc.Provider.Name -eq 'FileSystem') { $psi.WorkingDirectory = $loc.ProviderPath }

  $p = [Diagnostics.Process]::Start($psi)
  $stdout = [Console]::OpenStandardOutput()
  $p.StandardOutput.BaseStream.CopyTo($stdout)
  $stdout.Flush()
  $p.WaitForExit()
  Quit $p.ExitCode
} catch {
  [Console]::Error.WriteLine($_)
  Quit 1
} finally {
  if ($sqlFile) { Remove-Item -LiteralPath $sqlFile -Force -ErrorAction SilentlyContinue }
  # Interrupted (Ctrl-C): stop a still-running query process, and don't let the run read as
  # success.
  if (-not $script:done) {
    if ($p) { try { if (-not $p.HasExited) { $p.Kill() } } catch { } }
    [Console]::Error.WriteLine('-- interrupted')
    [Environment]::Exit(130)
  }
}
