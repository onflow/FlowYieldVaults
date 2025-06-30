#!/bin/bash

# Script to clean test logs by removing ANSI codes and timestamp prefixes
# Usage: ./clean_logs.sh [input_file] [output_file]

INPUT_FILE="${1:-fresh_test_output.log}"
OUTPUT_FILE="${2:-clean_test_output.log}"

# Clean the logs:
# 1. Remove ANSI color codes
# 2. Remove timestamp prefixes like "3:35PM INF LOG: "
# 3. Remove the quotes around log messages
# 4. Preserve the structure and indentation
# 5. Convert Unicode escape sequences to plain text

sed -E \
    -e 's/\x1b\[[0-9;]*m//g' \
    -e 's/^[0-9]+:[0-9]+[AP]M [A-Z]+ LOG: "(.*)"/\1/g' \
    -e 's/^[0-9]+:[0-9]+[AP]M [A-Z]+ LOG: //g' \
    -e 's/\\u\{2501\}/-/g' \
    -e 's/\\u\{2192\}/->/g' \
    -e 's/\\u\{2550\}/=/g' \
    -e 's/\\u\{255[0-9a-f]\}/+/g' \
    -e 's/\\u\{251[0-9a-f]\}/|/g' \
    -e 's/\\u\{[0-9a-f]+\}/?/g' \
    "$INPUT_FILE" > "$OUTPUT_FILE"

echo "Cleaned log saved to: $OUTPUT_FILE"
echo "Original file size: $(wc -c < "$INPUT_FILE") bytes"
echo "Cleaned file size: $(wc -c < "$OUTPUT_FILE") bytes" 