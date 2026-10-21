#!/bin/bash
# Regenerate src/swift/Sources/Studio/CatalogNames.swift from
# engine/contracts/command-catalog.v2.json so the command palette
# cannot drift from the real catalog.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="src/swift/Sources/Studio/CatalogNames.swift"

python3 -c "
import json
with open('engine/contracts/command-catalog.v2.json') as f:
    cat = json.load(f)
names = [c['name'] for c in cat['commands']]
lines = ['/// Auto-generated from command-catalog.v2.json.',
'/// Do not edit by hand.',
'/// Run scripts/generate-catalog-names.sh to regenerate.',
'',
'enum CatalogNames {',
'    static let names: [String] = [']
for n in names:
    lines.append(f'        \"{n}\",')
lines.append('    ]')
lines.append('}')
lines.append('')
outpath = '${OUT}'
with open(outpath, 'w') as out:
    out.write('\n'.join(lines) + '\n')
print(f'Regenerated {outpath} ({len(names)} names)')
"