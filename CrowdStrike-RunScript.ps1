#Requires -Version 5.1
using module @{ModuleName='PSFalcon';ModuleVersion='2.2'}
[CmdletBinding()]
param(
    [Parameter(Mandatory,Position=1)]
    [ValidatePattern('^[a-fA-F0-9]{32}$')]
    [string]$ClientId,
    [Parameter(Mandatory,Position=2)]
    [ValidatePattern('^\w{40}$')]
    [string]$ClientSecret,
    [Parameter(Position=3)]
    [ValidatePattern('^[a-fA-F0-9]{32}$')]
    [string]$MemberCid,
    [Parameter(Position=4)]
    [ValidateSet('us-1','us-2','us-gov-1','eu-1')]
    [string]$Cloud
)
begin {
    $Token = @{}
    @('ClientId','ClientSecret','Cloud','MemberCid').foreach{
        if ($PSBoundParameters.$_) { $Token[$_] = $PSBoundParameters.$_ }
    }
}
process {
    try {
        Request-FalconToken @Token
        if ((Test-FalconToken).Token -eq $true) {
            $HostList = Get-FalconHost -Filter "product_type_desc:'Workstation'+platform_name:'Windows'" -All -Detailed
            #$HostList = Get-FalconHost -Filter "platform_name:'Windows'+last_seen:>'now-15m'" -All -Detailed
            #$HostList = Get-FalconHost -Filter "hostname:['computer1','computer2']" -All -Detailed
            #$HostList = Get-FalconHost -Detailed | Where-Object {($_.hostname -eq 'computer1') -or ($_.hostname -eq 'computer2')}
            foreach ($1Host in $HostList) {
                invoke-falconrtr runscript "-cloudfile='Hybrid AAD Join'" -HostId $1Host.device_id -QueueOffline $True
            }
            #invoke-falconrtr runscript "-cloudfile='Hybrid AAD Join'" -host_ids '72baf746fa654d99b02e478402c1857b' -QueueOffline $True
            #$HostList
        }
    } catch {
        throw $_
    } finally {
        if ((Test-FalconToken).Token -eq $true) { Revoke-FalconToken }
    }
}