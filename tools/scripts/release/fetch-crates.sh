#!/usr/bin/env bash

while read line
do
    (
        cd "implementations/rust/ockam/$line";
        rm -rf release.toml
    )
done < <(ls "implementations/rust/ockam")