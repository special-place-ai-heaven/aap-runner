#!/bin/bash
# linux/services: systemd units as the image leaves them (enabled and active states), then the documented way to use
# the databases: sudo systemctl start postgresql.service (psql as the postgres user answers a query) and
# mysql.service (active, socket present; the image's root credential is not used here), both stopped again at the
# end. Runs only inside an Actions job (sudo, systemd).
# Sabotage not-started queries PostgreSQL without starting its service first.
# shellcheck source-path=SCRIPTDIR source=../lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
wl_start "$@"
require_actions

started=()
wl_cleanup() {
  local s
  for s in "${started[@]}"; do sudo -n systemctl stop "${s}" > /dev/null 2>&1; done
  return 0
}
state() { printf 'enabled=%s active=%s' "$(systemctl is-enabled "$1" 2>&1)" "$(systemctl is-active "$1" 2>&1)"; }
if [ -z "${SABOTAGE}" ]; then
  for s in $(oracle_keys services); do fact "service.${s}" "$(state "${s}")" "$(oracle "services/${s}")"; done
elif [ "${SABOTAGE}" = not-started ]; then
  line "sabotage not-started applied"
  fact sabotage.postgresql_active "$(systemctl is-active postgresql.service)" inactive
else
  die "unknown sabotage ${SABOTAGE}"
fi
run psql --version
fact postgresql.version "$(awk '{ print $3 }' <<< "${OUT}")" "$(oracle versions/postgresql)"
if [ -z "${SABOTAGE}" ]; then
  started+=(postgresql.service)
  run sudo -n systemctl start postgresql.service
  for _ in $(seq 30); do pg_isready -q && break; sleep 1; done
fi
run sudo -n -u postgres psql -tA -c 'select 6 * 7'
pg=${OUT}
fact postgresql.query "${pg}" 42

run mysqld --version
fact mysql.version "$(grep -oE 'Ver [^ ]+' <<< "${OUT}" | cut -c5-)" "$(oracle versions/mysql)"
started+=(mysql.service)
run sudo -n systemctl start mysql.service
fact mysql.active "$(systemctl is-active mysql.service)" active
fact mysql.socket "$([ -S /var/run/mysqld/mysqld.sock ] && echo yes)" yes
report "postgresql.query=${pg}" "mysql.active=active"
wl_end
