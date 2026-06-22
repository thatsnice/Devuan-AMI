# FIXME: cloud-init network stage occasionally skipped at boot

## Symptom

New EC2 instances launched from this AMI sometimes finish cloud-init
without ever running the network (`init`) stage. When that happens,
user-data is fetched (`init-local` sees it) but is never dispatched to
`/var/lib/cloud/instance/scripts/`, so `scripts-user` runs in ~1ms with
an empty directory and the instance never bootstraps itself.

It's intermittent. Of the new instances launched during the 2026-06-10
RentCoordinator incident, at least one had the network stage skipped
(`i-02f21c249479351c1`) and at least one ran it correctly
(`i-038d3e670f9b3aeba`) from the same AMI with the same user-data.

## Evidence

`/var/log/cloud-init.log` on a failing instance, in order:

```
init-local finished at Up 1.1 seconds.
  [local] Exiting. datasource DataSourceEc2Local not in local mode.
  finish: init-local: SUCCESS: searching for local datasources
modules:config starting at Up 40.5 seconds.
  ...
scripts-user ran successfully and took 0.001 seconds
```

The jump from `init-local` straight to `modules:config` is the
fingerprint — the `init` stage between them never logged anything,
which means `/etc/init.d/cloud-init-main start` was never invoked by
sysv-rc on this boot. (Confirmed: `grep -i 'cloud-init-main' /var/log/syslog
/var/log/messages /var/log/boot*` returns nothing on a failing boot.)

The script itself is not at fault. On a failing instance,
`sudo bash -x /etc/init.d/cloud-init-main start` runs cleanly, invokes
`/usr/bin/cloud-init init`, the network stage executes, user-data lands
in `/var/lib/cloud/instance/scripts/part-001`, and a subsequent
`cloud-init modules --mode final` (after clearing the `config_scripts_user`
semaphore) runs the user-data. So this is purely a question of why
sysv-rc fails to start the service on some boots.

## Suspected causes (in order of likelihood)

1. **Boot ordering race against `$syslog` / `$remote_fs`.**
   `cloud-init-main`'s LSB header declares `Required-Start: $remote_fs
   $syslog`. If insserv-resolved ordering occasionally places
   `cloud-init-main` such that one of its requirements isn't actually
   ready (or another concurrently-started script holds something it
   blocks on), sysv-rc may silently skip the start. `cloud-init-local`
   ran on the same boot, which suggests the local-only deps are fine
   but the network/remote-fs deps may not be.

2. **`insserv` ordering metadata baked into the AMI is stale.** If the
   AMI was snapshotted while `/var/lib/insserv/run.d` or `/etc/init.d/.depend.*`
   were in a partially-rebuilt state, the runtime ordering may
   intermittently honor a different set of links than the
   `S01cloud-init-main` symlinks would suggest. `update-rc.d -f
   cloud-init-main remove && update-rc.d cloud-init-main defaults`
   inside the AMI build, followed by an explicit `insserv` regenerate,
   would rule this out.

3. **A boot-time service running before sysv-rc finishes processes user-data
   races with cloud-init.** Less likely — there's no obvious candidate
   — but worth ruling out by capturing `/var/log/boot` or
   `/var/log/sysvinit-rc.log` from a failing boot.

## How to reproduce

Launch a small number of instances from the AMI back-to-back (the
RentCoordinator ASG churn during the incident produced one bad boot
per ~5-10 launches). On each instance, after cloud-init finishes:

```
:# Is user-data in the scripts dir? If absent, the network stage was skipped.
ls /var/lib/cloud/instance/scripts/

:# Did the init.d script run? If empty, it never got invoked.
grep -i 'cloud-init-main' /var/log/syslog /var/log/messages /var/log/boot*
```

## What to fix in the AMI build

Three concrete things to do in the builder (`src/configurator.coffee`):

1. **Make sure the init.d ordering is regenerated cleanly during AMI
   build.** After `update-rc.d cloud-init-main defaults`, run `insserv
   -d` (or equivalent) so the `.depend.*` files are fresh, and then
   snapshot. Don't rely on whatever state happened to exist on the
   build host.

2. **Stop depending on sysv-rc to run `cloud-init init` reliably.** The
   simplest belt-and-suspenders fix is to add a `start-on-boot` shim
   that runs at the end of `rc.local` (or as a one-shot service late
   in the boot) and does:

   ```
   if [ ! -f /var/lib/cloud/instance/boot-finished ] \
        && [ ! -d /var/lib/cloud/instance/scripts ]; then
       /usr/bin/cloud-init init
       /usr/bin/cloud-init modules --mode config
       /usr/bin/cloud-init modules --mode final
   fi
   ```

   That catches the case where sysv-rc skipped cloud-init-main, without
   affecting boots where it ran normally.

3. **Smoke-test for the missing-network-stage case in
   `src/smoke-test.coffee`.** A short test after first boot: assert
   `/var/lib/cloud/instance/scripts/` is non-empty (when user-data was
   provided). Today's smoke test apparently doesn't catch this.

## Workaround for affected instances (until the AMI is fixed)

```
sudo /usr/bin/cloud-init init
sudo rm -f /var/lib/cloud/instances/*/sem/config_scripts_user
sudo /usr/bin/cloud-init modules --mode final
```

Runs the network stage by hand, clears the once-per-instance lock so
`scripts-user` actually executes the user-data, and finishes the boot.

## References

- AMI ID at time of incident: `ami-0a5eab7419cee78d7` (Devuan daedalus
  amd64, custom, dated 2026-03-14)
- RentCoordinator infrastructure that uses this AMI:
  `../../rdeforest/RentCoordinator/infrastructure/cloudformation/rent-coordinator-infrastructure.yaml`
- Original failing-instance logs preserved at:
  `../../rdeforest/RentCoordinator/tmp/cloud-init.log` (gitignored)
