#!/usr/bin/env bash
# Idempotent Forgejo API-level state. Run via: just forge setup
# Env (from sops exec-env): forgejo_admin_pat, github_mirror_pat,
# harbor_url, harbor_username, harbor_password,
# cloudflare_api_token, cloudflare_account_id
set -euo pipefail
API="http://192.168.7.30:3000/api/v1"
AUTH="Authorization: token ${forgejo_admin_pat}"
ORG="operinko-labs"
GH_ORG="operinko-labs"    # GitHub org to migrate from
GH_USER_LOGIN="operinko"  # GitHub user account that also owns repos

fj() { curl -sf -H "$AUTH" -H 'Content-Type: application/json' "$@"; }

# --- org ---------------------------------------------------------------------
if ! fj "$API/orgs/$ORG" >/dev/null 2>&1; then
  fj -X POST "$API/orgs" -d "{\"username\":\"$ORG\",\"visibility\":\"private\"}" >/dev/null
  echo "created org $ORG"
fi

# --- build repo manifest (org repos + user-owned repos, dedup by name) ------
# Each line: "<github_owner>|<github_repo_name>|<forgejo_repo_name>"
manifest=()
declare -A seen

org_repos=$(curl -sf -H "Authorization: token ${github_mirror_pat}" \
  "https://api.github.com/orgs/$GH_ORG/repos?per_page=100" | jq -r '.[].name') \
  || { echo "ERROR: could not list GitHub org repos" >&2; exit 1; }
while IFS= read -r name; do
  [ -z "$name" ] && continue
  seen["$name"]=1
  manifest+=("$GH_ORG|$name|$name")
done <<<"$org_repos"

user_repos=$(curl -sf -H "Authorization: token ${github_mirror_pat}" \
  "https://api.github.com/user/repos?affiliation=owner&per_page=100" \
  | jq -r --arg u "$GH_USER_LOGIN" '.[] | select(.owner.login==$u) | .name') \
  || { echo "ERROR: could not list GitHub user repos" >&2; exit 1; }
while IFS= read -r name; do
  [ -z "$name" ] && continue
  target="$name"
  if [ -n "${seen[$name]:-}" ]; then
    target="${name}-personal"
  fi
  seen["$target"]=1
  manifest+=("$GH_USER_LOGIN|$name|$target")
done <<<"$user_repos"

# --- migrate + mirror every GitHub repo -------------------------------------
for entry in "${manifest[@]}"; do
  IFS='|' read -r owner name repo <<<"$entry"

  if ! fj "$API/repos/$ORG/$repo" >/dev/null 2>&1; then
    echo "migrating $owner/$name -> $ORG/$repo..."
    if ! fj -X POST "$API/repos/migrate" -d @- >/dev/null <<JSON
{"clone_addr":"https://github.com/$owner/$name.git","auth_token":"${github_mirror_pat}",
 "repo_owner":"$ORG","repo_name":"$repo","private":true,"service":"github",
 "issues":true,"pull_requests":true,"releases":true,"labels":true,"milestones":true,"wiki":true}
JSON
    then
      echo "WARN: migration failed for $owner/$name, will retry next run" >&2
      continue
    fi
  fi

  if ! fj "$API/repos/$ORG/$repo/push_mirrors" | jq -e 'length > 0' >/dev/null; then
    echo "adding push mirror for $repo -> $owner/$name..."
    if ! fj -X POST "$API/repos/$ORG/$repo/push_mirrors" -d @- >/dev/null <<JSON
{"remote_address":"https://github.com/$owner/$name.git",
 "remote_username":"$GH_USER_LOGIN","remote_password":"${github_mirror_pat}",
 "interval":"8h0m0s","sync_on_commit":true}
JSON
    then
      echo "WARN: push mirror setup failed for $repo, will retry next run" >&2
    fi
  fi
done

# --- org-level Actions secrets ----------------------------------------------
declare -A secrets=(
  [HARBOR_URL]="${harbor_url:-}" [HARBOR_USERNAME]="${harbor_username:-}"
  [HARBOR_PASSWORD]="${harbor_password:-}"
  [CLOUDFLARE_API_TOKEN]="${cloudflare_api_token:-}"
  [CLOUDFLARE_ACCOUNT_ID]="${cloudflare_account_id:-}"
)
for name in "${!secrets[@]}"; do
  [ -z "${secrets[$name]}" ] && { echo "skipping $name (no value collected)"; continue; }
  fj -X PUT "$API/orgs/$ORG/actions/secrets/$name" -d "{\"data\":\"${secrets[$name]}\"}" >/dev/null
done
echo "actions secrets set"
echo "done"
