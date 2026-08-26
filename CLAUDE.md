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

## Comments and documentation

Explanation is a cost. Pay it only where a reader would otherwise get it wrong.

- **Commentary never outgrows the code.** Match the density of the file you are editing and do not
  exceed it. A one-line change does not get a three-line preamble; no function gets a docstring
  longer than itself. If every small change arrives with its own essay, the file becomes unreadable.
- **One line is the default.** State the non-obvious fact and stop. Delete anything that restates
  what the code already says. If the explanation needs a paragraph, the code is wrong — fix the code.
- **No history, anywhere.** A comment says what is true now. Never what used to be true, what was
  tried, what the bug was, when something changed, or why something was removed. Git holds that.
  Nothing that no longer exists gets a tombstone: no "previously", no "formerly", no "note that we
  used to", no struck-through line, no dated remark. Rewrite the passage as though it had always
  read that way.
- **No new documents.** Do not add a README, guide, summary, design note or changelog unless asked.
  Where the README already covers the subject, extend that paragraph rather than appending a section.
