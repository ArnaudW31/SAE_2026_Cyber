# --- 0. Adresse fixe de DC01 -----------------------------------------
$if = (Get-NetAdapter | Where-Object Status -eq "Up" | Select-Object -First 1).Name
Set-NetIPInterface -InterfaceAlias $if -AddressFamily IPv4 -Dhcp Disabled
Get-NetIPAddress -InterfaceAlias $if -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Remove-NetIPAddress -Confirm:$false
Get-NetRoute -InterfaceAlias $if -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
    Remove-NetRoute -Confirm:$false
New-NetIPAddress -InterfaceAlias $if -IPAddress 10.10.20.10 -PrefixLength 24 -DefaultGateway 10.10.20.1
Set-DnsClientServerAddress -InterfaceAlias $if -ServerAddresses 10.10.20.10,127.0.0.1

Get-WindowsFeature DNS, RSAT-DNS-Server
# Install-WindowsFeature DNS -IncludeManagementTools   # seulement s'il manque

ipconfig /registerdns
Restart-Service Netlogon

# --- 1.1 Zone AD -----------------------------------------------------
Get-DnsServerZone | Format-Table ZoneName, ZoneType, IsDsIntegrated, ReplicationScope, DynamicUpdate
Set-DnsServerPrimaryZone -Name "ad.valdore-services.fr" -ReplicationScope Domain -DynamicUpdate Secure
Set-DnsServerPrimaryZone -Name "_msdcs.ad.valdore-services.fr" -DynamicUpdate Secure

# --- 1.2 Vieillissement et nettoyage (7 + 7 jours) -------------------
Set-DnsServerZoneAging -Name "ad.valdore-services.fr" -Aging $true -NoRefreshInterval 7.00:00:00 -RefreshInterval 7.00:00:00
Set-DnsServerScavenging -ScavengingState $true -ScavengingInterval 7.00:00:00 -ApplyOnAllZones

# --- 1.3 Vue interne de valdore-services.fr (split DNS) --------------
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

# --- 2. Zones inverses -----------------------------------------------
$reseaux = "10.10.10.0/24","10.10.20.0/24","10.10.30.0/24","10.10.40.0/24",
           "10.10.50.0/24","10.10.100.0/24","10.10.200.0/24","10.10.201.0/24"
foreach ($r in $reseaux) {
    Add-DnsServerPrimaryZone -NetworkId $r -ReplicationScope Domain -DynamicUpdate Secure
}
Add-DnsServerPrimaryZone -NetworkId "172.16.10.0/24" -ReplicationScope Domain -DynamicUpdate None

Get-DnsServerZone | Where-Object IsReverseLookupZone | Where-Object IsDsIntegrated |
    ForEach-Object { Set-DnsServerZoneAging -Name $_.ZoneName -Aging $true }
Get-DnsServerZone | Where-Object IsReverseLookupZone

# --- 3. Enregistrements A + PTR des serveurs --------------------------
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
if (-not (Get-DnsServerResourceRecord -ZoneName "20.10.10.in-addr.arpa" -Name "10" -RRType Ptr -ErrorAction SilentlyContinue)) {
    Add-DnsServerResourceRecordPtr -ZoneName "20.10.10.in-addr.arpa" -Name "10" -PtrDomainName "dc01.ad.valdore-services.fr"
}
Get-DnsServerResourceRecord -ZoneName $zone -RRType A | Sort-Object HostName

# --- 4. Redirecteur vers Unbound (OPNsense) ---------------------------
Set-DnsServerForwarder -IPAddress 10.10.20.1 -UseRootHint $false -Timeout 3
Get-DnsServerForwarder

# --- 5. DHCP ----------------------------------------------------------
Install-WindowsFeature DHCP -IncludeManagementTools
netsh dhcp add securitygroups
Restart-Service DHCPServer
Add-DhcpServerInDC -DnsName "dc01.ad.valdore-services.fr" -IPAddress 10.10.20.10
Set-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12 -Name ConfigurationState -Value 2

Add-DhcpServerv4Scope -Name "Postes VLAN 100" -StartRange 10.10.100.50 -EndRange 10.10.100.249 `
    -SubnetMask 255.255.255.0 -LeaseDuration 0.08:00:00 -State Active
Set-DhcpServerv4OptionValue -ScopeId 10.10.100.0 -Router 10.10.100.1 `
    -DnsServer 10.10.20.10 -DnsDomain "ad.valdore-services.fr"
# Pas d'option 119 : Windows la stocke en texte brut, illisible pour les clients (RFC 3397).

Set-DhcpServerv4DnsSetting -DynamicUpdates Always -DeleteDnsRROnLeaseExpiry $true `
    -UpdateDnsRRForOlderClients $true -NameProtection $true
New-ADUser -Name "svc-dhcp-dns" -SamAccountName "svc-dhcp-dns" `
    -UserPrincipalName "svc-dhcp-dns@ad.valdore-services.fr" `
    -Description "Mises a jour DNS du DHCP de DC01" `
    -AccountPassword (Read-Host -AsSecureString "Mot de passe") `
    -PasswordNeverExpires $true -CannotChangePassword $true -Enabled $true
Set-DhcpServerDnsCredential -Credential (Get-Credential "VALDORE\svc-dhcp-dns") -ComputerName "dc01"
Restart-Service DHCPServer

Get-DhcpServerv4Scope
Get-DhcpServerv4OptionValue -ScopeId 10.10.100.0
Get-DhcpServerv4DnsSetting
Get-DhcpServerDnsCredential

# --- 6. Durcissement --------------------------------------------------
Get-DnsServerZone | Where-Object { $_.ZoneType -eq "Primary" -and -not $_.IsAutoCreated -and $_.ZoneName -ne "TrustAnchors" } |
    ForEach-Object { Set-DnsServerPrimaryZone -Name $_.ZoneName -SecureSecondaries NoTransfer -Notify NoNotify }
Get-DnsServerZone | Select-Object ZoneName, SecureSecondaries, Notify

Get-ADGroupMember DnsAdmins            # doit être vide
wevtutil sl "Microsoft-Windows-DNSServer/Analytical" /e:true /q:true
Set-DnsServerResponseRateLimiting -Mode Enable -Force
Set-DnsServerCache -LockingPercent 100
dnscmd /config /socketpoolsize 10000
Restart-Service DNS
Get-DnsServerGlobalQueryBlockList      # doit contenir wpad et isatap

# --- 7. Vérifications -------------------------------------------------
dcdiag /test:dns /v /e
Test-DnsServer -IPAddress 10.10.20.10 -ZoneName "ad.valdore-services.fr"
Resolve-DnsName _ldap._tcp.dc._msdcs.ad.valdore-services.fr -Type SRV
Resolve-DnsName fs01.ad.valdore-services.fr
Resolve-DnsName www.valdore-services.fr      # attendu : 172.16.10.10