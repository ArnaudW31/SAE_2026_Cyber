# Adresse fixe et DNS de DC01 (adapter le nom de la carte : Get-NetAdapter)
$if = "Ethernet"
New-NetIPAddress -InterfaceAlias $if -IPAddress 10.10.20.10 -PrefixLength 24 -DefaultGateway 10.10.20.1
Set-DnsClientServerAddress -InterfaceAlias $if -ServerAddresses 10.10.20.10,127.0.0.1

# Rôle DNS et outils
Get-WindowsFeature DNS, RSAT-DNS-Server
Install-WindowsFeature DNS -IncludeManagementTools   # seulement s'il manque

# Après un changement d'adresse
ipconfig /registerdns
Restart-Service Netlogon

# État des zones
Get-DnsServerZone | Format-Table ZoneName, ZoneType, IsDsIntegrated, ReplicationScope, DynamicUpdate

# Zone AD : stockée dans AD, réplication domaine, mises à jour sécurisées
Set-DnsServerPrimaryZone -Name "ad.valdore-services.fr" -ReplicationScope Domain -DynamicUpdate Secure
Set-DnsServerPrimaryZone -Name "_msdcs.ad.valdore-services.fr" -DynamicUpdate Secure

# Vieillissement 7 + 7 jours et nettoyage automatique
Set-DnsServerZoneAging -Name "ad.valdore-services.fr" -Aging $true -NoRefreshInterval 7.00:00:00 -RefreshInterval 7.00:00:00
Set-DnsServerScavenging -ScavengingState $true -ScavengingInterval 7.00:00:00 -ApplyOnAllZones

Add-DnsServerPrimaryZone -Name "valdore-services.fr" -ReplicationScope Domain -DynamicUpdate None

$z = "valdore-services.fr"
Add-DnsServerResourceRecordA     -ZoneName $z -Name "www"      -IPv4Address 172.16.10.10
Add-DnsServerResourceRecordA     -ZoneName $z -Name "extranet" -IPv4Address 172.16.10.10
Add-DnsServerResourceRecordA     -ZoneName $z -Name "partage"  -IPv4Address 172.16.10.10
Add-DnsServerResourceRecordA     -ZoneName $z -Name "mail"     -IPv4Address 172.16.10.20
Add-DnsServerResourceRecordA     -ZoneName $z -Name "vpn"      -IPv4Address 203.0.113.2
Add-DnsServerResourceRecordMX    -ZoneName $z -Name "." -MailExchange "mail.valdore-services.fr" -Preference 10
Add-DnsServerResourceRecordCName -ZoneName $z -Name "autodiscover" -HostNameAlias "mail.valdore-services.fr"
Add-DnsServerResourceRecordCName -ZoneName $z -Name "autoconfig"   -HostNameAlias "mail.valdore-services.fr"

$reseaux = "10.10.10.0/24","10.10.20.0/24","10.10.30.0/24","10.10.40.0/24",
           "10.10.50.0/24","10.10.100.0/24","10.10.200.0/24","10.10.201.0/24"
foreach ($r in $reseaux) {
    Add-DnsServerPrimaryZone -NetworkId $r -ReplicationScope Domain -DynamicUpdate Secure
}
# DMZ : aucune mise à jour dynamique
Add-DnsServerPrimaryZone -NetworkId "172.16.10.0/24" -ReplicationScope Domain -DynamicUpdate None

# Vieillissement sur toutes les zones inverses
Get-DnsServerZone | Where-Object IsReverseLookupZone | Where-Object IsDsIntegrated |
    ForEach-Object { Set-DnsServerZoneAging -Name $_.ZoneName -Aging $true }

Get-DnsServerZone | Where-Object IsReverseLookupZone



$zone = "ad.valdore-services.fr"
$hotes = @{
    "fw01"="10.10.10.1"; "sw01"="10.10.10.2"; "pve01"="10.10.10.5"; "adm01"="10.10.10.10"
    "fs01"="10.10.20.20"; "app01"="10.10.20.30"; "bdd01"="10.10.30.10"
    "sup01"="10.10.40.10"; "nas01"="10.10.50.10"
    "web01"="172.16.10.10"; "mail01"="172.16.10.20"; "proxy"="10.10.100.1"
}
foreach ($h in $hotes.GetEnumerator()) {
    Add-DnsServerResourceRecordA -ZoneName $zone -Name $h.Key -IPv4Address $h.Value -CreatePtr
}

# PTR de DC01 s'il manque
if (-not (Get-DnsServerResourceRecord -ZoneName "20.10.10.in-addr.arpa" -Name "10" -RRType Ptr -ErrorAction SilentlyContinue)) {
    Add-DnsServerResourceRecordPtr -ZoneName "20.10.10.in-addr.arpa" -Name "10" -PtrDomainName "dc01.ad.valdore-services.fr"
}

# Contrôle
Get-DnsServerResourceRecord -ZoneName $zone -RRType A | Sort-Object HostName


Set-DnsServerForwarder -IPAddress 10.10.20.1 -UseRootHint $false -Timeout 3
Get-DnsServerForwarder


# 5.1 Installation et autorisation
Install-WindowsFeature DHCP -IncludeManagementTools
netsh dhcp add securitygroups
Restart-Service DHCPServer
Add-DhcpServerInDC -DnsName "dc01.ad.valdore-services.fr" -IPAddress 10.10.20.10
Set-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12 -Name ConfigurationState -Value 2

# 5.2 Étendue et options
Add-DhcpServerv4Scope -Name "Postes VLAN 100" -StartRange 10.10.100.50 -EndRange 10.10.100.249 `
    -SubnetMask 255.255.255.0 -LeaseDuration 0.08:00:00 -State Active
Set-DhcpServerv4OptionValue -ScopeId 10.10.100.0 -Router 10.10.100.1 `
    -DnsServer 10.10.20.10 -DnsDomain "ad.valdore-services.fr"
Set-DhcpServerv4OptionValue -ScopeId 10.10.100.0 -OptionId 119 -Value "ad.valdore-services.fr"

# 5.3 Mises à jour DNS par le DHCP
Set-DhcpServerv4DnsSetting -DynamicUpdates Always -DeleteDnsRROnLeaseExpiry $true `
    -UpdateDnsRRForOlderClients $true -NameProtection $true
New-ADUser -Name "svc-dhcp-dns" -AccountPassword (Read-Host -AsSecureString "Mot de passe") `
    -PasswordNeverExpires $true -CannotChangePassword $true -Enabled $true
Set-DhcpServerDnsCredential -Credential (Get-Credential "VALDORE\svc-dhcp-dns") -ComputerName dc01
Restart-Service DHCPServer


# 1. Aucun transfert ni notification sur toutes les zones primaires
Get-DnsServerZone | Where-Object { $_.ZoneType -eq "Primary" -and -not $_.IsAutoCreated } |
    ForEach-Object { Set-DnsServerPrimaryZone -Name $_.ZoneName -SecureSecondaries NoTransfer -Notify NoNotify }

# 4. Écoute sur l'adresse du serveur uniquement
Set-DnsServerSetting -ListeningIPAddress 10.10.20.10

# 6. Contrôle du groupe DnsAdmins (doit être vide)
Get-ADGroupMember DnsAdmins

# 7. Journal analytique (requêtes et réponses)
wevtutil sl "Microsoft-Windows-DNSServer/Analytical" /e:true /q:true

# 8. Limitation du débit des réponses
Set-DnsServerResponseRateLimiting -Mode Enable -Force

# 9. Cache et sockets
Set-DnsServerCache -LockingPercent 100
dnscmd /config /socketpoolsize 10000
Restart-Service DNS

# 10. Liste globale de blocage
Get-DnsServerGlobalQueryBlockList   # doit contenir wpad et isatap