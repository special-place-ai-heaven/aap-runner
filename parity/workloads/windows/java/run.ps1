# windows/java: the default JDK found through JAVA_HOME (how setup-java, Maven and Gradle find it) compiles, jars and
# runs a program. Maven and Gradle are not driven here: their first build downloads plugins.
# Sabotage no-java-home points JAVA_HOME at an empty folder.
param([Parameter(Mandatory)][string]$Work, [Parameter(Mandatory)][string]$Id, [string]$Sabotage = '')
Import-Module (Join-Path $PSScriptRoot '..\Workload.psm1') -Force

Invoke-Workload -Id $Id -Work $Work -Sabotage $Sabotage -Body {
    if (-not $Sabotage) {
        Add-Fact 'env.JAVA_HOME' $env:JAVA_HOME (Get-Oracle 'env/JAVA_HOME')
        Add-Fact 'env.JAVA_HOME_17_X64' $env:JAVA_HOME_17_X64 (Get-Oracle 'env/JAVA_HOME_17_X64')
    }
    if ($Sabotage -eq 'no-java-home') {
        $env:JAVA_HOME = Join-Path $Work 'no-jdk'
        New-Item -ItemType Directory -Force -Path $env:JAVA_HOME | Out-Null
        Write-Line 'sabotage no-java-home applied'
    }
    if (-not $env:JAVA_HOME) { throw 'JAVA_HOME is not set' }
    $bin = Join-Path $env:JAVA_HOME 'bin'
    foreach ($t in 'javac.exe', 'jar.exe', 'java.exe') {
        if (-not (Test-Path -LiteralPath (Join-Path $bin $t))) { throw "$t not found under JAVA_HOME" }
    }
    $env:JAVA_TOOL_OPTIONS = '-XX:-UsePerfData'  # no hsperfdata files in the shared temp folder
    Copy-Source (Join-Path $PSScriptRoot 'src') 'src'
    Invoke-Tool (Join-Path $bin 'javac.exe') @('--release', '17', '-d', 'classes', 'src\parity\Main.java') | Out-Null
    Invoke-Tool (Join-Path $bin 'jar.exe') @('--create', '--file', 'app.jar', '--main-class', 'parity.Main', '-C', 'classes', '.') | Out-Null
    $out = ((Invoke-Tool (Join-Path $bin 'java.exe') @('-jar', 'app.jar')).Lines | Where-Object { $_ -notlike 'Picked up JAVA_TOOL_OPTIONS*' }) -join ' '
    Add-Fact 'app.output' $out 'hello from java sum=10 amd64=True'
    $entries = Get-ZipEntries 'app.jar'
    Add-Fact 'jar.contains_main' ($entries -contains 'parity/Main.class') $true
    Write-Report (@("output=$out") + ($entries | ForEach-Object { "jar.entry=$_" }))
}
