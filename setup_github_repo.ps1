$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Guide = Join-Path $Root "GITHUB_RELEASE_SETUP.md"

Write-Host ""
Write-Host "GitHub CLI is not required." -ForegroundColor Green
Write-Host "Use GitHub Desktop to create/publish the repository and push source commits."
Write-Host "Use the GitHub website to create Releases and upload the APK."
Write-Host ""

if (Test-Path -LiteralPath $Guide) {
    Start-Process $Guide
}
else {
    Write-Host "Missing guide: $Guide" -ForegroundColor Yellow
}
