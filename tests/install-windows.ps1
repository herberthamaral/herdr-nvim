# End-to-end check of the plugin's Windows build hook (herdr/install.ps1), run
# the way `herdr plugin install` runs it, each case on a fresh copy of the
# checkout. CI runs it on windows-latest (VS 2026, no VS 2022: #67).
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/install-windows.ps1 [-RequirePrebuilt]
# -RequirePrebuilt (the release job): only the first case, and the version's
# Windows binary must be on GitHub, so a missing or misnamed asset fails
# instead of skipping. CI already ran the source-build cases on this commit.
param([switch]$RequirePrebuilt)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$repo = Split-Path -Parent $PSScriptRoot
$failures = 0

function Assert([string]$name, [bool]$ok) {
    if ($ok) { Write-Host "  ok    $name" } else { Write-Host "  FAIL  $name"; $script:failures++ }
}

# The checkout's tracked files, uncommitted edits included.
function New-Checkout([string]$version) {
    $dir = Join-Path ([IO.Path]::GetTempPath()) ("herdr-nvim-install-" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Path $dir | Out-Null
    $tree = git -C $repo stash create
    if (-not $tree) { $tree = "HEAD" }
    git -C $repo archive --format=zip -o "$dir.zip" $tree
    Expand-Archive -LiteralPath "$dir.zip" -DestinationPath $dir
    Remove-Item -LiteralPath "$dir.zip"
    if ($version) {
        $manifest = Join-Path $dir "herdr-plugin.toml"
        $text = [IO.File]::ReadAllText($manifest) -replace '(?m)^version = ".*"', "version = `"$version`""
        [IO.File]::WriteAllText($manifest, $text)
    }
    $dir
}

# Captures stderr without Windows PowerShell 5.1 turning it into errors.
function Invoke-Captured([string]$file, [string]$arguments, [string]$dir, [bool]$withCargo) {
    $info = New-Object System.Diagnostics.ProcessStartInfo -ArgumentList $file, $arguments
    $info.UseShellExecute = $false
    $info.WorkingDirectory = $dir
    $info.RedirectStandardError = $true
    if (-not $withCargo) {
        $info.EnvironmentVariables["PATH"] = ($env:PATH -split ";" |
            Where-Object { $_ -and -not (Test-Path -LiteralPath (Join-Path $_ "cargo.exe")) }) -join ";"
    }
    $process = [System.Diagnostics.Process]::Start($info)
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    $stderr -split "`r?`n" | Where-Object { $_ } | ForEach-Object { Write-Host "    | $_" }
    Write-Host "    | exit $($process.ExitCode)"
    [pscustomobject]@{ Exit = $process.ExitCode; Stderr = $stderr }
}

# The exact command herdr-plugin.toml gives herdr for Windows.
function Invoke-Hook([string]$dir, [bool]$withCargo) {
    Invoke-Captured "powershell.exe" "-NoProfile -ExecutionPolicy Bypass -File herdr/install.ps1" $dir $withCargo
}

function Assert-Installed([string]$dir) {
    $exe = Join-Path $dir "bin\herdr-nvim.exe"
    Assert "bin\herdr-nvim.exe is installed" (Test-Path -LiteralPath $exe)
    if (Test-Path -LiteralPath $exe) {
        Assert "bin\herdr-nvim.exe runs (no-arg exit 2)" ((Invoke-Captured $exe "" $dir $true).Exit -eq 2)
    }
}

function Assert-NoDownloadLeft([string]$dir) {
    Assert "no staged exe left in bin\" (-not (Test-Path -LiteralPath (Join-Path $dir "bin\herdr-nvim.new.exe")))
    Assert "no staged .sha256 left in bin\" (-not (Test-Path -LiteralPath (Join-Path $dir "bin\herdr-nvim.new.exe.sha256")))
}

function Test-Published([string]$url) {
    (Invoke-Captured "curl.exe" "--fail --silent --show-error --location --head --output NUL $url" $repo $true).Exit -eq 0
}

function Get-Sha256([string]$path) {
    (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
}

function Get-AsideCount([string]$dir) {
    @(Get-ChildItem -LiteralPath (Join-Path $dir "bin") -Filter "herdr-nvim.old-*.exe").Count
}

function Finish {
    if ($failures) { Write-Host "FAILED: $failures check(s)"; exit 1 }
    Write-Host "OK"
    exit 0
}

$builtFromSource = "target\release\herdr-nvim.exe"
$version = (Select-String -LiteralPath (Join-Path $repo "herdr-plugin.toml") -Pattern '^version = "(.*)"' |
    Select-Object -First 1).Matches[0].Groups[1].Value

Write-Host "== release v$version has the Windows binary and its .sha256: install.ps1 downloads it, no cargo needed"
$url = "https://github.com/herberthamaral/herdr-nvim/releases/download/v$version/herdr-nvim-x86_64-pc-windows-msvc.exe"
$published = (Test-Published $url) -and (Test-Published "$url.sha256")
if ($published) {
    $dir = New-Checkout $null
    $r = Invoke-Hook $dir $false
    Assert "exit 0 without cargo" ($r.Exit -eq 0)
    Assert-Installed $dir
    Assert "no source build" (-not (Test-Path -LiteralPath (Join-Path $dir $builtFromSource)))
    Assert-NoDownloadLeft $dir
}
elseif ($RequirePrebuilt) {
    Assert "v$version has the Windows binary and its .sha256 on GitHub ($url)" $false
}
else {
    Write-Host "  skip  v$version has no Windows binary or no .sha256 on GitHub (released before they existed, or not released yet)"
}
if ($RequirePrebuilt) { Finish }

# A stand-in release served on 127.0.0.1, so the cases below control the
# binary and its .sha256. The stand-in binary answers the probe like the real
# one (no argument: exit 2) and leaves a mark, so a case can tell whether it
# ever ran.
$serve = Join-Path ([IO.Path]::GetTempPath()) ("herdr-nvim-release-" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
$release = Join-Path $serve "v$version"
New-Item -ItemType Directory -Path $release | Out-Null
$asset = "herdr-nvim-x86_64-pc-windows-msvc.exe"
$fakeSource = Join-Path $serve "fake.rs"
[IO.File]::WriteAllText($fakeSource, 'fn main() { let _ = std::fs::write(std::env::var("HERDR_NVIM_TEST_MARKER").unwrap(), ""); std::process::exit(2) }')
$fake = Join-Path $serve "fake.exe"
$built = Invoke-Captured "rustc" "-o `"$fake`" `"$fakeSource`"" $serve $true
if ($built.Exit -ne 0) { throw "could not build the stand-in binary" }
$marker = Join-Path $serve "ran"
$env:HERDR_NVIM_TEST_MARKER = $marker
$port = (& python -c "import socket; s = socket.socket(); s.bind(('127.0.0.1', 0)); print(s.getsockname()[1])").Trim()
$server = Start-Process -FilePath "python" -ArgumentList "-m", "http.server", "--bind", "127.0.0.1", "--directory", "`"$serve`"", $port -WindowStyle Hidden -PassThru
foreach ($i in 1..50) {
    if ((Invoke-Captured "curl.exe" "--fail --silent --output NUL http://127.0.0.1:$port/" $repo $true).Exit -eq 0) { break }
    Start-Sleep -Milliseconds 200
}

# Puts the stand-in binary in the release with a .sha256 of the given kind.
function Publish([string]$kind) {
    $exe = Join-Path $release $asset
    Copy-Item -LiteralPath $fake -Destination $exe -Force
    $sumFile = "$exe.sha256"
    Remove-Item -LiteralPath $sumFile -Force -ErrorAction SilentlyContinue
    if ($kind -eq "none") { return }
    $sum = Get-Sha256 $exe
    $line = switch ($kind) {
        "good" { "$sum  $asset`n" }
        "wrong" { ("0" * 64) + "  $asset`n" }
        "upper-crlf" { $sum.ToUpperInvariant() + "  $asset`r`n" }
        "binary-mode" { "$sum *$asset`n" }
    }
    [IO.File]::WriteAllText($sumFile, $line)
}

function Invoke-StandIn([string]$dir) {
    Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
    Invoke-Hook $dir $false
}

$env:HERDR_NVIM_RELEASE_BASE = "http://127.0.0.1:$port"
try {
    Write-Host "== the stand-in binary matches its SHA-256: installed, no cargo needed"
    Publish "good"
    $dir = New-Checkout $null
    $r = Invoke-StandIn $dir
    Assert "exit 0" ($r.Exit -eq 0)
    $exe = Join-Path $dir "bin\herdr-nvim.exe"
    Assert "bin\herdr-nvim.exe is the release's binary" ((Test-Path -LiteralPath $exe) -and (Get-Sha256 $exe) -eq (Get-Sha256 $fake))
    Assert-NoDownloadLeft $dir

    foreach ($kind in "upper-crlf", "binary-mode") {
        Write-Host "== a .sha256 written as $kind still matches"
        Publish $kind
        $dir = New-Checkout $null
        $r = Invoke-StandIn $dir
        Assert "exit 0" ($r.Exit -eq 0)
        $exe = Join-Path $dir "bin\herdr-nvim.exe"
        Assert "bin\herdr-nvim.exe is the release's binary" ((Test-Path -LiteralPath $exe) -and (Get-Sha256 $exe) -eq (Get-Sha256 $fake))
    }

    Write-Host "== wrong SHA-256, no cargo: refused, the download never runs"
    Publish "wrong"
    $dir = New-Checkout $null
    $r = Invoke-StandIn $dir
    Assert "exit non-zero" ($r.Exit -ne 0)
    Assert "the error names the SHA-256" ($r.Stderr -match "does not match its SHA-256")
    Assert "the download never ran" (-not (Test-Path -LiteralPath $marker))
    Assert "nothing installed" (-not (Test-Path -LiteralPath (Join-Path $dir "bin\herdr-nvim.exe")))
    Assert-NoDownloadLeft $dir

    Write-Host "== wrong SHA-256 on an upgrade, no cargo: the installed exe stays"
    $dir = New-Checkout $null
    $exe = Join-Path $dir "bin\herdr-nvim.exe"
    New-Item -ItemType Directory -Force -Path (Join-Path $dir "bin") | Out-Null
    [IO.File]::WriteAllText($exe, "the exe from before")
    $before = Get-Sha256 $exe
    $r = Invoke-StandIn $dir
    Assert "exit non-zero" ($r.Exit -ne 0)
    Assert "the download never ran" (-not (Test-Path -LiteralPath $marker))
    Assert "bin\herdr-nvim.exe is unchanged" ((Get-Sha256 $exe) -eq $before)

    Write-Host "== the release has no .sha256, no cargo: refused, the download never runs"
    Publish "none"
    $dir = New-Checkout $null
    $r = Invoke-StandIn $dir
    Assert "exit non-zero" ($r.Exit -ne 0)
    Assert "the error says there is no SHA-256" ($r.Stderr -match "no SHA-256")
    Assert "the download never ran" (-not (Test-Path -LiteralPath $marker))
    Assert "nothing installed" (-not (Test-Path -LiteralPath (Join-Path $dir "bin\herdr-nvim.exe")))
    Assert-NoDownloadLeft $dir
}
finally {
    Remove-Item env:HERDR_NVIM_RELEASE_BASE -ErrorAction SilentlyContinue
    Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
}

Write-Host "== no Windows binary for this version (404): builds from source with the MSVC cargo finds"
$built = New-Checkout "0.0.0"
$r = Invoke-Hook $built $true
Assert "exit 0" ($r.Exit -eq 0)
Assert-Installed $built
Assert "built from source" (Test-Path -LiteralPath (Join-Path $built $builtFromSource))
Assert-NoDownloadLeft $built

# A sidebar keeps bin\herdr-nvim.exe running, and Windows can't overwrite a
# running exe. A copy of ping.exe stands in for it there, running, so the lock
# is the real image lock. Reinstalls reuse the build above (cargo has nothing to do).
Write-Host "== reinstall twice while the installed exe runs, then once after it ends"
$exe = Join-Path $built "bin\herdr-nvim.exe"
Copy-Item -LiteralPath (Join-Path $env:SystemRoot "System32\PING.EXE") -Destination $exe -Force
$running = Start-Process -FilePath $exe -ArgumentList "-n 600 127.0.0.1" -WindowStyle Hidden -PassThru
try {
    $r = Invoke-Hook $built $true
    Assert "first reinstall: exit 0" ($r.Exit -eq 0)
    Assert-Installed $built
    Assert "first reinstall: the running exe is set aside" ((Get-AsideCount $built) -eq 1)
    $r = Invoke-Hook $built $true
    Assert "second reinstall, the first still running: exit 0" ($r.Exit -eq 0)
    Assert-Installed $built
    Assert "second reinstall: the still-running exe stays set aside" ((Get-AsideCount $built) -eq 1)
    Assert-NoDownloadLeft $built
}
finally {
    Stop-Process -Id $running.Id -Force -ErrorAction SilentlyContinue
    $running.WaitForExit()
}
$r = Invoke-Hook $built $true
Assert "after it ends: exit 0" ($r.Exit -eq 0)
Assert-Installed $built
Assert "after it ends: no set-aside exe left" ((Get-AsideCount $built) -eq 0)

Write-Host "== no Windows binary and no cargo: fails and says cargo is missing"
$dir = New-Checkout "0.0.0"
$r = Invoke-Hook $dir $false
Assert "exit non-zero" ($r.Exit -ne 0)
Assert "the error names cargo" ($r.Stderr -match "no cargo")
Assert "the error says the release has no Windows binary yet" ($r.Stderr -match "no Windows binary on GitHub yet")
Assert "nothing installed" (-not (Test-Path -LiteralPath (Join-Path $dir "bin\herdr-nvim.exe")))
Assert-NoDownloadLeft $dir

Finish
