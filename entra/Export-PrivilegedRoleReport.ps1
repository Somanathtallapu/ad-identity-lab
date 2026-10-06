<#
    Export-PrivilegedRoleReport.ps1
    Exports every active directory role assignment in the tenant to CSV.
    Read-only. Requires: RoleManagement.Read.Directory, User.Read.All, Directory.Read.All
#>

$OutDir  = "$env:USERPROFILE\Documents\IAM"
$Stamp   = Get-Date -Format "yyyyMMdd-HHmmss"
$OutFile = Join-Path $OutDir "privileged-role-report-$Stamp.csv"

# Roles that confer tenant-takeover capability, directly or by escalation path
$HighRisk = @(
    "Global Administrator",
    "Privileged Role Administrator",
    "Privileged Authentication Administrator",
    "Application Administrator",
    "Cloud Application Administrator",
    "Authentication Administrator",
    "User Administrator",
    "Security Administrator",
    "Exchange Administrator",
    "SharePoint Administrator"
)

# Fail fast if not connected, rather than erroring one call at a time
$ctx = Get-MgContext
if (-not $ctx) {
    Write-Host "Not connected. Run Connect-MgGraph first." -ForegroundColor Red
    return
}
Write-Host "Tenant : $($ctx.TenantId)"
Write-Host "Scopes : $($ctx.Scopes -join ', ')`n"

$results = @()

foreach ($role in Get-MgDirectoryRole -All) {

    $members = Get-MgDirectoryRoleMember -DirectoryRoleId $role.Id -All

    if (-not $members) {
        $results += [PSCustomObject]@{
            RoleName       = $role.DisplayName
            MemberType     = "(none)"
            DisplayName    = ""
            UserPrincipal  = ""
            AccountEnabled = ""
            UserType       = ""
            ObjectId       = ""
            HighRisk       = ($HighRisk -contains $role.DisplayName)
        }
        continue
    }

    foreach ($m in $members) {

        # Graph returns directory objects; the odata type says what kind
        $type = $m.AdditionalProperties.'@odata.type' -replace '#microsoft.graph.',''

        $name = ""; $upn = ""; $enabled = ""; $utype = ""

        switch ($type) {
            "user" {
                try {
                    $u = Get-MgUser -UserId $m.Id -Property DisplayName,UserPrincipalName,AccountEnabled,UserType
                    $name = $u.DisplayName; $upn = $u.UserPrincipalName
                    $enabled = $u.AccountEnabled; $utype = $u.UserType
                } catch { $name = "(could not resolve)" }
            }
            "group" {
                try { $name = (Get-MgGroup -GroupId $m.Id).DisplayName } catch { $name = "(could not resolve)" }
            }
            "servicePrincipal" {
                try { $name = (Get-MgServicePrincipal -ServicePrincipalId $m.Id).DisplayName } catch { $name = "(could not resolve)" }
            }
        }

        $results += [PSCustomObject]@{
            RoleName       = $role.DisplayName
            MemberType     = $type
            DisplayName    = $name
            UserPrincipal  = $upn
            AccountEnabled = $enabled
            UserType       = $utype
            ObjectId       = $m.Id
            HighRisk       = ($HighRisk -contains $role.DisplayName)
        }
    }
}

$results | Sort-Object -Property @{Expression="HighRisk";Descending=$true}, RoleName |
    Export-Csv -Path $OutFile -NoTypeInformation

# Console summary
$results | Where-Object { $_.MemberType -ne "(none)" } |
    Sort-Object -Property @{Expression="HighRisk";Descending=$true}, RoleName |
    Format-Table RoleName, MemberType, DisplayName, UserType, HighRisk -AutoSize

$assigned = @($results | Where-Object { $_.MemberType -ne "(none)" }).Count
$risky    = @($results | Where-Object { $_.HighRisk -and $_.MemberType -ne "(none)" }).Count
$guests   = @($results | Where-Object { $_.UserType -eq "Guest" -and $_.HighRisk }).Count

Write-Host ""
Write-Host "Assignments found      : $assigned"
Write-Host "In high-risk roles     : $risky"
Write-Host "Guests in high-risk    : $guests" -ForegroundColor $(if ($guests -gt 0) { "Red" } else { "Green" })
Write-Host "Report written to      : $OutFil
