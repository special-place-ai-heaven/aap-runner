#!/bin/bash
# linux/browsers: browser and driver versions (Chrome, ChromeDriver, Chromium, Edge, Edge WebDriver, Firefox,
# Geckodriver, the Selenium jar), the driver variables, and headless Chrome (CHROME_BIN, its default sandbox) running a
# local page's JavaScript (--dump-dom). No network: the page is a file.
# Sabotage no-chrome points CHROME_BIN (what Karma and similar runners read) at a file that does not exist.
# shellcheck source-path=SCRIPTDIR source=../lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
wl_start "$@"

ver() { grep -oE '[0-9]+(\.[0-9]+)+' <<< "$1" | head -n 1; }
if [ -z "${SABOTAGE}" ]; then
  for n in $(oracle_keys browser_env); do fact "env.${n}" "$(printenv "${n}")" "$(oracle "browser_env/${n}")"; done
  for b in google-chrome:chrome chromedriver:chromedriver chromium:chromium microsoft-edge:edge \
    "${EDGEWEBDRIVER:-}/msedgedriver:edgedriver" firefox:firefox geckodriver:geckodriver; do
    try_run "${b%:*}" --version
    fact "version.${b#*:}" "$(ver "${OUT}")" "$(oracle "versions/${b#*:}")"
  done
  fact selenium.jar "$([ -r "${SELENIUM_JAR_PATH:-}" ] && echo yes)" yes
  observe chromedriver.path "$(command -v chromedriver)"
elif [ "${SABOTAGE}" = no-chrome ]; then
  export CHROME_BIN="${WORK}/no-chrome/google-chrome"
  line "sabotage no-chrome applied"
  fact sabotage.chrome_bin_exists "$([ -e "${CHROME_BIN}" ] && echo yes)" ''
else
  die "unknown sabotage ${SABOTAGE}"
fi
[ -x "${CHROME_BIN:-}" ] || die "CHROME_BIN is not an executable: ${CHROME_BIN:-<unset>}"
run timeout 120 "${CHROME_BIN}" --headless=new --disable-gpu --no-first-run --disable-background-networking \
  --disable-component-update --user-data-dir="${WORK}/chrome-profile" \
  --dump-dom "file://${WL_LIB_DIR}/browsers/page.html"
dom=$(grep -o '<p id="out">[^<]*</p>' <<< "${OUT}")
fact chrome.dump_dom "${dom}" '<p id="out">js ran 10</p>'
report "chrome.dump_dom=${dom}"
wl_end
