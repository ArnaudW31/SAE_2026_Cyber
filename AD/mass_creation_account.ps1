function New-TempPassword {
    param([int]$Length = 14)

    # Caractères ambigus exclus (0/O, 1/l/I) pour faciliter la lecture à l'oral
    $upper   = 'ABCDEFGHJKLMNPQRSTUVWXYZ'.ToCharArray()
    $lower   = 'abcdefghijkmnpqrstuvwxyz'.ToCharArray()
    $digits  = '23456789'.ToCharArray()
    $symbols = '!#$%&*+-=?@'.ToCharArray()
    $all     = $upper + $lower + $digits + $symbols

    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    function Get-RandomChar([char[]]$set) {
        $b = New-Object byte[] 4
        $rng.GetBytes($b)
        $set[[BitConverter]::ToUInt32($b,0) % $set.Length]
    }

    # Au moins un caractère de chaque catégorie (complexité exigée par la PSO)
    $chars = @(
        (Get-RandomChar $upper), (Get-RandomChar $lower),
        (Get-RandomChar $digits), (Get-RandomChar $symbols)
    )
    while ($chars.Count -lt $Length) { $chars += Get-RandomChar $all }

    # Mélange pour ne pas avoir toujours la même structure
    -join ($chars | Sort-Object { Get-Random })
}

$domaine = "ad.valdore-services.fr"
$resultats = @()

Import-Csv .\users.csv -Delimiter ';' | ForEach-Object {
    $mdp = New-TempPassword -Length 14
    $ou  = "OU=$($_.Service),OU=Utilisateurs,OU=Valdore,DC=ad,DC=valdore-services,DC=fr"

    New-ADUser -Name "$($_.Prenom) $($_.Nom)" `
        -GivenName $_.Prenom -Surname $_.Nom `
        -SamAccountName $_.Login `
        -UserPrincipalName "$($_.Login)@$domaine" `
        -EmailAddress ("$($_.Prenom).$($_.Nom)@valdore-services.fr").ToLower() `
        -Path $ou `
        -AccountPassword (ConvertTo-SecureString $mdp -AsPlainText -Force) `
        -ChangePasswordAtLogon $true `
        -Enabled $true

    Add-ADGroupMember -Identity "GG_$($_.Service)" -Members $_.Login

    $resultats += [pscustomobject]@{
        Login           = $_.Login
        Nom             = "$($_.Prenom) $($_.Nom)"
        MotDePasseTemp  = $mdp
    }
}

# Affichage à l'écran
$resultats | Format-Table -AutoSize

# Export pour remise aux utilisateurs
$resultats | Export-Csv "$env:USERPROFILE\Desktop\mdp_temporaires.csv" -NoTypeInformation -Delimiter ';' -Encoding UTF8