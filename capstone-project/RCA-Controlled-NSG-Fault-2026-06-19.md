# Root Cause Analysis (RCA)

## Incident Title
Controlled Fault Injection: NSG SSH Rule Changed from Allow to Deny

## Date
2026-06-19

## Environment
- Cloud: Microsoft Azure
- Scope: Compute Tower resources only
- Resource Group: finbridge-dev-rg
- NSG: finbridge-dev-nsg
- VM: finbridge-dev-vm
- NSG Rule: allow-ssh-from-bastion-subnet

## 1. Incident Summary
A controlled and reversible fault was intentionally injected by modifying the Network Security Group rule allow-ssh-from-bastion-subnet on finbridge-dev-nsg. The rule action for inbound TCP/22 was changed from Allow to Deny at 12:11:13 UTC.

### Impact
- Inbound SSH connectivity from the bastion subnet to finbridge-dev-vm was blocked.
- Synthetic connectivity verification changed from Allow to Deny for inbound TCP/22.
- VM compute/OS health remained normal during the event.
- Blast radius remained limited to network access policy for administrative SSH.

## 2. Timeline (UTC)
| Timestamp | Action | Observation | Source |
|---|---|---|---|
| 12:10:18 | Baseline check | VM power state running; SSH rule present as Allow | Azure CLI |
| 12:11:13 | Fault triggered | NSG rule updated Allow -> Deny on TCP/22 | Azure CLI |
| 12:11:16 | Control-plane write recorded | NSG security rule write event logged | Azure Activity Log |
| 12:12:54 | Configuration detection | NSG rule Access confirmed as Deny | Azure CLI |
| 12:12:59 | Synthetic path test | test-ip-flow returned Deny for inbound TCP/22 | Network Watcher |
| 12:13:21 | Drift analysis | Terraform plan proposed Deny -> Allow correction | Terraform plan |
| 12:15:12 | Health isolation check | VM Run Command succeeded (vm-agent-ok) | Azure VM Agent |
| 12:16:00 | Remediation | NSG rule reverted to Allow | Azure CLI |
| 12:16:10 | Recovery verification | test-ip-flow returned Allow (baseline restored) | Network Watcher |
| 12:31:41 | Full restore confirmation run | NSG rule remained Allow, test-ip-flow Allow, VM running | Azure CLI + Network Watcher |
| 12:32:42 | Post-restore IaC drift validation | Terraform plan showed 1 add pending (azurerm_bastion_host.compute) | Terraform plan |

## 3. Detection
The issue was detected using layered operational signals:
- Configuration signal: NSG rule inspection showed Access set to Deny.
- Synthetic network signal: Network Watcher test-ip-flow changed from Allow to Deny for inbound TCP/22.
- IaC drift signal: Terraform plan identified deviation from desired state and planned Deny -> Allow update.
- Audit signal: Azure Activity Log captured the NSG rule write operation and caller context.

## 4. Root Cause
### Technical Cause
The direct root cause was an NSG rule misconfiguration on finbridge-dev-nsg:
- Rule: allow-ssh-from-bastion-subnet
- Change: Access Allow -> Deny
- Affected flow: Inbound TCP/22 traffic from bastion subnet CIDR 10.30.2.0/26 to VM path

### Why It Caused the Failure
Azure NSG policy evaluation enforced the explicit Deny on matching SSH traffic. As a result, the SSH data path was blocked at the network policy layer before the VM could accept connections.

## 5. Contributing Factors
- No preventive guardrail blocked high-risk management-port NSG action changes.
- No mandatory pre/post connectivity gate in the change path for NSG updates.
- Monitoring detected the fault quickly, but prevention controls were not in place.
- Control-plane change success alone did not indicate data-plane health.

## 6. Impact Assessment
### Affected
- SSH administrative access path from bastion subnet to finbridge-dev-vm.

### Not Affected
- VM power and guest OS responsiveness.
- Azure VM agent execution path.
- Underlying compute service availability.

### Blast Radius
- Network policy only.
- Limited to Compute Tower SSH access path.
- No evidence of wider service degradation.

## 7. Resolution
### Immediate Mitigation
- Reverted NSG rule allow-ssh-from-bastion-subnet Access from Deny back to Allow.

### Recovery Actions
1. Restored NSG rule to Allow at 12:16:00 UTC.
2. Re-ran synthetic flow test for inbound TCP/22.
3. Confirmed restored policy and connectivity behavior.

## 8. Verification Against Baseline
### Baseline
- Rule Access = Allow
- test-ip-flow for inbound TCP/22 = Allow

### During Fault
- Rule Access = Deny
- test-ip-flow for inbound TCP/22 = Deny

### Post-Remediation
- Rule Access = Allow
- test-ip-flow for inbound TCP/22 = Allow

Recovery was verified as complete and consistent with pre-fault baseline behavior.

## 9. Preventive Actions
1. NSG Guardrails
- Enforce Azure Policy for sensitive management-port rule changes.
- Require approval workflow for Access changes on critical NSGs.

2. Validation Controls
- Add mandatory pre/post Network Watcher test-ip-flow checks in operational runbooks and CI/CD.
- Block change completion if required path checks fail.

3. Monitoring and Alerting
- Alert on NSG writes affecting TCP/22 and other management ports.
- Alert on synthetic connectivity transitions from Allow to Deny.

4. Drift and Compliance
- Schedule Terraform drift detection and auto-create incident tickets on divergence.
- Enforce IaC-first updates for NSG/security rules where feasible.

5. Change Management
- Require explicit rollback command and validation steps with each network policy change.
- Add peer-review checklist for NSG modifications.

## 10. Key Learnings
- Network policy failures can isolate management access while compute remains healthy.
- Synthetic path checks are critical because host health alone can mask network access issues.
- Combining configuration, synthetic, audit, and IaC drift signals yields fast and confident RCA.
- Controlled fault injection with measured rollback improves operational readiness and incident discipline.

## Evidence Appendix
- NSG update event: allow-ssh-from-bastion-subnet Access changed Allow -> Deny at 12:11:13 UTC.
- Activity log event around 12:11:16 UTC confirms NSG security rule write by active user.
- Terraform detected drift and planned correction Deny -> Allow.
- VM agent command succeeded during incident, confirming compute health.
- Post-fix synthetic flow returned Allow, confirming recovery.

## 11. Post-Restore Operational Result
### Recovery State
- Final restore run at 12:31:41 UTC confirmed:
	- NSG SSH rule access set to Allow
	- Network Watcher test-ip-flow result = Allow for inbound TCP/22
	- VM power state = running

### IaC Parity Check
- Terraform drift check at 12:32:42 UTC reported:
	- Plan: 1 to add, 0 to change, 0 to destroy
	- Pending resource: azurerm_bastion_host.compute (finbridge-dev-bastion)

### Interpretation
- Fault remediation is complete for the injected NSG issue.
- Environment access baseline is restored.
- Full Terraform desired-state parity is not yet complete due to the pending Bastion host create action.
