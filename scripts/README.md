# JML Onboarding Automation

PowerShell automation for the **Joiner** stage of the identity lifecycle. Reads a
CSV of new hires, creates each Active Directory account in the OU that matches
their department, assigns the department's role group, sets an expiration date
for contractors, and writes a timestamped audit log.

Built against the `somu.local` lab domain (see the main README).

---

## Why automate this

Onboarding by hand means typing four or five commands per person. That is slow,
but the real problem is **consistency**: every manual run is a chance to typo a
group name, put someone in the wrong OU, or forget the expiration date on a
contractor. Three months later nobody can explain why one intern has more access
than another.

A script produces the same result from the same input, every time — and leaves a
record proving what it did.

---

## How it works

```
new-hires.csv
     │
     ▼
For each row:
     ├── Already exists?  ──► log WARN, skip
     ├── Look up department → OU + security group
     ├── Create the AD account (must change password at logon)
     ├── Add to the department's role group
     ├── Contractor? ──► set account expiration
     └── Log the result
     │
     ▼
onboarding-log.txt  +  summary on screen
```

### Input

`new-hires.csv`

```csv
FirstName,LastName,Department,Title,Type,EndDate
Aarav,Patel,Finance,Financial Analyst,Permanent,
Nina,Okafor,HR,HR Specialist,Permanent,
Tom,Riley,IT,IT Intern,Contractor,2026-12-31
```

### Department mapping

Routing is a lookup table rather than a chain of if-statements:

```powershell
$DeptMap = @{
    "Finance" = @{ OU = "OU=Finance,DC=somu,DC=local"; Group = "Finance-Staff" }
    "HR"      = @{ OU = "OU=HR,DC=somu,DC=local";      Group = "HR-Staff" }
    "IT"      = @{ OU = "OU=IT,DC=somu,DC=local";      Group = "Helpdesk" }
}
```

Adding a department means adding one line. No new logic, no risk of breaking what
already works.

---

## Design decisions

**Access comes from groups, never direct assignment.** The script adds each user
to their department's security group rather than granting permissions to the
account. That is RBAC, and it is what makes an access review answerable.

**Contractors expire automatically.** `Set-ADAccountExpiration` means nobody has
to remember to offboard a temp. Orphaned contractor accounts are a standard audit
finding.

**`-ChangePasswordAtLogon $true`.** The admin sets an initial password but the
user must replace it on first login, so no administrator ends up knowing a live
user password.

**The password is prompted for, not stored.** `Read-Host -AsSecureString` keeps it
out of the script file and out of the shell history.

**`try` / `catch` around each user.** One bad row logs an error and the run
continues. Without it, a single failure kills the whole batch.

**An existence check makes it safe to re-run.** Scripts get re-run — after a
partial failure, after someone adds a row to the CSV. The script skips accounts
that already exist instead of erroring out.

**Everything is logged with a timestamp.** The log is what answers *"who was
provisioned, when, and by what process."*

---

## Sample run

First run — three accounts created:

```
2026-09-29 17:04:54 [INFO] === Onboarding run started ===
2026-09-29 17:04:54 [INFO] Processing Aarav Patel (aarav.patel)
2026-09-29 17:04:54 [INFO] Created aarav.patel in OU=Finance,DC=somu,DC=local
2026-09-29 17:04:55 [INFO] Added aarav.patel to Finance-Staff
2026-09-29 17:04:55 [INFO] Processing Nina Okafor (nina.okafor)
2026-09-29 17:04:55 [INFO] Created nina.okafor in OU=HR,DC=somu,DC=local
2026-09-29 17:04:55 [INFO] Added nina.okafor to HR-Staff
2026-09-29 17:04:55 [INFO] Processing Tom Riley (tom.riley)
2026-09-29 17:04:55 [INFO] Created tom.riley in OU=IT,DC=somu,DC=local
2026-09-29 17:04:55 [INFO] Added tom.riley to Helpdesk
2026-09-29 17:04:55 [INFO] Set expiration for tom.riley to 2026-12-31
2026-09-29 17:04:55 [INFO] === Run complete: 3 created, 0 skipped, 0 failed ===
```

Second run — nothing duplicated:

```
2026-09-29 17:08:59 [INFO] === Onboarding run started ===
2026-09-29 17:08:59 [INFO] Processing Aarav Patel (aarav.patel)
2026-09-29 17:08:59 [WARN] aarav.patel already exists - skipping
2026-09-29 17:08:59 [INFO] Processing Nina Okafor (nina.okafor)
2026-09-29 17:08:59 [WARN] nina.okafor already exists - skipping
2026-09-29 17:08:59 [INFO] Processing Tom Riley (tom.riley)
2026-09-29 17:08:59 [WARN] tom.riley already exists - skipping
2026-09-29 17:08:59 [INFO] === Run complete: 0 created, 3 skipped, 0 failed ===
```

### Verified in AD

```powershell
Get-ADUser -Filter * -Properties Department, AccountExpirationDate |
  Select-Object Name, SamAccountName, Department, AccountExpirationDate, Enabled
```

| Name | SamAccountName | Department | AccountExpirationDate | Enabled |
|---|---|---|---|---|
| Aarav Patel | aarav.patel | Finance | — | True |
| Nina Okafor | nina.okafor | HR | — | True |
| Tom Riley | tom.riley | IT | 12/31/2026 | True |

Only the contractor has an expiration date — the conditional logic read `Type`
from the CSV and acted on it.

---

## Running it

```powershell
# Requires the ActiveDirectory module and rights to create users in the target OUs
.\New-UserOnboarding.ps1
```

The script prompts for an initial password, then processes every row in
`C:\IAM\new-hires.csv`.

---

## Problems hit while building it

**Empty SecureString.** The first version defined `$Password` *after* the main
loop, so an empty SecureString reached `New-ADUser` and the domain rejected it:
*"The password does not meet the length, complexity, or history requirement."*
Useful failure — it proved the `try`/`catch` worked, since the run logged the
error and carried on rather than crashing.

**Order of operations matters.** PowerShell executes top to bottom. Anything the
main loop depends on has to be defined above it.

---

## Next

- Extend to Mover: read a change file, add new groups, remove old ones, move the
  OU
- Extend to Leaver: disable, strip group memberships, log for retention
- Replace the CSV with a live HR feed
- Port the same logic to Microsoft Graph for Entra ID
