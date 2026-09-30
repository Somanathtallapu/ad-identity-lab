# =============================================================
#  New-UserOnboarding.ps1
#  JML onboarding automation for Active Directory
#
#  Reads a CSV of new hires, creates each account in the OU that
#  matches their department, assigns the department's role group,
#  sets an expiration date for contractors, and logs every result.
#
#  Usage:  .\New-UserOnboarding.ps1
#  Domain: somu.local
# =============================================================

# ---- Configuration ----

$CsvPath = "C:\IAM\new-hires.csv"
$LogPath = "C:\IAM\onboarding-log.txt"
$Domain  = "somu.local"

# Department -> OU and security group.
# Adding a new department means adding one line here, not new logic.
$DeptMap = @{
    "Finance" = @{ OU = "OU=Finance,DC=somu,DC=local"; Group = "Finance-Staff" }
    "HR"      = @{ OU = "OU=HR,DC=somu,DC=local";      Group = "HR-Staff" }
    "IT"      = @{ OU = "OU=IT,DC=somu,DC=local";      Group = "Helpdesk" }
}

# ---- Logging ----

# Writes a timestamped line to both the log file and the screen.
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "$timestamp [$Level] $Message"
    Add-Content -Path $LogPath -Value $line
    Write-Host $line
}

# ---- Input ----

# Prompt for the initial password rather than storing it in the script.
$Password = Read-Host -AsSecureString "Enter initial password for new accounts"

# ---- Main ----

Write-Log "=== Onboarding run started ==="

$users   = Import-Csv -Path $CsvPath
$created = 0
$skipped = 0
$failed  = 0

foreach ($user in $users) {

    $sam         = ("{0}.{1}" -f $user.FirstName, $user.LastName).ToLower()
    $upn         = "$sam@$Domain"
    $displayName = "$($user.FirstName) $($user.LastName)"

    Write-Log "Processing $displayName ($sam)"

    try {
        # Re-running the script should not error on existing accounts.
        if (Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue) {
            Write-Log "$sam already exists - skipping" "WARN"
            $skipped++
            continue
        }

        # Look up where this person belongs.
        $dept = $DeptMap[$user.Department]
        if (-not $dept) {
            Write-Log "No mapping for department '$($user.Department)' - skipping $sam" "ERROR"
            $failed++
            continue
        }

        # Create the account.
        New-ADUser -Name $displayName `
            -GivenName $user.FirstName `
            -Surname $user.LastName `
            -SamAccountName $sam `
            -UserPrincipalName $upn `
            -Path $dept.OU `
            -AccountPassword $Password `
            -Enabled $true `
            -Department $user.Department `
            -Title $user.Title `
            -ChangePasswordAtLogon $true

        Write-Log "Created $sam in $($dept.OU)"

        # Access comes from the group, never assigned to the user directly.
        Add-ADGroupMember -Identity $dept.Group -Members $sam
        Write-Log "Added $sam to $($dept.Group)"

        # Contractors expire automatically so nobody has to remember.
        if ($user.Type -eq "Contractor" -and $user.EndDate) {
            Set-ADAccountExpiration -Identity $sam -DateTime $user.EndDate
            Write-Log "Set expiration for $sam to $($user.EndDate)"
        }

        $created++
    }
    catch {
        # One bad row should not stop the run.
        Write-Log "FAILED to create $sam - $($_.Exception.Message)" "ERROR"
        $failed++
    }
}

Write-Log "=== Run complete: $created created, $skipped skipped, $failed failed ==="
