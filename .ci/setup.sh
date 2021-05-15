#!/bin/bash
set -xou pipefail

grep -E ' $' -n -r . --include=*.{hs,hs-boot,sh} --exclude-dir=dist-newstyle
if [[ $? == 0 ]]; then
    echo "EOL whitespace detected. See ^"
    exit 1;
fi

set -e

# Check whether version numbers in snap / clash-{prelude,lib,ghc} are the same
cabal_files="clash-prelude/clash-prelude.cabal clash-lib/clash-lib.cabal clash-ghc/clash-ghc.cabal clash-cores/clash-cores.cabal"
snapcraft_file=".ci/bindist/linux/snap/snap/snapcraft.yaml"
versions=$(grep "^[vV]ersion" $cabal_files $snapcraft_file | grep -Eo '[0-9]+(\.[0-9]+)+')

if [[ $(echo $versions | tr ' ' '\n' | wc -l) == 5 ]]; then
    if [[ $(echo $versions | tr ' ' '\n' | uniq | wc -l) != 1 ]]; then
        echo "Expected all distributions to have the same version number. Found: $versions"
        exit 1;
    fi
else
    echo "Expected to find version number in all distributions. Found: $versions";
    exit 1;
fi

# You'd think comparing v${version} with ${CI_COMMIT_TAG} would do the
# trick, but no..
CI_COMMIT_TAG=${CI_COMMIT_TAG:-}
version=$(echo $versions | tr ' ' '\n' | head -n 1)
tag_version=${CI_COMMIT_TAG:1:${#CI_COMMIT_TAG}-1}  # Strip first character (v0.99 -> 0.99)

if [[ ${tag_version} != "" && ${version} != ${tag_version} ]]; then
    if [[ "${CI_COMMIT_TAG:0:1}" == "v" ]]; then
        echo "Tag name and distribution's release number should match:"
        echo "  Tag version:          ${CI_COMMIT_TAG}"
        echo "  Distribution version: v${version}"
        exit 1;
    else
        echo "\$CI_COMMIT_TAG should start with a 'v'. Found: ${CI_COMMIT_TAG}"
        exit 1;
    fi
fi

# Print out versions for debugging purposes
cabal --version
ghc --version

# This might happen when running on Circle CI or during tags
CI_COMMIT_BRANCH=${CI_COMMIT_BRANCH:-no_branch_set_by_ci}

# File may exist as part of a dist.tar.zst
if [ ! -f cabal.project.local ]; then
  cp .ci/cabal.project.local .

  MULTIPLE_HIDDEN=${MULTIPLE_HIDDEN:-yes}
  if [[ "$MULTIPLE_HIDDEN" == "yes" ]]; then
    sed -i 's/flags: +doctests/flags: +doctests +multiple-hidden/g' cabal.project.local
  elif [[ "$MULTIPLE_HIDDEN" == "no" ]]; then
    sed -i 's/flags: +doctests/flags: +doctests -multiple-hidden/g' cabal.project.local
  fi

  if [[ "$CI_COMMIT_BRANCH" =~ "^partial-evaluator-" ]]; then
    sed -i 's/-experimental-evaluator/+experimental-evaluator/g' cabal.project.local
  fi

  set +u
  if [[ "$GHC_HEAD" == "yes" ]]; then
    cat .ci/cabal.project.local.append-HEAD >> cabal.project.local
  fi
  set -u

  # Fix index-state to prevent rebuilds if Hackage changes between build -> test.
  sed -i "s/HEAD/$(date -u +%FT%TZ)/g" cabal.project.local
fi

cat cabal.project.local

rm -f ${HOME}/.cabal/config
cabal user-config init
sed -i "s/-- ghc-options:/ghc-options: -j$THREADS/g" ${HOME}/.cabal/config
sed -i "s/^[- ]*jobs:.*/jobs: $CABAL_JOBS/g" ${HOME}/.cabal/config
sed -i "/remote-repo-cache:.*/d" ${HOME}/.cabal/config
cat ${HOME}/.cabal/config

set +u

# run v2-update first to generate the cabal config file that we can then modify
# retry 5 times, as hackage servers are not perfectly reliable
NEXT_WAIT_TIME=0
until cabal v2-update || [ $NEXT_WAIT_TIME -eq 5 ]; do
  sleep $(( NEXT_WAIT_TIME++ ))
done
