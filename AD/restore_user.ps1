Get-ADObject -Filter 'isDeleted -eq $true -and samAccountName -eq "LOGINDELUSER"'
    -IncludeDeletedObjects | Restore-ADObject