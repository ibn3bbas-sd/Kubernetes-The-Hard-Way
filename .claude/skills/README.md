# Runbooks (Claude Code skills)

One document per piece of work. Each records what was built, what was actually done, and the
gotchas found - so the next person (or Claude) doesn't re-derive them.

These are notes on *this fork's* additions. The lab instructions themselves live in
[../../docs/](../../docs/) and in the per-hypervisor directories.

Each runbook is a **Claude Code skill**: one directory per runbook, content in `SKILL.md`, with
`name` and `description` frontmatter. Claude discovers them automatically and reads one when its
`description` matches the task; you can also pull one in by name with `/<skill-name>`. They are
still plain markdown - read them directly if you prefer.

| Skill | Covers |
|---|---|
| [hyperv-mobaxterm-runbook](hyperv-mobaxterm-runbook/SKILL.md) | **Current route.** Running the five VMs as plain Hyper-V VMs over SSH from MobaXterm, after dropping Multipass for its daemon deadlock. The cut-over (nothing had to be rebuilt - Multipass only ever made ordinary Gen2 VMs), how to get in when SSH is down, the two separate SSH key setups and which host each runs on, and the traps: `ssh-keygen` failing on a fresh MobaXterm home, a world-readable private key, ping failing while SSH works, `AutomaticStopAction=Save` resuming etcd with a stale clock, and the cloud-init ISO `Move-VMStorage` leaves behind in the Multipass vault |
| [pasting-lab-commands-from-windows](pasting-lab-commands-from-windows/SKILL.md) | **Read this before lab 04 if you are on Windows.** Copying commands from a browser gives CRLF, and bash does not treat `\r` as whitespace - so `\`-continued commands are cut in half (`openssl req` silently falls back to interactive prompts and writes the CSR to the screen, leaving a `.key` with no `.crt` and no clear error), and heredocs embed `\r` into every systemd unit and kubeconfig they write. 196 continuation lines across the labs are affected. Includes a five-second test, the fix, and how to recover |
| [multipass-windows-runbook](multipass-windows-runbook/SKILL.md) | **Superseded for day-to-day use**, but keep it - it is the record of *why* the network is built as it is, and the Hyper-V route inherits that design wholesale. The `multipass-windows/` route - Multipass + Hyper-V on Windows, driven from WSL. Why the lab needs a dedicated Hyper-V switch (the Default Switch subnet is re-randomised on every host reboot, and this lab writes node IPs into certificate SANs), and the traps that each cost a run: stdin not crossing the WSL boundary, `multipass transfer` needing Windows paths, `netplan apply` killing the `multipass exec` channel, `timeout` needing `-k` against a Windows process, and the Multipass/Hyper-V daemon deadlock |

## Conventions

- **Status is stated inline**, near the top or per-section: `DONE`, `IN PROGRESS`, `PAUSED`,
  `NOT STARTED`. Trust the section, not the filename.
- **Paths are exact and repo-relative** so they can be pasted straight into a shell. If you move a
  script, fix the doc. Markdown links use the `../../../` depth this directory sits at; bare paths
  in tables and code spans are relative to the repo root.
- The frontmatter `description` is what makes Claude load the runbook, so write it as *symptoms and
  situations*, not a summary - the error message you'd actually be staring at.
- Write it when the work happens, not later - the value is in the details that are obvious now and
  gone in a week: the wrong turn, the misleading error, the constraint that wasn't documented
  anywhere.
