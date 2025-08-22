#!/bin/bash

TEMPLATE="./cadence/contracts/mocks/incrementfi/SwapPairTemplate.cdc"
OUTPUT="./cadence/contracts/mocks/incrementfi/SwapPair.cdc"

jq -r '
  (.contracts, .dependencies)
  | to_entries[]
  | select(.value.aliases.emulator != null)
  | "\(.key) 0x\(.value.aliases.emulator|sub("^0x";""))"
' flow.json > contracts_map.txt

cp "$TEMPLATE" "$OUTPUT"
cat $OUTPUT

while read name address; do
  sed -i '' -E "s|^[[:space:]]*import[[:space:]]+\"${name}\"[[:space:]]*;?[[:space:]]*$|import ${name} from ${address}|g" "$OUTPUT"
done < contracts_map.txt

# Generate hex string
xxd -p "$OUTPUT" | tr -d '\n'

