#!/usr/bin/env bash

val=$(eval "cargo metadata --no-deps | jq '[.packages[] | {name: .name, version: .version, release: .metadata.release.release}]'")
length=$(eval "echo '$val' | jq '. | length' ")
echo "$length"
length=$(eval "echo '$val' | jq '. | length' ")

for (( c=0; c<$length; c++ ))
  do 
    repo_name=$(eval "echo '$val' | jq '.[$c].name' | tr -d '\"' ")
    release=$(eval "echo '$val' | jq '.[$c].release' ")
    version=$(eval "echo '$val' | jq '.[$c].version' | tr -d '\"' ")
    if $release == true; then
        (
            cd ~/vendor;
            echo "https://static.crates.io/crates/${repo_name}/${repo_name}-${version}.crate"
            if curl "https://static.crates.io/crates/${repo_name}/${repo_name}-${version}.crate" --output "${repo_name}-${version}.crate"; then
                echo "Downloaded $repo_name"
            else
                echo "Error downloading $repo_name"
            fi
        )
    fi
done
