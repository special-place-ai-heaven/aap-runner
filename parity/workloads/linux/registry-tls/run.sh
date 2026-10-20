#!/bin/bash
# linux/registry-tls: what package registries and TLS clients on this image rely on, read from configuration and never
# fetched: the OpenSSL package and the system CA bundle (also as Python and Node see it), the apt mirror list and
# sources, npm's registry, pip's and NuGet's configured indexes. Then a local TLS server (openssl s_server with a
# self-signed certificate for localhost) is reached with curl and Python trusting that certificate as their CA.
# Sabotage untrusted-ca calls the same server without giving curl the certificate.
# shellcheck source-path=SCRIPTDIR source=../lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
wl_start "$@"

server=''
wl_cleanup() {
  [ -z "${server}" ] || kill "${server}" 2> /dev/null
  return 0
}
if [ -z "${SABOTAGE}" ]; then
  fact openssl.package "$(dpkg-query -W -f '${Version}' openssl)" "$(oracle versions/openssl)"
  bundle=/etc/ssl/certs/ca-certificates.crt
  n=$(grep -c 'BEGIN CERTIFICATE' "${bundle}")
  observe ca.bundle_certs "${n}"
  fact ca.bundle_over_100_certs "$([ "${n:-0}" -gt 100 ] && echo yes)" yes
  run python3 -B -I -c 'import ssl; c = ssl.create_default_context(); print(ssl.get_default_verify_paths().openssl_cafile); print(c.cert_store_stats()["x509_ca"])'
  observe python.cafile "${OUT%%$'\n'*}"
  fact python.default_context_over_100_cas "$([ "${OUT##*$'\n'}" -gt 100 ] && echo yes)" yes
  run node -p 'require("tls").rootCertificates.length'
  observe node.root_certificates "${OUT}"
  observe env.SSL_CERT_FILE "${SSL_CERT_FILE:-<unset>}"
  observe env.NODE_EXTRA_CA_CERTS "${NODE_EXTRA_CA_CERTS:-<unset>}"
  # apt: the mirror list the image configures, in order, and every source URI
  fact apt.mirrors "$(awk '{ print $1 }' /etc/apt/apt-mirrors.txt 2> /dev/null | sed -E 's#^[a-z]+://([^/]+)/.*#\1#')" "$(oracle_list apt_mirrors)"
  observe apt.uris "$(cat /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources 2> /dev/null | sed -n -E 's/^URIs: *//p; s/^deb(-src)? +(\[[^]]*\] +)?([^ ]+).*/\3/p' | sort -u)"
  run npm config get registry
  fact npm.registry "${OUT}" "$(oracle registries/npm)"
  run python3 -m pip config list
  fact pip.config "${OUT}" "$(oracle registries/pip_config)"
  observe env.PIP_INDEX_URL "${PIP_INDEX_URL:-<unset>}"
  export DOTNET_CLI_HOME="${WORK}/dotnet-home" DOTNET_NOLOGO=1 DOTNET_CLI_TELEMETRY_OPTOUT=1
  run dotnet nuget list source --format short
  fact nuget.sources "${OUT}" "$(oracle registries/nuget)"
elif [ "${SABOTAGE}" != untrusted-ca ]; then
  die "unknown sabotage ${SABOTAGE}"
fi

run openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout key.pem -out cert.pem -days 1 \
  -subj /CN=localhost -addext subjectAltName=DNS:localhost,IP:127.0.0.1
run python3 -B -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
port=${OUT}
openssl s_server -accept "127.0.0.1:${port}" -cert cert.pem -key key.pem -www -quiet > s_server.log 2>&1 < /dev/null &
server=$!
up=''
for _ in $(seq 50); do
  curl -s -k -o /dev/null "https://localhost:${port}/" && { up=yes; break; }
  sleep 0.2
done
fact tls.server_up "${up}" yes
if [ "${SABOTAGE}" = untrusted-ca ]; then
  line "sabotage untrusted-ca applied"
  run curl --fail -sS -o page.html "https://localhost:${port}/"
else
  run curl --fail -sS --cacert cert.pem -o page.html "https://localhost:${port}/"
fi
fact tls.curl "$(grep -q 's_server' page.html && echo yes)" yes
run python3 -B -I -c 'import ssl, sys, urllib.request
ctx = ssl.create_default_context(cafile=sys.argv[1])
print(urllib.request.urlopen(sys.argv[2], context=ctx, timeout=10).status)' cert.pem "https://localhost:${port}/"
fact tls.python "${OUT}" 200
report "tls.curl=ok" "tls.python=${OUT}"
wl_end
