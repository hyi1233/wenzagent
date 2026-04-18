$lines = [IO.File]::ReadAllLines('d:\project\Github\wenzagent\test\employee_crud_sync_test.dart')
for ($i = 813; $i -le 845; $i++) {
    Write-Host "${i}: $($lines[$i])"
}
