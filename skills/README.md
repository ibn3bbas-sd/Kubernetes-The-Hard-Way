# Runbooks

One document per piece of work. Each records what was built, what was actually done, and the
gotchas found - so the next person (or Claude) doesn't re-derive them.

These are notes on *this fork's* additions. The lab instructions themselves live in
[../docs/](../docs/) and in the per-hypervisor directories.

| Doc | Covers |
|---|---|
| [pasting-lab-commands-from-windows.md](pasting-lab-commands-from-windows.md) | **Read this before lab 04 if you are on Windows.** Copying commands from a browser gives CRLF, and bash does not treat `\r` as whitespace - so `\`-continued commands are cut in half (`openssl req` silently falls back to interactive prompts and writes the CSR to the screen, leaving a `.key` with no `.crt` and no clear error), and heredocs embed `\r` into every systemd unit and kubeconfig they write. 196 continuation lines across the labs are affected. Includes a five-second test, the fix, and how to recover |
| [multipass-windows-runbook.md](multipass-windows-runbook.md) | The `multipass-windows/` route - Multipass + Hyper-V on Windows, driven from WSL. Why the lab needs a dedicated Hyper-V switch (the Default Switch subnet is re-randomised on every host reboot, and this lab writes node IPs into certificate SANs), and the traps that each cost a run: stdin not crossing the WSL boundary, `multipass transfer` needing Windows paths, `netplan apply` killing the `multipass exec` channel, `timeout` needing `-k` against a Windows process, and the Multipass/Hyper-V daemon deadlock |

## Conventions

- **Status is stated inline**, near the top or per-section: `DONE`, `IN PROGRESS`, `PAUSED`,
  `NOT STARTED`. Trust the section, not the filename.
- **Paths are exact and repo-relative** so they can be pasted straight into a shell. If you move a
  script, fix the doc.
- Write it when the work happens, not later - the value is in the details that are obvious now and
  gone in a week: the wrong turn, the misleading error, the constraint that wasn't documented
  anywhere.
