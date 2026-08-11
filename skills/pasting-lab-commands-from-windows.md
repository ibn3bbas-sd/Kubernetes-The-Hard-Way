# Pasting lab commands from Windows: CRLF silently truncates them

**Living doc.** Status: **ACTIVE - affects every lab from 04 onwards.** Hit on 2026-08-11 during
[04-certificate-authority](../docs/04-certificate-authority.md) while working through the
[multipass-windows](multipass-windows-runbook.md) route.

If you copy commands from a browser on Windows and paste them into a VM shell, each line arrives
terminated `\r\n` instead of `\n`. Bash does not treat `\r` as whitespace, and that breaks the lab
in two different ways - **both of which can look like success.**

## Failure 1: `\`-continued commands are cut in half

The labs write long commands across lines:

```bash
openssl req -new -key kube-proxy.key \
  -subj "/CN=system:kube-proxy/O=system:node-proxier" -out kube-proxy.csr
```

With CRLF, the `\` escapes the **carriage return**, not the line break. The line break then ends the
command, and everything after it runs as a separate command.

What that looked like in practice:

```
You are about to be asked to enter information that will be incorporated
into your certificate request.
...
Country Name (2 letter code) [AU]:
State or Province Name (full name) [Some-State]:
...
-----BEGIN CERTIFICATE REQUEST-----
MIICijCCAXICAQAwRTELMAkGA1UEBhMCQVUxEzARBgNVBAgMClNvbWUtU3RhdGUx
...
-----END CERTIFICATE REQUEST-----
-subj: command not found
Can't open "kube-proxy.csr" for reading, No such file or directory
-CA: command not found
```

Read that carefully, because it is the whole trap:

1. `openssl req` ran **without** `-subj` and **without** `-out`, so it fell back to interactive
   prompts. Pressing Enter through them is harmless-looking and produces a CSR.
2. That CSR went to **stdout** - printed to the screen, saved nowhere.
3. `-subj ...` ran as a command: `command not found`.
4. The signing step then failed because `kube-proxy.csr` does not exist.

**Net result: a `.key` with no `.crt`, and no single error that says so.** The same thing had
already happened one step earlier to `kube-controller-manager` without being noticed - the giveaway
was `kube-controller-manager.key` existing with no `.crt` beside it.

Later labs fail far from the cause: kubeconfig steps that reference a missing certificate, or an
API server that will not start.

## Failure 2: heredocs embed `\r` into the files they write

Worse, and harder to spot. Labs 07, 08, 10 and 11 create systemd units and kubeconfigs like this:

```bash
cat <<EOF | sudo tee /etc/systemd/system/kube-apiserver.service
[Service]
ExecStart=/usr/local/bin/kube-apiserver \\
  --advertise-address=${PRIMARY_IP} \\
...
EOF
```

Here the command does not break - the heredoc swallows the lines - so **every line lands in the
unit file with a trailing `\r`**. systemd then parses values with an invisible carriage return
attached, and you get failures that make no sense against a file that looks perfect in `cat`.

Check any file written by a heredoc:

```bash
grep -c $'\r' /etc/systemd/system/kube-apiserver.service   # expect 0
cat -A /etc/systemd/system/kube-apiserver.service | head   # ^M means CR present
```

## Confirm it in five seconds

Paste exactly this:

```bash
echo one \
  two
```

* `one two` - continuations are fine, this doc does not apply to you.
* `one` followed by `two: command not found` - confirmed.

## How much of the lab this affects

`\`-continued lines per doc:

| Doc | Lines |
|---|---|
| 04-certificate-authority | 19 |
| 05-kubernetes-configuration-files | 38 |
| 07-bootstrapping-etcd | 22 |
| 08-bootstrapping-kubernetes-controllers | 56 |
| 10-bootstrapping-kubernetes-workers | 20 |
| 11-tls-bootstrapping-kubernetes-workers | 27 |
| 12-configuring-kubectl | 7 |
| 16-smoke-test | 6 |
| 17-e2e-tests | 1 |
| **total** | **196** |

This is not a one-off to work around; it needs fixing once, properly.

## The fix

**Preferred - paste into a file and strip the CRs.** Client-independent, works for every block in
every lab, and is the only safe option for heredoc blocks and for the `kube-apiserver` SAN list,
where silent truncation would be very hard to trace:

```bash
cat > /tmp/step.sh     # paste the whole block, then press Ctrl-D
sed -i 's/\r$//' /tmp/step.sh
bash /tmp/step.sh
```

**For a single short command**, collapsing it onto one line also works, since there is no `\` left
to be broken:

```bash
openssl req -new -key kube-proxy.key -subj "/CN=system:kube-proxy/O=system:node-proxier" -out kube-proxy.csr
```

**Fix it at the source if your terminal allows it.** MobaXterm, PuTTY and Windows Terminal each
have paste behaviour settings; if yours can send LF only, that removes the problem for good. Worth
five minutes before starting lab 05, which has twice as many continuations as 04.

## Recovering from it

The `.key` files are fine - `openssl genrsa` is a single line and always succeeded. Reuse the key
and redo only the CSR and signing steps. For example:

```bash
openssl req -new -key kube-controller-manager.key -subj "/CN=system:kube-controller-manager/O=system:kube-controller-manager" -out kube-controller-manager.csr
openssl x509 -req -in kube-controller-manager.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out kube-controller-manager.crt -days 1000
```

## Catching it early

* After any multi-line block, `ls -l` the file it was supposed to create. A key with no matching
  certificate is the signature of this bug.
* Run `~/cert_verify.sh` wherever the labs tell you to. It catches exactly this class of gap, and
  anything red means an earlier step, not a lab bug.
* A quick audit of lab 04's expected output:

```bash
cd ~
for f in ca admin kube-controller-manager kube-proxy kube-scheduler \
         kube-apiserver service-account apiserver-etcd-client etcd-server; do
  printf "%-28s key=%s crt=%s\n" "$f" \
    "$([ -f $f.key ] && echo Y || echo -)" "$([ -f $f.crt ] && echo Y || echo -)"
done
```

## Why this is not in the upstream labs

The lab was written and tested on macOS and Linux, where the clipboard carries LF. It is specific
to driving the VMs from a Windows host - the same reason the
[multipass-windows](multipass-windows-runbook.md) route exists at all.
