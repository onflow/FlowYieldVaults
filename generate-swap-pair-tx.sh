#!/bin/bash

TEMPLATE="./cadence/contracts/mocks/SwapPairTemplate.cdc"
OUTPUT="./cadence/contracts/mocks/SwapPair.cdc"

TX="./cadence/transactions/mocks/amm/setup.cdc"

jq -r '
  (.contracts, .dependencies)
  | to_entries[]
  | select(.value.aliases.emulator != null)
  | "\(.key) 0x\(.value.aliases.emulator|sub("^0x";""))"
' flow.json > contracts_map.txt

cp "$TEMPLATE" "$OUTPUT"

while read name address; do
	sed -i '' -E "s|^[[:space:]]*import[[:space:]]+\"${name}\"[[:space:]]*;?[[:space:]]*$|import ${name} from ${address}|g" "$OUTPUT"
done < contracts_map.txt

HEX_STRING=$(xxd -p "$OUTPUT" | tr -d '\n')

sed -i '' -E "s|^[[:space:]]*let swapPairTemplateCode[[:space:]]*=[[:space:]]*\"[^\"]*\"|        let swapPairTemplateCode = \"${HEX_STRING}\"|" $TX

