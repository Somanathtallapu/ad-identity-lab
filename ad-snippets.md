# Active Directory PowerShell Snippets

Command reference built while setting up the `somu.local` lab domain.
Environment: Windows Server 2025 on VirtualBox, DC01 @ 10.0.2.15

---

## Discovery — when you forget a command

```powershell
# Find commands by keyword
Get-Command *ADUser*

# Show real working examples for any cmdlet
Get-Help New-ADUser -Examples

# List every property an object has (so you know what you can query/set)
Get-ADUser priya.sharma -Properties * | Get-Member
```

**Tip:** Type part of a command or parameter and press `Tab` to autocomplete.
Prevents typos.

**The pattern:** PowerShell is verb-noun. Learn the verbs (`Get`, `New`, `Set`,
`Remove`, `Add`, `Enable`, `Disable`) and the nouns (`ADUser`, `ADGroup`,
`ADGroupMember`, `ADOrganizationalUnit`) and you can guess most commands.

---

## Domain and DC info

```powershell
# Domain details
Get-ADDomain | Select-Object Name, DNSRoot, NetBIOSName, DomainMode

# Domain controller details
Get-ADDomainController | Select-Object Name, IPv4Address, IsGlobalCatalog, Site

# Forest details
Get-ADForest | Select-Object Name, ForestMode, GlobalCatalogs, Domains
```

---

## Organizational Units

OUs are for **management** — Group Policy links to them, and admin rights can be
delegated per-OU. A user lives in exactly one OU. (Groups are for access; a user
can be in many.)

```powershell
# Create an OU at the domain root
New-ADOrganizationalUnit -Name "Finance" -Path "DC=somu,DC=local"

# List all OUs
Get-ADOrganizationalUnit -Filter * | Select-Object Name, DistinguishedName

# Move an object into a different OU
Move-ADObject -Identity "CN=Priya Sharma,OU=Finance,DC=somu,DC=local" `
  -TargetPath "OU=HR,DC=somu,DC=local"
```

**Distinguished Name (DN)** reads right-to-left, like a reversed file path:
`OU=Finance,DC=somu,DC=local`

Note: `CN=Users` is a **container**, not an OU — Group Policy can't be linked to
it. That's why real companies move users into proper OUs.

---

## Users

```powershell
# Prompt for a password securely (never hardcode passwords)
$pw = Read-Host -AsSecureString "Enter password"

# Create a user
New-ADUser -Name "Priya Sharma" `
  -GivenName "Priya" -Surname "Sharma" `
  -SamAccountName "priya.sharma" `
  -UserPrincipalName "priya.sharma@somu.local" `
  -Path "OU=Finance,DC=somu,DC=local" `
  -AccountPassword $pw -Enabled $true `
  -Department "Finance" -Title "Financial Analyst"

# List users with useful properties
Get-ADUser -Filter * -Properties Department |
  Select-Object Name, SamAccountName, Department, Enabled, DistinguishedName

# Modify an existing user
Set-ADUser -Identity "priya.sharma" -Title "Senior Financial Analyst"
Set-ADUser -Identity "priya.sharma" -Description "HR - Terminated 09/21/2026"

# Set an expiration date (contractors, interns)
Set-ADAccountExpiration -Identity "intern.user" -DateTime "2026-12-15"
Clear-ADAccountExpiration -Identity "intern.user"
```

| Field | What it is |
|---|---|
| `SamAccountName` | Legacy login format — `SOMU\priya.sharma` |
| `UserPrincipalName` | Modern login, email-style — carries into Entra ID |
| `Path` | Which OU the account is created in |
| `Department` / `Title` | Metadata that drives dynamic groups and access reviews |

**Note:** `$pw` does not survive a reboot. Re-run `Read-Host` after restarting, or
AD rejects the blank password with a complexity error.

---

## Groups

Groups are for **access**. Permissions attach to groups, never to individual users.

```powershell
# Create a security group
New-ADGroup -Name "Finance-Staff" -GroupScope Global -GroupCategory Security `
  -Path "OU=Finance,DC=somu,DC=local"

# Add a member
Add-ADGroupMember -Identity "Finance-Staff" -Members "priya.sharma"

# Remove a member (the step people forget on a Mover)
Remove-ADGroupMember -Identity "Finance-Staff" -Members "priya.sharma"

# List direct members
Get-ADGroupMember -Identity "Finance-Staff" | Select-Object Name, SamAccountName

# See what groups a user belongs to
Get-ADPrincipalGroupMembership priya.sharma | Select-Object Name
```

**Gotcha:** AD cmdlets use `-Identity`. The *local* account cmdlets
(`Add-LocalGroupMember`) use `-Group`. Same job, different parameter name.

**Gotcha:** `-GroupCategory Security` grants access. `Distribution` is email-only
and **cannot** grant access — common interview trap.

### Group scopes

| Scope | Can contain | Use for |
|---|---|---|
| Domain Local | Users/groups from any domain | Assigning permissions to a resource |
| Global | Users from its own domain | Grouping users by role |
| Universal | Users from any domain in the forest | Multi-domain forests |

**AGDLP** — Microsoft's recommended model:
**A**ccounts → **G**lobal groups → **D**omain **L**ocal groups → **P**ermissions

### Nested groups

```powershell
# A group can contain other groups
New-ADGroup -Name "All-Employees" -GroupScope Global -GroupCategory Security `
  -Path "DC=somu,DC=local"
Add-ADGroupMember -Identity "All-Employees" -Members "Finance-Staff","HR-Staff"

# Direct members only — returns the GROUPS
Get-ADGroupMember -Identity "All-Employees"

# Walks down through nesting — returns the actual USERS
Get-ADGroupMember -Identity "All-Employees" -Recursive
```

`-Recursive` is the access-review command. It answers *"who actually has this
access?"* rather than just listing direct members.

Nested groups are where **privilege creep** hides — someone joins a harmless group
nested two levels up inside one with elevated rights.

⚠️ **Token bloat:** every group membership goes into the user's Kerberos ticket.
Too many nested groups and the ticket exceeds its size limit and login fails.

---

## Joiner / Mover / Leaver (JML)

The core lifecycle of an IAM role.

### Joiner
```powershell
New-ADUser -Name "..." -SamAccountName "..." -Path "OU=...,DC=somu,DC=local" `
  -AccountPassword $pw -Enabled $true
Add-ADGroupMember -Identity "Finance-Staff" -Members "new.user"
```

### Mover
```powershell
# Add new access
Add-ADGroupMember -Identity "HR-Staff" -Members "the.user"

# Remove old access — skipping this causes PRIVILEGE CREEP
Remove-ADGroupMember -Identity "Finance-Staff" -Members "the.user"

# Move the account to the new OU
Move-ADObject -Identity "CN=The User,OU=Finance,DC=somu,DC=local" `
  -TargetPath "OU=HR,DC=somu,DC=local"

# Update stale metadata
Set-ADUser -Identity "the.user" -Department "HR" -Title "HR Coordinator"
```

### Leaver
```powershell
# Disable, don't delete — preserves the account for audit/investigation
Disable-ADAccount -Identity "the.user"

# Strip group memberships so a mistaken re-enable doesn't restore full access
Remove-ADGroupMember -Identity "HR-Staff" -Members "the.user"

# Verify
Get-ADUser "the.user" | Select-Object Name, Enabled
```

**Disabling does NOT remove group memberships.** A complete leaver process strips
groups too.

**Temporary staff:** set an expiration date so the account auto-disables.
Orphaned accounts are a top audit finding.

---

## Group Policy

```powershell
# List all GPOs in the domain
Get-GPO -All | Select-Object DisplayName, GpoStatus, CreationTime

# What actually applies to a container, and in what order
Get-GPInheritance -Target "OU=Finance,DC=somu,DC=local"

# Force a refresh instead of waiting 90 minutes
gpupdate /force

# See what applied to a specific user/computer
gpresult /r
```

**Reading `Get-GPInheritance`:**

| Field | Meaning |
|---|---|
| `GpoLinks` | Linked directly to this container (raw link order) |
| `InheritedGpoLinks` | Everything that actually applies, in winning order |
| `GpoInheritanceBlocked` | If Yes, policies from above are ignored |

### Precedence — in order of strength

1. **Enforced** GPOs — nothing overrides these
2. **Closest container** — OU beats domain beats site (**LSDOU**)
3. **Link order** — lower number wins at the same level
4. **Block Inheritance** stops 2 and 3 from above, but never 1

**Processing order:** Local → Site → Domain → OU. Last one processed wins, so
link order 1 is written last and therefore wins.

**Two halves of every GPO:**
- **Computer Configuration** — applies at boot (password policy, firewall)
- **User Configuration** — applies at login (wallpaper, drive mappings)

Putting a setting in the wrong half silently does nothing.

**Refresh cycle:** every 90 minutes with a random 0–30 minute offset, so thousands
of machines don't hammer the DC simultaneously.

---

## Password policy

Password policy is **domain-wide** — one per domain, set in the Default Domain
Policy. Linking a password GPO to an OU does nothing for domain accounts.

```powershell
# See the domain default
Get-ADDefaultDomainPasswordPolicy
```

⚠️ Default `LockoutThreshold` is **0** — lockout disabled, unlimited password
guesses. Every real deployment changes this.

### Fine-Grained Password Policies (PSO)

A PSO targets a **group or user**, not an OU.

```powershell
New-ADFineGrainedPasswordPolicy -Name "Admin-Password-Policy" -Precedence 10 `
  -MinPasswordLength 20 -PasswordHistoryCount 24 -ComplexityEnabled $true `
  -LockoutThreshold 3 -LockoutDuration "00:30:00" `
  -LockoutObservationWindow "00:30:00" -MaxPasswordAge "30.00:00:00"

# Scope it to a group
Add-ADFineGrainedPasswordPolicySubject -Identity "Admin-Password-Policy" `
  -Subjects "Domain Admins"

# List PSOs
Get-ADFineGrainedPasswordPolicy -Filter * |
  Select-Object Name, Precedence, MinPasswordLength, LockoutThreshold

# What actually applies to a specific person
Get-ADUserResultantPasswordPolicy -Identity "Administrator"

# Fix a default you didn't choose
Set-ADFineGrainedPasswordPolicy -Identity "Admin-Password-Policy" `
  -ReversibleEncryptionEnabled $false
```

**Lowest precedence number wins** when multiple PSOs apply.

**Empty result** from `Get-ADUserResultantPasswordPolicy` means no PSO applies and
the account falls back to the domain default — not an error.

⚠️ **Read back every property after creating a policy object**, not just the ones
you set. `ReversibleEncryptionEnabled` defaulted to `True` on creation, which
stores passwords recoverably.

### Lockout trade-off

Lockout protects against brute force but creates a **denial-of-service** opening:
with a threshold of 3, an attacker can lock out the whole company with three bad
guesses per account. Current NIST guidance leans toward longer passwords and MFA
over aggressive lockout.

---

## Delegation

Grant a specific right on a specific OU instead of handing out Domain Admin.

**GUI:** ADUC → right-click the OU → **Delegate Control...** → select group →
choose the task.

```powershell
# Verify what was delegated
(Get-Acl "AD:OU=HR,DC=somu,DC=local").Access |
  Where-Object {$_.IdentityReference -like "*Helpdesk*"} |
  Select-Object IdentityReference, ActiveDirectoryRights, ObjectType

# Confirm the boundary — should return nothing for other OUs
(Get-Acl "AD:OU=Finance,DC=somu,DC=local").Access |
  Where-Object {$_.IdentityReference -like "*Helpdesk*"}
```

Delegation is just **ACEs** (Access Control Entries) written onto the OU object.
The wizard is a friendly front-end for editing permissions.

**Fixed GUIDs, identical in every AD deployment:**

| GUID | Right |
|---|---|
| `00299570-246d-11d0-a768-00aa006e0529` | Reset Password |
| `bf967a0a-0de6-11d0-a285-00aa003049e2` | pwdLastSet (force change at next logon) |

**Reset vs Change:** *change* requires the old password, *reset* does not. Anyone
who can reset a password can take over that account — so delegating Reset Password
over an OU with privileged accounts creates an escalation path. Tools like
BloodHound map exactly these delegation chains.

---

## Service accounts

Non-human identities. The most dangerous objects in AD: passwords that never
rotate, privileges nobody trimmed, and no clear owner.

### Traditional service account

```powershell
New-ADUser -Name "svc-sql" -SamAccountName "svc-sql" `
  -UserPrincipalName "svc-sql@somu.local" -Path "OU=IT,DC=somu,DC=local" `
  -AccountPassword $pw -Enabled $true -PasswordNeverExpires $true `
  -Description "SQL Server service account - owner: IT DBA team"

# Register a Service Principal Name
setspn -S MSSQLSvc/sql01.somu.local:1433 svc-sql

# List SPNs on an account
setspn -L svc-sql
```

Always record an **owner** in the Description. Service accounts with no recorded
owner are a standard audit finding.

### Group Managed Service Account (gMSA)

AD generates a 240-character password and rotates it every 30 days. Nobody ever
knows it. Cannot be used for interactive logon.

```powershell
# One-time per forest
Add-KdsRootKey -EffectiveTime ((Get-Date).AddHours(-10))

New-ADServiceAccount -Name "gmsa-backup" -DNSHostName "gmsa-backup.somu.local" `
  -PrincipalsAllowedToRetrieveManagedPassword "Domain Controllers"

# List gMSAs (Get-ADUser won't find them — different ObjectClass)
Get-ADServiceAccount -Filter * | Select-Object Name, ObjectClass, Enabled

Get-ADServiceAccount -Identity "gmsa-backup" -Properties * |
  Select-Object Name, PrincipalsAllowedToRetrieveManagedPassword, `
    ManagedPasswordIntervalInDays
```

| | Traditional | gMSA |
|---|---|---|
| Password | human-set, never rotates | 240 chars, auto-rotated |
| Anyone knows it | yes | no |
| Interactive logon | possible | blocked |
| Kerberoastable | yes | not usefully |

**Kerberoasting:** any domain user can request a service ticket for an account
with an SPN. The ticket is encrypted with that account's password hash, so it can
be cracked offline. Weak password = domain compromise. Mitigation: long random
passwords, or gMSA.

**Duplicate SPNs** break authentication entirely — a classic "service account
can't authenticate" ticket.

---

## Auditing and event logs

Auditing only records **forward**. Enable it today and you get nothing about
yesterday — step one when inheriting an environment.

```powershell
# Check what's currently enabled
auditpol /get /category:*

# Enable the categories that matter
auditpol /set /subcategory:"User Account Management" /success:enable /failure:enable
auditpol /set /subcategory:"Security Group Management" /success:enable /failure:enable
auditpol /set /subcategory:"Logon" /success:enable /failure:enable
auditpol /set /subcategory:"Kerberos Service Ticket Operations" /success:enable /failure:enable
```

In production these are set via **Group Policy** (Advanced Audit Policy
Configuration) so they apply to every DC.

### Reading logs

```powershell
# Specific event ID, full detail
Get-WinEvent -FilterHashtable @{LogName='Security'; ID=4720} -MaxEvents 1 |
  Format-List TimeCreated, Message

# Just the timeline
Get-WinEvent -FilterHashtable @{LogName='Security'; ID=4728} -MaxEvents 10 |
  Select-Object TimeCreated, Id

# Multiple IDs at once
Get-WinEvent -FilterHashtable @{LogName='Security'; ID=4720,4722,4725,4726} -MaxEvents 20 |
  Select-Object TimeCreated, Id

# Time-bounded
Get-WinEvent -FilterHashtable @{
  LogName='Security'
  ID=4625
  StartTime=(Get-Date).AddDays(-1)
} | Select-Object TimeCreated, Id

# Pivot from a Logon ID to the session that performed an action
Get-WinEvent -FilterHashtable @{LogName='Security'; ID=4624} -MaxEvents 50 |
  Where-Object {$_.Message -like "*0x8DBB8*"} | Format-List TimeCreated, Message

# Check retention
Get-WinEvent -ListLog Security |
  Select-Object LogName, MaximumSizeInBytes, RecordCount, LogMode
```

**Use `-FilterHashtable`, not `Where-Object`, for the initial filter.**
FilterHashtable filters at the log engine (fast). Where-Object pulls every event
into memory first (very slow on a real DC).

### Event IDs

| ID | Event |
|---|---|
| **4624 / 4625** | Logon success / failure |
| **4634 / 4647** | Logoff |
| **4720** | User account created |
| **4722 / 4725** | Account enabled / disabled |
| **4726** | Account deleted |
| **4728 / 4732** | Member added to security group |
| **4729 / 4733** | Member removed from group |
| **4740 / 4767** | Account locked out / unlocked |
| **4768** | Kerberos TGT requested |
| **4769** | Kerberos service ticket — **Kerberoasting appears here** |
| **4771** | Kerberos pre-auth failed |
| **5136** | Directory object modified |

**Patterns, not single events:**
- `4720` → `4728` — account created then given group membership. Normal during
  onboarding, alarming at 3am.
- Many `4625` → one `4624` — password guessing that worked.
- `4725` → `4722` — a leaver's account came back to life.

### Logon Types (inside 4624/4625)

| Type | Meaning |
|---|---|
| 2 | Interactive (console) |
| 3 | Network (SMB, file share) |
| 4 | Batch (scheduled task) |
| 5 | Service |
| 7 | Unlock |
| 8 | NetworkCleartext ⚠️ |
| 10 | RemoteInteractive (RDP) |
| 11 | CachedInteractive |

⚠️ Type 10 on a DC outside a change window, or Type 2 by a service account, are
worth investigating.

### Event structure

Every account-management event has a **Subject** (who did it) and a **target**
(who it was done to). The Subject's `Logon ID` is the pivot — search 4624 for the
same ID to find the source machine and logon type.

### Retention

`LogMode: Circular` means old events are silently overwritten when the log fills.
128 MB default. A busy DC can cycle through that in under an hour, which is why
production forwards everything to a SIEM.

---

## SIDs and RIDs

```
S-1-5-21-2919560040-1087947747-677299318-500
└──┬───┘ └──────────────┬──────────────┘ └┬┘
 prefix     domain identifier            RID
```

**Universal RIDs, identical in every Windows domain:**

| RID | Always is |
|---|---|
| 500 | Built-in Administrator |
| 501 | Guest |
| 502 | krbtgt |
| 512 | Domain Admins |
| 513 | Domain Users |
| 519 | Enterprise Admins |
| 1000+ | Accounts someone created |

Permissions are stored against **SIDs, not names**:
- Rename a user → access survives (same SID)
- Delete and recreate with the same name → access is **gone** (new SID)

Renaming the built-in Administrator is cosmetic — attackers enumerate by RID.

**krbtgt** never logs in, but its password hash signs every Kerberos ticket. Steal
it and you can forge a **Golden Ticket** — any user, any privilege, any duration.
The only fix is resetting the krbtgt password twice.

---

## UAC flags (userAccountControl)

A bitmask holding account flags, shown in events as hex.

```
Old UAC Value: 0x0  →  New UAC Value: 0x11
0x11 = 0x10 (normal account) + 0x01 (disabled)
```

| Flag | Name | Risk |
|---|---|---|
| `0x0020` | PASSWD_NOTREQD | Account can have a **blank password** |
| `0x400000` | DONT_REQ_PREAUTH | Enables **AS-REP Roasting** |
| `0x10000` | DONT_EXPIRE_PASSWORD | Password never rotates |
| `0x80000` | TRUSTED_FOR_DELEGATION | Unconstrained delegation — very dangerous |

---

## Audit hunt queries

Run these on any environment you inherit. **Empty output is the good result.**

```powershell
# AS-REP roastable — Kerberos pre-auth disabled
Get-ADUser -Filter {DoesNotRequirePreAuth -eq $true} `
  -Properties DoesNotRequirePreAuth | Select-Object Name

# Blank password permitted — ENABLED accounts only
Get-ADUser -Filter {PasswordNotRequired -eq $true -and Enabled -eq $true} `
  -Properties PasswordNotRequired | Select-Object Name

# Kerberoastable — has an SPN. Runs fine as an UNPRIVILEGED user.
Get-ADUser -Filter {ServicePrincipalName -like "*"} `
  -Properties ServicePrincipalName, PasswordLastSet |
  Select-Object Name, ServicePrincipalName, PasswordLastSet

# Passwords that never expire
Get-ADUser -Filter {PasswordNeverExpires -eq $true -and Enabled -eq $true} `
  -Properties PasswordNeverExpires | Select-Object Name

# Stale accounts — no logon in 90 days
$cutoff = (Get-Date).AddDays(-90)
Get-ADUser -Filter {LastLogonDate -lt $cutoff -and Enabled -eq $true} `
  -Properties LastLogonDate | Select-Object Name, LastLogonDate

# Who's in Domain Admins
Get-ADGroupMember -Identity "Domain Admins" -Recursive |
  Select-Object Name, SamAccountName
```

On the SPN query, check `PasswordLastSet` — a service account whose password is
years old is an urgent finding.

---

## DNS — because AD can't run without it

DNS translates `somu.local` into the DC's IP so clients can find it. **SRV
records** advertise which server runs which service (Kerberos, LDAP).

```powershell
# View A records in the domain zone
Get-DnsServerResourceRecord -ZoneName "somu.local" -RRType "A"

# View SRV records — how clients locate domain controllers
Get-DnsServerResourceRecord -ZoneName "somu.local" -RRType "SRV"
```

Troubleshooting:
```
nslookup somu.local
dcdiag /test:dns
ipconfig /all
```

**Interview line:** *"Most Active Directory problems are actually DNS problems."*

**Why a DC needs a static IP:** DNS records map names to IPs. If DHCP changed the
DC's address, every record would point to the wrong place.

**Why the DC's DNS points to `127.0.0.1`:** the domain controller *is* the DNS
server, so it asks itself. Pointing it elsewhere breaks AD record lookup.

---

## Kerberos

Single sign-on: the password crosses the network **once**, then only tickets move.

```
1. Client → KDC:  "I'm priya.sharma"     ← KDC runs on every DC
   KDC → Client:  TGT (valid ~10 hrs)

2. Client → TGS:  "TGT here, I want \\fileserver"
   TGS → Client:  Service Ticket

3. Client → File server:  Service Ticket → access granted from groups in ticket
```

| Term | Meaning |
|---|---|
| **KDC** | Key Distribution Center — runs on every DC |
| **TGT** | Ticket Granting Ticket — the "wristband" |
| **TGS** | Ticket Granting Service |
| **Service Ticket** | Grants access to one specific service |
| **SPN** | Service Principal Name — maps a service to an account |

```powershell
# View your current tickets
klist

# Clear the ticket cache (fixes stale-ticket issues after a password change)
klist purge
```

**Clock skew:** tickets carry timestamps. More than **5 minutes** of drift between
client and DC and the ticket is rejected as a possible replay attack. "Check the
time" is a real Kerberos troubleshooting step.

**Kerberos vs NTLM:**

| | Kerberos | NTLM |
|---|---|---|
| Method | tickets | challenge-response |
| Mutual auth | yes | no |
| Timestamps | yes | no |
| Status | preferred | legacy, being phased out |

Windows falls back to NTLM when Kerberos can't be used — connecting by IP instead
of hostname, for example. Attackers force that fallback because NTLM hashes can be
relayed.

**Common IAM tickets:**
- "Login slow/failing after a password change" → stale ticket, `klist purge`
- "Works by hostname, fails by IP" → Kerberos needs the name; IP forces NTLM
- "Service account can't authenticate" → missing or duplicate SPN

---

## Bulk operations (the interview answer)

Asked *"how would you create 50 users from a CSV?"* — the expected answer:

```powershell
Import-Csv .\new-hires.csv | ForEach-Object {
    New-ADUser -Name $_.Name `
      -SamAccountName $_.SamAccountName `
      -UserPrincipalName "$($_.SamAccountName)@somu.local" `
      -Path $_.OUPath `
      -AccountPassword (ConvertTo-SecureString $_.Password -AsPlainText -Force) `
      -Enabled $true
}
```

Say out loud: *test on a few accounts first, and log the results.*

---

## Debugging habits

- **Read the first red line.** It usually names the exact problem.
- A misspelled **cmdlet** throws `CommandNotFoundException`.
- A misspelled **parameter** throws `ParameterBindingException` — "A parameter
  cannot be found".
- A misspelled **property** fails *silently* — you just get empty columns. Watch
  for `{}` or blanks.
- `$` inside a property name turns it into a variable: `IPv$Address` → empty.
- Paste one command per line. Multiple commands on one line get read as arguments
  to the first.
- After any command that returns nothing, run a `Get-` to verify state rather than
  assuming success.

---

## GUI equivalents

| Console | Opens from |
|---|---|
| **ADUC** (Active Directory Users and Computers) | Server Manager → Tools |
| **Group Policy Management** | Server Manager → Tools |
| **DNS Manager** | Server Manager → Tools |
| **Event Viewer** | Server Manager → Tools |

PowerShell scales; the consoles are faster for one-offs. IAM roles expect
familiarity with both.
