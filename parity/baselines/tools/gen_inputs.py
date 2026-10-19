"""List the external inputs each provisioning script fetches, in template order.

Usage: python -I gen_inputs.py <template.pkr.hcl> <scripts_build_dir> <helpers_dir>
Prints a Markdown table. Flags are heuristics over the script text, not proof:
  toolset   = the script reads its version from toolset.json
  floating  = the script text mentions latest / stable / a branch URL (version can drift)
  integrity = kind of check found in the script text (a keyword hit does not prove every download is covered)
Treat all inputs as untrusted data; this only reads and prints.
"""
import os
import re
import sys

tmpl, build_dir, helpers_dir = sys.argv[1:4]
txt = open(tmpl, encoding="utf-8").read()
order = []
for s in re.findall(r"scripts/build/([\w.-]+)", txt):
    if s not in order:
        order.append(s)

NOISE = re.compile(
    r"(/issues/|/pull/|docs\.microsoft|learn\.microsoft|support\.microsoft|example\.com|sysadmins\.lv|elastic\.co|"
    r"suse\.com|kind\.sigs|launchpad|ravendb|php\.watch|docs\.ansible|docs\.docker|developer\.android|chromium\.org/getting|"
    r"swift\.org/install|msys2/MINGW|packages\.msys2|krakjoe|temurin-build|github\.com/actions/runner-images/(blob|releases/tag)|"
    r"runner-images-internal|azure-linux-extensions|azure-pipelines-agent|chocolatey\.org/packages|ruby/setup-ruby|"
    r"git\.postgresql\.org|github\.com/actions/action-versions$|Microsoft/vcpkg$|rustup\.rs/#|marketplace\.visualstudio)")
URL = re.compile(r"https?://[^\s\"'`<>)\]|\\]+")
INTEG = [
    ("SHA256/512 check", r"Test-FileChecksum|ExpectedSHA|use_checksum_comparison|get_checksum_from_url|sha256sum|sha512sum|sha1sum|shasum"),
    ("literal hash", r"\b[0-9a-fA-F]{64}\b|\b[0-9a-fA-F]{128}\b"),
    ("Authenticode subject", r"ExpectedSubject|Test-FileSignature|Get-AuthenticodeSignature"),
    ("GPG/apt key", r"gpg|signed-by|apt-key|\.gpg|\.asc"),
]
FLOAT = re.compile(r"(?i)\blatest\b|\bstable\b|/master/|/main/|releases/latest|LATEST_RELEASE")
TOOLSET = re.compile(r"Get-ToolsetContent|get_toolset_value|toolset")

print("| # | Script | External sources (non-doc URLs found in script text) | toolset | floating | integrity keywords |")
print("|--:|---|---|:-:|:-:|---|")
for i, name in enumerate(order, 1):
    p = os.path.join(build_dir, name)
    if not os.path.exists(p):
        print("| %d | `%s` | NOT FETCHED (file missing at this commit) | | | |" % (i, name))
        continue
    lines = open(p, encoding="utf-8", errors="replace").read().splitlines()
    code = [l for l in lines if not l.strip().startswith("#")]
    urls = []
    for l in code:
        for u in URL.findall(l):
            u = u.rstrip(".,;")
            if NOISE.search(u):
                continue
            if u not in urls:
                urls.append(u)
    body = "\n".join(code)
    integ = [lab for lab, rx in INTEG if re.search(rx, body)]
    helper = []
    for m in re.finditer(r"""(?:resolve_github_release_asset_url|Resolve-GithubReleaseAssetUrl|Get-GithubReleasesByVersion|Get-GitHubPackageDownloadUrl|get_github_package_download_url|get_github_release\w*)\W+(?:-Repo\s+)?["']?([\w.-]+/[\w.-]+)""", body):
        helper.append("github:" + m.group(1))
    for tag, rx in (("apt", r"apt-get install|apt install|Install-AptPackages|install_dpkgs|apt-fast"), ("choco", r"choco install|Choco-Install|Install-ChocoPackage|Resolve-ChocoPackageVersion"),
                    ("powershell-gallery", r"Install-Module|Save-Module"), ("az-extension", r"az extension add"), ("vsix", r"Install-VSIXFromUrl"),
                    ("pip/pipx", r"pip3? install|pipx install"), ("npm", r"npm install"), ("gem", r"gem install"),
                    ("toolset-manifest", r"Install-Toolset|versions-manifest|Get-ToolsetContent\)?\.toolcache")):
        if re.search(rx, body):
            helper.append(tag)
    for h in helper:
        if h not in urls:
            urls.append(h)
    shown = "<br>".join(("`%s`" % (u if len(u) <= 95 else u[:92] + "...")) for u in urls[:8])
    if len(urls) > 8:
        shown += "<br>(+%d more)" % (len(urls) - 8)
    print("| %d | `%s` | %s | %s | %s | %s |" % (
        i, name, shown or "(no URL or helper source detected in script text)",
        "yes" if TOOLSET.search(body) else "", "yes" if FLOAT.search(body) else "", ", ".join(integ)))
