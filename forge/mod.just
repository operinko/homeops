set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

forge_dir := justfile_dir() + '/forge'
forge_ip := '192.168.7.30'
npmplus_ip := '192.168.0.5'
runner1_ip := '192.168.7.31'
runner2_ip := '192.168.7.32'

[private]
default:
    just -l forge

[doc('Apply Forgejo config to the forge LXC')]
apply-forgejo:
    ssh root@{{ forge_ip }} 'mkdir -p -m 700 /root/.homeops-staging'
    sops -d {{ forge_dir }}/secrets.sops.yaml | minijinja-cli {{ forge_dir }}/config/app.ini.j2 --format yaml - | ssh root@{{ forge_ip }} 'umask 077; cat > /root/.homeops-staging/app.ini'
    scp -q {{ forge_dir }}/apply-forgejo.sh root@{{ forge_ip }}:/root/.homeops-staging/
    ssh root@{{ forge_ip }} 'bash /root/.homeops-staging/apply-forgejo.sh; rc=$?; rm -rf /root/.homeops-staging; exit $rc'

[doc('Apply runner config: just forge apply-runner 1|2 (set FORGEJO_RUNNER_TOKEN to (re)register)')]
apply-runner n:
    #!/usr/bin/env bash
    set -euo pipefail
    ip=$([ "{{ n }}" = "1" ] && echo "{{ runner1_ip }}" || echo "{{ runner2_ip }}")
    ssh root@$ip 'mkdir -p -m 700 /root/.homeops-staging'
    sops -d {{ forge_dir }}/secrets.sops.yaml | minijinja-cli {{ forge_dir }}/config/runner-config.yaml.j2 --format yaml - | ssh root@$ip 'umask 077; cat > /root/.homeops-staging/config.yaml'
    scp -q {{ forge_dir }}/apply-runner.sh root@$ip:/root/.homeops-staging/
    ssh root@$ip "FORGEJO_RUNNER_TOKEN='${FORGEJO_RUNNER_TOKEN:-}' bash /root/.homeops-staging/apply-runner.sh; rc=\$?; rm -rf /root/.homeops-staging; exit \$rc"

[doc('Apply WireGuard + stream config to the npmplus LXC')]
apply-npmplus:
    ssh root@{{ npmplus_ip }} 'mkdir -p -m 700 /root/.homeops-staging'
    sops -d {{ forge_dir }}/secrets.sops.yaml | minijinja-cli {{ forge_dir }}/config/wg0-npmplus.conf.j2 --format yaml - | ssh root@{{ npmplus_ip }} 'umask 077; cat > /root/.homeops-staging/wg0.conf'
    scp -q {{ forge_dir }}/apply-npmplus.sh root@{{ npmplus_ip }}:/root/.homeops-staging/
    ssh root@{{ npmplus_ip }} 'sh /root/.homeops-staging/apply-npmplus.sh; rc=$?; rm -rf /root/.homeops-staging; exit $rc'

[doc('One-time/idempotent Forgejo API-level state (org, mirrors, secrets)')]
setup:
    sops exec-env {{ forge_dir }}/secrets.sops.yaml 'bash {{ forge_dir }}/setup-forgejo.sh'

[doc('SSH into the forge LXC')]
ssh:
    ssh root@{{ forge_ip }}
