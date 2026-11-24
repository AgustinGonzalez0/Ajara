# Verificación del APK de release (ejecutar después de `flutter build apk --release --split-per-abi`).
# Comprueba garantías que los tests en modo debug NO cubren:
#   1. Sin permisos de red (INTERNET / ACCESS_NETWORK_STATE) -> procesamiento offline garantizado por el SO.
#   2. Sin el TelemetryInitializer de ONNX Runtime.
#   3. Clases de ONNX Runtime presentes sin ofuscar (R8 las rompe y la inferencia aborta por JNI).
# Uso: powershell -File tool\verify_release.ps1 [-Apk build\app\outputs\flutter-apk\app-arm64-v8a-release.apk]
param([string]$Apk = "build\app\outputs\flutter-apk\app-arm64-v8a-release.apk")
$ErrorActionPreference = "Stop"
$sdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { "$env:LOCALAPPDATA\Android\sdk" }
$aapt = Get-ChildItem "$sdk\build-tools" -Directory | Sort-Object Name | Select-Object -Last 1 | ForEach-Object { Join-Path $_.FullName "aapt2.exe" }
if (-not (Test-Path $Apk)) { throw "No existe $Apk" }
$fail = 0
$perms = & $aapt dump permissions $Apk
if ($perms -match "android.permission.INTERNET|ACCESS_NETWORK_STATE") { Write-Host "FALLA: el APK declara permisos de red" -ForegroundColor Red; $fail++ }
else { Write-Host "OK: sin permisos de red" -ForegroundColor Green }
$manifest = & $aapt dump xmltree $Apk --file AndroidManifest.xml
if ($manifest -match "TelemetryInitializer") { Write-Host "FALLA: TelemetryInitializer presente" -ForegroundColor Red; $fail++ }
else { Write-Host "OK: sin TelemetryInitializer de ONNX Runtime" -ForegroundColor Green }
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $Apk))
$found = $false
foreach ($e in $zip.Entries | Where-Object { $_.Name -like "classes*.dex" }) {
  $r = New-Object System.IO.StreamReader($e.Open(), [System.Text.Encoding]::GetEncoding(28591))
  if ($r.ReadToEnd().Contains("Lai/onnxruntime/TensorInfo;")) { $found = $true }
  $r.Close()
}
$zip.Dispose()
if ($found) { Write-Host "OK: clases ai.onnxruntime conservadas (reglas R8)" -ForegroundColor Green }
else { Write-Host "FALLA: ai/onnxruntime/TensorInfo no encontrado en el dex (R8 lo ofuscó)" -ForegroundColor Red; $fail++ }
if ($fail -gt 0) { exit 1 } else { Write-Host "Release verificado." }
