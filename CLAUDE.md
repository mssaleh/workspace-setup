# CLAUDE.md
<!-- git-workflow-rule -->
## Git workflow

- **Never create a branch or a pull request without an explicit request.** When asked to commit,
  commit to the branch that is currently checked out — including `main`. Do not branch first as a
  precaution, and do not offer branching as a safer default.
- Commit only when asked. Push only when asked. Each is a separate ask; permission to commit is not
  permission to push.

## Changing a host

- **A setting you cannot explain is a setting somebody chose.** Kernel parameters, mount options,
  sysctl values and firewall rules already on a host were usually put there deliberately. Read it,
  leave it, say what you found.
- **Never hide a package transaction.** `>/dev/null 2>&1 || true` on an `apt` call discards the
  cascade and the exit status together, so a step that removed nothing looks like one that worked.
  Simulate and name what goes (`apt_report_removals`), pass `-y`, and report failures.

## Verifying a change

Check the running value, never the file you wrote. Drop-in directories do not even agree on which
file wins: `sysctl.d` takes the **last** assignment, `sshd_config.d` the **first**. The verification
recipes under **System-level files you install yourself** in the README are part of those files — a
new one ships with the command that proves it took effect.

## Comments

Match the density of the code you are editing. State the non-obvious fact and stop; do not restate
what the code says, and do not narrate the bug that motivated a fix.
