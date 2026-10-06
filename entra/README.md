# Microsoft Entra ID: Identity, Access Control, and Governance

Cloud half of this lab. The `somu.local` Active Directory domain (see the main README)
covers on-prem identity; this covers the same problems in Microsoft Entra ID — where
there are no OUs, no LDAP, and no Group Policy, and the tools are different.

Built in a free Entra ID tenant. Everything here is real configuration against a live
directory, not screenshots from documentation.

---

## Contents

| Section | What it covers |
|---|---|
| [1. Tenant build](#1-tenant-build) | Users, groups, licensing model |
| [2. Application registration and OIDC](#2-application-registration-and-oidc) | SSO app, real token issued and inspected |
| [3. Identity investigation](#3-identity-investigation) | Reconstructing an authentication timeline from sign-in logs |
| [4. Directory roles and least privilege](#4-directory-roles-and-least-privilege) | Role model, escalation paths, audit evidence |
| [5. Conditional Access policy design](#5-conditional-access-policy-design) | Four policy specs written before deployment |
| [6. Automated access review](#6-automated-access-review) | Graph PowerShell script, CSV evidence |
| [7. Findings](#7-findings) | Six issues found in the tenant |
| [8. Problems hit](#8-problems-hit) | What broke and why |

---

## 1. Tenant build

Four users, three security groups, one app registration.

**Structural difference from AD that drives everything else:** Entra has no OU tree.
A directory is flat. Where AD scopes permission by *location in a hierarchy*, Entra
scopes it by *role assignment* — tenant-wide by default, narrowed only by
Administrative Units (P1) or by targeting a single application.

That one difference is why delegation looks completely different on the two platforms:

| | Active Directory | Entra ID |
|---|---|---|
| Permission | ACE on an object | Role definition (100+ built-in) |
| Scope | OU subtree | Tenant-wide, or Administrative Unit, or one app |
| Delegation | Build a custom ACL | Assign a pre-built role |
| Directory protocol | LDAP | Microsoft Graph (REST) |
| Policy engine | Group Policy (pull, ~90 min) | Conditional Access (evaluated at sign-in) |
| Group types | Security / Distribution, 3 scopes | Security / Microsoft 365, Assigned / Dynamic |

Groups created here are plain security groups — `GroupTypes` comes back empty, which is
how you tell at a glance. `{Unified}` would mean a Microsoft 365 group,
`{DynamicMembership}` a rule-based one (P1).

---

## 2. Application registration and OIDC

Registered an application in the tenant, configured redirect URIs, enabled ID tokens,
and completed a sign-in that issued a real JWT.

**What the token proved:**

- It is three base64url segments — header, payload, signature — joined by dots.
  **Encoded, not encrypted.** Anyone holding it can read every claim.
- Validation is four checks, in order: signature, `iss` (issuer), `aud` (audience),
  `exp` (expiry). Skipping `aud` means accepting a token minted for a different
  application, which is a real and exploited class of bug.
- The implicit flow is deprecated because it returns tokens in the URL fragment, where
  they land in browser history and referrer headers. Authorization code flow with PKCE
  is the current standard.

**Protocol roles, since the three get conflated constantly:**

```
SAML 2.0   XML assertions, browser POST. Enterprise SSO, still everywhere.
OAuth 2.0  Authorization only. "This app may read your calendar." Not authentication.
OIDC       A thin authentication layer on top of OAuth 2.0. Adds the ID token.
```

OAuth answers *what may this app do*. OIDC answers *who is this user*. Using OAuth
alone for login is the mistake behind a long list of broken implementations.

---

## 3. Identity investigation

A full authentication timeline reconstructed from sign-in logs alone, with no memory
of the events.

```
11:10:07   Password   FAILED     "Invalid username or password"  (error 50126)
11:15:27   Password   OK, then interrupted for password change
11:18:35   MFA completed in Azure AD                    Status: Interrupted
11:18:42   No authentication events  -->  token issued from existing session (SSO)
```

### Reading the sign-in log

**Status has three values, and the middle one is misread constantly:**

| Status | Meaning |
|---|---|
| Success | Token issued |
| Failure | Rejected — bad credential, blocked, locked out |
| **Interrupted** | Sign-in paused to ask for something more: MFA, password change, consent |

`Interrupted` is a normal step inside a successful login. Escalating every one of them
buries a team in noise.

**Correlation ID is the pivot.** A Correlation ID identifies one sign-in *journey*;
each Request ID is one leg of it. Filtering the log on a Correlation ID returns every
request belonging to that journey. This is the same move as pivoting on a Logon ID in
the Windows Security log — different platform, identical technique.

**The Authentication details tab is the evidence, not the policy.** It lists each
factor attempted, in order, with a result:

| Date | Method | Method detail | Succeeded | Result detail |
|---|---|---|---|---|
| 2026-10-01T18:10:07Z | Password | Password in the cloud | No | Invalid username or password |

One row means one factor, which means no MFA on that attempt. When an auditor asks for
proof an account used MFA, this table is the answer. A Conditional Access policy is a
statement of intent; this is what actually happened.

`Password in the cloud` also identifies the authentication model: the hash was
validated by Entra itself (cloud-only user or Password Hash Sync). `Password in the
on-premises directory` would mean Pass-Through Authentication handing off to a domain
controller.

### The finding that matters: SSO means an authenticated session is a credential

The 11:18:42 event reports **"No authentication events were triggered."** A token was
issued with no password and no MFA, because a valid session already existed.

Which means anything that holds that session gets tokens with no authentication
events at all. An attacker who steals the session cookie or refresh token — infostealer
malware, an adversary-in-the-middle phishing proxy — **signs in without ever
re-triggering MFA.** MFA is not broken; it is simply never asked again.

Mitigations, all Conditional Access session controls:

| Control | Effect |
|---|---|
| Sign-in frequency | Forces reauthentication on an interval, so a stolen token expires |
| Continuous Access Evaluation | Revokes a live token on disable, password reset, or IP change |
| Persistent browser session: Never | Kills the cookie with the browser |
| Token protection | Binds the token to a device, so a copied token is useless |

Grant controls decide whether a sign-in happens. Session controls decide how long it
stays valid and what kills it early.

---

## 4. Directory roles and least privilege

### Roles that are secretly equivalent to Global Administrator

| Role | Escalation path |
|---|---|
| Privileged Role Administrator | Can assign any role, including Global Admin, to itself |
| Application Administrator | Can add a credential to a high-privilege app and inherit its permissions |
| Authentication Administrator | Can re-register a user's MFA onto an attacker-controlled device |
| Privileged Authentication Administrator | Same, but against admins too |

An organization that counts "we only have two Global Admins" while handing out these
roles has considerably more than two people who can take over the tenant. Counting
Global Admins is not an access review.

**Global Reader is the underused answer to most access requests.** Full read across the
directory, zero write. Most requests for admin rights are really requests for
visibility.

**Protected actions** are built in: an administrator cannot reset the password of an
account holding a higher-privileged role. The Helpdesk Administrator role description
states it directly — *"Can reset passwords for non-administrators and Helpdesk
Administrators."* Without that boundary, Helpdesk Admin would be a one-step path to
owning the tenant.

### Audit evidence of a privilege change

Assigning a role writes an audit event. The fields that matter:

| Field | Value | Why |
|---|---|---|
| Activity Type | Add member to role | The event to alert on |
| Category | **RoleManagement** | The category to alert on — catches every privilege change |
| Initiated by (actor) | Object ID | Display name is frequently blank; you resolve the GUID yourself |
| Target(s) | User object + Role object | An event often has multiple targets |
| Modified Properties | Old value -> New value | Blank old value = addition, not modification |

**Role template IDs are universal GUIDs.** Helpdesk Administrator is
`729827e3-9c14-49f7-bb1b-9608f156bbb8` in every tenant; Global Administrator is
`62e90394-69f5-4237-9190-012177145e10`. Detections written against template IDs survive
renames and locale changes; detections written against display names do not. Same
reasoning as RID 512 always meaning Domain Admins.

### The detection rule this lab produced

Reviewing the audit log turned up a role assignment where the **actor and the target
were the same object ID** — an account granting itself a privileged role.

Legitimate role assignments are almost always one person granting a role to someone
else. Self-assignment of privilege is either a careless admin or an attacker
establishing persistence.

```
Category     = RoleManagement
ActivityType = "Add member to role"
AND InitiatedBy.ObjectId == Target.ObjectId
  -> ALERT, high severity
```

---

## 5. Conditional Access policy design

Conditional Access requires Entra ID P1, so these were written as deployable specs
rather than configured. Writing the design before the build is the point — every one
of these has a failure mode that is cheaper to find on paper.

**The model:** signals (who, what app, where, which device, what risk, which client) →
evaluation → grant controls (block / require MFA / require compliant device) and
session controls.

**Four rules that govern every policy:**

1. **There is no implicit deny.** If no policy matches, access is granted. CA is not a
   firewall. A policy scoped to zero users protects nobody and raises no error.
2. **Block always wins.** No precedence order, no link order like Group Policy.
3. **A break-glass account is mandatory** — cloud-only, FIDO2, excluded from every
   policy, alerted on. Without it, one bad policy locks the tenant out permanently and
   recovery is a support ticket.
4. **Report-only first, always.** It evaluates and logs without enforcing, so you can
   read who *would* have been hit before anyone actually is.

### CA01 — Require MFA for administrators

```
Users included:   Directory roles (not individuals) — Global Admin, Privileged Role Admin,
                  User Admin, Security Admin, Exchange Admin, SharePoint Admin,
                  Helpdesk Admin, Authentication Admin, Conditional Access Admin,
                  Application Admin, Cloud Application Admin
Users excluded:   svc-breakglass-01
Target resources: All cloud apps
Grant controls:   Require multifactor authentication
Session controls: Sign-in frequency 4 hours; persistent browser never
Enable state:     Report-only -> On after 48h of clean report data
```

**Scoped to roles, not people**, so the admin hired next month is covered automatically.
Same reasoning as using groups instead of per-user permissions in AD.

**Sign-in frequency of 4 hours** against a 90-day default: given what SSO does to
stolen tokens, an admin token that lives for 90 days is the whole attack.

*Breaks if wrong:* scoping to users lets new admins escape silently; no break-glass
exclusion means total lockout; service accounts holding admin roles cannot do
interactive MFA and need workload identities or certificate auth, not an exclusion.

### CA02 — Block legacy authentication

```
Users:            All     Excluded: svc-breakglass-01
Conditions:       Client apps -> Exchange ActiveSync clients + Other clients
                  (NOT Browser, NOT Mobile apps and desktop clients)
Grant controls:   Block access
Enable state:     Report-only -> On
```

Legacy protocols (POP, IMAP, SMTP AUTH, ActiveSync) cannot do MFA, so they are the
standing bypass around every MFA policy in the tenant. Password spray lives here.

**Pre-deployment step:** filter the sign-in logs on `Client app = Exchange ActiveSync +
Other clients` *before* writing the policy. That shows every legacy attempt in the
retention window and tells you exactly what is about to break — a scanner that emails
PDFs, an old reporting script, a line-of-business app nobody owns.

**CA is the second line, not the first.** The stronger fix is disabling the protocols at
source — SMTP AUTH per mailbox, POP/IMAP in Exchange Online, Authentication Policies.
Blocking at the token endpoint while leaving the protocols enabled is weaker than
turning them off.

*Breaks if wrong:* selecting Browser blocks normal web access; selecting Mobile apps and
desktop clients blocks legitimate Outlook and Teams.

### CA03 — Require MFA for all users

```
Users:            All     Excluded: break-glass, Entra Connect sync account,
                                    service accounts, time-bound rollout waves
Grant controls:   Require multifactor authentication
Enable state:     Report-only -> On, deployed in waves
```

**Guests are included, not excluded** — a B2B guest without MFA is an unmanaged account
from another company holding access to your data.

**Overlap with CA01 is deliberate.** CA policies stack; all grant controls must be
satisfied. Requiring MFA twice just means MFA. The redundancy means admins stay covered
if CA03 is ever misscoped or disabled.

**Require compliant device is unavailable in this tenant** — zero devices are enrolled,
so that grant control would lock out 100% of users. Device-based controls become
possible only after Intune enrollment or hybrid join.

*Every exclusion is a documented, time-bound exception with a compensating control.*
An exclusion group nobody reviews is how "we require MFA everywhere" quietly becomes
"we require MFA for 60% of people."

### CA04 — Block access from outside the United States

```
Conditions:       Locations -> exclude Named Location "United States"
Grant controls:   Block access
```

**Honest weakness, stated up front: a $3/month VPN defeats this entirely.** Entra
geolocates by IP. An attacker exits through a US endpoint and the policy sees a
domestic sign-in. Meanwhile a legitimate employee gets locked out from an airport
abroad.

Country blocking is a **noise filter, not a security control.** It cuts commodity
scanning traffic and nothing else. Shipping it as a security control, rather than as
noise reduction, is a misrepresentation of what it does.

### CA05 — Block the device code flow

Added after using `Connect-MgGraph -UseDeviceAuthentication`. The device code flow
exists for devices that cannot show a browser, and it is the basis of **device code
phishing**: an attacker initiates the flow and sends the victim a genuine Microsoft code
and URL. Everything on the victim's screen is legitimately Microsoft, so "check the URL"
advice fails completely, and the token lands in the attacker's session.

Block it except where a documented need exists.

---

## 6. Automated access review

`Export-PrivilegedRoleReport.ps1` — enumerates every active directory role, resolves
every member, flags escalation-path roles, and exports timestamped CSV evidence.

### Why Graph, and why scopes matter

AD cmdlets inherit the caller's Windows token: whatever you can do, the cmdlet can do.
Graph is the opposite — **permissions are declared up front and the token carries only
those**:

```powershell
Connect-MgGraph -TenantId "<tenant>" -Scopes "User.Read.All","Group.Read.All",
                "RoleManagement.Read.Directory","Directory.Read.All"
```

A script holding only read scopes cannot cause damage, however badly it is written or
however it is tampered with. Least privilege enforced at the token layer instead of
trusted to the code.

`Get-MgContext` returns the scopes actually held — which includes `openid` and `profile`
that were never requested. Those are the standard OIDC scopes, added automatically.
Always read back what you were granted rather than assuming you got what you asked for.

**Delegated vs application permissions:** delegated means the app acts *as the signed-in
user*, and effective permission is the intersection of the scope and what that user can
do. Application permissions mean the app acts as itself with no user, so nothing narrows
them. This script is delegated and read-only by design.

### Design decisions

**Fail fast on no connection.** Checking `Get-MgContext` once and exiting beats one
error per role.

**Member type is read from `@odata.type`, not assumed.** A role can be held by a user, a
**group**, or a **service principal**. Scripts that assume "user" silently drop
application assignments — which is exactly where an attacker would hide one.

**`$HighRisk` is a list, not a check for Global Admin.** Privileged Role Admin,
Application Admin and Authentication Admin all reach Global Admin by a short path.
That list is what makes this a security tool rather than an inventory.

**Guests in privileged roles are counted separately and printed in red.**

**Timestamped CSV output.** An access review is evidence. When an auditor asks who held
Global Admin in October, the answer is a file, not a screenshot.

### Sample output

```
Tenant : 414df17a-9dac-417d-abed-f5b27f9d952f
Scopes : Directory.Read.All, Group.Read.All, openid, profile,
         RoleManagement.Read.Directory, User.Read.All, email

RoleName               MemberType DisplayName             UserType HighRisk
--------               ---------- -----------             -------- --------
Global Administrator   user       <tenant admin>          Member      True
Helpdesk Administrator user       Priya Sharma            Member     False

Assignments found      : 2
In high-risk roles     : 1
Guests in high-risk    : 0
Report written to      : ...\privileged-role-report-20261006-115913.csv
```

### A Graph behaviour worth knowing

`Get-MgDirectoryRole` returns only **activated** roles, not all 100+ definitions. Entra
does not instantiate a role object until something is assigned to it, so this cmdlet
returns roles *in use* — which is what an access review wants. The full catalogue is
`Get-MgDirectoryRoleTemplate`.

---

## 7. Findings

| # | Finding | Severity | Recommendation |
|---|---|---|---|
| 1 | Single Global Administrator; no break-glass account | High | Add a second admin and a cloud-only FIDO2 break-glass account excluded from all CA policies, with alerting on its use |
| 2 | Global Administrator authenticates via an external consumer identity (`#EXT#` UPN) | High | Create a cloud-only administrative account in the tenant's own domain |
| 3 | Redundant role assignment — Helpdesk Administrator granted to an account already holding Global Administrator | Medium | Remove. Grants no capability; pure privilege creep |
| 4 | All role assignments are Direct standing privilege | Medium | Move to PIM eligible assignments with time-bound activation, justification and approval (P2) |
| 5 | Sign-in and audit log retention is 7 days (Free tier) | Medium | Export to a Log Analytics workspace or SIEM; 7 days is shorter than most incident dwell times |
| 6 | No devices enrolled; device-based grant controls unavailable | Info | Blocks "require compliant device" and "require hybrid joined device" until Intune or hybrid join exists |

Findings 3 and 4 were the useful ones: both are invisible unless you look at the
assignment path and ask what each role actually adds.

---

## 8. Problems hit

**Portal filters silently reset.** Applying a Correlation ID filter reset the date range
to Last 24 hours, and the query returned "No results" with no warning. The event existed;
a different filter was excluding it.

This is the most dangerous failure mode in log analysis: **"no results" and "wrong
question" look identical on screen.** In a real investigation, "no evidence of
compromise" and "my date range was wrong" are the same picture. Habit: when a query
returns nothing, verify the filters before believing the result.

**`Connect-MgGraph` returned an empty context.** `Get-MgContext` showed blank TenantId,
Account and Scopes — connected to nothing useful, with no error. Two causes: the sign-in
used a personal Microsoft account rather than the tenant identity, and the Windows
Account Manager broker was swallowing tenant context on PowerShell 5.1. Fixed by passing
`-TenantId` explicitly and `-UseDeviceAuthentication` to bypass WAM.

**A counter printed blank instead of a number.** `($results | Where-Object {...}).Count`
returned nothing when exactly one object matched. In PowerShell 5.1, `Where-Object`
returns a bare object rather than a single-element array, and `PSCustomObject` has no
`.Count` property — so it evaluated to `$null`. Zero matches and two matches both worked;
one match did not.

Fixed with the array subexpression operator:

```powershell
$risky = @($results | Where-Object { $_.HighRisk -and $_.MemberType -ne "(none)" }).Count
```

Same family of bug as a misspelled property name producing an empty column instead of an
error: **the silent wrong answer, not the loud failure.** Those are the ones that reach
production.

**A placeholder was passed to the API literally**, and Graph returned `400 BadRequest`
with a request ID. Worth contrasting: a bad *property* name in PowerShell fails silently,
but a bad *value* sent to a REST API gets rejected loudly with a status code. Knowing
which layer fails quietly is most of debugging.

---

## Next

- Entra Connect hybrid lab — sync `somu.local` into this tenant, which turns
  `Password in the cloud` into `Password in the on-premises directory` and makes hybrid
  join (and device-based CA) possible
- Deploy the five CA policies during a P1/P2 trial, in report-only first, and capture
  the Conditional Access column in the sign-in logs as proof of enforcement
- PIM: convert the standing role assignments to eligible, and run an access review
  campaign against the findings above
- Extend the report script to cover group-based role assignments and service principal
  credentials with expiry dates
