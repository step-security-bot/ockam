
#!/bin/bash
checks=()
while read line
do
    cd "implementations/rust/ockam/$line";

    ln -s ../../release.toml release.toml;

    cd "../../../../";
done < <(ls "implementations/rust/ockam")

echo "\n\n\n"
for d in "${checks[@]}"; do
    echo "$d";
done