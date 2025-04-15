#!/bin/bash

set -e

##############
# PARAMETERS #
##############
contract_folder=$1/kani_verify_std/target/x86_64-unknown-linux-gnu/debug/deps
supported_regex=$2
unsupported_regex=neg

goto_transcoder_git=https://github.com/rafaelsamenezes/goto-transcoder
esbmc_url=https://github.com/esbmc/esbmc/releases/download/nightly-7867f5e5595b9e181cd36eb9155d1905f87ad241/esbmc-linux.zip

##########
# SCRIPT #
##########

echo "Checking contracts with goto-transcoder"

if [ ! -d "goto-transcoder" ]; then
    echo "goto-transcoder not found. Downloading..."
    git clone $goto_transcoder_git
    cd goto-transcoder
    wget $esbmc_url
    unzip esbmc-linux.zip
    chmod +x ./linux-release/bin/esbmc
    cd ..
fi

ls $contract_folder | grep "$supported_regex" | grep -v .symtab.out > ./goto-transcoder/_contracts.txt

cd goto-transcoder
while IFS= read -r line; do
    # I expect each line to be similar to 'core-58cefd8dce4133f9__RNvNtNtCs9uKEoH8KKW4_4core3num6verify24checked_unchecked_add_i8.out'
    # The entrypoint of the contract would be _RNvNtNtCs9uKEoH8KKW4_4core3num6verify24checked_unchecked_add_i8
    # So we use awk to extract this name.
    contract=`echo "$line" | awk '{match($0, /(_RNv.*).out/, arr); print arr[1]}'`
    echo "Processing: $contract"
    if [[ -z "$contract" ]]; then
        continue
    fi
    if echo "$contract" | grep -q "$unsupported_regex"; then
        continue
    fi
    echo "$contract" >> _verified.txt
    echo "Running: goto-transcoder $contract $contract_folder/$line $contract.esbmc.goto"
    cargo run cbmc2esbmc $contract ../$contract_folder/$line $contract.esbmc.goto
    ./linux-release/bin/esbmc --binary $contract.esbmc.goto
done < "_contracts.txt"

echo "Entrypoints"
cat _contracts.txt
echo "Supported"
cat _verified.txt

rm _contracts.txt
rm _verified.txt
cd ..
