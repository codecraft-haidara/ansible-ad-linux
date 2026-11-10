#!/usr/bin/env bash
# Test réel du volet sudo/DBA, sans Active Directory : groupes et utilisateurs
# LOCAUX, use_fully_qualified_names=false.
#
# ATTENTION : à lancer en root sur une machine de test jetable (VM, conteneur).
# Le script crée des comptes locaux et écrit dans /etc/sudoers.d/.
#
#   sudo bash tests/test_local_sudo.sh
set -u
cd "$(dirname "$0")/.."

DBA=t_dba        # membre de dba_caisff
ADM=t_admin      # membre de admdisr
fail=0

getent group admdisr    >/dev/null || groupadd admdisr
getent group dba_caisff >/dev/null || groupadd dba_caisff
id "$DBA" >/dev/null 2>&1 || useradd -m -G dba_caisff "$DBA"
id "$ADM" >/dev/null 2>&1 || useradd -m -G admdisr "$ADM"
id postgres >/dev/null 2>&1 || useradd -r -m postgres
# sudo -l a besoin que la commande existe : faux pg_dump si PostgreSQL est absent
command -v pg_dump >/dev/null || { printf '#!/bin/sh\nexit 0\n' > /usr/local/bin/pg_dump; chmod 755 /usr/local/bin/pg_dump; }

run_role() {
  ansible-playbook -i tests/inventory_local.yml playbooks/ad_linux.yml \
    --tags sudo,dba --skip-tags preflight
}

echo "===== 1er passage ====="
run_role | tee /tmp/ad_linux_run1.log | tail -n 4
echo "===== 2e passage (idempotence) ====="
run_role | tee /tmp/ad_linux_run2.log | tail -n 4
if grep -Eq 'changed=0 .*failed=0' /tmp/ad_linux_run2.log; then
  echo "OK    idempotence : changed=0"
else
  echo "ECHEC idempotence"; fail=1
fi

# check <attendu: oui|non> <utilisateur> <arguments de sudo -l ...>
check() {
  local want=$1 user=$2; shift 2
  if sudo -l -U "$user" "$@" >/dev/null 2>&1; then got=oui; else got=non; fi
  if [ "$got" = "$want" ]; then res="OK   "; else res="ECHEC"; fail=1; fi
  printf '%s %-8s attendu=%s obtenu=%s : %s\n' "$res" "$user" "$want" "$got" "$*"
}

echo "===== DBA : autorisé ====="
check oui "$DBA" apt-get install htop
check oui "$DBA" apt-get install -y htop
check oui "$DBA" apt-get install htop postgresql-client
check oui "$DBA" apt-get update
check oui "$DBA" systemctl restart postgresql
check oui "$DBA" systemctl reload postgresql
check oui "$DBA" -u postgres pg_dump
check oui "$DBA" -u postgres bash
echo "===== DBA : REFUSÉ ====="
check non "$DBA" apt-get install -o APT::Update::Pre-Invoke::=/bin/sh htop
check non "$DBA" apt-get install htop -o APT::Update::Pre-Invoke::=/bin/sh
check non "$DBA" apt-get install openssh-server-
check non "$DBA" apt-get install ./paquet.deb
check non "$DBA" apt-get install
check non "$DBA" apt-get remove openssh-server
check non "$DBA" apt-get update -o APT::Update::Pre-Invoke::=/bin/sh
check non "$DBA" systemctl status postgresql
check non "$DBA" systemctl restart ssh
check non "$DBA" bash
echo "===== Admin ====="
check oui "$ADM" bash
check oui "$ADM" systemctl status postgresql

echo "===== Fichiers ====="
stat -c '%a %U:%G %n' /etc/sudoers.d/ad-groups /etc/sudoers.d/dba /var/backups/postgresql
visudo -c

[ "$fail" -eq 0 ] && echo "RÉSULTAT : tous les tests passent" || echo "RÉSULTAT : au moins un ÉCHEC"
exit "$fail"
