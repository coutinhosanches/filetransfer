#!/bin/bash
#
# soma_fitas_db.sh
#
# Consolida a ocupação por Fita (Barcode) e Banco de Dados (Database).

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

# Criar arquivos temporários para ambos os comandos
TMP_LSVOL="$(mktemp)"
TMP_LSPIECE="$(mktemp)"

# Garantir a remoção dos arquivos temporários ao sair do script
trap 'rm -f "$TMP_LSVOL" "$TMP_LSPIECE"' EXIT

# 1. Executa obtool lsvol e grava direto no arquivo
obtool lsvol --barcode "$BARCODES" --contents > "$TMP_LSVOL" 2>/dev/null

if [[ ! -s "$TMP_LSVOL" ]]; then
    echo "ERRO: Nenhum dado retornado pelo obtool lsvol." >&2
    exit 1
fi

# Extrai os Volume IDs (VID) encontrados no lsvol
VIDS="$(awk '$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && $4 !~ /^[0-9]+$/ {print $4}' "$TMP_LSVOL" | sort -u)"

# 2. Executa o lspiece salvando direto no arquivo temporário
for vid in $VIDS; do
    obtool lspiece --vid "$vid" --section --long >> "$TMP_LSPIECE" 2>/dev/null
done

# 3. Processa os dois arquivos sequencialmente no AWK
awk '
# Trecho 1: Processa o arquivo TMP_LSPIECE
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

# Trecho 2: Processa o arquivo TMP_LSVOL
# Identifica o cabeçalho do Volume/Fita
$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && $4 !~ /^[0-9]+$/ && $5 !~ /^[0-9]+$/ {
    current_tape = $5
    next
}

# Identifica linha de conteúdo (peça)
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

    # Acumula por Fita + Database
    tape_db_bytes[current_tape, db_name] += bytes
    tape_db_objs[current_tape, db_name]++

    # Acumula total por Fita
    tape_bytes[current_tape] += bytes
    tape_objs[current_tape]++

    # Acumula Total Geral
    grand_bytes += bytes
    grand_objs++

    tapes[current_tape] = 1
    dbs[db_name] = 1
}

END {
    printf "\n%-15s %-20s %10s %14s %12s\n", "BARCODE", "DATABASE", "OBJETOS", "GB", "TB"
    print "--------------------------------------------------------------------------"

    for (t in tapes) {
        for (d in dbs) {
            if ((t, d) in tape_db_bytes) {
                printf "%-15s %-20s %10d %14.2f %12.2f\n",
                       t,
                       d,
                       tape_db_objs[t, d],
                       tape_db_bytes[t, d] / 1024^3,
                       tape_db_bytes[t, d] / 1024^4
            }
        }
        print "--------------------------------------------------------------------------"
        printf "%-15s %-20s %10d %14.2f %12.2f\n",
               t, "SUBTOTAL", tape_objs[t], tape_bytes[t] / 1024^3, tape_bytes[t] / 1024^4
        print "=========================================================================="
    }

    printf "%-15s %-20s %10d %14.2f %12.2f\n",
           "TOTAL GERAL", "-", grand_objs, grand_bytes / 1024^3, grand_bytes / 1024^4
    print "=========================================================================="
}
' "$TMP_LSPIECE" "$TMP_LSVOL"
