# Stands in for the zccache daemon in the P13 tests: it only has to be alive. Exits by itself after ten minutes.
$end = (Get-Date).AddMinutes(10)
while ((Get-Date) -lt $end) { Start-Sleep -Seconds 2 }
