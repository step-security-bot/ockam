#!/usr/bin/env bash

crates_to_be_excluded=();

val=$(eval "cargo metadata --no-deps | jq '[.packages[] | {name: .name, version: .version, release: .metadata.release.release, path: .manifest_path}]'");
length=$(eval "echo '$val' | jq '. | length' ");
echo "$length";


last_git_tag=$(git describe --tags --abbrev=0);
echo "$last_git_tag";

function is_folder_updated(){
    cd "$1";

    updated=1;
    git diff $last_git_tag --quiet --name-status -- ./src || updated=0;

    # Check if Cargo.toml was changed.
    if [[ $updated == 1 ]]; then
        git diff $last_git_tag --quiet --name-status -- ./Cargo.toml || updated=0;
    fi

    echo $updated
}

# Check crates to be excluded.
for (( c=0; c<$length; c++ )); do
    repo_name=$(eval "echo '$val' | jq '.[$c].name' | tr -d '\"' ");
    release=$(eval "echo '$val' | jq '.[$c].release' ");
    version=$(eval "echo '$val' | jq '.[$c].version' | tr -d '\"' ");
    path=$(eval "echo '$val' | jq '.[$c].path' | sed 's/\/Cargo.toml//' | tr -d '\"'");
    # Check if said crate is has recently been updated compared to the last tag.
    if $release == true; then
        is_crate_updated="$(is_folder_updated $path)";

        if [[ $is_crate_updated == 1 ]]; then
            crates_to_be_excluded=(${crates_to_be_excluded[@]}, $repo_name);
        fi
    fi
done

exclude_string="--exclude ockam";

for crate in ${crates_to_be_excluded[@]}; do
    exclude_string="${exclude_string[@]} --exclude $crate";
done

# Bump all crates and publish them.
cargo release minor --no-tag --no-dev-version $exclude_string --token nnn --execute;
