#!/bin/bash
#
# soma_fitas_db.sh
#
# Consolida a ocupação por Banco de Dados (Database) e Fita (Barcode).

set -u
set -o pipefail

SCRIPT_NAME="$(basename "$0")"

usage() {
    cat <<EOF
Uso:
  $SCRIPT_NAME BARCODE[,BARCODE,...]
  $SCRIPT_NAME BARCODE BARCODE ...

Exemplos:
  $SCRIPT_NAME PS0157,PS0184
  $SCRIPT_NAME PS0157 PS0184 PS0185
EOF
}

if [[ $# -eq 0 ]]; then
    usage
    exit 1
fi

case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
esac

BARCODES=""
for arg in "$@"; do
    if [[ -n "$BARCODES" ]]; then
        BARCODES="${BARCODES},${arg}"
    else
        BARCODES="${arg}"
    fi
done

BARCODES="$(printf '%s\n' "$BARCODES" | tr -d '[:space:]')"

if [[ -z "$BARCODES" ]]; then
    echo "ERRO: nenhum barcode informado." >&2
    exit 1
fi

if ! command -v obtool >/dev/null 2>&1; then
    echo "ERRO: comando 'obtool' não encontrado no PATH." >&2
    exit 127
fi

echo "=========================================================================="
echo " Coletando informações de volumes e peças de backup..."
echo "=========================================================================="

TMP_LSVOL="$(mktemp)"
TMP_LSPIECE="$(mktemp)"

trap 'rm -f "$TMP_LSVOL" "$TMP_LSPIECE"' EXIT

# 1. Executa obtool lsvol
obtool lsvol --barcode "$BARCODES" --contents > "$TMP_LSVOL" 2>/dev/null

if [[ ! -s "$TMP_LSVOL" ]]; then
    echo "ERRO: Nenhum dado retornado pelo obtool lsvol." >&2
    exit 1
fi

# Extrai os Volume IDs (VID)
VIDS="$(awk '$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && $4 !~ /^[0-9]+$/ {print $4}' "$TMP_LSVOL" | sort -u)"

# 2. Executa obtool lspiece
for vid in $VIDS; do
    obtool lspiece --vid "$vid" --section --long >> "$TMP_LSPIECE" 2>/dev/null
done

# 3. Processa e gera saída formatada para ordenação
awk '
FILENAME == ARGV[1] {
    if ($0 ~ /^[[:space:]]*Database:[[:space:]]*/) {
        curr_db = $0
        sub(/^[[:space:]]*Database:[[:space:]]*/, "", curr_db)
        gsub(/[[:space:]]+$/, "", curr_db)
    }
    else if ($0 ~ /^[[:space:]]*BSOID:[[:space:]]*/) {
        bsoid = $0
        sub(/^[[:space:]]*BSOID:[[:space:]]*/, "", bsoid)
        gsub(/[[:space:]]+$/, "", bsoid)
        if (bsoid != "") {
            bsoid_to_db[bsoid] = curr_db
        }
    }
    next
}

$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && $4 !~ /^[0-9]+$/ && $5 !~ /^[0-9]+$/ {
    current_tape = $5
    next
}

$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/ && $6 ~ /^[0-9]+([.,][0-9]+)?$/ {
    bsoid = $1
    value = $6
    unit = toupper($7)
    gsub(",", ".", value)

    bytes = 0
    if (unit ~ /^(B|BYTE|BYTES)$/) bytes = value
    else if (unit ~ /^(K|KB|KBYTE|KBYTES|KG|KIB)$/) bytes = value * 1024
    else if (unit ~ /^(M|MB|MBYTE|MBYTES|MIB)$/) bytes = value * 1024^2
    else if (unit ~ /^(G|GB|GBYTE|GBYTES|GIB)$/) bytes = value * 1024^3
    else if (unit ~ /^(T|TB|TBYTE|TBYTES|TIB)$/) bytes = value * 1024^4
    else next

    db_name = (bsoid in bsoid_to_db) ? bsoid_to_db[bsoid] : "OUTROS/SISTEMA"

    db_tape_bytes[db_name, current_tape] += bytes
    db_tape_objs[db_name, current_tape]++

    grand_bytes += bytes
    grand_objs++

    dbs[db_name] = 1
    tapes[current_tape] = 1
}

END {
    for (d in dbs) {
        for (t in tapes) {
            if ((d, t) in db_tape_bytes) {
                # Imprime linhas brutas delimitadas por ponto e vírgula para fácil ordenação
                printf "%s;%s;%d;%.2f;%.2f\n",
                       d,
                       t,
                       db_tape_objs[d, t],
                       db_tape_bytes[d, t] / 1024^3,
                       db_tape_bytes[d, t] / 1024^4
            }
        }
    }
    # Imprime Total Geral na última linha com prefixo especial
    printf "___TOTAL___;-;%d;%.2f;%.2f\n", grand_objs, grand_bytes / 1024^3, grand_bytes / 1024^4
}
' "$TMP_LSPIECE" "$TMP_LSVOL" | sort -t';' -k1,1 -k2,2 | awk -F';' '
BEGIN {
    printf "\n%-20s %-15s %10s %14s %12s\n", "DATABASE", "BARCODE", "OBJETOS", "GB", "TB"
    print "--------------------------------------------------------------------------"
    curr_db = ""
    db_objs = 0
    db_bytes_gb = 0
    db_bytes_tb = 0
}

{
    if ($1 == "___TOTAL___") {
        if (curr_db != "") {
            print "--------------------------------------------------------------------------"
            printf "%-20s %-15s %10d %14.2f %12.2f\n", curr_db, "SUBTOTAL", db_objs, db_bytes_gb, db_bytes_tb
            print "=========================================================================="
        }
        printf "%-20s %-15s %10d %14.2f %12.2f\n", "TOTAL GERAL", "-", $3, $4, $5
        print "=========================================================================="
        next
    }

    if (curr_db != "" && curr_db != $1) {
        print "--------------------------------------------------------------------------"
        printf "%-20s %-15s %10d %14.2f %12.2f\n", curr_db, "SUBTOTAL", db_objs, db_bytes_gb, db_bytes_tb
        print "=========================================================================="
        db_objs = 0
        db_bytes_gb = 0
        db_bytes_tb = 0
    }

    curr_db = $1
    db_objs += $3
    db_bytes_gb += $4
    db_bytes_tb += $5

    printf "%-20s %-15s %10d %14.2f %12.2f\n", $1, $2, $3, $4, $5
}
'
