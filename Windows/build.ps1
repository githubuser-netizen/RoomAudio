param([ValidateSet('win-x64','win-arm64')][string[]]$Runtimes = @('win-x64','win-arm64'))
$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
Push-Location $ProjectRoot
try {
    dotnet run --project Windows/RoomAudio.Tests -c Release
    if ($LASTEXITCODE -ne 0) { throw 'Audio/protocol tests failed.' }
    foreach ($Runtime in $Runtimes) {
        $Output = Join-Path $ProjectRoot "dist/RoomAudio-$Runtime"
        dotnet publish Windows/RoomAudio.Windows -c Release -r $Runtime --self-contained true -p:PublishSingleFile=true -p:EnableCompressionInSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o $Output
        if ($LASTEXITCODE -ne 0) { throw "Build failed: $Runtime" }
        Copy-Item Windows/README.md (Join-Path $Output 'README.md')
        Copy-Item Windows/THIRD-PARTY-NOTICES.md $Output
        Copy-Item Windows/DOTNET-*.txt $Output
        Compress-Archive -Path "$Output/*" -DestinationPath "dist/RoomAudio-$Runtime.zip" -Force
    }
} finally { Pop-Location }
