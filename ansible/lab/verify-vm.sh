#!/usr/bin/env bash
set -euo pipefail
umask 077
lab=$(mktemp -d)
cleanup() {
  if [[ -s "$lab/qemu.pid" ]]; then
    sudo kill "$(cat "$lab/qemu.pid")" 2>/dev/null || true
  fi
  rm -rf "$lab"
}
trap cleanup EXIT

echo '=== Prepare isolated Ubuntu 24.04 guest ==='
ssh-keygen -q -t ed25519 -N '' -f "$lab/controller"
ssh-keygen -q -t ed25519 -N '' -f "$lab/host"
student_password=$(openssl rand -hex 24)
student_hash=$(printf '%s' "$student_password" | openssl passwd -6 -stdin)
export SSHPASS="$student_password"
cat > "$lab/user-data" <<DATA
#cloud-config
hostname: devops-vm
manage_etc_hosts: true
ssh_pwauth: true
ssh_deletekeys: true
ssh_keys:
  ed25519_private: |
$(sed 's/^/    /' "$lab/host")
  ed25519_public: $(cat "$lab/host.pub")
users:
  - name: student
    shell: /bin/bash
    groups: [sudo]
    lock_passwd: false
    hashed_passwd: '$student_hash'
    sudo: 'ALL=(ALL) ALL'
DATA
printf 'instance-id: ansible-pr11-1\nlocal-hostname: devops-vm\n' > "$lab/meta-data"
cloud-localds "$lab/seed.img" "$lab/user-data" "$lab/meta-data"
curl -fLsS --retry 4 https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img -o "$lab/ubuntu.img"
qemu-img create -q -f qcow2 -F qcow2 -b "$lab/ubuntu.img" "$lab/guest.qcow2" 12G

if sudo test -c /dev/kvm; then
  cpu=(-accel kvm -cpu host)
  echo 'QEMU acceleration: KVM'
else
  cpu=(-accel tcg,thread=multi -cpu max)
  echo 'QEMU acceleration: TCG'
fi
sudo qemu-system-x86_64 "${cpu[@]}" -machine q35 -smp 2 -m 3072 \
  -display none -serial "file:$lab/serial.log" -daemonize -pidfile "$lab/qemu.pid" \
  -drive "file=$lab/guest.qcow2,if=virtio" -drive "file=$lab/seed.img,format=raw,if=virtio,readonly=on" \
  -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:22211-:22,hostfwd=tcp:127.0.0.1:18081-:80

printf '[127.0.0.1]:22211 %s\n' "$(cut -d ' ' -f 1,2 "$lab/host.pub")" > "$lab/known_hosts"
ssh_opts=(-p 22211 -o "UserKnownHostsFile=$lab/known_hosts" -o StrictHostKeyChecking=yes -o ConnectTimeout=5)
bootstrap_opts=(-o PreferredAuthentications=password -o PubkeyAuthentication=no)
ready=0
for attempt in {1..100}; do
  if sshpass -e ssh "${ssh_opts[@]}" "${bootstrap_opts[@]}" student@127.0.0.1 true 2>"$lab/ssh-error"; then
    ready=1
    break
  fi
  sleep 3
done
if [[ "$ready" == 0 ]]; then
  cat "$lab/ssh-error"
  sudo tail -65 "$lab/serial.log"
  exit 1
fi
sshpass -e ssh "${ssh_opts[@]}" "${bootstrap_opts[@]}" student@127.0.0.1 'cloud-init status --wait && whoami && uname -m'

export ANSIBLE_SSH_ARGS="-o UserKnownHostsFile=$lab/known_hosts -o StrictHostKeyChecking=yes -o ControlMaster=no"
export LAB_CONTROLLER="$lab/controller"
python - "$lab" <<'PY'
import json
import os
import sys
from pathlib import Path

d = Path(sys.argv[1])
common = {"ansible_host": "127.0.0.1", "ansible_port": 22211,
          "automation_public_key_file": str(d / "controller.pub")}
password = os.environ["SSHPASS"]
(d / "bootstrap.json").write_text(json.dumps(
    dict(common, ansible_password=password, ansible_become_password=password)))
(d / "prod.json").write_text(json.dumps(
    dict(common, ansible_private_key_file=str(d / "controller"))))
PY

cd ansible
ansible-inventory -i inventory/bootstrap.ini --graph
ansible-inventory --graph
ansible-playbook -i inventory/bootstrap.ini site.yml --syntax-check
ansible-playbook site.yml --syntax-check
ansible-playbook verify.yml --syntax-check
prod=(-e "@$lab/prod.json")
remote() {
  ssh "${ssh_opts[@]}" -o BatchMode=yes -i "$LAB_CONTROLLER" devops@127.0.0.1 "$@"
}
health() {
  curl -fsS http://127.0.0.1:18081/health | tee "$lab/health.json"
  python -c 'import json,sys; assert json.load(open(sys.argv[1])) == {"status":"ok"}' "$lab/health.json"
}
zero_changes() {
  grep -Eq 'changed=0[[:space:]]+unreachable=0[[:space:]]+failed=0' "$1"
}

echo '=== Bootstrap as student with password and sudo ==='
ansible-playbook -i inventory/bootstrap.ini -e "@$lab/bootstrap.json" site.yml | tee "$lab/bootstrap.log"
echo '=== SSH key, non-interactive sudo, HTTP and UFW ==='
remote 'whoami && sudo -n true && echo sudo-ok'
ansible all "${prod[@]}" -m ansible.builtin.ping
if sshpass -e ssh "${ssh_opts[@]}" "${bootstrap_opts[@]}" student@127.0.0.1 true >"$lab/password-only.log" 2>&1; then
  echo 'Unexpected password-only authentication success'
  exit 1
fi
cat "$lab/password-only.log"
grep -q 'Permission denied (publickey)' "$lab/password-only.log"
health
curl -fsS http://127.0.0.1:18081/
remote "sudo ss -tlnp | grep -E ':(22|80|5000)\\b'; sudo ufw status verbose; docker --version; docker ps"
remote 'test ! -e /etc/nginx/sites-enabled/default && test -L /etc/nginx/sites-enabled/devops-ci-app'

echo '=== Idempotent deployment with production inventory ==='
ansible-playbook "${prod[@]}" site.yml | tee "$lab/second.log"
zero_changes "$lab/second.log"
echo '=== Manual drift and playbook recovery ==='
remote "docker rm -f devops-ci-app && sudo sed -i 's/127.0.0.1:5000/127.0.0.1:5001/' /etc/nginx/sites-available/devops-ci-app && sudo nginx -t && sudo systemctl reload nginx"
curl -sS -D "$lab/headers" -o /dev/null http://127.0.0.1:18081/health
head -1 "$lab/headers"
grep -Eq '^HTTP/[^ ]+ 502 ' "$lab/headers"
ansible-playbook "${prod[@]}" site.yml | tee "$lab/drift.log"
health

echo '=== Missing image tag preserves running container ==='
old_container=$(remote 'docker inspect -f "{{.Id}}" devops-ci-app')
if ansible-playbook "${prod[@]}" -e app_tag=0000000000000000000000000000000000000000 site.yml | tee "$lab/missing.log"; then
  echo 'Unexpected success with nonexistent image tag'
  exit 1
fi
grep -Eqi 'manifest unknown|not found|404' "$lab/missing.log"
health
current_container=$(remote 'docker inspect -f "{{.Id}}" devops-ci-app')
test "$old_container" = "$current_container"
printf 'Unchanged container id: %s\n' "$current_container"
ansible-playbook "${prod[@]}" site.yml | tee "$lab/restored.log"
zero_changes "$lab/restored.log"

echo '=== Read-only audit, stopped-container detection and recovery ==='
ansible-playbook "${prod[@]}" verify.yml | tee "$lab/audit1.log"
ansible-playbook "${prod[@]}" verify.yml | tee "$lab/audit2.log"
zero_changes "$lab/audit1.log"
zero_changes "$lab/audit2.log"
remote 'docker stop devops-ci-app'
if ansible-playbook "${prod[@]}" verify.yml | tee "$lab/audit-fail.log"; then
  echo 'Unexpected audit success with stopped container'
  exit 1
fi
grep -q 'container_info.container.State.Running' "$lab/audit-fail.log"
ansible-playbook "${prod[@]}" site.yml
ansible-playbook "${prod[@]}" verify.yml | tee "$lab/audit-final.log"
zero_changes "$lab/audit-final.log"
health
