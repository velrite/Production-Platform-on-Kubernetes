# Evidence

> **Evidence statement.** The AWS environment was built, tested, and destroyed between 2026-07-26 and 2026-08-09. The account's Free Plan credits then expired, so live cluster screenshots cannot be re-captured. The evidence below is the Git history, the validated infrastructure code, and the results recorded in `TESTING_AND_VALIDATION.md`. NetworkPolicy enforcement, RBAC use, and rollback are **not verified**.

## 01 Git commit timeline
17 commits over 7 days (2026-07-26 to 2026-08-09). The working copy was lost mid-build, so some files were re-committed from backup.

![Git commit timeline](evidence/01-git-commit-timeline.png)

## 02 Repository structure and size
777 lines across the Terraform files and scripts.

![Repository structure](evidence/02-repo-structure-and-iac-size.png)

## 03 GitHub commit history
The same timeline as recorded by GitHub's servers.

![GitHub commit graph](evidence/03-github-commit-graph.png)

## 04 Terraform static validation
Reproduced offline. Shows the configuration is valid; it does not prove it was applied.

![Terraform validate](evidence/04-terraform-validate.png)

## 05 Test results in commit history
The recorded results were committed in `34a1c0d` on 2026-08-09. This proves when the record was committed, not when the tests ran.

![Test results commit history](evidence/05-test-results-commit-history.png)

## 07 Script syntax check
Syntax check only. No linting claim.

![Script syntax check](evidence/07-script-syntax-check.png)
